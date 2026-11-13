import { buildBuybackCashOutMetadata, buildBuybackPayMetadata } from '@bananapus/nana-sdk-core/v6'
import { describe, expect, it, vi } from 'vitest'
import { assetUrl } from '@/lib/format'
import { tokenAddressOf } from '@/lib/fair-lunch/reads'
import { payTx, tradeTx } from '@/lib/fair-lunch/writes'

vi.mock('@/lib/fair-lunch/reads', async original => ({
  ...(await original<typeof import('@/lib/fair-lunch/reads')>()),
  wiringOn: async () => ({ terminal: '0x00000000000000000000000000000000000000aa', buyback: '0x00000000000000000000000000000000000000bb' }),
}))

const ETH = 10n ** 18n
const ETH_MONEY = { address: '0x000000000000000000000000000000000000EEEe', symbol: 'ETH', decimals: 18 } as const
const USDC = { address: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', symbol: 'USDC', decimals: 6 } as const
const registry = '0x00000000000000000000000000000000000000bb'

describe('payTx', () => {
  // A payment still waiting when the lunch is served would mint nothing: the minimum makes it revert instead.
  it('refuses to land for fewer tokens than the fixed price', async () => {
    const tx = await payTx({ chainId: 8453, projectId: 7, money: ETH_MONEY }, ETH / 4n, '0x0000000000000000000000000000000000000001')
    expect(tx.value).toBe(ETH / 4n)
    expect(tx.args[4]).toBe(250_000n * ETH)
  })
  // An ERC-20 is pulled by the terminal, so nothing travels with the call, and a whole unit still buys a million.
  it('pays an ERC-20 with no value and the same price per whole unit', async () => {
    const tx = await payTx({ chainId: 8453, projectId: 7, money: USDC }, 250_000n, '0x0000000000000000000000000000000000000001')
    expect([tx.value, tx.args[1], tx.args[2], tx.args[4]]).toEqual([0n, USDC.address, 250_000n, 250_000n * ETH])
  })
})

describe('tradeTx', () => {
  const me = '0x0000000000000000000000000000000000000001'
  // The terminal's own minimum counts only what it mints, which is nothing once served: the hook's minimum is the one.
  it('buys by paying the project, with the minimum in the buyback metadata', async () => {
    const tx = await tradeTx({ chainId: 8453, projectId: 7, money: ETH_MONEY }, ETH, 990_000n * ETH, me, false)
    expect([tx.functionName, tx.value, tx.args[4]]).toEqual(['pay', ETH, 0n])
    expect(tx.args[6]).toBe(buildBuybackPayMetadata({ hook: registry, amountToSwapWith: 0n, minimumSwapAmountOut: 990_000n * ETH, skipSplits: true }))
  })
  it('sells by cashing out to the seller, with the minimum in the buyback metadata', async () => {
    const tx = await tradeTx({ chainId: 8453, projectId: 7, money: ETH_MONEY }, 1000n * ETH, ETH / 1000n, me, true)
    expect([tx.functionName, tx.value, tx.args[0], tx.args[2], tx.args[5]]).toEqual(['cashOutTokensOf', undefined, me, 1000n * ETH, me])
    expect(tx.args[6]).toBe(buildBuybackCashOutMetadata({ hook: registry, minimumSwapAmountOut: ETH / 1000n }))
  })
})

describe('tokenAddressOf', () => {
  // Lunch 40 on the Base fork: the terms its create sent, and the token it deployed.
  it('finds the token a create deployed, from its terms', () => {
    expect(tokenAddressOf({
      sender: '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266', salt: '0x0000000000000000000000000000000000000000000000000000000000000000', hostChainId: 8453, token: ETH_MONEY.address, deadline: 1795038375,
      creator: '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266', keepPercent: 200_000_000n, keepCap: ETH / 2n, tokenPercent: 100_000_000n, vestingDuration: 31_449_600, claimsPercent: 0n, claimsRoot: '0x0000000000000000000000000000000000000000000000000000000000000000', claimsVestingDuration: 0,
    }, {
      lunch: '0x5daafb44b864aaeb779f96365474ca6338311782', controller: '0x3Fcec3572e84b624477BcfF4E2CF1f7dEAb648F1',
      tokens: '0x1f80d8f057eE36b4C2656D107E4e4558B71bA7D9', implementation: '0x6DB9Cf17222D8DE2012Fe13B9FA5bB7981fa0b17',
    })).toBe('0x470fcaB5329C9F37BCe7b0e0f021d18E4B53Dbc2')
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
