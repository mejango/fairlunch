import { focusManager, QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, type ReactNode } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { LunchView } from '@/components/LunchView'
import { PriceChart } from '@/components/PriceChart'
import { QUERY_DEFAULTS } from '@/lib/query-defaults'
import { ETH, lunch, NOW } from './support/lunch'

const reads = vi.hoisted(() => ({ readLunch: vi.fn(), readCopies: vi.fn(), readHostOf: vi.fn(), readPoolFees: vi.fn(), readVesting: vi.fn(), readServed: vi.fn(), readClaimList: vi.fn(), readClaimed: vi.fn(), readPriceHistory: vi.fn(), claimCallOf: vi.fn(), releaseCall: vi.fn() }))
vi.mock('@/lib/fair-lunch/reads', () => reads)
const quotes = vi.hoisted(() => ({ quoteSwap: vi.fn(), quoteSwapFor: vi.fn() }))
vi.mock('@/lib/fair-lunch/writes', async original => ({ ...(await original<typeof import('@/lib/fair-lunch/writes')>()), ...quotes }))
vi.mock('@/hooks/useWallet', () => ({ useWallet: () => ({ address: undefined, isConnected: false }) }))
vi.mock('@/components/TxAction', () => ({ TxAction: ({ label }: { label: string }) => <button type="button">{label}</button> }))
vi.mock('@/components/ChainIcon', () => ({ ChainIcon: () => null }))

const served = lunch({ deadline: NOW - 9000, servedAt: NOW - 7200, price: 0.000001, claimsPercent: 100_000_000n, claimsTokens: 1000n * ETH })
/** A history whose points are `width` seconds apart. */
const history = (width: number) => ({ short: false, points: [0, 1, 2].map(i => ({ time: NOW - (2 - i) * width, price: 0.000001 })) })

let root: Root | null = null
/** Renders with the site's own query defaults, on a clock the test moves. */
async function show(view: ReactNode) {
  root = createRoot(document.body.appendChild(document.createElement('div')))
  const client = new QueryClient({ defaultOptions: { queries: QUERY_DEFAULTS } })
  await act(async () => { root!.render(<QueryClientProvider client={client}>{view}</QueryClientProvider>) })
  await pass(0)
}
const pass = (seconds: number) => act(async () => { await vi.advanceTimersByTimeAsync(seconds * 1000) })
const page = <LunchView chainId={8453} projectId={7} burns={[]} logoUri={null} />

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(NOW * 1000)
  reads.readLunch.mockResolvedValue(lunch({}))
  reads.readCopies.mockResolvedValue([])
  reads.readPoolFees.mockResolvedValue({ tokens: 0n, money: 0n })
  reads.readVesting.mockResolvedValue({ total: 0n, sent: 0n })
  reads.readServed.mockResolvedValue(null)
  reads.readClaimList.mockResolvedValue([['0x0000000000000000000000000000000000000009', '1000000000000000000']])
  reads.readClaimed.mockResolvedValue([0n])
  reads.readPriceHistory.mockResolvedValue(history(720))
  quotes.quoteSwap.mockResolvedValue(ETH)
})

afterEach(() => {
  act(() => root?.unmount())
  root = null
  document.body.innerHTML = ''
  focusManager.setFocused(undefined)
})

describe('how often a page reads', () => {
  it('asks for the lunch again every 30 seconds, not sooner', async () => {
    await show(page)
    expect(reads.readLunch).toHaveBeenCalledTimes(1)
    await pass(29)
    expect(reads.readLunch).toHaveBeenCalledTimes(1)
    await pass(1)
    expect(reads.readLunch).toHaveBeenCalledTimes(2)
  })

  it('asks nothing while hidden, and at once when looked at again', async () => {
    await show(page)
    act(() => focusManager.setFocused(false))
    await pass(120)
    expect(reads.readLunch).toHaveBeenCalledTimes(1)
    act(() => focusManager.setFocused(true))
    await pass(0)
    expect(reads.readLunch).toHaveBeenCalledTimes(2)
  })

  it('tries a failed read once more', async () => {
    reads.readLunch.mockRejectedValue(new Error('The node hiccuped.'))
    await show(page)
    await pass(5)
    expect(reads.readLunch).toHaveBeenCalledTimes(2)
  })

  it('does not try a read again that the rate limit refused', async () => {
    reads.readLunch.mockRejectedValue(new Error('Request failed.', { cause: Object.assign(new Error('Too many requests.'), { status: 429 }) }))
    await show(page)
    await pass(5)
    expect(reads.readLunch).toHaveBeenCalledTimes(1)
  })

  it('reads the chart again when a point of it has passed, not sooner', async () => {
    await show(<PriceChart lunch={served} burns={[]} />)
    await pass(719)
    expect(reads.readPriceHistory).toHaveBeenCalledTimes(1)
    await pass(1)
    expect(reads.readPriceHistory).toHaveBeenCalledTimes(2)
  })

  it('reads a chart of narrow points every 30 seconds', async () => {
    reads.readPriceHistory.mockResolvedValue(history(5))
    await show(<PriceChart lunch={served} burns={[]} />)
    await pass(29)
    expect(reads.readPriceHistory).toHaveBeenCalledTimes(1)
    await pass(1)
    expect(reads.readPriceHistory).toHaveBeenCalledTimes(2)
  })

  it('asks the pool for one quote once the typing pauses', async () => {
    reads.readLunch.mockResolvedValue(served)
    await show(page)
    const input = document.querySelector<HTMLInputElement>('section[aria-label="Swap"] input')!
    const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!
    for (const text of ['1', '12', '125']) {
      act(() => { setValue.call(input, text); input.dispatchEvent(new Event('input', { bubbles: true })) })
      await pass(0.1)
    }
    expect(quotes.quoteSwap).not.toHaveBeenCalled()
    await pass(0.3)
    expect(quotes.quoteSwap.mock.calls.map(call => call[1])).toEqual([125n * ETH])
  })

  it('reads what the airdrop has sent only while its list is open', async () => {
    reads.readLunch.mockResolvedValue(served)
    await show(page)
    await pass(60)
    expect(reads.readClaimed).not.toHaveBeenCalled()
    const list = [...document.querySelectorAll('details')].find(details => details.textContent?.includes('Airdrop'))!
    act(() => { list.open = true; list.dispatchEvent(new Event('toggle')) })
    await pass(0)
    expect(reads.readClaimed).toHaveBeenCalledTimes(1)
  })
})
