import { jbDirectoryAbi, jbMultiTerminalAbi, jbProjectsAbi, jbTerminalStoreAbi, MappableAsset, NATIVE_TOKEN, parseSuckerDeployerConfig, type JBChainId } from '@bananapus/nana-sdk-core'
import { buildPermit2ApproveTx, buildUniswapV4ExactInputSwapTx, quoteUniswapV4ExactInputSingle, UNISWAP_PERMIT2_ADDRESS, UNISWAP_V4_UNIVERSAL_ROUTER_ADDRESSES } from '@bananapus/nana-sdk-core/v6/uniswap-v4'
import { buildBridgeClaimTx, CCIP_SUCKER_TRANSPORT_VALUES, findSuckerTransportValue, type JBClaim } from '@bananapus/nana-sdk-core/v6'
import { erc20Abi, maxUint256, pad, parseAbi, zeroHash, type Abi, type Address, type Hex } from 'viem'
import type { TxRequest } from '@/hooks/useSafeTx'
import { jbCenterPublicClient } from '@/lib/jbcenter-rpc'
import { fairLunchAbi } from './abi'
import type { Copy, Lunch } from './reads'
import { wiringOn } from './reads'
import { TOKENS_PER_ETH } from './split'

/** What a creator chooses. Percents are whole numbers, 0 to 50. */
export type LunchTerms = {
  name: string; symbol: string; projectUri: string
  hostChainId: number; otherChainIds: number[]
  deadline: number; creator: Address
  keepPercent: number; keepCapWei: bigint; tokenPercent: number; vestingSeconds: number
  salt: Hex
}

/** The gas a bridged message needs on the other side, as `FairLunch` maps it at `serve`. */
const SUCKER_MIN_GAS = 200_000
const PERCENT = 10_000_000 // 1% of JBConstants.SPLITS_TOTAL_PERCENT

/** The `createFor` call for one of a lunch's chains. Every chain gets the same terms, or their bridges won't pair. */
export async function createTx(terms: LunchTerms, chainId: number): Promise<TxRequest> {
  const { lunch } = await wiringOn(chainId)
  const client = jbCenterPublicClient(chainId)
  const directory = await client.readContract({ address: lunch, abi: fairLunchAbi, functionName: 'DIRECTORY' })
  const projects = await client.readContract({ address: directory, abi: jbDirectoryAbi, functionName: 'PROJECTS' })
  const fee = await client.readContract({ address: projects, abi: jbProjectsAbi, functionName: 'creationFee' })
  const isHost = chainId === terms.hostChainId
  const chains = [terms.hostChainId, ...terms.otherChainIds] as JBChainId[]
  // The SDK knows each pair's bridge deployer. The host maps nothing until it's served; the others map ETH home.
  const deployers = chains.length > 1
    ? parseSuckerDeployerConfig(chainId as JBChainId, chains, [MappableAsset.NATIVE], { version: 6, bridge: 'ccip' }).deployerConfigurations
    : []
  const config = {
    name: terms.name, symbol: terms.symbol, projectUri: terms.projectUri,
    hostChainId: BigInt(terms.hostChainId), deadline: terms.deadline, creator: terms.creator,
    keepPercent: terms.keepPercent * PERCENT, keepCap: terms.keepCapWei, tokenPercent: terms.tokenPercent * PERCENT,
    vestingDuration: terms.vestingSeconds, salt: terms.salt,
    suckerDeploymentConfiguration: {
      salt: zeroHash,
      deployerConfigurations: deployers.map(({ deployer }) => ({
        deployer, peer: zeroHash,
        mappings: isHost ? [] : [{ localToken: NATIVE_TOKEN as Address, minGas: SUCKER_MIN_GAS, remoteToken: pad(NATIVE_TOKEN as Address, { size: 32 }) }],
      })),
    },
  }
  return { chainId, address: lunch, abi: fairLunchAbi as Abi, functionName: 'createFor', args: [config], value: fee, label: 'Make lunch' }
}

/**
 * A payment into a cooking lunch, for tokens at the fixed price. It refuses to land for fewer: a payment still
 * waiting when the lunch is served would otherwise go to a buyback and mint nothing.
 */
export async function payTx(lunch: Pick<Lunch, 'chainId' | 'projectId'>, amount: bigint, payer: Address): Promise<TxRequest> {
  const { terminal } = await wiringOn(lunch.chainId)
  return { chainId: lunch.chainId, address: terminal, abi: jbMultiTerminalAbi as Abi, functionName: 'pay',
    args: [BigInt(lunch.projectId), NATIVE_TOKEN, amount, payer, amount * TOKENS_PER_ETH, '', '0x'], value: amount, label: 'Pay' }
}

/** One of the calls anyone can make for a lunch on its host chain. */
export async function upkeepTx(chainId: number, projectId: number, functionName: 'serve' | 'burn' | 'collect'): Promise<TxRequest> {
  const { lunch } = await wiringOn(chainId)
  return { chainId, address: lunch, abi: fairLunchAbi as Abi, functionName, args: [BigInt(projectId)] }
}

/**
 * Sending a copy's ETH to the host. The call carries the bridge's payment, and the contract returns what the bridge
 * doesn't use, so this sends the smallest of the SDK's amounts that the call goes through with.
 */
export async function sendHomeTx(copy: Pick<Copy, 'chainId' | 'projectId'>, account: Address): Promise<TxRequest & { value: bigint; sending: bigint }> {
  const { lunch, terminal, store } = await wiringOn(copy.chainId)
  const call = { address: lunch, abi: fairLunchAbi, functionName: 'sendHome', args: [BigInt(copy.projectId)] } as const
  const client = jbCenterPublicClient(copy.chainId)
  // Someone else may have sent it since the page last looked. An empty send still pays the bridge.
  const sending = await client.readContract({ address: store, abi: jbTerminalStoreAbi, functionName: 'balanceOf', args: [terminal, BigInt(copy.projectId), NATIVE_TOKEN] })
  if (sending === 0n) throw new Error('Nothing is waiting there now.')
  const value = await findSuckerTransportValue(CCIP_SUCKER_TRANSPORT_VALUES, amount => client.simulateContract({ ...call, account, value: amount }))
  if (value === null) throw new Error("This can't be sent right now. Check you have ETH for the bridge.")
  return { chainId: copy.chainId, ...call, abi: fairLunchAbi as Abi, value, sending, label: 'Send home' }
}

/** Bringing delivered ETH into the host lunch. Anyone can; it goes to the lunch whoever calls. */
export function claimTx(hostChainId: number, copy: Pick<Copy, 'hostSucker'>, claim: JBClaim): TxRequest {
  const tx = buildBridgeClaimTx({ chainId: hostChainId as JBChainId, sucker: copy.hostSucker, claim })
  return { ...tx, abi: tx.abi as Abi, label: 'Bring in' }
}

/** What `amountIn` swaps for in a lunch's pool right now: ETH for tokens, or tokens for ETH when `selling`. */
export function quoteSwap(lunch: Pick<Lunch, 'chainId' | 'poolKey'>, amountIn: bigint, selling: boolean): Promise<bigint> {
  return quoteUniswapV4ExactInputSingle(jbCenterPublicClient(lunch.chainId), { chainId: lunch.chainId as JBChainId, poolKey: lunch.poolKey, zeroForOne: !selling, amountIn })
}

/** A swap with the pool through Uniswap's router, refusing less than `minimumOut`. */
export function swapTx(lunch: Pick<Lunch, 'chainId' | 'poolKey'>, amountIn: bigint, minimumOut: bigint, recipient: Address, selling: boolean): TxRequest {
  const tx = buildUniswapV4ExactInputSwapTx({ chainId: lunch.chainId as JBChainId, poolKey: lunch.poolKey, zeroForOne: !selling, amountIn, minimumAmountOut: minimumOut, recipient, deadline: BigInt(Math.floor(Date.now() / 1000) + 600) })
  return { ...tx, abi: tx.abi as Abi, label: selling ? 'Sell' : 'Buy' }
}

const permit2Abi = parseAbi(['function allowance(address owner, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)'])
/** How long the router may pull a sale's tokens: long enough to press Sell, no longer. */
const SALE_ALLOWANCE_SECONDS = 1800

/**
 * The approval a sale of `amount` still needs from `owner`, or null when it can go. Uniswap pulls tokens through
 * Permit2: the token approves Permit2 once, then Permit2 lets the router take this sale's amount for a short while.
 */
export async function sellApprovalTx(lunch: Pick<Lunch, 'chainId' | 'token'>, owner: Address, amount: bigint): Promise<TxRequest | null> {
  const chainId = lunch.chainId as JBChainId
  const client = jbCenterPublicClient(chainId)
  const router = UNISWAP_V4_UNIVERSAL_ROUTER_ADDRESSES[chainId]
  if (!router) throw new Error('Swaps are not on this chain.')
  const [approved, [allowed, expiration]] = await Promise.all([
    client.readContract({ address: lunch.token, abi: erc20Abi, functionName: 'allowance', args: [owner, UNISWAP_PERMIT2_ADDRESS] }),
    client.readContract({ address: UNISWAP_PERMIT2_ADDRESS, abi: permit2Abi, functionName: 'allowance', args: [owner, lunch.token, router] }),
  ])
  if (approved < amount) {
    return { chainId, address: lunch.token, abi: erc20Abi as Abi, functionName: 'approve', args: [UNISWAP_PERMIT2_ADDRESS, maxUint256], label: 'Approve' }
  }
  const now = Math.floor(Date.now() / 1000)
  if (allowed >= amount && expiration > now + 60) return null
  const tx = buildPermit2ApproveTx({ chainId, token: lunch.token, amount, expiration: now + SALE_ALLOWANCE_SECONDS })
  return { ...tx, abi: tx.abi as Abi, label: 'Allow' }
}
