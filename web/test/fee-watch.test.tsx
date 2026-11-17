import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { useFeeBuybackReview } from '@/components/FeeBuybackNotice'

const fee = vi.hoisted(() => ({ check: vi.fn(), stop: vi.fn(), watch: vi.fn() }))
vi.mock('@bananapus/nana-sdk-core/v6/fee-buyback', async original => ({
  ...(await original<typeof import('@bananapus/nana-sdk-core/v6/fee-buyback')>()),
  isFeePayingCall: () => true,
  checkFeeBuyback: fee.check,
}))
vi.mock('@/lib/fee-buyback-client', () => ({ feeBuybackContext: () => ({ client: { watchBlockNumber: fee.watch }, options: {} }) }))

const calls = [{ chainId: 8453, from: '0x0000000000000000000000000000000000000001', to: '0x0000000000000000000000000000000000000002', data: '0x' }] as unknown as Parameters<typeof useFeeBuybackReview>[0]
function Review() {
  useFeeBuybackReview(calls)
  return null
}

let root: Root | null = null
async function look(state: 'visible' | 'hidden') {
  Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => state })
  await act(async () => { document.dispatchEvent(new Event('visibilitychange')) })
}

afterEach(() => {
  act(() => root?.unmount())
  root = null
  delete (document as { visibilityState?: string }).visibilityState
})

describe('the fee review', () => {
  it('watches blocks only while it can be seen, and checks at once when looked at again', async () => {
    fee.check.mockResolvedValue({ status: 'none', fees: [] })
    fee.watch.mockReturnValue(fee.stop)
    root = createRoot(document.body.appendChild(document.createElement('div')))
    await act(async () => { root!.render(<Review />) })
    expect([fee.check.mock.calls.length, fee.watch.mock.calls.length, fee.stop.mock.calls.length]).toEqual([1, 1, 0])
    expect(fee.watch.mock.calls[0][0].pollingInterval).toBe(4000)

    await look('hidden')
    expect([fee.check.mock.calls.length, fee.watch.mock.calls.length, fee.stop.mock.calls.length]).toEqual([1, 1, 1])

    await look('visible')
    expect([fee.check.mock.calls.length, fee.watch.mock.calls.length, fee.stop.mock.calls.length]).toEqual([2, 2, 1])

    act(() => root?.unmount())
    root = null
    expect(fee.stop).toHaveBeenCalledTimes(2)
  })
})
