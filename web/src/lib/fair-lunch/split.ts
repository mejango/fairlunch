/** How a raise divides at `serve`, mirroring `FairLunch.serve` step for step. All amounts in smallest units. */
export const TOKENS_PER_UNIT = 1_000_000n
/** The fundraise's price, in whole units of money per token. */
export const RAISE_PRICE = 1 / Number(TOKENS_PER_UNIT)
/** The tokens an amount of money buys during the fundraise. Tokens have 18 decimals. */
export const tokensFor = (amount: bigint, decimals: number) => (amount * TOKENS_PER_UNIT * 10n ** 18n) / 10n ** BigInt(decimals)
export const PERCENT_TOTAL = 1_000_000_000n
/** Half: the most a creator can keep of the ETH or take of the tokens. */
export const MAX_CREATOR_PERCENT = PERCENT_TOTAL / 2n
/** Juicebox's fee on the raise as it's paid out: 2.5%. */
const FEE = 25n
const FEE_TOTAL = 1000n

export type Terms = { keepPercent: bigint; keepCap: bigint; tokenPercent: bigint }
export type Split = { creatorEth: bigint; poolEth: bigint; fee: bigint; poolTokens: bigint; creatorTokens: bigint }

const less = (a: bigint, b: bigint) => (a < b ? a : b)
const afterFee = (amount: bigint) => amount - (amount * FEE) / FEE_TOTAL

/** `supply` is the tokens payers hold, 1,000,000 per whole unit raised on the host chain. */
export function splitOf(raised: bigint, supply: bigint, terms: Terms, decimals = 18): Split {
  if (raised === 0n) return { creatorEth: 0n, poolEth: 0n, fee: 0n, poolTokens: 0n, creatorTokens: 0n }
  const keep = less((raised * terms.keepPercent) / PERCENT_TOTAL, terms.keepCap)
  // The contract pays the keep as a split percent of the raise, which rounds it down.
  const gross = (raised * ((keep * PERCENT_TOTAL) / raised)) / PERCENT_TOTAL
  const creatorEth = afterFee(gross)
  const poolEth = afterFee(raised - gross)
  const poolTokens = tokensFor(poolEth, decimals)
  const creatorTokens = ((supply + poolTokens) * terms.tokenPercent) / (PERCENT_TOTAL - terms.tokenPercent)
  return { creatorEth, poolEth, fee: raised - creatorEth - poolEth, poolTokens, creatorTokens }
}
