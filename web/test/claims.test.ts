import { concat, encodeAbiParameters, keccak256, type Hex } from 'viem'
import { describe, expect, it } from 'vitest'
import { claimEntriesOf, claimProofOf, claimsRootOf, SHARES_TOTAL, type ClaimEntry } from '@/lib/fair-lunch/claims'

// OpenZeppelin's MerkleProof.verify, as FairLunchClaims uses it.
const verify = (entry: ClaimEntry, proof: Hex[], root: Hex) => {
  const leaf = keccak256(keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [entry[0], BigInt(entry[1])])))
  return proof.reduce((node, other) => keccak256(concat(BigInt(node) < BigInt(other) ? [node, other] : [other, node])), leaf) === root
}
const account = (n: number) => `0x${n.toString(16).padStart(40, '0')}` as const

describe('claims', () => {
  it('turns address,amount lines into shares of 1e18, merging repeats and skipping a header', () => {
    const entries = claimEntriesOf(`address,amount\n${account(1)},30\n${account(2)}, 10\n\n${account(1)},60`)
    expect(entries).toEqual([[account(1), '900000000000000000'], [account(2), '100000000000000000']])
    expect(entries.reduce((sum, [, shares]) => sum + BigInt(shares), 0n)).toBeLessThanOrEqual(SHARES_TOTAL)
  })

  it('refuses a line it cannot read', () => {
    expect(() => claimEntriesOf(`${account(1)},1\nnot an address,2`)).toThrow('Line 2')
    expect(() => claimEntriesOf(`${account(1)}`)).toThrow('Line 1')
    expect(() => claimEntriesOf('')).toThrow('no addresses')
  })

  it('proves every entry of lists of every small size, and no other', () => {
    for (let size = 1; size <= 9; size++) {
      const entries = Array.from({ length: size }, (_, i) => [account(i + 1), String(i + 1)] as const)
      const root = claimsRootOf(entries)
      entries.forEach((entry, i) => {
        expect(verify(entry, claimProofOf(entries, i), root)).toBe(true)
        expect(verify([entry[0], String(BigInt(entry[1]) + 1n)], claimProofOf(entries, i), root)).toBe(false)
      })
    }
  })
})
