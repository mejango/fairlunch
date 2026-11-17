import { bendystraw } from '@/lib/bendystraw'
import { PRODUCTION_CHAINS, TESTNET_CHAINS } from '@/lib/chains'
import { jbCenterPublicClient } from '@/lib/jbcenter-rpc'
import { fairLunchAbi } from './abi'
import { deploymentOn } from './deployments'
import type { PublicClient } from 'viem'
import { readClock, readLunch, readMoney } from './reads'

/** A lunch as the home page lists it. Server only: Bendystraw is read here and nowhere in the browser. */
export type ListedLunch = {
  chainId: number; projectId: number; name: string | null; symbol: string | null; logoUri: string | null
  /** Everything ever paid in, in the money's smallest unit. */
  paidIn: string; deadline: number; servedAt: number
  /** What the lunch raises. */
  money: { symbol: string; decimals: number }
  /** The pool's price in money per token, once served and readable. */
  price: number | null
}

const LIST = `query FairLunches($owners: [String!]) {
  projects(where: { owner_in: $owners, version: 6 }, orderBy: "createdAt", orderDirection: "desc", limit: 200) {
    items { chainId projectId name tokenSymbol logoUri volume }
  }
}`

type Row = { chainId: number; projectId: number; name: string | null; tokenSymbol: string | null; logoUri: string | null; volume: string }

/** ponytail: the newest 200 projects Fair Lunch owns, copies included. Page through the index when there are more.
 * Every lunch on its host chain, newest first. The index finds the projects Fair Lunch owns; the contract says which
 * chain hosts each and where it is in its life. */
export function listLunches(network: 'mainnet' | 'testnet'): Promise<ListedLunch[]> {
  const kept = lists.get(network)
  if (kept && Date.now() - kept.at < LIST_KEPT_MS) return kept.list
  const list = readList(network)
  lists.set(network, { at: Date.now(), list })
  // A list that failed is read again by the next visit.
  list.catch(() => { if (lists.get(network)?.list === list) lists.delete(network) })
  return list
}

/** How long the server answers every visit with one read of the list. The home page has no poll on top of it. */
const LIST_KEPT_MS = 30_000
const lists = new Map<string, { at: number; list: Promise<ListedLunch[]> }>()

async function readList(network: 'mainnet' | 'testnet'): Promise<ListedLunch[]> {
  const chains = (network === 'mainnet' ? PRODUCTION_CHAINS : TESTNET_CHAINS).filter(chain => deploymentOn(chain.id))
  const owners = [...new Set(chains.map(chain => deploymentOn(chain.id)!.address.toLowerCase()))]
  if (!owners.length) return []
  const { projects } = await bendystraw<{ projects: { items: Row[] } }>(LIST, { owners }, { network, policy: 'no-store' })
  const listed = await Promise.all(projects.items.map(async row => {
    const deployment = deploymentOn(row.chainId)
    if (!deployment) return null
    const record = await jbCenterPublicClient(row.chainId).readContract({
      address: deployment.address, abi: fairLunchAbi, functionName: 'recordOf', args: [BigInt(row.projectId)],
    }).catch(() => null)
    if (!record || Number(record.hostChainId) !== row.chainId) return null
    const { symbol, decimals } = await readMoney(jbCenterPublicClient(row.chainId) as PublicClient, record.token)
    const clock = await readClock(row.chainId, row.projectId)
    const price = clock.servedAt ? (await readLunch(row.chainId, row.projectId).catch(() => null))?.price ?? null : null
    return { chainId: row.chainId, projectId: row.projectId, name: row.name, symbol: row.tokenSymbol, logoUri: row.logoUri,
      paidIn: row.volume, deadline: clock.deadline, servedAt: clock.servedAt, money: { symbol, decimals }, price }
  }))
  return listed.filter(lunch => lunch !== null)
}

const PAGE = `query FairLunchPage($chainId: Int!, $projectId: Int!, $from: String!) {
  projects(where: { chainId: $chainId, projectId: $projectId, version: 6 }, limit: 1) { items { logoUri } }
  burnEvents(where: { chainId: $chainId, projectId: $projectId, version: 6, from: $from }, orderBy: "timestamp", orderDirection: "desc", limit: 500) {
    items { timestamp amount txHash }
  }
}`

/** What the index adds to a lunch's page, in one request: its logo, and the burns Fair Lunch made of its token, newest
 * first, for the chart's 🔥 marks and the burned total.
 * ponytail: the newest 500 burns. A lunch with more needs a summed field in the index. */
export async function indexedOf(chainId: number, projectId: number): Promise<{ logoUri: string | null; burns: { time: number; amount: string; txHash: string }[] }> {
  const deployment = deploymentOn(chainId)
  if (!deployment) return { logoUri: null, burns: [] }
  const { projects, burnEvents } = await bendystraw<{ projects: { items: { logoUri: string | null }[] }; burnEvents: { items: { timestamp: number; amount: string; txHash: string }[] } }>(
    PAGE, { chainId, projectId, from: deployment.address.toLowerCase() }, { chainId, policy: 'no-store' })
  return { logoUri: projects.items[0]?.logoUri ?? null, burns: burnEvents.items.map(({ timestamp, amount, txHash }) => ({ time: Number(timestamp), amount, txHash })) }
}
