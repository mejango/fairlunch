/** Where a lunch is. `empty` is past its deadline with nothing raised: it can never be served. */
export type Phase = 'cooking' | 'ready' | 'empty' | 'resting' | 'eating'

/** Buybacks wait this long after `serve`, while the pool's price average builds. */
export const REST_SECONDS = 30 * 60

export const PHASE_LABEL: Record<Phase, string> = {
  cooking: '🧑‍🍳 Cooking',
  ready: '🍽️ Ready to serve',
  empty: '🫙 Nobody came',
  resting: '🍽️ Served',
  eating: '🔥 Eating',
}

export function phaseOf(lunch: { deadline: number; servedAt: number }, raised: bigint, now: number): Phase {
  if (lunch.servedAt) return now < lunch.servedAt + REST_SECONDS ? 'resting' : 'eating'
  if (now <= lunch.deadline) return 'cooking'
  return raised > 0n ? 'ready' : 'empty'
}

/** "3d 4h", "4h 12m", "12m 5s", "5s". */
export function countdown(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds))
  const parts: [number, string][] = [[Math.floor(s / 86400), 'd'], [Math.floor(s / 3600) % 24, 'h'], [Math.floor(s / 60) % 60, 'm'], [s % 60, 's']]
  const first = parts.findIndex(([value]) => value > 0)
  return first < 0 ? '0s' : parts.slice(first, first + 2).map(([value, unit]) => `${value}${unit}`).join(' ')
}
