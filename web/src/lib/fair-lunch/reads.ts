import { jbControllerAbi, jbMultiTerminalAbi, jbTerminalStoreAbi, jbTokensAbi, NATIVE_TOKEN, type JBChainId } from '@bananapus/nana-sdk-core'
import { UNISWAP_V4_STATE_VIEW_ADDRESSES, uniswapV4PoolId, uniswapV4PriceAtTick, type UniswapV4PoolKey } from '@bananapus/nana-sdk-core/v6/uniswap-v4'
import { claimFromSuckerMovement, getSuckerMovements, getV6SuckerPairs, type JBClaim } from '@bananapus/nana-sdk-core/v6'
import { erc20Abi, isAddressEqual, parseAbi, type Address, type PublicClient } from 'viem'
import { jbCenterPublicClient } from '@/lib/jbcenter-rpc'
import { fairLunchAbi } from './abi'
import { deploymentOn } from './deployments'

/** Everything a lunch's page shows that the chain knows. Amounts in wei, times in seconds. */
export type Lunch = {
  chainId: number
  projectId: number
  hostChainId: number
  deadline: number
  servedAt: number
  creator: Address
  keepPercent: bigint
  keepCap: bigint
  tokenPercent: bigint
  vestingDuration: number
  vestingWallet: Address
  token: Address
  name: string
  symbol: string
  uri: string
  /** The project's ETH balance: the raise while cooking, what waits for the next burn after. */
  balance: bigint
  supply: bigint
  poolKey: UniswapV4PoolKey
  /** The pool's price in ETH per token, once it exists. */
  price: number | null
}

const stateViewAbi = parseAbi(['function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)'])
const oracleAbi = [
  { type: 'function', name: 'observe', stateMutability: 'view', outputs: [{ type: 'int56[]' }, { type: 'uint160[]' }],
    inputs: [{ name: 'key', type: 'tuple', components: [{ name: 'currency0', type: 'address' }, { name: 'currency1', type: 'address' }, { name: 'fee', type: 'uint24' }, { name: 'tickSpacing', type: 'int24' }, { name: 'hooks', type: 'address' }] }, { name: 'secondsAgos', type: 'uint32[]' }] },
] as const

/** The token's price in ETH at a pool tick. The pool's currency0 is ETH. */
const priceAt = (tick: number) => uniswapV4PriceAtTick(tick, true, 18)

/** The Juicebox contracts a chain's Fair Lunch was deployed with. They never change. */
const wiring = new Map<number, Promise<{ lunch: Address; terminal: Address; store: Address; tokens: Address; controller: Address }>>()
export function wiringOn(chainId: number) {
  const known = wiring.get(chainId)
  if (known) return known
  const deployment = deploymentOn(chainId)
  if (!deployment) throw new Error('Fair Lunch is not on this chain.')
  const client = jbCenterPublicClient(chainId)
  const lunch = deployment.address
  const read = (async () => {
    const [terminal, tokens, controller] = await Promise.all((['TERMINAL', 'TOKENS', 'CONTROLLER'] as const).map(functionName =>
      client.readContract({ address: lunch, abi: fairLunchAbi, functionName })))
    const store = await client.readContract({ address: terminal, abi: jbMultiTerminalAbi, functionName: 'STORE' })
    return { lunch, terminal, store, tokens, controller }
  })()
  wiring.set(chainId, read)
  read.catch(() => wiring.delete(chainId))
  return read
}

/** A lunch on its host chain, or null when the project isn't one. */
export async function readLunch(chainId: number, projectId: number, signal?: AbortSignal): Promise<Lunch | null> {
  const { lunch, terminal, store, tokens, controller } = await wiringOn(chainId)
  const client = jbCenterPublicClient(chainId, signal)
  const id = BigInt(projectId)
  const [record, poolKey, token, balance, supply, uri] = await Promise.all([
    client.readContract({ address: lunch, abi: fairLunchAbi, functionName: 'recordOf', args: [id] }),
    client.readContract({ address: lunch, abi: fairLunchAbi, functionName: 'poolKeyOf', args: [id] }),
    client.readContract({ address: tokens, abi: jbTokensAbi, functionName: 'tokenOf', args: [id] }),
    client.readContract({ address: store, abi: jbTerminalStoreAbi, functionName: 'balanceOf', args: [terminal, id, NATIVE_TOKEN] }),
    client.readContract({ address: tokens, abi: jbTokensAbi, functionName: 'totalSupplyOf', args: [id] }),
    client.readContract({ address: controller, abi: jbControllerAbi, functionName: 'uriOf', args: [id] }),
  ])
  if (Number(record.hostChainId) !== chainId) return null
  const stateView = UNISWAP_V4_STATE_VIEW_ADDRESSES[chainId as keyof typeof UNISWAP_V4_STATE_VIEW_ADDRESSES]
  const [name, symbol, slot0] = await Promise.all([
    client.readContract({ address: token, abi: erc20Abi, functionName: 'name' }),
    client.readContract({ address: token, abi: erc20Abi, functionName: 'symbol' }),
    record.servedAt && stateView
      ? client.readContract({ address: stateView, abi: stateViewAbi, functionName: 'getSlot0', args: [uniswapV4PoolId(poolKey)] })
      : null,
  ])
  return {
    chainId, projectId, hostChainId: Number(record.hostChainId), deadline: record.deadline, servedAt: record.servedAt,
    creator: record.creator, keepPercent: BigInt(record.keepPercent), keepCap: record.keepCap, tokenPercent: BigInt(record.tokenPercent),
    vestingDuration: record.vestingDuration, vestingWallet: record.vestingWallet, token, name, symbol, uri, balance, supply, poolKey,
    price: slot0 ? priceAt(slot0[1]) : null,
  }
}

export type PricePoint = { time: number; price: number }

/**
 * The pool's price over the last `seconds`, as `points` averages, from the pool's own oracle: one call, no indexer.
 * The oracle keeps the pool's whole life until it has traded in tens of thousands of separate blocks. Past that,
 * the oldest ranges fail to load and the chart says so.
 */
export async function readPriceHistory(lunch: Pick<Lunch, 'chainId' | 'poolKey' | 'servedAt'>, seconds: number, points: number, signal?: AbortSignal): Promise<PricePoint[]> {
  if (!lunch.servedAt) return []
  const client = jbCenterPublicClient(lunch.chainId, signal)
  const oracle = { address: lunch.poolKey.hooks, abi: oracleAbi } as const
  // The pool's history starts when the lunch was served, by the chain's clock.
  const { timestamp } = await client.getBlock()
  const span = Math.min(seconds, Number(timestamp) - lunch.servedAt)
  const step = Math.floor(span / points)
  if (step < 1) return []
  const secondsAgos = Array.from({ length: points + 1 }, (_, i) => step * (points - i))
  const [cumulatives] = await client.readContract({ ...oracle, functionName: 'observe', args: [lunch.poolKey, secondsAgos] })
  const now = Number(timestamp)
  // An average tick is rarely whole. ETH is currency0 and both sides have 18 decimals, so a tick is tokens per ETH as
  // a power of 1.0001, and the token's price in ETH is its inverse.
  return secondsAgos.slice(1).map((ago, i) => ({
    time: now - ago,
    price: 1.0001 ** -(Number(cumulatives[i + 1] - cumulatives[i]) / step),
  }))
}

/** A lunch's project on another chain. It mints nothing: what's paid there waits to be sent to the host. */
export type Copy = {
  chainId: number
  projectId: number
  /** ETH waiting there to be sent home. */
  balance: bigint
  /** ETH sent home that the bridge hasn't delivered yet. */
  onTheWay: bigint
  /** The host's sucker for this copy, and the delivered ETH it can bring in. */
  hostSucker: Address
  claims: JBClaim[]
}

const suckerAbi = parseAbi(['function projectId() view returns (uint256)', 'function peer() view returns (bytes32)'])
const sameAddress = (word: `0x${string}`, address: Address) => isAddressEqual(`0x${word.slice(-40)}`, address)

/**
 * A lunch's copies on other chains, read from the host. A chain the creator hasn't made the lunch on yet has no
 * sucker to answer, and is left out.
 */
export async function readCopies(lunch: Pick<Lunch, 'chainId' | 'projectId'>, signal?: AbortSignal): Promise<Copy[]> {
  const host = jbCenterPublicClient(lunch.chainId, signal) as PublicClient
  const { lunch: fairLunch } = await wiringOn(lunch.chainId)
  const pairs = await getV6SuckerPairs(host, { chainId: lunch.chainId as JBChainId, projectId: BigInt(lunch.projectId) })
  const copies = await Promise.all(pairs.map(async pair => {
    const chainId = Number(pair.remoteChainId)
    if (!deploymentOn(chainId)) return null
    const client = jbCenterPublicClient(chainId, signal) as PublicClient
    const there = { address: pair.remote, abi: suckerAbi } as const
    const made = await Promise.all([client.readContract({ ...there, functionName: 'projectId' }), client.readContract({ ...there, functionName: 'peer' })]).catch(() => null)
    // Only a sucker that points back at the host's is this lunch's copy.
    if (!made || !sameAddress(made[1], pair.local)) return null
    const { terminal, store } = await wiringOn(chainId)
    const [balance, movements] = await Promise.all([
      client.readContract({ address: store, abi: jbTerminalStoreAbi, functionName: 'balanceOf', args: [terminal, made[0], NATIVE_TOKEN] }),
      getSuckerMovements(client, host, { sourceSucker: pair.remote, destinationSucker: pair.local, sourceToken: NATIVE_TOKEN as Address }),
    ])
    // Holders bridge through the same suckers. Only what was sent home to Fair Lunch is the lunch's.
    const sentHome = movements.filter(movement => sameAddress(movement.leaf.beneficiary, fairLunch))
    return {
      chainId, projectId: Number(made[0]), balance, hostSucker: pair.local,
      onTheWay: sentHome.filter(movement => movement.status === 'pending').reduce((sum, movement) => sum + movement.leaf.terminalTokenAmount, 0n),
      claims: sentHome.filter(movement => movement.status === 'claimable').map(claimFromSuckerMovement),
    }
  }))
  return copies.filter(copy => copy !== null)
}

/** The host lunch of a copy, or null when the project isn't a copy of one. */
export async function readHostOf(chainId: number, projectId: number, signal?: AbortSignal): Promise<{ chainId: number; projectId: number } | null> {
  const { lunch } = await wiringOn(chainId)
  const client = jbCenterPublicClient(chainId, signal) as PublicClient
  const record = await client.readContract({ address: lunch, abi: fairLunchAbi, functionName: 'recordOf', args: [BigInt(projectId)] })
  const hostChainId = Number(record.hostChainId)
  if (!hostChainId || hostChainId === chainId || !deploymentOn(hostChainId)) return null
  const pairs = await getV6SuckerPairs(client, { chainId: chainId as JBChainId, projectId: BigInt(projectId) })
  const pair = pairs.find(candidate => Number(candidate.remoteChainId) === hostChainId)
  if (!pair) return null
  const hostProjectId = await jbCenterPublicClient(hostChainId, signal).readContract({ address: pair.remote, abi: suckerAbi, functionName: 'projectId' }).catch(() => null)
  return hostProjectId === null ? null : { chainId: hostChainId, projectId: Number(hostProjectId) }
}
