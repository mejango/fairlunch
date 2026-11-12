import { jbDirectoryAbi, jbMultiTerminalAbi, jbProjectsAbi, jbTerminalStoreAbi, MappableAsset, NATIVE_TOKEN, parseSuckerDeployerConfig, type JBChainId } from '@bananapus/nana-sdk-core'
import { quoteUniswapV4ExactInputSingle } from '@bananapus/nana-sdk-core/v6/uniswap-v4'
import { buildBridgeClaimTx, buildBuybackCashOutMetadata, buildBuybackPayMetadata, CCIP_SUCKER_TRANSPORT_VALUES, findSuckerTransportValue, type JBClaim } from '@bananapus/nana-sdk-core/v6'
import { erc20Abi, isAddressEqual, pad, zeroHash, type Abi, type Address, type Hex } from 'viem'
import type { TxRequest } from '@/hooks/useSafeTx'
import { jbCenterPublicClient } from '@/lib/jbcenter-rpc'
import { fairLunchAbi } from './abi'
import type { Copy, Lunch } from './reads'
import { findMade, wiringOn } from './reads'
import { tokensFor } from './split'

/** What a creator chooses. Percents are whole numbers, 0 to 50. */
export type LunchTerms = {
  name: string; symbol: string; projectUri: string
  hostChainId: number; otherChainIds: number[]
  /** What the lunch raises, as its address on each of the lunch's chains. ETH is the same everywhere. */
  tokenOn: Record<number, Address>
  /** The money's symbol and decimals on the host chain, for showing amounts. */
  money: { symbol: string; decimals: number }
  /** `sender` signs every chain's create. `creator` is paid the share and the tokens. */
  deadline: number; sender: Address; creator: Address
  keepPercent: number; keepCapWei: bigint; tokenPercent: number; vestingSeconds: number
  salt: Hex
}

/** The gas a bridged message needs on the other side, as `FairLunch` maps it at `serve`. */
const SUCKER_MIN_GAS = 200_000
const PERCENT = 10_000_000 // 1% of JBConstants.SPLITS_TOTAL_PERCENT

/** The project these terms already made on a chain, or null: what a create that finished out of sight left behind. */
export function madeOn(terms: LunchTerms, chainId: number, signal?: AbortSignal): Promise<number | null> {
  return findMade({ sender: terms.sender, salt: terms.salt, hostChainId: terms.hostChainId, token: terms.tokenOn[terms.hostChainId], deadline: terms.deadline, creator: terms.creator,
    keepPercent: BigInt(terms.keepPercent * PERCENT), keepCap: terms.keepCapWei, tokenPercent: BigInt(terms.tokenPercent * PERCENT), vestingDuration: terms.vestingSeconds }, chainId, signal)
}

/** The `createFor` call for one of a lunch's chains. Every chain gets the same terms, or their bridges won't pair. */
export async function createTx(terms: LunchTerms, chainId: number): Promise<TxRequest> {
  const { lunch } = await wiringOn(chainId)
  const client = jbCenterPublicClient(chainId)
  const directory = await client.readContract({ address: lunch, abi: fairLunchAbi, functionName: 'DIRECTORY' })
  const projects = await client.readContract({ address: directory, abi: jbDirectoryAbi, functionName: 'PROJECTS' })
  const fee = await client.readContract({ address: projects, abi: jbProjectsAbi, functionName: 'creationFee' })
  const isHost = chainId === terms.hostChainId
  const chains = [terms.hostChainId, ...terms.otherChainIds] as JBChainId[]
  // The SDK knows each pair's bridge deployer. The host maps nothing until it's served; the others map their money
  // home as the host's.
  const deployers = chains.length > 1
    ? parseSuckerDeployerConfig(chainId as JBChainId, chains, [MappableAsset.NATIVE], { version: 6, bridge: 'ccip' }).deployerConfigurations
    : []
  const config = {
    name: terms.name, symbol: terms.symbol, projectUri: terms.projectUri,
    hostChainId: BigInt(terms.hostChainId), token: terms.tokenOn[terms.hostChainId], deadline: terms.deadline, creator: terms.creator,
    keepPercent: terms.keepPercent * PERCENT, keepCap: terms.keepCapWei, tokenPercent: terms.tokenPercent * PERCENT,
    vestingDuration: terms.vestingSeconds, salt: terms.salt,
    suckerDeploymentConfiguration: {
      salt: zeroHash,
      deployerConfigurations: deployers.map(({ deployer }) => ({
        deployer, peer: zeroHash,
        mappings: isHost ? [] : [{ localToken: terms.tokenOn[chainId], minGas: SUCKER_MIN_GAS, remoteToken: pad(terms.tokenOn[terms.hostChainId], { size: 32 }) }],
      })),
    },
  }
  return { chainId, address: lunch, abi: fairLunchAbi as Abi, functionName: 'createFor', args: [config], value: fee, label: 'Make lunch' }
}

/**
 * A payment into a cooking lunch, for tokens at the fixed price. It refuses to land for fewer: a payment still
 * waiting when the lunch is served would otherwise mint nothing.
 */
export async function payTx(lunch: Pick<Lunch, 'chainId' | 'projectId' | 'money'>, amount: bigint, payer: Address): Promise<TxRequest> {
  const { terminal } = await wiringOn(lunch.chainId)
  const { address, decimals } = lunch.money
  return { chainId: lunch.chainId, address: terminal, abi: jbMultiTerminalAbi as Abi, functionName: 'pay',
    args: [BigInt(lunch.projectId), address, amount, payer, tokensFor(amount, decimals), '', '0x'], value: valueOf(lunch.money, amount), label: 'Fund' }
}

const isEth = (money: Pick<Lunch['money'], 'address'>) => isAddressEqual(money.address, NATIVE_TOKEN as Address)
/** ETH travels with the call. An ERC-20 is pulled by the terminal, which needs an allowance first. */
const valueOf = (money: Lunch['money'], amount: bigint) => (isEth(money) ? amount : 0n)

/**
 * How much more of a lunch's money the terminal has to be allowed to take before `account` can pay `amount`. Zero for
 * ETH, and once the allowance covers it.
 */
export async function allowanceShortOf(lunch: Pick<Lunch, 'chainId' | 'money'>, account: Address, amount: bigint): Promise<bigint> {
  if (isEth(lunch.money) || amount === 0n) return 0n
  const { terminal } = await wiringOn(lunch.chainId)
  const allowed = await jbCenterPublicClient(lunch.chainId).readContract({ address: lunch.money.address, abi: erc20Abi, functionName: 'allowance', args: [account, terminal] })
  return allowed >= amount ? 0n : amount
}

/** Allowing the terminal to take exactly `amount` of a lunch's money. */
export async function allowTx(lunch: Pick<Lunch, 'chainId' | 'money'>, amount: bigint): Promise<TxRequest> {
  const { terminal } = await wiringOn(lunch.chainId)
  return { chainId: lunch.chainId, address: lunch.money.address, abi: erc20Abi as Abi, functionName: 'approve', args: [terminal, amount], label: `Allow ${lunch.money.symbol}` }
}

/** One of the calls anyone can make for a lunch on its host chain. One that would do nothing is refused: a collect
 * with no fees, or a burn the price limit stops before it buys anything. */
export async function upkeepTx(chainId: number, projectId: number, functionName: 'serve' | 'burn' | 'collect', account: Address): Promise<TxRequest> {
  const { lunch } = await wiringOn(chainId)
  const call = { address: lunch, abi: fairLunchAbi, functionName, args: [BigInt(projectId)] } as const
  if (functionName === 'collect') {
    const { result } = await jbCenterPublicClient(chainId).simulateContract({ ...call, functionName, account })
    if (result[0] === 0n && result[1] === 0n) throw new Error('No pool fees to collect yet.')
  }
  if (functionName === 'burn') {
    const { result } = await jbCenterPublicClient(chainId).simulateContract({ ...call, functionName, account })
    if (result[0] === 0n && result[1] === 0n) throw new Error("The price is at its limit for now. Try again in a few minutes.")
  }
  return { chainId, ...call, abi: fairLunchAbi as Abi }
}

/**
 * Sending a copy's money to the host. The call carries the bridge's payment, and the contract returns what the bridge
 * doesn't use, so this sends the smallest of the SDK's amounts that the call goes through with.
 */
export async function sendHomeTx(copy: Pick<Copy, 'chainId' | 'projectId' | 'money'>, account: Address): Promise<TxRequest & { value: bigint; sending: bigint }> {
  const { lunch, terminal, store } = await wiringOn(copy.chainId)
  const call = { address: lunch, abi: fairLunchAbi, functionName: 'sendHome', args: [BigInt(copy.projectId)] } as const
  const client = jbCenterPublicClient(copy.chainId)
  // Someone else may have sent it since the page last looked. An empty send still pays the bridge.
  const sending = await client.readContract({ address: store, abi: jbTerminalStoreAbi, functionName: 'balanceOf', args: [terminal, BigInt(copy.projectId), copy.money.address] })
  if (sending === 0n) throw new Error('Nothing is waiting there now.')
  const value = await findSuckerTransportValue(CCIP_SUCKER_TRANSPORT_VALUES, amount => client.simulateContract({ ...call, account, value: amount }))
  if (value === null) throw new Error("This can't be sent right now. Check you have ETH for the bridge.")
  return { chainId: copy.chainId, ...call, abi: fairLunchAbi as Abi, value, sending, label: 'Send home' }
}

/** Bringing delivered money into the host lunch. Anyone can; it goes to the lunch whoever calls. */
export function claimTx(hostChainId: number, copy: Pick<Copy, 'hostSucker'>, claim: JBClaim): TxRequest {
  const tx = buildBridgeClaimTx({ chainId: hostChainId as JBChainId, sucker: copy.hostSucker, claim })
  return { ...tx, abi: tx.abi as Abi, label: 'Bring in' }
}

/** What `amountIn` swaps for in a lunch's pool right now: money for tokens, or tokens for money when `selling`. */
export function quoteSwap(lunch: Pick<Lunch, 'chainId' | 'poolKey' | 'moneyIs0'>, amountIn: bigint, selling: boolean): Promise<bigint> {
  return quoteUniswapV4ExactInputSingle(jbCenterPublicClient(lunch.chainId), { chainId: lunch.chainId as JBChainId, poolKey: lunch.poolKey, zeroForOne: selling !== lunch.moneyIs0, amountIn })
}

/**
 * What has to go in for `amountOut` to come out. The pool's quoter only answers the other way round, so this asks it
 * a few times, scaling the input by how far off the last answer was.
 */
export async function quoteSwapFor(lunch: Pick<Lunch, 'chainId' | 'poolKey' | 'price' | 'money' | 'moneyIs0'>, amountOut: bigint, selling: boolean): Promise<bigint> {
  if (!lunch.price) throw new Error('No price yet.')
  // Start from the pool's price: a whole token (18 decimals) is worth `price` whole units of money.
  const token = 10n ** 18n
  const price = BigInt(Math.round(lunch.price * 10 ** lunch.money.decimals * 1e9))
  const scale = token * 10n ** 9n
  let amountIn = selling ? (amountOut * scale) / price : (amountOut * price) / scale
  for (let round = 0; round < 4 && amountIn > 0n; round++) {
    const out = await quoteSwap(lunch, amountIn, selling)
    if (out === 0n) break
    amountIn = (amountIn * amountOut) / out + 1n
  }
  return amountIn
}

/**
 * A trade with a served lunch's pool, through its project: paying buys for the payer, cashing out sells. The Juicebox
 * buyback hook does the swap and refuses less than `minimumOut`. Selling needs no approval, since the terminal burns
 * the seller's own tokens.
 */
export async function tradeTx(lunch: Pick<Lunch, 'chainId' | 'projectId' | 'money'>, amount: bigint, minimumOut: bigint, account: Address, selling: boolean): Promise<TxRequest> {
  const { terminal, buyback } = await wiringOn(lunch.chainId)
  const id = BigInt(lunch.projectId)
  const call = { chainId: lunch.chainId, address: terminal, abi: jbMultiTerminalAbi as Abi }
  if (selling) {
    const metadata = buildBuybackCashOutMetadata({ hook: buyback, minimumSwapAmountOut: minimumOut })
    return { ...call, functionName: 'cashOutTokensOf', args: [account, id, amount, lunch.money.address, 0n, account, metadata], label: 'Sell' }
  }
  // The buyback hook delivers the tokens, so the terminal's own minimum stays zero and the hook's holds.
  const metadata = buildBuybackPayMetadata({ hook: buyback, amountToSwapWith: 0n, minimumSwapAmountOut: minimumOut, skipSplits: true })
  return { ...call, functionName: 'pay', args: [id, lunch.money.address, amount, account, 0n, '', metadata], value: valueOf(lunch.money, amount), label: 'Buy' }
}
