import { jbControllerAbi, jbMultiTerminalAbi, jbTerminalStoreAbi, jbTokensAbi, NATIVE_TOKEN, type JBChainId } from '@bananapus/nana-sdk-core'
import { UNISWAP_V4_STATE_VIEW_ADDRESSES, uniswapV4PoolId, type UniswapV4PoolKey } from '@bananapus/nana-sdk-core/v6/uniswap-v4'
import { claimFromSuckerMovement, getSuckerMovements, getV6SuckerPairs, type JBClaim } from '@bananapus/nana-sdk-core/v6'
import { encodeAbiParameters, encodePacked, erc20Abi, getContractAddress, isAddressEqual, keccak256, parseAbi, type Address, type Hex, type PublicClient } from 'viem'
import { jbCenterPublicClient } from '@/lib/jbcenter-rpc'
import { fairLunchAbi } from './abi'
import { deploymentOn } from './deployments'

/** What a lunch raises and its pool trades against: ETH or an ERC-20. */
export type Money = { address: Address; symbol: string; decimals: number }
const ETH: Money = { address: NATIVE_TOKEN as Address, symbol: 'ETH', decimals: 18 }

/** A token as money. A chain's native token is ETH everywhere Fair Lunch is. */
export async function readMoney(client: PublicClient, address: Address): Promise<Money> {
  if (isAddressEqual(address, ETH.address)) return ETH
  const [symbol, decimals] = await Promise.all([
    client.readContract({ address, abi: erc20Abi, functionName: 'symbol' }),
    client.readContract({ address, abi: erc20Abi, functionName: 'decimals' }),
  ])
  return { address, symbol, decimals }
}

/** Everything a lunch's page shows that the chain knows. Amounts in the smallest unit, times in seconds. */
export type Lunch = {
  chainId: number
  projectId: number
  hostChainId: number
  /** When the lunch was made. */
  startedAt: number
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
  /** What the lunch raises. */
  money: Money
  /** Whether the money is the pool's currency0. */
  moneyIs0: boolean
  /** The project's balance of its money: the raise while cooking, what waits for the next burn after. */
  balance: bigint
  supply: bigint
  poolKey: UniswapV4PoolKey
  /** The pool's price in money per token, once it exists. */
  price: number | null
  /** The money in the pool at that price, once it exists. */
  pooled: bigint | null
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

/** The token's price in whole units of money at a pool tick. A tick is currency1 per currency0 as a power of 1.0001,
 * in smallest units, and the token has 18 decimals. */
const priceAt = (tick: number, on: Pick<Lunch, 'money' | 'moneyIs0'>) => 1.0001 ** (on.moneyIs0 ? -tick : tick) * 10 ** (18 - on.money.decimals)

/** The Juicebox contracts a chain's Fair Lunch was deployed with. They never change. */
const wiring = new Map<number, Promise<{ lunch: Address; terminal: Address; store: Address; tokens: Address; controller: Address; buyback: Address; router: Address }>>()
export function wiringOn(chainId: number) {
  const known = wiring.get(chainId)
  if (known) return known
  const deployment = deploymentOn(chainId)
  if (!deployment) throw new Error('Fair Lunch is not on this chain.')
  const client = jbCenterPublicClient(chainId)
  const lunch = deployment.address
  const read = (async () => {
    const [terminal, tokens, controller, buyback, router] = await Promise.all((['TERMINAL', 'TOKENS', 'CONTROLLER', 'BUYBACK_REGISTRY', 'ROUTER_TERMINAL_REGISTRY'] as const).map(functionName =>
      client.readContract({ address: lunch, abi: fairLunchAbi, functionName })))
    const store = await client.readContract({ address: terminal, abi: jbMultiTerminalAbi, functionName: 'STORE' })
    return { lunch, terminal, store, tokens, controller, buyback, router }
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
  const [record, poolKey, token, supply, uri, [ruleset]] = await Promise.all([
    client.readContract({ address: lunch, abi: fairLunchAbi, functionName: 'recordOf', args: [id] }),
    client.readContract({ address: lunch, abi: fairLunchAbi, functionName: 'poolKeyOf', args: [id] }),
    client.readContract({ address: tokens, abi: jbTokensAbi, functionName: 'tokenOf', args: [id] }),
    client.readContract({ address: tokens, abi: jbTokensAbi, functionName: 'totalSupplyOf', args: [id] }),
    client.readContract({ address: controller, abi: jbControllerAbi, functionName: 'uriOf', args: [id] }),
    // A lunch's first ruleset starts when it's made.
    client.readContract({ address: controller, abi: jbControllerAbi, functionName: 'currentRulesetOf', args: [id] }),
  ])
  if (Number(record.hostChainId) !== chainId) return null
  const moneyIs0 = !isAddressEqual(poolKey.currency0, token)
  const stateView = UNISWAP_V4_STATE_VIEW_ADDRESSES[chainId as keyof typeof UNISWAP_V4_STATE_VIEW_ADDRESSES]
  const pool = record.servedAt && stateView ? { address: stateView, abi: stateViewAbi, args: [uniswapV4PoolId(poolKey)] } as const : null
  const [money, balance, name, symbol, slot0, liquidity] = await Promise.all([
    readMoney(client as PublicClient, record.token),
    client.readContract({ address: store, abi: jbTerminalStoreAbi, functionName: 'balanceOf', args: [terminal, id, record.token] }),
    client.readContract({ address: token, abi: erc20Abi, functionName: 'name' }),
    client.readContract({ address: token, abi: erc20Abi, functionName: 'symbol' }),
    pool ? client.readContract({ ...pool, functionName: 'getSlot0' }) : null,
    pool ? client.readContract({ ...pool, functionName: 'getLiquidity' }) : null,
  ])
  return {
    chainId, projectId, hostChainId: Number(record.hostChainId), startedAt: Number(ruleset.start), deadline: record.deadline, servedAt: record.servedAt,
    creator: record.creator, keepPercent: BigInt(record.keepPercent), keepCap: record.keepCap, tokenPercent: BigInt(record.tokenPercent),
    vestingDuration: record.vestingDuration, vestingWallet: record.vestingWallet, token, name, symbol, uri, money, moneyIs0, balance, supply, poolKey,
    price: slot0 ? priceAt(slot0[1], { money, moneyIs0 }) : null,
    // The position spans every price, so its currency0 is its liquidity over the square root of the price, and its
    // currency1 is its liquidity times it.
    pooled: slot0 && liquidity !== null && slot0[0] > 0n ? (moneyIs0 ? (liquidity << 96n) / slot0[0] : (liquidity * slot0[0]) >> 96n) : null,
  }
}

/** The pool fees a served lunch's position has earned and not yet collected: what `collect` would move right now. */
export async function readPoolFees(lunch: Pick<Lunch, 'chainId' | 'projectId'>, signal?: AbortSignal): Promise<{ tokens: bigint; money: bigint }> {
  const { lunch: address } = await wiringOn(lunch.chainId)
  const { result } = await jbCenterPublicClient(lunch.chainId, signal).simulateContract({ address, abi: fairLunchAbi, functionName: 'collect', args: [BigInt(lunch.projectId)] })
  return { tokens: result[0], money: result[1] }
}

export type PricePoint = { time: number; price: number }
export type PriceHistory = { points: PricePoint[]; /** The oracle no longer keeps the whole range asked for. */ short: boolean }

/**
 * The pool's price over the last `seconds`, as `points` averages, from the pool's own oracle: one call, no indexer.
 * ponytail: the oracle keeps 1,801 observations, one per second the pool trades in, so a busy pool keeps as little as
 * its last half hour. The range is cut to what's kept. Longer history needs the pool's swaps indexed.
 */
export async function readPriceHistory(lunch: Pick<Lunch, 'chainId' | 'poolKey' | 'servedAt' | 'money' | 'moneyIs0'>, seconds: number, points: number, signal?: AbortSignal): Promise<PriceHistory> {
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
  // An average tick is rarely whole.
  return { short, points: secondsAgos.slice(1).map((ago, i) => ({
    time: now - ago,
    price: priceAt(Number(cumulatives[i + 1] - cumulatives[i]) / step, lunch),
  })) }
}

export type MadeTerms = { /** The wallet that sends the create. */ sender: Address; salt: Hex; hostChainId: number; /** The host's money. */ token: Address; deadline: number; creator: Address; keepPercent: bigint; keepCap: bigint; tokenPercent: bigint; vestingDuration: number }

/** Where `createFor` deploys a lunch's token: fixed by the terms and the wallet that sent them. */
export function tokenAddressOf(terms: MadeTerms, on: { lunch: Address; controller: Address; tokens: Address; implementation: Address }): Address {
  // FairLunch's salt, then the controller's, then the token store's: each scopes the one before to its caller.
  const lunchSalt = keccak256(encodeAbiParameters(
    [{ type: 'address' }, { type: 'bytes32' }, { type: 'uint256' }, { type: 'address' }, { type: 'uint256' }, { type: 'address' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }],
    [terms.sender, terms.salt, BigInt(terms.hostChainId), terms.token, BigInt(terms.deadline), terms.creator, terms.keepPercent, terms.keepCap, terms.tokenPercent, BigInt(terms.vestingDuration)]))
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
  /** That chain's money. */
  money: Money
  /** Money waiting there to be sent home. */
  balance: bigint
  /** Money sent home that the bridge hasn't delivered yet. */
  onTheWay: bigint
  /** The host's sucker for this copy, and the delivered money it can bring in. */
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
    const { terminal, store, lunch: there_ } = await wiringOn(chainId)
    const money = await readMoney(client, (await client.readContract({ address: there_, abi: fairLunchAbi, functionName: 'recordOf', args: [made[0]] })).token)
    // One chain's bridge history failing to load doesn't hide what waits there, or the other chains.
    const [balance, movements] = await Promise.all([
      client.readContract({ address: store, abi: jbTerminalStoreAbi, functionName: 'balanceOf', args: [terminal, made[0], money.address] }),
      getSuckerMovements(client, host, { sourceSucker: pair.remote, destinationSucker: pair.local, sourceToken: money.address }).catch(() => []),
    ])
    // Holders bridge through the same suckers. Only what was sent home to Fair Lunch is the lunch's.
    const sentHome = movements.filter(movement => sameAddress(movement.leaf.beneficiary, fairLunch))
    return {
      chainId, projectId: Number(made[0]), money, balance, hostSucker: pair.local,
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
