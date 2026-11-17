// @vitest-environment node
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { indexedOf, listLunches } from '@/lib/fair-lunch/indexed'
import { findMade, type MadeTerms } from '@/lib/fair-lunch/reads'

const read = vi.hoisted(() => vi.fn())
vi.mock('@/lib/jbcenter-rpc', () => ({ jbCenterPublicClient: () => ({ readContract: read }) }))

const ADDRESS = '0x00000000000000000000000000000000000000aa'
/** The index's answer to every request, counted. */
const index = (data: unknown) => {
  const fetched = vi.fn(async () => new Response(JSON.stringify({ data }), { headers: { 'content-type': 'application/json' } }))
  vi.stubGlobal('fetch', fetched)
  return fetched
}

beforeEach(() => {
  read.mockImplementation(async ({ functionName }: { functionName: string }) => (functionName === 'projectIdOf' ? 0n : ADDRESS))
})

describe('what the server asks the index', () => {
  it("reads a lunch page's logo and burns in one request", async () => {
    const fetched = index({ projects: { items: [{ logoUri: 'ipfs://logo' }] }, burnEvents: { items: [{ timestamp: 5, amount: '7', txHash: '0x01' }] } })
    expect(await indexedOf(11155111, 3)).toEqual({ logoUri: 'ipfs://logo', burns: [{ time: 5, amount: '7', txHash: '0x01' }] })
    expect(fetched).toHaveBeenCalledTimes(1)
  })

  it('answers visits within 30 seconds with one read of the list', async () => {
    vi.useFakeTimers()
    const fetched = index({ projects: { items: [] } })
    await listLunches('testnet')
    await listLunches('testnet')
    expect(fetched).toHaveBeenCalledTimes(1)
    vi.advanceTimersByTime(30_000)
    await listLunches('testnet')
    expect(fetched).toHaveBeenCalledTimes(2)
  })

  it('reads a list that failed again on the next visit', async () => {
    // Long after anything an earlier visit kept.
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(Date.now() + 3_600_000)
    vi.stubGlobal('fetch', vi.fn(async () => new Response('No.', { status: 400 })))
    await expect(listLunches('testnet')).rejects.toThrow()
    const fetched = index({ projects: { items: [] } })
    expect(await listLunches('testnet')).toEqual([])
    expect(fetched).toHaveBeenCalledTimes(1)
  })
})

describe('findMade', () => {
  it('reads what cannot change once, however often it is asked', async () => {
    const terms = { sender: ADDRESS, salt: `0x${'11'.repeat(32)}`, hostChainId: 11155111, token: ADDRESS, deadline: 1, creator: ADDRESS, keepPercent: 0n, keepCap: 0n, tokenPercent: 0n, vestingDuration: 0, claimsPercent: 0n, claimsRoot: `0x${'00'.repeat(32)}`, claimsVestingDuration: 0 } as MadeTerms
    expect(await findMade(terms, 11155111)).toBeNull()
    const first = read.mock.calls.length
    expect(await findMade(terms, 11155111)).toBeNull()
    expect(read.mock.calls.slice(first).map(([call]) => call.functionName)).toEqual(['projectIdOf'])
  })
})
