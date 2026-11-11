import { formatUnits } from 'viem'

const number = (digits: number) => new Intl.NumberFormat('en-US', { maximumFractionDigits: digits })

/** "1.2345" from wei: four decimals, fewer for big amounts, never scientific. */
export function formatEth(wei: bigint): string {
  const value = Number(formatUnits(wei, 18))
  if (value !== 0 && value < 0.0001) return '<0.0001'
  return number(value >= 1000 ? 0 : value >= 10 ? 2 : 4).format(value)
}

/** "12.3M", "4,500": token counts are large, so they're compact. */
export function formatTokens(wei: bigint): string {
  return new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 2 }).format(Number(formatUnits(wei, 18)))
}

/** A token's price in ETH: significant digits, since it's far below 1. */
export function formatPrice(price: number): string {
  return new Intl.NumberFormat('en-US', { maximumSignificantDigits: 4, maximumFractionDigits: 12 }).format(price)
}

/** "+12.3%". */
export function formatChange(ratio: number): string {
  return `${ratio >= 0 ? '+' : ''}${(ratio * 100).toFixed(1)}%`
}

/** An image a project names, through Center's gateway when it's on IPFS. Anything but https or ipfs is not shown. */
export function assetUrl(uri: string | null | undefined): string | null {
  if (!uri) return null
  if (uri.startsWith('ipfs://')) return `https://juicebox.center/ipfs/${uri.slice(7)}`
  return uri.startsWith('https://') ? uri : null
}
