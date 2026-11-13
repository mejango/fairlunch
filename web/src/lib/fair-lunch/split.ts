/** How a raise divides at `serve`, mirroring `FairLunch.serve` step for step. All amounts in smallest units. */
export const TOKENS_PER_UNIT = 1_000_000n
/** The fundraise's price, in whole units of money per token. */
export const RAISE_PRICE = 1 / Number(TOKENS_PER_UNIT)
/** The tokens an amount of money buys during the fundraise. Tokens have 18 decimals. */
export const tokensFor = (amount: bigint, decimals: number) => (amount * TOKENS_PER_UNIT * 10n ** 18n) / 10n ** BigInt(decimals)
/** What an amount of tokens is worth at the fundraise's price, which is also the price the pool opens at. */
export const moneyFor = (tokens: bigint, decimals: number) => (tokens * 10n ** BigInt(decimals)) / (TOKENS_PER_UNIT * 10n ** 18n)
export const PERCENT_TOTAL = 1_000_000_000n
/** The raise: what payers paid for the tokens they hold. Money that reached the balance any other way isn't in it. */
export const raisedOf = (balance: bigint, supply: bigint, decimals: number) => {
  const sold = moneyFor(supply, decimals)
  return balance < sold ? balance : sold
}
/** Juicebox's fee on the raise as it's paid out: 2.5%. */
const FEE = 25n
const FEE_TOTAL = 1000n

export type Terms = { keepPercent: bigint; keepCap: bigint; tokenPercent: bigint; /** The airdrop list's share of supply. */ claimsPercent?: bigint; /** Seconds the chef's tokens and the airdrop's unlock over. */ vestingDuration?: number; claimsVestingDuration?: number }
export type Split = { creatorEth: bigint; poolEth: bigint; fee: bigint; poolTokens: bigint; creatorTokens: bigint; claimsTokens: bigint }

const less = (a: bigint, b: bigint) => (a < b ? a : b)
const afterFee = (amount: bigint) => amount - (amount * FEE) / FEE_TOTAL

/** `supply` is the tokens payers hold, 1,000,000 per whole unit raised on the host chain. */
export function splitOf(raised: bigint, supply: bigint, terms: Terms, decimals = 18): Split {
  if (raised === 0n) return { creatorEth: 0n, poolEth: 0n, fee: 0n, poolTokens: 0n, creatorTokens: 0n, claimsTokens: 0n }
  const keep = less((raised * terms.keepPercent) / PERCENT_TOTAL, terms.keepCap)
  // The contract pays the keep as a split percent of the raise, which rounds it down.
  const gross = (raised * ((keep * PERCENT_TOTAL) / raised)) / PERCENT_TOTAL
  const creatorEth = afterFee(gross)
  const poolEth = afterFee(raised - gross)
  const poolTokens = tokensFor(poolEth, decimals)
  const claimsPercent = terms.claimsPercent ?? 0n
  const granted = ((supply + poolTokens) * (terms.tokenPercent + claimsPercent)) / (PERCENT_TOTAL - terms.tokenPercent - claimsPercent)
  const claimsTokens = claimsPercent ? (granted * claimsPercent) / (terms.tokenPercent + claimsPercent) : 0n
  return { creatorEth, poolEth, fee: raised - creatorEth - poolEth, poolTokens, creatorTokens: granted - claimsTokens, claimsTokens }
}

/** A market cap two ways: `circulating` leaves out tokens still vesting, `diluted` counts every token. */
export type Caps = { circulating: bigint; diluted: bigint }

/** The caps there'd be if a raise were served now, at the price the pool opens at. Nothing has vested yet then. */
export function projectedCapOf(raised: bigint, supply: bigint, terms: Terms, decimals = 18): Caps {
  const split = splitOf(raised, supply, terms, decimals)
  const free = supply + split.poolTokens
  const locked = (terms.vestingDuration ? split.creatorTokens : 0n) + (terms.claimsVestingDuration ? split.claimsTokens : 0n)
  const all = free + split.creatorTokens + split.claimsTokens
  return { circulating: moneyFor(all - locked, decimals), diluted: moneyFor(all, decimals) }
}

/** How many of `tokens` are still locked at `now`, unlocking evenly over `duration` seconds from `start`. */
export const unvestedOf = (tokens: bigint, start: number, duration: number, now: number) =>
  !duration || now >= start + duration ? 0n : tokens - (tokens * BigInt(Math.max(now - start, 0))) / BigInt(duration)
