import { bendystraw } from '@/lib/bendystraw'
import { PRODUCTION_CHAINS, TESTNET_CHAINS } from '@/lib/chains'
import { jbCenterPublicClient } from '@/lib/jbcenter-rpc'
import { fairLunchAbi } from './abi'
import { deploymentOn } from './deployments'

/** A lunch as the home page lists it. Server only: Bendystraw is read here and nowhere in the browser. */
export type ListedLunch = {
  chainId: number; projectId: number; name: string | null; symbol: string | null; logoUri: string | null
  /** Everything ever paid in, in wei. */
  paidIn: string; deadline: number; servedAt: number
}

const LIST = `query FairLunches($owners: [String!]) {
  projects(where: { owner_in: $owners, version: 6 }, orderBy: "createdAt", orderDirection: "desc", limit: 200) {
    items { chainId projectId name tokenSymbol logoUri volume }
  }
}`

type Row = { chainId: number; projectId: number; name: string | null; tokenSymbol: string | null; logoUri: string | null; volume: string }

/** Every lunch on its host chain, newest first. The index finds the projects Fair Lunch owns; the contract says which
 * chain hosts each and where it is in its life. */
export async function listLunches(network: 'mainnet' | 'testnet'): Promise<ListedLunch[]> {
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
    return { chainId: row.chainId, projectId: row.projectId, name: row.name, symbol: row.tokenSymbol, logoUri: row.logoUri,
      paidIn: row.volume, deadline: record.deadline, servedAt: record.servedAt }
  }))
  return listed.filter(lunch => lunch !== null)
}

const BURNS = `query FairLunchBurns($chainId: Int!, $projectId: Int!, $from: String!) {
  burnEvents(where: { chainId: $chainId, projectId: $projectId, version: 6, from: $from }, orderBy: "timestamp", orderDirection: "desc", limit: 500) {
    items { timestamp amount txHash }
  }
}`

/** The burns Fair Lunch made of a lunch's token, newest first: the chart's 🔥 marks. */
export async function burnsOf(chainId: number, projectId: number): Promise<{ time: number; amount: string; txHash: string }[]> {
  const deployment = deploymentOn(chainId)
  if (!deployment) return []
  const { burnEvents } = await bendystraw<{ burnEvents: { items: { timestamp: number; amount: string; txHash: string }[] } }>(
    BURNS, { chainId, projectId, from: deployment.address.toLowerCase() }, { chainId, policy: 'no-store' })
  return burnEvents.items.map(({ timestamp, amount, txHash }) => ({ time: Number(timestamp), amount, txHash }))
}

const LOGO = `query FairLunchLogo($chainId: Int!, $projectId: Int!) {
  projects(where: { chainId: $chainId, projectId: $projectId, version: 6 }, limit: 1) { items { logoUri } }
}`

export async function logoOf(chainId: number, projectId: number): Promise<string | null> {
  const { projects } = await bendystraw<{ projects: { items: { logoUri: string | null }[] } }>(LOGO, { chainId, projectId }, { chainId, policy: 'no-store' })
  return projects.items[0]?.logoUri ?? null
}
