import type { Abi } from 'viem'
import { describe, expect, it, vi } from 'vitest'
import { assetUrl } from '@/lib/format'
import { tokenAddressOf } from '@/lib/fair-lunch/reads'
import { payTx, swapTx } from '@/lib/fair-lunch/writes'

vi.mock('@/lib/fair-lunch/reads', async original => ({
  ...(await original<typeof import('@/lib/fair-lunch/reads')>()),
  wiringOn: async () => ({ terminal: '0x00000000000000000000000000000000000000aa' }),
}))

const ETH = 10n ** 18n
const poolKey = { currency0: '0x0000000000000000000000000000000000000000', currency1: '0x0000000000000000000000000000000000000003', fee: 10000, tickSpacing: 200, hooks: '0x0000000000000000000000000000000000000004' } as const

describe('payTx', () => {
  // A payment still waiting when the lunch is served would mint nothing: the minimum makes it revert instead.
  it('refuses to land for fewer tokens than the fixed price', async () => {
    const tx = await payTx({ chainId: 8453, projectId: 7 }, ETH / 4n, '0x0000000000000000000000000000000000000001')
    expect(tx.value).toBe(ETH / 4n)
    expect(tx.args[4]).toBe(250_000n * ETH)
  })
})

describe('swapTx', () => {
  const deadlineOf = (tx: { abi: Abi; args: readonly unknown[] }) => tx.args[2] as bigint
  it('never promises a sale longer than its allowance lasts', () => {
    const soon = Math.floor(Date.now() / 1000) + 300
    const sale = swapTx({ chainId: 8453, poolKey }, ETH, 1n, '0x0000000000000000000000000000000000000001', true, true, soon)
    expect(sale.deadline).toBe(soon)
    expect(deadlineOf(sale)).toBe(BigInt(soon))
  })
  it("gives a Safe's owners days and a wallet minutes", () => {
    const now = Math.floor(Date.now() / 1000)
    const wallet = swapTx({ chainId: 8453, poolKey }, ETH, 1n, '0x0000000000000000000000000000000000000001', false, false)
    const safe = swapTx({ chainId: 8453, poolKey }, ETH, 1n, '0x0000000000000000000000000000000000000001', false, true)
    expect(wallet.deadline - now).toBeLessThanOrEqual(3600)
    expect(safe.deadline - now).toBeGreaterThan(86_400)
  })
})

describe('tokenAddressOf', () => {
  // Lunch 46 on the Base fork: the terms its create sent, and the token it deployed.
  it('finds the token a create deployed, from its terms', () => {
    expect(tokenAddressOf({
      salt: '0x000000000000000000000000000000000000000000000000000001a1cdcd5516', hostChainId: 8453, deadline: 1794457718,
      creator: '0x1234567890123456789012345678901234567890', keepPercent: 200_000_000n, keepCap: ETH / 2n, tokenPercent: 100_000_000n, vestingDuration: 31_449_600,
    }, {
      lunch: '0x14bc17f526613fc1fd7f89e9d2ae4d37ef8010fd', controller: '0x3Fcec3572e84b624477BcfF4E2CF1f7dEAb648F1',
      tokens: '0x1f80d8f057eE36b4C2656D107E4e4558B71bA7D9', implementation: '0x6DB9Cf17222D8DE2012Fe13B9FA5bB7981fa0b17',
    })).toBe('0x7B4e3c6F4627aA0212193864eddf48223e60044d')
  })
})

describe('assetUrl', () => {
  it('shows IPFS images through the gateway and nothing else', () => {
    expect(assetUrl('ipfs://bafy123/logo.png')).toBe('https://juicebox.center/ipfs/bafy123/logo.png')
    expect(assetUrl('https://example.com/a.png')).toBeNull()
    expect(assetUrl('ipfs://../../x')).toBeNull()
    expect(assetUrl('ipfs://bafy?x=1')).toBeNull()
    expect(assetUrl(null)).toBeNull()
  })
})
