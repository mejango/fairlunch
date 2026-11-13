// A lunch's whole life on two testnets, one step per run, with the builders the site uses:
//   FAIR_LUNCH_KEY_FILE=<file holding a testnet key> node scripts/testnet-walk.mjs <state.json> <create|create-host|refund|pay-copy|airdrop|send-home|serve|status|claim|burn|collect|pay-host|buy|sell|probe>
// `probe` drives test/PoolProbe.sol (PROBE_ADDRESS), the adversary: `probe sandwich <burn|collect|buy|sell> <eth|token> <push> [victim amount]`,
// `probe seed <start tick> <lower> <upper> <eth> <tokens>`, `probe unseed <position>`, `probe swap <eth|token> <amount>`, `probe withdraw`.
// FAIR_LUNCH_ADDRESS names the deployment to walk.
// The host is Arbitrum Sepolia and the copy is Sepolia: the one testnet pair Chainlink carries ETH between. Fair
// Lunch must be at the same address on both.
import { jbDirectoryAbi, jbMultiTerminalAbi, jbProjectsAbi, jbTerminalStoreAbi, MappableAsset, NATIVE_TOKEN, parseSuckerDeployerConfig } from '@bananapus/nana-sdk-core'
import { buildBridgeClaimTx, buildBuybackCashOutMetadata, buildBuybackPayMetadata, CCIP_SUCKER_TRANSPORT_VALUES, claimFromSuckerMovement, findSuckerTransportValue, getSuckerMovements, getV6SuckerPairs } from '@bananapus/nana-sdk-core/v6'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { quoteUniswapV4ExactInputSingle } from '@bananapus/nana-sdk-core/v6/uniswap-v4'
import { createPublicClient, createWalletClient, decodeFunctionResult, encodeFunctionData, erc20Abi, formatEther, http, pad, parseEther, zeroHash } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { arbitrumSepolia, sepolia } from 'viem/chains'
import { fairLunchAbi } from '../src/lib/fair-lunch/abi.ts'
import { claimProofOf, claimsAbi, claimsRootOf } from '../src/lib/fair-lunch/claims.ts'

// WALK_AIRDROP=<percent> gives that share of supply to the sender (60%) and one other address (40%).
const LIST = account => [[account, '600000000000000000'], ['0x00000000000000000000000000000000000a11ce', '400000000000000000']]

const LUNCH = process.env.FAIR_LUNCH_ADDRESS
const [stateFile, step] = process.argv.slice(2)
const account = privateKeyToAccount(readFileSync(process.env.FAIR_LUNCH_KEY_FILE, 'utf8').trim())
const side = (chain, rpc) => ({ chain, client: createPublicClient({ chain, transport: http(rpc) }), wallet: createWalletClient({ chain, transport: http(rpc), account }) })
const host = side(arbitrumSepolia, 'https://arbitrum-sepolia-rpc.publicnode.com')
const copy = side(sepolia, 'https://ethereum-sepolia-rpc.publicnode.com')
const state = existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, 'utf8')) : {}
const big = value => JSON.stringify(value, (_, v) => (typeof v === 'bigint' ? v.toString() : v), 1)

const send = async (on, tx) => {
  // Headroom, as the site sends.
  const gas = (await on.client.estimateContractGas({ ...tx, account })) * 12n / 10n
  const receipt = await on.client.waitForTransactionReceipt({ hash: await on.wallet.writeContract({ ...tx, gas }) })
  console.log(`${tx.functionName} on ${on.chain.name}: ${receipt.status}, gas ${receipt.gasUsed}, ${receipt.transactionHash}`)
  if (receipt.status !== 'success') throw new Error('reverted')
  return receipt
}
const wiring = async on => {
  const read = functionName => on.client.readContract({ address: LUNCH, abi: fairLunchAbi, functionName })
  const terminal = await read('TERMINAL')
  return { terminal, store: await on.client.readContract({ address: terminal, abi: jbMultiTerminalAbi, functionName: 'STORE' }), directory: await read('DIRECTORY') }
}
const balanceOf = async (on, id) => {
  const { terminal, store } = await wiring(on)
  return on.client.readContract({ address: store, abi: jbTerminalStoreAbi, functionName: 'balanceOf', args: [terminal, BigInt(id), NATIVE_TOKEN] })
}
const pay = async (on, id, eth, minimum) => {
  const { terminal } = await wiring(on)
  const amount = parseEther(eth)
  return send(on, { address: terminal, abi: jbMultiTerminalAbi, functionName: 'pay', args: [BigInt(id), NATIVE_TOKEN, amount, account.address, minimum, '', '0x'], value: amount })
}
const movements = async () => {
  const [pair] = await getV6SuckerPairs(host.client, { chainId: host.chain.id, projectId: BigInt(state.hostId) })
  return { pair, moves: await getSuckerMovements(copy.client, host.client, { sourceSucker: pair.remote, destinationSucker: pair.local, sourceToken: NATIVE_TOKEN, blockRange: 9000n }) }
}

if (step === 'create' || step === 'create-host') {
  const minutes = Number(process.argv[4] ?? 20)
  const terms = { deadline: Math.floor(Date.now() / 1000) + minutes * 60, salt: pad(`0x${Date.now().toString(16)}`, { size: 32 }) }
  const chainIds = [host.chain.id, copy.chain.id]
  for (const on of step === 'create' ? [host, copy] : [host]) {
    const isHost = on === host
    const projects = await on.client.readContract({ address: (await wiring(on)).directory, abi: jbDirectoryAbi, functionName: 'PROJECTS' })
    const fee = await on.client.readContract({ address: projects, abi: jbProjectsAbi, functionName: 'creationFee' })
    const { deployerConfigurations } = parseSuckerDeployerConfig(on.chain.id, chainIds, [MappableAsset.NATIVE], { version: 6, bridge: 'ccip' })
    const config = {
      name: 'Burrito', symbol: 'BRTO', projectUri: '', hostChainId: BigInt(host.chain.id), token: '0x000000000000000000000000000000000000EEEe', deadline: terms.deadline, creator: account.address,
      keepPercent: 200_000_000, keepCap: parseEther('0.005'), tokenPercent: 100_000_000, vestingDuration: Number(process.env.WALK_CHEF_WEEKS ?? 26) * 604800, claimsPercent: Number(process.env.WALK_AIRDROP ?? 0) * 10_000_000, claimsRoot: process.env.WALK_AIRDROP ? claimsRootOf(LIST(account.address)) : zeroHash, claimsVestingDuration: Number(process.env.WALK_AIRDROP_WEEKS ?? 0) * 604800, salt: terms.salt,
      suckerDeploymentConfiguration: { salt: zeroHash, deployerConfigurations: deployerConfigurations.map(({ deployer }) => ({
        deployer, peer: zeroHash, mappings: isHost ? [] : [{ localToken: NATIVE_TOKEN, minGas: 200_000, remoteToken: pad(NATIVE_TOKEN, { size: 32 }) }],
      })) },
    }
    const call = { address: LUNCH, abi: fairLunchAbi, functionName: 'createFor', args: [config], value: fee }
    const { result: id } = await on.client.simulateContract({ ...call, account })
    await send(on, call)
    state[isHost ? 'hostId' : 'copyId'] = Number(id)
  }
  Object.assign(state, terms)
  writeFileSync(stateFile, big(state))
  const raise = process.argv[5] ?? '0.05'
  await pay(host, state.hostId, raise, parseEther(raise) * 1_000_000n)
  // The copy takes nothing while the host sells tokens.
  if (step === 'create') console.log('copy pay during the raise:', await pay(copy, state.copyId, '0.002', 0n).then(() => 'WENT THROUGH', error => `refused, ${String(error.shortMessage ?? error).slice(0, 160)}`))
  console.log(big(state))
} else if (step === 'pay-copy') {
  await pay(copy, state.copyId, process.argv[4] ?? '0.01', 0n)
  console.log({ copyBalance: formatEther(await balanceOf(copy, state.copyId)) })
} else if (step === 'airdrop') {
  // Sends the list's other address its tokens, with the proof the site builds.
  const claims = await host.client.readContract({ address: LUNCH, abi: fairLunchAbi, functionName: 'CLAIMS' })
  const list = LIST(account.address), id = BigInt(state.hostId)
  await send(host, { address: claims, abi: claimsAbi, functionName: 'claim', args: [id, list[1][0], BigInt(list[1][1]), claimProofOf(list, 1)] })
  console.log({ pool: formatEther(await host.client.readContract({ address: claims, abi: claimsAbi, functionName: 'tokenCountOf', args: [id] })),
    claimed: await host.client.readContract({ address: claims, abi: claimsAbi, functionName: 'claimedOf', args: [id, list[1][0]] }) })
} else if (step === 'release') {
  // Sends the chef the tokens that have vested.
  const claims = await host.client.readContract({ address: LUNCH, abi: fairLunchAbi, functionName: 'CLAIMS' })
  const id = BigInt(state.hostId)
  await send(host, { address: claims, abi: claimsAbi, functionName: 'release', args: [id] })
  console.log({ chefTokens: formatEther(await host.client.readContract({ address: claims, abi: claimsAbi, functionName: 'creatorTokenCountOf', args: [id] })),
    sent: formatEther(await host.client.readContract({ address: claims, abi: claimsAbi, functionName: 'creatorClaimedOf', args: [id] })) })
} else if (step === 'send-home') {
  const call = { address: LUNCH, abi: fairLunchAbi, functionName: 'sendHome', args: [BigInt(state.copyId)] }
  const sending = await balanceOf(copy, state.copyId)
  const value = await findSuckerTransportValue(CCIP_SUCKER_TRANSPORT_VALUES, amount => copy.client.simulateContract({ ...call, account, value: amount }))
  if (value === null) throw new Error('no transport value goes through')
  const before = await copy.client.getBalance({ address: account.address })
  const receipt = await send(copy, { ...call, value })
  const cost = before - await copy.client.getBalance({ address: account.address }) - receipt.gasUsed * receipt.effectiveGasPrice
  console.log({ sent: formatEther(sending), offered: formatEther(value), bridgeCost: formatEther(cost), leftOnCopy: formatEther(await balanceOf(copy, state.copyId)) })
} else if (step === 'serve' || step === 'burn' || step === 'collect') {
  const call = { address: LUNCH, abi: fairLunchAbi, functionName: step, args: [BigInt(state.hostId)] }
  const { result } = await host.client.simulateContract({ ...call, account })
  await send(host, call)
  console.log({ simulated: big(result), balance: formatEther(await balanceOf(host, state.hostId)) })
} else if (step === 'refund') {
  // Until the deadline, tokens go back for what they were paid for. After it this reverts.
  const { terminal } = await wiring(host)
  const before = await balanceOf(host, state.hostId)
  await send(host, { address: terminal, abi: jbMultiTerminalAbi, functionName: 'cashOutTokensOf', args: [account.address, BigInt(state.hostId), parseEther(process.argv[4] ?? '1000'), NATIVE_TOKEN, 0n, account.address, '0x'] })
  console.log({ leftTheLunch: formatEther(before - await balanceOf(host, state.hostId)), balance: formatEther(await balanceOf(host, state.hostId)) })
} else if (step === 'pay-host') {
  await pay(host, state.hostId, process.argv[4] ?? '0.01', 0n)
  console.log({ balance: formatEther(await balanceOf(host, state.hostId)) })
} else if (step === 'buy' || step === 'sell') {
  // As the site trades: the pool's quote less 2%, named to the buyback hook. Without a quoter, any minimum at all.
  const selling = step === 'sell'
  const id = BigInt(state.hostId)
  const amount = parseEther(process.argv[4] ?? (selling ? '1000' : '0.001'))
  const { terminal } = await wiring(host)
  const read = functionName => host.client.readContract({ address: LUNCH, abi: fairLunchAbi, functionName, args: functionName === 'poolKeyOf' ? [id] : [] })
  const [hook, poolKey] = [await read('BUYBACK_REGISTRY'), await read('poolKeyOf')]
  const out = await quoteUniswapV4ExactInputSingle(host.client, { chainId: host.chain.id, poolKey, zeroForOne: !selling, amountIn: amount }).catch(() => 50n)
  const minimum = out - out / 50n
  const tokens = () => host.client.readContract({ address: poolKey.currency1, abi: erc20Abi, functionName: 'balanceOf', args: [account.address] })
  const before = { tokens: await tokens(), eth: await host.client.getBalance({ address: account.address }) }
  await send(host, selling
    ? { address: terminal, abi: jbMultiTerminalAbi, functionName: 'cashOutTokensOf', args: [account.address, id, amount, NATIVE_TOKEN, 0n, account.address, buildBuybackCashOutMetadata({ hook, minimumSwapAmountOut: minimum })] }
    : { address: terminal, abi: jbMultiTerminalAbi, functionName: 'pay', args: [id, NATIVE_TOKEN, amount, account.address, 0n, '', buildBuybackPayMetadata({ hook, amountToSwapWith: 0n, minimumSwapAmountOut: minimum, skipSplits: true })], value: amount })
  console.log({ minimum: formatEther(minimum), tokens: formatEther(await tokens() - before.tokens), eth: formatEther(await host.client.getBalance({ address: account.address }) - before.eth), balance: formatEther(await balanceOf(host, state.hostId)) })
} else if (step === 'probe') {
  const [, , , , action, ...rest] = process.argv
  const probe = { address: process.env.PROBE_ADDRESS, abi: JSON.parse(readFileSync(new URL('../../out/PoolProbe.sol/PoolProbe.json', import.meta.url), 'utf8')).abi }
  const id = BigInt(state.hostId)
  const { terminal } = await wiring(host)
  const key = await host.client.readContract({ address: LUNCH, abi: fairLunchAbi, functionName: 'poolKeyOf', args: [id] })
  const hook = await host.client.readContract({ address: LUNCH, abi: fairLunchAbi, functionName: 'BUYBACK_REGISTRY' })
  const held = async () => ({ eth: await host.client.getBalance({ address: probe.address }), tokens: key.currency1 === '0x0000000000000000000000000000000000000000' ? 0n : await host.client.readContract({ address: key.currency1, abi: erc20Abi, functionName: 'balanceOf', args: [probe.address] }).catch(() => 0n) })
  const run = async (functionName, args, value = 0n) => {
    const before = await held()
    const call = { ...probe, functionName, args, value }
    const simulated = await host.client.simulateContract({ ...call, account }).then(({ result }) => result, error => { console.log(`${functionName} would revert: ${error.shortMessage ?? error.message}`); return null })
    if (simulated === null) return null
    await send(host, call)
    const after = await held()
    console.log({ probeEth: formatEther(after.eth - before.eth - value), probeTokens: formatEther(after.tokens - before.tokens) })
    return simulated
  }
  if (action === 'sandwich') {
    const [victim, side, push, victimAmount] = rest
    const ethFirst = side === 'eth'
    const pushed = parseEther(push)
    const amount = parseEther(victimAmount ?? '0')
    // The victim's trade names the pool's quote less 2%, taken before the push, as the site would.
    const quote = selling => quoteUniswapV4ExactInputSingle(host.client, { chainId: host.chain.id, poolKey: key, zeroForOne: !selling, amountIn: amount }).then(out => out - out / 50n)
    const [target, value, data] = victim === 'buy'
      ? [terminal, amount, encodeFunctionData({ abi: jbMultiTerminalAbi, functionName: 'pay', args: [id, NATIVE_TOKEN, amount, probe.address, 0n, '', buildBuybackPayMetadata({ hook, amountToSwapWith: 0n, minimumSwapAmountOut: await quote(false), skipSplits: true })] })]
      : victim === 'sell'
        ? [terminal, 0n, encodeFunctionData({ abi: jbMultiTerminalAbi, functionName: 'cashOutTokensOf', args: [probe.address, id, amount, NATIVE_TOKEN, 0n, probe.address, buildBuybackCashOutMetadata({ hook, minimumSwapAmountOut: await quote(true) })] })]
        : [LUNCH, 0n, encodeFunctionData({ abi: fairLunchAbi, functionName: victim, args: [id] })]
    const result = await run('sandwich', [key, ethFirst, pushed, target, value, data], (ethFirst ? pushed : 0n) + value)
    if (result) {
      const [back, returned] = result
      const inner = victim === 'burn' || victim === 'collect' ? decodeFunctionResult({ abi: fairLunchAbi, functionName: victim, data: returned }).map(value => formatEther(value)) : undefined
      console.log({ victim, push: `${push} ${side}`, back: formatEther(back), attackerResult: formatEther(back - pushed), [victim]: inner, balance: formatEther(await balanceOf(host, state.hostId)) })
    }
  } else if (action === 'seed') {
    const [start, lower, upper, eth, tokens] = rest
    // Uniswap's own tick-to-price function isn't in the SDK: 1.0001^(tick/2) in Q96 is close enough to start a pool at.
    const sqrtPriceX96 = BigInt(Math.floor(1.0001 ** (Number(start) / 2) * 2 ** 48)) * 2n ** 48n
    console.log({ positionId: String(await run('seed', [key, sqrtPriceX96, Number(lower), Number(upper), parseEther(eth), parseEther(tokens)], parseEther(eth))) })
  } else if (action === 'unseed') await run('unseed', [key, BigInt(rest[0])])
  else if (action === 'swap') console.log({ received: formatEther(await run('swap', [key, rest[0] === 'eth', parseEther(rest[1])], rest[0] === 'eth' ? parseEther(rest[1]) : 0n) ?? 0n) })
  else await run('withdraw', [key.currency1])
} else if (step === 'claim') {
  const { pair, moves } = await movements()
  const ready = moves.filter(move => move.status === 'claimable')
  if (!ready.length) throw new Error(`nothing delivered yet: ${moves.map(move => move.status).join(', ') || 'no movements'}`)
  for (const move of ready) await send(host, buildBridgeClaimTx({ chainId: host.chain.id, sucker: pair.local, claim: claimFromSuckerMovement(move) }))
  console.log({ balance: formatEther(await balanceOf(host, state.hostId)) })
} else {
  const { moves } = await (state.copyId ? movements() : Promise.resolve({ moves: [] })).catch(error => ({ moves: [], error: console.log('movements failed:', error.shortMessage ?? error.message) }))
  const poolKey = await host.client.readContract({ address: LUNCH, abi: fairLunchAbi, functionName: 'poolKeyOf', args: [BigInt(state.hostId)] })
  const tokensPerEth = await quoteUniswapV4ExactInputSingle(host.client, { chainId: host.chain.id, poolKey, zeroForOne: true, amountIn: 10n ** 12n }).then(out => Number(out) / 1e12, () => null)
  console.log(big({ ...state, tokensPerEthAfterFee: tokensPerEth, now: Math.floor(Date.now() / 1000), servedAt: await host.client.readContract({ address: LUNCH, abi: fairLunchAbi, functionName: 'servedAtOf', args: [BigInt(state.hostId)] }), hostBalance: formatEther(await balanceOf(host, state.hostId)), copyBalance: state.copyId ? formatEther(await balanceOf(copy, state.copyId)) : undefined,
    movements: moves.map(move => ({ status: move.status, eth: formatEther(move.leaf.terminalTokenAmount) })),
    wallet: { host: formatEther(await host.client.getBalance({ address: account.address })), copy: formatEther(await copy.client.getBalance({ address: account.address })) } }))
}
