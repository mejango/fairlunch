import { jbControllerAbi, jbMultiTerminalAbi, jbTerminalStoreAbi, jbTokensAbi, NATIVE_TOKEN, type JBChainId } from '@bananapus/nana-sdk-core'
import { UNISWAP_V4_STATE_VIEW_ADDRESSES, uniswapV4PoolId, uniswapV4PriceAtTick, type UniswapV4PoolKey } from '@bananapus/nana-sdk-core/v6/uniswap-v4'
import { claimFromSuckerMovement, getSuckerMovements, getV6SuckerPairs, type JBClaim } from '@bananapus/nana-sdk-core/v6'
import { encodeAbiParameters, encodePacked, erc20Abi, getContractAddress, isAddressEqual, keccak256, parseAbi, type Address, type Hex, type PublicClient } from 'viem'
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
  /** The ETH in the pool at that price, once it exists. */
  pooledEth: bigint | null
}

const stateViewAbi = parseAbi([
  'function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)',
  'function getLiquidity(bytes32 poolId) view returns (uint128)',
])
const oracleAbi = [
  { type: 'function', name: 'observe', stateMutability: 'view', outputs: [{ type: 'int56[]' }, { type: 'uint160[]' }],
    inputs: [{ name: 'key', type: 'tuple', components: [{ name: 'currency0', type: 'address' }, { name: 'currency1', type: 'address' }, { name: 'fee', type: 'uint24' }, { name: 'tickSpacing', type: 'int24' }, { name: 'hooks', type: 'address' }] }, { name: 'secondsAgos', type: 'uint32[]' }] },
  { type: 'function', name: 'observationCoverageOf', stateMutability: 'view', outputs: [{ type: 'uint32' }],
    inputs: [{ name: 'key', type: 'tuple', components: [{ name: 'currency0', type: 'address' }, { name: 'currency1', type: 'address' }, { name: 'fee', type: 'uint24' }, { name: 'tickSpacing', type: 'int24' }, { name: 'hooks', type: 'address' }] }] },
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
  const pool = record.servedAt && stateView ? { address: stateView, abi: stateViewAbi, args: [uniswapV4PoolId(poolKey)] } as const : null
  const [name, symbol, slot0, liquidity] = await Promise.all([
    client.readContract({ address: token, abi: erc20Abi, functionName: 'name' }),
    client.readContract({ address: token, abi: erc20Abi, functionName: 'symbol' }),
    pool ? client.readContract({ ...pool, functionName: 'getSlot0' }) : null,
    pool ? client.readContract({ ...pool, functionName: 'getLiquidity' }) : null,
  ])
  return {
    chainId, projectId, hostChainId: Number(record.hostChainId), deadline: record.deadline, servedAt: record.servedAt,
    creator: record.creator, keepPercent: BigInt(record.keepPercent), keepCap: record.keepCap, tokenPercent: BigInt(record.tokenPercent),
    vestingDuration: record.vestingDuration, vestingWallet: record.vestingWallet, token, name, symbol, uri, balance, supply, poolKey,
    price: slot0 ? priceAt(slot0[1]) : null,
    // The position spans every price, so its ETH (currency0) is its liquidity over the square root of the price.
    pooledEth: slot0 && liquidity !== null && slot0[0] > 0n ? (liquidity << 96n) / slot0[0] : null,
  }
}

export type PricePoint = { time: number; price: number }
export type PriceHistory = { points: PricePoint[]; /** The oracle no longer keeps the whole range asked for. */ short: boolean }

/**
 * The pool's price over the last `seconds`, as `points` averages, from the pool's own oracle: one call, no indexer.
 * ponytail: the oracle keeps 1,801 observations, one per second the pool trades in, so a busy pool keeps as little as
 * its last half hour. The range is cut to what's kept. Longer history needs the pool's swaps indexed.
 */
export async function readPriceHistory(lunch: Pick<Lunch, 'chainId' | 'poolKey' | 'servedAt'>, seconds: number, points: number, signal?: AbortSignal): Promise<PriceHistory> {
  if (!lunch.servedAt) return { points: [], short: false }
  const client = jbCenterPublicClient(lunch.chainId, signal)
  const oracle = { address: lunch.poolKey.hooks, abi: oracleAbi } as const
  // The pool's history starts when the lunch was served, by the chain's clock.
  const [{ timestamp }, kept] = await Promise.all([
    client.getBlock(),
    client.readContract({ ...oracle, functionName: 'observationCoverageOf', args: [lunch.poolKey] }),
  ])
  const asked = Math.min(seconds, Number(timestamp) - lunch.servedAt)
  const span = Math.min(asked, kept)
  const short = span < asked
  const step = Math.floor(span / points)
  if (step < 1) return { points: [], short }
  const secondsAgos = Array.from({ length: points + 1 }, (_, i) => step * (points - i))
  const [cumulatives] = await client.readContract({ ...oracle, functionName: 'observe', args: [lunch.poolKey, secondsAgos] })
  const now = Number(timestamp)
  // An average tick is rarely whole. ETH is currency0 and both sides have 18 decimals, so a tick is tokens per ETH as
  // a power of 1.0001, and the token's price in ETH is its inverse.
  return { short, points: secondsAgos.slice(1).map((ago, i) => ({
    time: now - ago,
    price: 1.0001 ** -(Number(cumulatives[i + 1] - cumulatives[i]) / step),
  })) }
}

export type MadeTerms = { salt: Hex; hostChainId: number; deadline: number; creator: Address; keepPercent: bigint; keepCap: bigint; tokenPercent: bigint; vestingDuration: number }

/** Where `createFor` deploys a lunch's token: fixed by the terms and the wallet that sent them (the creator). */
export function tokenAddressOf(terms: MadeTerms, on: { lunch: Address; controller: Address; tokens: Address; implementation: Address }): Address {
  // FairLunch's salt, then the controller's, then the token store's: each scopes the one before to its caller.
  const lunchSalt = keccak256(encodeAbiParameters(
    [{ type: 'address' }, { type: 'bytes32' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'address' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }],
    [terms.creator, terms.salt, BigInt(terms.hostChainId), BigInt(terms.deadline), terms.creator, terms.keepPercent, terms.keepCap, terms.tokenPercent, BigInt(terms.vestingDuration)]))
  const controllerSalt = keccak256(encodePacked(['address', 'bytes32'], [on.lunch, lunchSalt]))
  const salt = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'bytes32' }], [on.controller, controllerSalt]))
  // An ERC-1167 clone's creation code.
  const bytecode = `0x3d602d80600a3d3981f3363d3d373d3d3d363d73${on.implementation.slice(2)}5af43d82803e903d91602b57fd5bf3` as Hex
  return getContractAddress({ opcode: 'CREATE2', from: on.tokens, salt, bytecode })
}

/**
 * The project a creator's terms already made on a chain, or null. The chain itself says whether a create went
 * through, whatever this browser remembers of it.
 */
export async function findMade(terms: MadeTerms, chainId: number, signal?: AbortSignal): Promise<number | null> {
  const { lunch, tokens, controller } = await wiringOn(chainId)
  const client = jbCenterPublicClient(chainId, signal)
  const implementation = await client.readContract({ address: tokens, abi: parseAbi(['function TOKEN() view returns (address)']), functionName: 'TOKEN' })
  const token = tokenAddressOf(terms, { lunch, controller, tokens, implementation })
  const projectId = await client.readContract({ address: tokens, abi: jbTokensAbi, functionName: 'projectIdOf', args: [token] })
  return projectId ? Number(projectId) : null
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
    // One chain's bridge history failing to load doesn't hide what waits there, or the other chains.
    const [balance, movements] = await Promise.all([
      client.readContract({ address: store, abi: jbTerminalStoreAbi, functionName: 'balanceOf', args: [terminal, made[0], NATIVE_TOKEN] }),
      getSuckerMovements(client, host, { sourceSucker: pair.remote, destinationSucker: pair.local, sourceToken: NATIVE_TOKEN as Address }).catch(() => []),
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
