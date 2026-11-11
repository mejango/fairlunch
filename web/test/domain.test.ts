import { describe, expect, it } from 'vitest'
import { countdown, phaseOf } from '@/lib/fair-lunch/phase'
import { splitOf } from '@/lib/fair-lunch/split'

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
    expect(phaseOf(lunch, 0n, 1000)).toBe('cooking')
    expect(phaseOf(lunch, 1n, 1001)).toBe('ready')
    expect(phaseOf(lunch, 0n, 1001)).toBe('empty')
    expect(phaseOf({ deadline: 1000, servedAt: 2000 }, 0n, 2000 + 1799)).toBe('resting')
    expect(phaseOf({ deadline: 1000, servedAt: 2000 }, 0n, 2000 + 1800)).toBe('eating')
  })
  it('counts down in two units', () => {
    expect(countdown(3 * 86400 + 4 * 3600 + 5)).toBe('3d 4h')
    expect(countdown(65)).toBe('1m 5s')
    expect(countdown(-1)).toBe('0s')
  })
})
