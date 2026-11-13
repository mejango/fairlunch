import { concat, encodeAbiParameters, getAddress, isAddress, keccak256, parseAbi, parseUnits, type Address, type Hex } from 'viem'

/** A lunch's list of addresses, as `FairLunchClaims` reads it: each entry is an address and its share out of 1e18. */
export const SHARES_TOTAL = 10n ** 18n
/** An address and its share, as a decimal string so a list survives JSON. */
export type ClaimEntry = readonly [account: Address, shares: string]

export const claimsAbi = parseAbi([
  'function percentOf(uint256 projectId) view returns (uint32)',
  'function rootOf(uint256 projectId) view returns (bytes32)',
  'function tokenCountOf(uint256 projectId) view returns (uint256)',
  'function claimedOf(uint256 projectId, address account) view returns (uint256)',
  'function vestingDurationOf(uint256 projectId) view returns (uint32)',
  'function creatorTokenCountOf(uint256 projectId) view returns (uint256)',
  'function creatorClaimedOf(uint256 projectId) view returns (uint256)',
  'function release(uint256 projectId) returns (uint256)',
  'function claim(uint256 projectId, address account, uint256 shares, bytes32[] proof) returns (uint256)',
])

const leafOf = ([account, shares]: ClaimEntry) =>
  keccak256(keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [account, BigInt(shares)])))
const pairOf = (a: Hex, b: Hex) => keccak256(concat(BigInt(a) < BigInt(b) ? [a, b] : [b, a]))

/** Every layer of the tree, leaves first. A node without a neighbor moves up as it is. */
function layersOf(entries: readonly ClaimEntry[]): Hex[][] {
  const layers = [entries.map(leafOf)]
  while (layers[layers.length - 1].length > 1) {
    const below = layers[layers.length - 1]
    layers.push(below.flatMap((node, i) => (i % 2 ? [] : [i + 1 < below.length ? pairOf(node, below[i + 1]) : node])))
  }
  return layers
}

export const claimsRootOf = (entries: readonly ClaimEntry[]): Hex => layersOf(entries).at(-1)![0]

/** The proof `FairLunchClaims.claim` takes for the entry at `index`. */
export function claimProofOf(entries: readonly ClaimEntry[], index: number): Hex[] {
  const proof: Hex[] = []
  for (const layer of layersOf(entries).slice(0, -1)) {
    const neighbor = index ^ 1
    if (neighbor < layer.length) proof.push(layer[neighbor])
    index >>= 1
  }
  return proof
}

/** A list from lines of `address,amount`. Amounts are relative: each entry gets its amount's share of the total. */
export function claimEntriesOf(csv: string): ClaimEntry[] {
  const amounts = new Map<Address, bigint>()
  csv.split(/\r?\n/).map(line => line.trim()).filter(Boolean).forEach((line, i) => {
    const [account, amount] = line.split(/[,;\t ]+/)
    // A first line that isn't an address is a header.
    if (!isAddress(account ?? '', { strict: false })) {
      if (i === 0) return
      throw new Error(`Line ${i + 1} doesn't start with an address.`)
    }
    let value: bigint
    try { value = parseUnits(amount ?? '', 18) } catch { throw new Error(`Line ${i + 1} needs an amount after the address.`) }
    if (value <= 0n) throw new Error(`Line ${i + 1} needs an amount above zero.`)
    const key = getAddress(account)
    amounts.set(key, (amounts.get(key) ?? 0n) + value)
  })
  const total = [...amounts.values()].reduce((sum, value) => sum + value, 0n)
  if (total === 0n) throw new Error('The list has no addresses.')
  return [...amounts].map(([account, value]) => [account, ((value * SHARES_TOTAL) / total).toString()] as const).filter(([, shares]) => shares !== '0')
}
