// A lunch's whole life on two testnets, one step per run, with the builders the site uses:
//   FAIR_LUNCH_KEY_FILE=<file holding a testnet key> node scripts/testnet-walk.mjs <state.json> <create|send-home|serve|status|claim|burn|collect>
// The host is Arbitrum Sepolia and the copy is Sepolia: the one testnet pair Chainlink carries ETH between. Fair
// Lunch must be at the same address on both.
import { jbDirectoryAbi, jbMultiTerminalAbi, jbProjectsAbi, jbTerminalStoreAbi, MappableAsset, NATIVE_TOKEN, parseSuckerDeployerConfig } from '@bananapus/nana-sdk-core'
import { buildBridgeClaimTx, CCIP_SUCKER_TRANSPORT_VALUES, claimFromSuckerMovement, findSuckerTransportValue, getSuckerMovements, getV6SuckerPairs } from '@bananapus/nana-sdk-core/v6'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { createPublicClient, createWalletClient, formatEther, http, pad, parseEther, zeroHash } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { arbitrumSepolia, sepolia } from 'viem/chains'
import { fairLunchAbi } from '../src/lib/fair-lunch/abi.ts'

const LUNCH = '0x5b572319a362683a6735a00876709e3dd10b0557'
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

if (step === 'create') {
  const minutes = Number(process.argv[4] ?? 20)
  const terms = { deadline: Math.floor(Date.now() / 1000) + minutes * 60, salt: pad(`0x${Date.now().toString(16)}`, { size: 32 }) }
  const chainIds = [host.chain.id, copy.chain.id]
  for (const on of [host, copy]) {
    const isHost = on === host
    const projects = await on.client.readContract({ address: (await wiring(on)).directory, abi: jbDirectoryAbi, functionName: 'PROJECTS' })
    const fee = await on.client.readContract({ address: projects, abi: jbProjectsAbi, functionName: 'creationFee' })
    const { deployerConfigurations } = parseSuckerDeployerConfig(on.chain.id, chainIds, [MappableAsset.NATIVE], { version: 6, bridge: 'ccip' })
    const config = {
      name: 'Burrito', symbol: 'BRTO', projectUri: '', hostChainId: BigInt(host.chain.id), deadline: terms.deadline, creator: account.address,
      keepPercent: 200_000_000, keepCap: parseEther('0.005'), tokenPercent: 100_000_000, vestingDuration: 26 * 604800, salt: terms.salt,
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
  await pay(host, state.hostId, '0.05', parseEther('0.05') * 1_000_000n)
  await pay(copy, state.copyId, '0.02', 0n)
  console.log(big(state))
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
} else if (step === 'pay-host') {
  await pay(host, state.hostId, process.argv[4] ?? '0.01', 0n)
  console.log({ balance: formatEther(await balanceOf(host, state.hostId)) })
} else if (step === 'claim') {
  const { pair, moves } = await movements()
  const ready = moves.filter(move => move.status === 'claimable')
  if (!ready.length) throw new Error(`nothing delivered yet: ${moves.map(move => move.status).join(', ') || 'no movements'}`)
  for (const move of ready) await send(host, buildBridgeClaimTx({ chainId: host.chain.id, sucker: pair.local, claim: claimFromSuckerMovement(move) }))
  console.log({ balance: formatEther(await balanceOf(host, state.hostId)) })
} else {
  const record = await host.client.readContract({ address: LUNCH, abi: fairLunchAbi, functionName: 'recordOf', args: [BigInt(state.hostId)] })
  const { moves } = await movements().catch(error => ({ moves: [], error: console.log('movements failed:', error.shortMessage ?? error.message) }))
  console.log(big({ ...state, now: Math.floor(Date.now() / 1000), servedAt: record.servedAt, hostBalance: formatEther(await balanceOf(host, state.hostId)), copyBalance: formatEther(await balanceOf(copy, state.copyId)),
    movements: moves.map(move => ({ status: move.status, eth: formatEther(move.leaf.terminalTokenAmount) })),
    wallet: { host: formatEther(await host.client.getBalance({ address: account.address })), copy: formatEther(await copy.client.getBalance({ address: account.address })) } }))
}
