#!/usr/bin/env bash
# Pre-push backup of the LINKED Supabase project (production).
#
# Run this before every `supabase db push` (the free plan has no automatic backups). Takes about 10 minutes.
# It only READS. It needs the Supabase CLI logged in and linked, plus jq and gzip; it does
# NOT need Docker or the database password (it goes through `supabase db query --linked`).
#
# What you get, in $SABALIVE_BACKUP_DIR (default ~/sabalive-backups)/<UTC time>/ :
#   data/<schema>.<table>.json.gz   every row of every public table, plus auth.users,
#                                   auth.identities and the migration history
#   schema/*.json, functions.sql    live functions, policies, triggers, columns, cron jobs: a
#                                   snapshot of what production really contains (compare with git
#                                   to spot changes made by hand)
#   storage-objects.json            names and sizes of uploaded media (not the files)
#   MANIFEST.txt                    row counts per table, checked against the database
#
# The folder holds user data (emails, wallets, chats). It is created private (700) and kept
# OUTSIDE the repo. Never commit it, never share it.
#
# Restoring: the data is plain JSON rows. Tables and functions come from the migrations in git;
# schema/functions.sql shows what the live functions looked like.
set -euo pipefail

cd "$(dirname "$0")/../.."    # the sabalive/ app repo (where supabase/ lives)

command -v supabase >/dev/null || { echo "supabase CLI not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found (brew install jq)"; exit 2; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ROOT="${SABALIVE_BACKUP_DIR:-$HOME/sabalive-backups}"
OUT="$ROOT/$STAMP"
PAGE=10000

umask 077
mkdir -p "$OUT/data" "$OUT/schema"
echo "Backing up the linked project to $OUT"

# run SQL, print only the rows array (stderr, with the CLI's progress and update notices, is dropped)
rows() { supabase db query --linked -o json "$1" 2>/dev/null | jq -c '.rows'; }

PROJECT=$(cat supabase/.temp/project-ref 2>/dev/null || echo "unknown")
echo "Project ref: $PROJECT"
echo "$PROJECT" > "$OUT/PROJECT_REF"

# ---- 1. which tables
TABLES=$(rows "select table_schema || '.' || table_name as t from information_schema.tables
  where table_type = 'BASE TABLE' and table_schema = 'public'
  union select 'auth.users' union select 'auth.identities' union select 'supabase_migrations.schema_migrations'
  order by 1" | jq -r '.[].t')
NTABLES=$(echo "$TABLES" | wc -l | tr -d ' ')
echo "Tables to export: $NTABLES"

# ---- 2. expected row counts (one query), to check each export against
COUNT_SQL=$(echo "$TABLES" | awk 'BEGIN{ORS=""} {if (NR>1) print " union all "; print "select '\''" $0 "'\'' as t, count(*) as n from " $0}')
rows "$COUNT_SQL" > "$OUT/counts.json"

# ---- 3. the data, one table at a time, paged for the large ones
TOTAL_ROWS=0
FAILED=0
: > "$OUT/MANIFEST.txt"
for T in $TABLES; do
  EXPECT=$(jq -r --arg t "$T" '.[] | select(.t == $t) | .n' "$OUT/counts.json")
  FILE="$OUT/data/$T.json.gz"
  if [ "${EXPECT:-0}" -eq 0 ]; then
    echo "[]" | gzip > "$FILE"
    printf '%-60s %8s rows (empty)\n' "$T" 0 >> "$OUT/MANIFEST.txt"
    continue
  fi
  TMP=$(mktemp)
  OFFSET=0
  while [ "$OFFSET" -lt "$EXPECT" ]; do
    rows "select to_jsonb(x) as r from (select * from $T order by ctid limit $PAGE offset $OFFSET) x" \
      | jq -c '.[].r' >> "$TMP"
    OFFSET=$((OFFSET + PAGE))
  done
  GOT=$(wc -l < "$TMP" | tr -d ' ')
  jq -s '.' "$TMP" | gzip > "$FILE"
  rm -f "$TMP"
  if [ "$GOT" -eq "$EXPECT" ]; then
    printf '%-60s %8s rows\n' "$T" "$GOT" >> "$OUT/MANIFEST.txt"
  else
    # rows can change while we read a live database; a small drift on a busy table is normal
    printf '%-60s %8s rows (database had %s when counted)\n' "$T" "$GOT" "$EXPECT" >> "$OUT/MANIFEST.txt"
    DIFF=$(( GOT > EXPECT ? GOT - EXPECT : EXPECT - GOT ))
    if [ "$DIFF" -gt $(( EXPECT / 20 + 20 )) ]; then
      echo "  !! $T: exported $GOT rows but expected $EXPECT"
      FAILED=1
    fi
  fi
  TOTAL_ROWS=$((TOTAL_ROWS + GOT))
done

# ---- 4. a snapshot of what production really contains
rows "select n.nspname as schema, p.proname as name, pg_get_function_identity_arguments(p.oid) as args,
        pg_get_functiondef(p.oid) as def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prokind in ('f', 'p') order by 1, 2, 3" > "$OUT/schema/functions.json"
jq -r '.[] | .def + ";\n"' "$OUT/schema/functions.json" > "$OUT/schema/functions.sql"
rows "select schemaname, tablename, policyname, cmd, roles, qual, with_check from pg_policies
      where schemaname = 'public' order by 1, 2, 3" > "$OUT/schema/policies.json"
rows "select c.relname as tbl, pg_get_triggerdef(t.oid) as def from pg_trigger t
      join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
      where not t.tgisinternal and n.nspname = 'public' order by 1, 2" > "$OUT/schema/triggers.json"
rows "select table_name, column_name, data_type, is_nullable, column_default from information_schema.columns
      where table_schema = 'public' order by table_name, ordinal_position" > "$OUT/schema/columns.json"
rows "select jobid, jobname, schedule, command, active from cron.job order by jobid" > "$OUT/schema/cron_jobs.json" || true
rows "select bucket_id, name, (metadata->>'size')::bigint as bytes from storage.objects order by 1, 2" \
  > "$OUT/storage-objects.json" || true
supabase migration list --linked > "$OUT/migrations.txt" 2>/dev/null || true

# ---- 5. checksums and a verdict
( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS )
SIZE=$(du -sh "$OUT" | cut -f1)
chmod -R go-rwx "$OUT"
echo
if [ "$FAILED" -eq 0 ]; then
  echo "BACKUP OK: $NTABLES tables, $TOTAL_ROWS rows, $SIZE  ->  $OUT"
  echo "Copy it somewhere safe (not into the repo). Then you can push."
else
  echo "BACKUP INCOMPLETE: see the lines marked !! above and $OUT/MANIFEST.txt. Do NOT push yet."
  exit 1
fi
