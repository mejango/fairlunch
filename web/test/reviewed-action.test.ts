/**
 * useReviewedAction, the site's one send hook, through the SDK's real engine with a fake chain and wallet: a confirmed
 * review sends exactly the prepared bytes once, and a declined review or View as sends nothing.
 */

import { QueryClient } from '@tanstack/react-query'
import { createElement, createRef, forwardRef, useImperativeHandle } from 'react'
import TestRenderer, { act } from 'react-test-renderer'
import { createWalletClient, custom, encodeFunctionData, hexToBigInt, numberToHex, type Abi, type Address, type Hex } from 'viem'
import { jbMultiTerminalAbi, NATIVE_TOKEN } from '@bananapus/nana-sdk-core'
import { registerReviewHandler } from '@bananapus/nana-sdk-core/review'
import { afterEach, describe, expect, it, vi } from 'vitest'

const ALICE = '0x2222222222222222222222222222222222222222' as Address
const TERMINAL = '0x5555555555555555555555555555555555555555' as Address

const queries = new QueryClient()
vi.mock('@tanstack/react-query', async original => ({
  ...(await original<typeof import('@tanstack/react-query')>()),
  useQueryClient: () => queries,
}))

/** One chain whose sends are mined in the next block; eth_call always succeeds. */
const chain = { head: 100n, nonce: 7, mined: new Map<string, bigint>(), sent: new Map<string, { to: Address; data: Hex; value: bigint; nonce: number }>() }
const block = (number: bigint) => ({ number, hash: numberToHex(number, { size: 32 }), timestamp: 1_000n, transactions: [] })
function receipt(hash: Hex) {
  const mined = chain.mined.get(hash)!
  return { transactionHash: hash, blockNumber: mined, blockHash: numberToHex(mined, { size: 32 }), status: 'success', transactionIndex: 0, from: ALICE, to: chain.sent.get(hash)?.to, logs: [] }
}
const client = {
  chain: { id: 84532, name: 'Base Sepolia' },
  request: async ({ method }: { method: string }) => {
    if (method === 'eth_call') return '0x'
    if (method === 'eth_getBlockByNumber') return { number: numberToHex(chain.head), hash: numberToHex(chain.head, { size: 32 }) }
    throw new Error(`unexpected ${method}`)
  },
  estimateGas: async () => 21_000n,
  readContract: async () => { throw new Error('no token reads here') },
  getChainId: async () => 84532,
  getBlockNumber: async () => chain.head,
  getTransactionCount: async () => chain.nonce,
  getBlock: async ({ blockNumber }: { blockNumber?: bigint } = {}) => block(blockNumber ?? chain.head),
  getTransaction: async ({ hash }: { hash: Hex }) => {
    const tx = chain.sent.get(hash)
    if (!tx) throw Object.assign(new Error('not found'), { name: 'TransactionNotFoundError' })
    const mined = chain.mined.get(hash)!
    return { hash, chainId: 84532, from: ALICE, to: tx.to, input: tx.data, value: tx.value, nonce: tx.nonce, blockNumber: mined, blockHash: numberToHex(mined, { size: 32 }), transactionIndex: 0 }
  },
  getTransactionReceipt: async ({ hash }: { hash: Hex }) => receipt(hash),
  waitForTransactionReceipt: async ({ hash }: { hash: Hex }) => receipt(hash),
}

/** What the wallet was asked to send, in order. The SDK's adapter reaches a wallet only through its provider. */
const walletSends: { to: Address; data: Hex; value: bigint }[] = []
const wallet = createWalletClient({
  transport: custom({
    request: async ({ method, params }: { method: string; params?: unknown }) => {
      if (method === 'eth_chainId') return numberToHex(84532)
      if (method !== 'eth_sendTransaction') throw new Error(`Unexpected wallet request ${method}`)
      const [tx] = params as [{ to: Address; data?: Hex; value?: Hex }]
      const sent = { to: tx.to, data: tx.data ?? '0x', value: tx.value ? hexToBigInt(tx.value) : 0n }
      walletSends.push(sent)
      const hash = numberToHex(walletSends.length, { size: 32 })
      chain.sent.set(hash, { ...sent, nonce: chain.nonce })
      chain.head += 1n
      chain.nonce += 1
      chain.mined.set(hash, chain.head)
      return hash
    },
  }, { retryCount: 0 }),
})

/** The wallet wagmi sends through: another one can expose the same account and chain. */
const connector = vi.hoisted(() => ({ uid: 'wallet-a' }))
vi.mock('@wagmi/core', async original => ({
  ...(await original<typeof import('@wagmi/core')>()),
  getAccount: () => ({ address: ALICE, chainId: 84532, connector: { uid: connector.uid, id: 'test' } }),
  getWalletClient: async () => wallet,
  getPublicClient: () => client,
  switchChain: vi.fn(),
}))
vi.mock('@/hooks/useWallet', () => ({ useWallet: () => ({ isConnected: true, address: '0x2222222222222222222222222222222222222222' }) }))
vi.mock('@/providers/Providers', () => ({ wagmiConfig: {} }))
vi.mock('@/lib/safe-connector', async original => ({
  ...(await original<typeof import('@/lib/safe-connector')>()),
  isSafeConnection: () => false,
}))

import { useReviewedAction, type TxRequest } from '@/hooks/useReviewedAction'
import { clearViewAs, setViewAs, VIEW_AS_WRITE_BLOCKED } from '@/lib/viewAs'

type Action = ReturnType<typeof useReviewedAction>
const Harness = forwardRef<Action>(function Harness(_, ref) {
  const value = useReviewedAction()
  useImperativeHandle(ref, () => value, [value])
  return null
})

/** A payment as `payTx` builds it, to a project of its own so each test's hold is its own. */
const pay = (project: bigint): TxRequest => ({
  chainId: 84532, address: TERMINAL, abi: jbMultiTerminalAbi as Abi, functionName: 'pay',
  args: [project, NATIVE_TOKEN, 10n ** 16n, ALICE, 5n, '', '0x'], value: 10n ** 16n, label: 'Fund',
})

const unregister: (() => void)[] = []
afterEach(() => {
  while (unregister.length) unregister.pop()!()
  walletSends.length = 0
  connector.uid = 'wallet-a'
  clearViewAs()
})

async function run(request: TxRequest, review: Parameters<typeof registerReviewHandler>[0]) {
  unregister.push(registerReviewHandler(review))
  const ref = createRef<Action>()
  let renderer!: TestRenderer.ReactTestRenderer
  await act(async () => { renderer = TestRenderer.create(createElement(Harness, { ref })) })
  await act(async () => { await ref.current!.run(request, ALICE) })
  const { phase, error, hash } = ref.current!
  await act(async () => renderer.unmount())
  return { phase, error, hash }
}

describe('useReviewedAction', () => {
  it('sends exactly the prepared call once after its review is confirmed', async () => {
    const request = pay(1n)
    const models: { to: string; data: string; value: bigint }[] = []
    const ended = await run(request, async prompt => {
      models.push(...prompt.model.calls.map(({ to, data, value }) => ({ to, data, value })))
      return prompt.confirmation
    })
    const data = encodeFunctionData({ abi: request.abi, functionName: request.functionName, args: request.args as unknown[] })
    expect(models).toEqual([{ to: TERMINAL, data, value: request.value }])
    expect(walletSends).toEqual([{ to: TERMINAL, data, value: request.value }])
    expect(ended).toEqual({ phase: 'success', error: null, hash: numberToHex(1, { size: 32 }) })
  })

  it('sends nothing when the review is declined, and a plain true confirms nothing', async () => {
    expect(await run(pay(2n), async () => null)).toMatchObject({ phase: 'idle', error: null })
    // The SDK takes only the confirmation it minted for the prompt.
    const forged = await run(pay(2n), (async () => true) as unknown as Parameters<typeof registerReviewHandler>[0])
    expect(forged.phase).not.toBe('success')
    expect(walletSends).toEqual([])
  })

  it('refuses while viewing as another account, before the wallet', async () => {
    setViewAs('0x3333333333333333333333333333333333333333')
    const review = vi.fn(async (prompt: { confirmation: unknown }) => prompt.confirmation)
    const ended = await run(pay(3n), review as unknown as Parameters<typeof registerReviewHandler>[0])
    expect(ended).toMatchObject({ phase: 'error', error: VIEW_AS_WRITE_BLOCKED })
    expect(walletSends).toEqual([])
  })

  it('sends nothing through a wallet that replaced the reviewed one while its review was open', async () => {
    // Wallet B, with the same account on the same chain, becomes the active connector before the person confirms.
    const ended = await run(pay(4n), async prompt => {
      connector.uid = 'wallet-b'
      return prompt.confirmation
    })
    expect(walletSends).toEqual([])
    expect(ended).toMatchObject({ phase: 'error', error: 'Wallet connection changed. Review the transaction again.' })
  })
})
