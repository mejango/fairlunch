import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { LunchView } from '@/components/LunchView'
import type { Copy, Lunch } from '@/lib/fair-lunch/reads'

const reads = vi.hoisted(() => ({ readLunch: vi.fn(), readCopies: vi.fn(), readHostOf: vi.fn(), readPoolFees: vi.fn() }))
vi.mock('@/lib/fair-lunch/reads', () => reads)
vi.mock('@/hooks/useWallet', () => ({ useWallet: () => ({ address: undefined, isConnected: false }) }))
// The page's buttons and chart are their own units: a label is all the page decides about them.
vi.mock('@/components/TxAction', () => ({ TxAction: ({ label }: { label: string }) => <button type="button">{label}</button> }))
vi.mock('@/components/PriceChart', () => ({ PriceChart: () => <div>chart</div> }))
vi.mock('@/components/ChainIcon', () => ({ ChainIcon: () => null }))

const ETH = 10n ** 18n
const NOW = 1_800_000_000
const lunch = (over: Partial<Lunch>): Lunch => ({
  chainId: 8453, projectId: 7, hostChainId: 8453, startedAt: NOW - 3600, deadline: NOW + 3600, servedAt: 0, creator: '0x0000000000000000000000000000000000000001',
  keepPercent: 200_000_000n, keepCap: ETH, tokenPercent: 100_000_000n, vestingDuration: 52 * 604800, vestingWallet: '0x0000000000000000000000000000000000000002',
  token: '0x0000000000000000000000000000000000000003', name: 'Sandwich', symbol: 'SAND', uri: '', balance: 3n * ETH, supply: 3_000_000n * ETH,
  poolKey: { currency0: '0x0000000000000000000000000000000000000000', currency1: '0x0000000000000000000000000000000000000003', fee: 10000, tickSpacing: 200, hooks: '0x0000000000000000000000000000000000000004' },
  price: null, pooledEth: null, ...over,
})

let root: Root | null = null
async function show(found: Lunch | null, copies: Copy[] = [], fees = { tokens: 5n * ETH, eth: ETH / 100n }): Promise<string> {
  vi.spyOn(Date, 'now').mockReturnValue(NOW * 1000)
  reads.readLunch.mockResolvedValue(found)
  reads.readCopies.mockResolvedValue(copies)
  reads.readPoolFees.mockResolvedValue(fees)
  const node = document.body.appendChild(document.createElement('div'))
  root = createRoot(node)
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  await act(async () => {
    root!.render(<QueryClientProvider client={client}><LunchView chainId={8453} projectId={7} burns={[]} logoUri={null} /></QueryClientProvider>)
  })
  // The page's reads settle over a few turns: the lunch first, then what hangs off it.
  await act(async () => { await new Promise(resolve => setTimeout(resolve, 30)) })
  return node.textContent ?? ''
}
const buttons = () => [...document.querySelectorAll('button')].map(button => button.textContent)

afterEach(() => {
  act(() => root?.unmount())
  root = null
  document.body.innerHTML = ''
})

describe('LunchView', () => {
  it('takes payments while cooking, and nothing else', async () => {
    const text = await show(lunch({}))
    expect(text).toContain('Cooking lunch')
    expect(text).toContain('1h 0m left')
    // Half the fundraise's time is gone.
    const bar = document.querySelector<HTMLProgressElement>('progress[aria-label="Time gone of the fundraise"]')
    expect([bar?.value, bar?.max]).toEqual([3600, 7200])
    expect(text).toContain('No refunds')
    expect(buttons()).toEqual(['Fund'])
  })

  it('offers only Serve once the deadline passes with something raised', async () => {
    const text = await show(lunch({ deadline: NOW - 1 }))
    expect(text).toContain('Ready to serve')
    expect(buttons()).toEqual(['🍽️ Serve it'])
  })

  it('offers nothing when nobody paid', async () => {
    const text = await show(lunch({ deadline: NOW - 1, balance: 0n }))
    expect(text).toContain('Nobody came')
    expect(buttons()).toEqual([])
  })

  it('swaps but does not burn while the price average builds', async () => {
    const text = await show(lunch({ deadline: NOW - 600, servedAt: NOW - 60, price: 0.000001 }))
    expect(text).toContain('Lunch is served')
    expect(text).toContain('buybacks start in 29m 0s')
    expect(text).toContain('See the pool on Uniswap')
    expect(buttons()).toEqual(['↓', 'Buy SAND', 'Collect'])
  })

  it('swaps, burns what waits and collects once eating', async () => {
    const text = await show(lunch({ deadline: NOW - 9000, servedAt: NOW - 7200, price: 0.000001, balance: ETH / 4n }))
    expect(text).toContain('Lunch is served')
    expect(text).toContain('0.01 ETH\n5 SAND')
    expect(buttons()).toEqual(['↓', 'Buy SAND', '🔥 Buy and burn', 'Collect'])
  })

  it('hides Burn and Collect when there is nothing for them to move', async () => {
    await show(lunch({ deadline: NOW - 9000, servedAt: NOW - 7200, price: 0.000001, balance: 0n }), [], { tokens: 0n, eth: 0n })
    expect(buttons()).toEqual(['↓', 'Buy SAND'])
  })

  it('lists other chains with only the buttons that have something to move', async () => {
    const copy = (over: Partial<Copy>): Copy => ({ chainId: 10, projectId: 3, balance: 0n, onTheWay: 0n, hostSucker: '0x0000000000000000000000000000000000000005', claims: [], ...over })
    const claim = { token: '0x000000000000000000000000000000000000EEEe', proof: [], leaf: { index: 0n, beneficiary: '0x', projectTokenCount: 1n, terminalTokenAmount: ETH / 10n, metadata: '0x' } } as unknown as Copy['claims'][number]
    const text = await show(lunch({}), [
      copy({ balance: ETH / 2n, onTheWay: ETH / 5n }),
      copy({ chainId: 42161, claims: [claim] }),
    ])
    expect(text).toContain('0.5 ETH waiting, 0.2 ETH on the way')
    expect(buttons()).toEqual(['Fund', 'Send home', 'Bring in 0.1 ETH'])
  })

  it('points a copy at its lunch, and says so when there is none', async () => {
    reads.readHostOf.mockResolvedValue({ chainId: 8453, projectId: 41 })
    expect(await show(null)).toContain('This lunch is on Base')
    expect(document.querySelector('a')?.getAttribute('href')).toBe('/base:41')
    act(() => root?.unmount())
    reads.readHostOf.mockResolvedValue(null)
    expect(await show(null)).toContain('No lunch here')
  })
})
