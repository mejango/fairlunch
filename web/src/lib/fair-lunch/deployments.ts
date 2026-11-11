import { getAddress, type Address } from 'viem'
import records from './deployments.json'

const RECORDS = records as Record<string, { address: Address }>
/** A local fork's FairLunch, for chains the record doesn't cover yet. */
const ENV_ADDRESS = process.env.NEXT_PUBLIC_FAIR_LUNCH_ADDRESS ? getAddress(process.env.NEXT_PUBLIC_FAIR_LUNCH_ADDRESS) : null

/** Where FairLunch is on a chain, or null when it isn't deployed there. */
export function deploymentOn(chainId: number): { address: Address } | null {
  return RECORDS[String(chainId)] ?? (ENV_ADDRESS ? { address: ENV_ADDRESS } : null)
}
