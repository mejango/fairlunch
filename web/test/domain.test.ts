import { describe, expect, it } from 'vitest'
import { countdown, phaseOf } from '@/lib/fair-lunch/phase'
import { projectedCapOf, splitOf, unvestedOf } from '@/lib/fair-lunch/split'

const ETH = 10n ** 18n

describe('splitOf', () => {
  // The contract's fork tests: 10 ETH raised, 20% kept, 1 ETH cap.
  it('caps the keep and takes the fee from both sides', () => {
    const split = splitOf(10n * ETH, 10_000_000n * ETH, { keepPercent: 200_000_000n, keepCap: ETH, tokenPercent: 0n })
    expect(split.creatorEth).toBe((ETH * 975n) / 1000n)
    expect(split.poolEth).toBe((9n * ETH * 975n) / 1000n)
    expect(split.poolTokens).toBe(split.poolEth * 1_000_000n)
    expect(split.creatorTokens).toBe(0n)
    expect(split.creatorEth + split.poolEth + split.fee).toBe(10n * ETH)
  })
  it('gives the creator their share of the final supply', () => {
    const split = splitOf(10n * ETH, 10_000_000n * ETH, { keepPercent: 0n, keepCap: 0n, tokenPercent: 100_000_000n })
    const total = 10_000_000n * ETH + split.poolTokens + split.creatorTokens
    expect((split.creatorTokens * 1000n) / total).toBe(99n) // 10%, rounded down
  })
  it('is all zero with nothing raised', () => {
    expect(splitOf(0n, 0n, { keepPercent: 1n, keepCap: 1n, tokenPercent: 1n }).poolEth).toBe(0n)
  })
})

describe('phaseOf', () => {
  const lunch = { deadline: 1000, servedAt: 0 }
  it('follows the lifecycle', () => {
    expect(phaseOf(lunch, 0n, 999)).toBe('cooking')
    expect(phaseOf(lunch, 1n, 1000)).toBe('ready')
    expect(phaseOf(lunch, 0n, 1000)).toBe('empty')
    expect(phaseOf({ deadline: 1000, servedAt: 2000 }, 0n, 2000 + 1799)).toBe('resting')
    expect(phaseOf({ deadline: 1000, servedAt: 2000 }, 0n, 2000 + 1800)).toBe('eating')
  })
  it('counts down in two units', () => {
    expect(countdown(3 * 86400 + 4 * 3600 + 5)).toBe('3d 4h')
    expect(countdown(65)).toBe('1m 5s')
    expect(countdown(-1)).toBe('0s')
  })
})

describe('market caps', () => {
  const terms = { keepPercent: 0n, keepCap: 0n, tokenPercent: 100_000_000n, claimsPercent: 400_000_000n }
  it('leaves vesting tokens out of the circulating cap and counts them fully diluted', () => {
    const all = projectedCapOf(10n * ETH, 10_000_000n * ETH, terms)
    expect(all.circulating).toBe(all.diluted)
    const chef = projectedCapOf(10n * ETH, 10_000_000n * ETH, { ...terms, vestingDuration: 1 })
    const both = projectedCapOf(10n * ETH, 10_000_000n * ETH, { ...terms, vestingDuration: 1, claimsVestingDuration: 1 })
    expect(chef.diluted).toBe(all.diluted)
    // A tenth of supply is the chef's, four tenths the airdrop's.
    expect(Number(chef.circulating) / Number(all.diluted)).toBeCloseTo(0.9)
    expect(Number(both.circulating) / Number(all.diluted)).toBeCloseTo(0.5)
  })
  it('unlocks evenly', () => {
    expect(unvestedOf(100n, 1000, 100, 1000)).toBe(100n)
    expect(unvestedOf(100n, 1000, 100, 1025)).toBe(75n)
    expect(unvestedOf(100n, 1000, 100, 1100)).toBe(0n)
    expect(unvestedOf(100n, 1000, 0, 999)).toBe(0n)
  })
})
