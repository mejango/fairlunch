import { payIntent } from '@bananapus/nana-sdk-core/review'
import type { Address } from 'viem'
import type { TxRequest } from '@/hooks/useSafeTx'

/** A write's hold key, from the SDK's intent builders. A pay is keyed by project and beneficiary; every other Fair
 * Lunch write (create, serve, burn, collect, send home) is held by its exact call. */
export function holdIntent(request: Pick<TxRequest, 'chainId' | 'functionName' | 'args'>, _account: Address): string | undefined {
  if (request.functionName !== 'pay') return undefined
  return payIntent({ chainId: request.chainId, project: request.args[0] as bigint, beneficiary: request.args[3] as Address })
}
