// Makes a lunch on two local forks (host first, then its copy), pays the copy, and sends that home, with the builders
// the site uses: node scripts/copy-check.mjs <hostRpc> <copyRpc> <fairLunch>
// LUNCH_ACCOUNT, LUNCH_NAME, LUNCH_SYMBOL, LUNCH_MINUTES (on the host's clock) and LUNCH_RAISE dress it for a local look.
import { jbDirectoryAbi, jbMultiTerminalAbi, jbProjectsAbi, jbTerminalStoreAbi, MappableAsset, NATIVE_TOKEN, parseSuckerDeployerConfig } from '@bananapus/nana-sdk-core'
import { CCIP_SUCKER_TRANSPORT_VALUES, findSuckerTransportValue, getSuckerMovements, getV6SuckerPairs } from '@bananapus/nana-sdk-core/v6'
import { createPublicClient, createWalletClient, http, pad, parseEther, zeroHash } from 'viem'
import { base, optimism } from 'viem/chains'
import { fairLunchAbi } from '../src/lib/fair-lunch/abi.ts'
import { claimsRootOf } from '../src/lib/fair-lunch/claims.ts'

const [hostRpc, copyRpc, lunch] = process.argv.slice(2)
const account = process.env.LUNCH_ACCOUNT ?? '0x1234567890123456789012345678901234567890'
const sides = [[base, hostRpc], [optimism, copyRpc]].map(([chain, rpc]) => ({
  chain, client: createPublicClient({ chain, transport: http(rpc) }), wallet: createWalletClient({ chain, transport: http(rpc), account }),
}))
for (const { client } of sides) {
  await client.request({ method: 'anvil_setBalance', params: [account, '0x56bc75e2d63100000'] })
  await client.request({ method: 'anvil_autoImpersonateAccount', params: [true] })
}
const send = async (side, tx) => {
  // Headroom, as the site sends: a bare estimate runs out when a pool's oracle writes in the mined block and not the estimated one.
  const gas = (await side.client.estimateContractGas(tx)) * 12n / 10n
  const receipt = await side.client.waitForTransactionReceipt({ hash: await side.wallet.writeContract({ ...tx, gas }) })
  if (receipt.status !== 'success') throw new Error(`${tx.functionName} reverted on ${side.chain.name}: ${receipt.transactionHash}`)
  return receipt
}
const times = await Promise.all(sides.map(async ({ client }) => Number((await client.getBlock()).timestamp)))
const chainIds = sides.map(side => side.chain.id)
const terms = { deadline: process.env.LUNCH_MINUTES ? times[0] + Number(process.env.LUNCH_MINUTES) * 60 : Math.max(...times) + 3600, salt: pad(`0x${Date.now().toString(16)}`, { size: 32 }) }

// LUNCH_AIRDROP=<percent> gives that share of supply to the sender (60%) and one other address (40%).
const list = [[account, '600000000000000000'], ['0x00000000000000000000000000000000000a11ce', '400000000000000000']]
const claims = process.env.LUNCH_AIRDROP ? { percent: Number(process.env.LUNCH_AIRDROP) * 10_000_000, root: claimsRootOf(list) } : { percent: 0, root: zeroHash }
if (process.env.LUNCH_AIRDROP) console.log(JSON.stringify({ claims: list }))
const ids = []
for (const side of sides) {
  const isHost = side === sides[0]
  const read = functionName => side.client.readContract({ address: lunch, abi: fairLunchAbi, functionName })
  const projects = await side.client.readContract({ address: await read('DIRECTORY'), abi: jbDirectoryAbi, functionName: 'PROJECTS' })
  const fee = await side.client.readContract({ address: projects, abi: jbProjectsAbi, functionName: 'creationFee' })
  const { deployerConfigurations } = parseSuckerDeployerConfig(side.chain.id, chainIds, [MappableAsset.NATIVE], { version: 6, bridge: 'ccip' })
  const config = {
    name: process.env.LUNCH_NAME ?? 'Burrito', symbol: process.env.LUNCH_SYMBOL ?? 'BRTO', projectUri: '', hostChainId: BigInt(chainIds[0]), token: '0x000000000000000000000000000000000000EEEe', deadline: terms.deadline, creator: account,
    keepPercent: 200_000_000, keepCap: parseEther('0.5'), tokenPercent: 100_000_000, vestingDuration: 52 * 604800, claimsPercent: claims.percent, claimsRoot: claims.root, salt: terms.salt,
    suckerDeploymentConfiguration: { salt: zeroHash, deployerConfigurations: deployerConfigurations.map(({ deployer }) => ({
      deployer, peer: zeroHash, mappings: isHost ? [] : [{ localToken: NATIVE_TOKEN, minGas: 200_000, remoteToken: pad(NATIVE_TOKEN, { size: 32 }) }],
    })) },
  }
  const call = { address: lunch, abi: fairLunchAbi, functionName: 'createFor', args: [config], value: fee, account }
  const { result: id } = await side.client.simulateContract(call)
  await send(side, call)
  ids.push(id)
  side.terminal = await read('TERMINAL')
}
const [host, copy] = sides
console.log({ hostId: ids[0], copyId: ids[1] })

const paid = parseEther('0.3'), raise = parseEther(process.env.LUNCH_RAISE ?? '1')
await send(host, { address: host.terminal, abi: jbMultiTerminalAbi, functionName: 'pay', args: [ids[0], NATIVE_TOKEN, raise, account, 0n, '', '0x'], value: raise })
await send(copy, { address: copy.terminal, abi: jbMultiTerminalAbi, functionName: 'pay', args: [ids[1], NATIVE_TOKEN, paid, account, 0n, '', '0x'], value: paid })
if (process.argv.includes('--stop-before-send')) process.exit(0)

const sendHome = { address: lunch, abi: fairLunchAbi, functionName: 'sendHome', args: [ids[1]], account }
const value = await findSuckerTransportValue(CCIP_SUCKER_TRANSPORT_VALUES, amount => copy.client.simulateContract({ ...sendHome, value: amount }))
const before = await copy.client.getBalance({ address: account })
const receipt = await send(copy, { ...sendHome, value })
const spent = before - await copy.client.getBalance({ address: account }) - receipt.gasUsed * receipt.effectiveGasPrice
const store = await copy.client.readContract({ address: copy.terminal, abi: jbMultiTerminalAbi, functionName: 'STORE' })
const left = await copy.client.readContract({ address: store, abi: jbTerminalStoreAbi, functionName: 'balanceOf', args: [copy.terminal, ids[1], NATIVE_TOKEN] })
const [pair] = await getV6SuckerPairs(host.client, { chainId: host.chain.id, projectId: ids[0] })
const movements = await getSuckerMovements(copy.client, host.client, { sourceSucker: pair.remote, destinationSucker: pair.local, sourceToken: NATIVE_TOKEN, blockRange: 9000n }) // the public fork upstream caps log scans at 10,000 blocks
console.log({ status: receipt.status, offeredWei: value, bridgeCostWei: spent, leftOnCopyWei: left,
  movements: movements.map(m => ({ status: m.status, wei: m.leaf.terminalTokenAmount, toFairLunch: m.leaf.beneficiary.slice(-40).toLowerCase() === lunch.slice(2).toLowerCase() })) })
