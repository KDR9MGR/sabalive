#!/usr/bin/env python3
"""Puts the User ID, the window and (for the undo) the pack file into one of the revert_user_gifts_*.sql files and prints the SQL.
Used by revert_user_gifts.sh and by scripts/db/tests/revert_user_gifts_test.sql, so both run exactly the same text.
usage: revert_user_gifts_fill.py <sql file> <User ID digits> <from> <to> [pack file]"""
import re
import sys

sql_file, uid, t_from, t_to = sys.argv[1:5]
pack_file = sys.argv[5] if len(sys.argv) > 5 else ""
ts = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\+00$")
if not re.fullmatch(r"\d{3,12}", uid) or not ts.match(t_from) or not ts.match(t_to):
    sys.exit("bad User ID or window")
sql = open(sql_file).read()
sql = sql.replace("__DISPLAY_ID__", uid).replace("__FROM__", t_from).replace("__TO__", t_to)
if "__PACK__" in sql:
    pack = open(pack_file).read().strip()
    if "$pack$" in pack:
        sys.exit("the pack contains the quote marker")
    sql = sql.replace("__PACK__", pack)
sys.stdout.write(sql)
