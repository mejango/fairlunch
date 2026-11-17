import { isRateLimited } from '@bananapus/nana-sdk-core/jbcenter'
import type { DefaultOptions } from '@tanstack/react-query'

/** How often a page asks again for what can change while it is open and visible. */
export const POLL_MS = 30_000

/**
 * Every read's defaults. A read that has gone stale is asked again when its tab is looked at again: polls stop while
 * the tab is hidden. One failure is tried once more, except a rate limit's refusal, which another try only adds to.
 */
export const QUERY_DEFAULTS: DefaultOptions['queries'] = {
  staleTime: POLL_MS,
  gcTime: 10 * 60_000,
  retry: (failures, error) => failures < 1 && !isRateLimited(error),
  refetchOnWindowFocus: true,
}
