// Who may PUBLISH audio into a PK battle's shared channel ("pk-<battleId>"). Kept apart from index.ts (which imports Deno modules) so
// Node's test runner can check the rule: scripts/test_functions.sh.

export type BattleRow = {
  host_a_id: string;
  host_b_id: string;
  status: string;
  stream_a_id: string;
  stream_b_id: string;
  /** 'invite' / 'random' for a battle made by the PK battle layer; null for a legacy PK-mode battle. */
  source: string | null;
};

/**
 * - only while the battle is live;
 * - the two hosts always;
 * - for a battle made by the PK layer (it has a source) also anyone who holds a seat in either of the two lives: the guests of both
 *   rooms keep talking when everybody moves to the shared channel. A legacy battle keeps the old rule (the two hosts only).
 */
export function mayPublishToBattle(battle: BattleRow | null, userId: string, seatedStreamIds: string[]): boolean {
  if (!battle || battle.status !== "live") return false;
  if (battle.host_a_id === userId || battle.host_b_id === userId) return true;
  if (battle.source == null) return false;
  return seatedStreamIds.includes(battle.stream_a_id) || seatedStreamIds.includes(battle.stream_b_id);
}
