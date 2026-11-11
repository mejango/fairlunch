// Sells on a local fork with the same builders the Swap card uses: node scripts/sell-check.mjs <rpc> <fairLunch> <projectId> <account>
import { buildPermit2ApproveTx, buildUniswapV4ExactInputSwapTx, quoteUniswapV4ExactInputSingle, UNISWAP_PERMIT2_ADDRESS } from '@bananapus/nana-sdk-core/v6/uniswap-v4'
import { createPublicClient, createWalletClient, erc20Abi, http, maxUint256, parseAbi } from 'viem'
import { base } from 'viem/chains'

const [rpc, lunch, id, account] = process.argv.slice(2)
const client = createPublicClient({ chain: base, transport: http(rpc) })
const wallet = createWalletClient({ chain: base, transport: http(rpc), account })
const abi = parseAbi(['function poolKeyOf(uint256) view returns ((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks))'])
const poolKey = await client.readContract({ address: lunch, abi, functionName: 'poolKeyOf', args: [BigInt(id)] })
const token = poolKey.currency1
const held = await client.readContract({ address: token, abi: erc20Abi, functionName: 'balanceOf', args: [account] })
const amount = held / 10n
const send = async tx => client.waitForTransactionReceipt({ hash: await wallet.writeContract(tx) })
await send({ address: token, abi: erc20Abi, functionName: 'approve', args: [UNISWAP_PERMIT2_ADDRESS, maxUint256] })
await send(buildPermit2ApproveTx({ chainId: 8453, token, amount, expiration: Math.floor(Date.now() / 1000) + 86400 * 365 }))
const out = await quoteUniswapV4ExactInputSingle(client, { chainId: 8453, poolKey, zeroForOne: false, amountIn: amount })
const before = await client.getBalance({ address: account })
const receipt = await send(buildUniswapV4ExactInputSwapTx({ chainId: 8453, poolKey, zeroForOne: false, amountIn: amount, minimumAmountOut: out - out / 50n, recipient: account, deadline: BigInt(Math.floor(Date.now() / 1000) + 86400 * 365) }))
const after = await client.getBalance({ address: account })
const left = await client.readContract({ address: token, abi: erc20Abi, functionName: 'balanceOf', args: [account] })
console.log({ status: receipt.status, sold: held - left === amount, quotedWei: out, gainedWei: after - before + receipt.gasUsed * receipt.effectiveGasPrice })
