import { jbControllerAbi, jbMultiTerminalAbi, jbTerminalStoreAbi, jbTokensAbi, NATIVE_TOKEN } from '@bananapus/nana-sdk-core'
import { UNISWAP_V4_STATE_VIEW_ADDRESSES, uniswapV4PoolId, uniswapV4PriceAtTick, type UniswapV4PoolKey } from '@bananapus/nana-sdk-core/v6/uniswap-v4'
import { erc20Abi, parseAbi, type Address } from 'viem'
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
