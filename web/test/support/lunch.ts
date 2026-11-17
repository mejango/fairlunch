import type { Lunch } from '@/lib/fair-lunch/reads'

export const ETH = 10n ** 18n
export const NOW = 1_800_000_000
export const lunch = (over: Partial<Lunch>): Lunch => ({
  chainId: 8453, projectId: 7, hostChainId: 8453, startedAt: NOW - 3600, deadline: NOW + 3600, servedAt: 0, creator: '0x0000000000000000000000000000000000000001',
  keepPercent: 200_000_000n, keepCap: ETH, tokenPercent: 100_000_000n, vestingDuration: 52 * 604800, claimsPercent: 0n, claimsTokens: 0n, claimsVestingDuration: 0,
  token: '0x0000000000000000000000000000000000000003', name: 'Sandwich', symbol: 'SAND', uri: '', balance: 3n * ETH, supply: 3_000_000n * ETH,
  poolKey: { currency0: '0x0000000000000000000000000000000000000000', currency1: '0x0000000000000000000000000000000000000003', fee: 10000, tickSpacing: 200, hooks: '0x0000000000000000000000000000000000000004' },
  money: { address: '0x000000000000000000000000000000000000EEEe', symbol: 'ETH', decimals: 18 }, moneyIs0: true,
  price: null, pooled: null, ...over,
})
