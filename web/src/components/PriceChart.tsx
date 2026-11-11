'use client'

import { useQuery } from '@tanstack/react-query'
import { useMemo, useState } from 'react'
import { formatChange, formatPrice, formatTokens } from '@/lib/format'
import { readPriceHistory, type Lunch } from '@/lib/fair-lunch/reads'
import { TOKENS_PER_ETH } from '@/lib/fair-lunch/split'

export type Burn = { time: number; amount: string; txHash: string }

const RANGES = [['1H', 3600], ['1D', 86400], ['1W', 604800], ['1M', 2592000], ['All', 0]] as const
const POINTS = 120
const W = 800, H = 320, PAD = 8
const RAISE_PRICE = 1 / Number(TOKENS_PER_ETH)

const clock = (time: number, long: boolean) => new Date(time * 1000).toLocaleString('en-US',
  long ? { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' } : { hour: 'numeric', minute: '2-digit' })

/** The pool's price over time, from its own oracle: range buttons, a crosshair, the raise price, and every burn. */
export function PriceChart({ lunch, burns }: { lunch: Lunch; burns: readonly Burn[] }) {
  const [range, setRange] = useState<(typeof RANGES)[number]>(RANGES[1])
  const [hover, setHover] = useState<number | null>(null)
  const seconds = range[1] || Math.max(60, Math.floor(Date.now() / 1000) - lunch.servedAt)
  const { data, isError } = useQuery({
    queryKey: ['fair-lunch', 'prices', lunch.chainId, lunch.projectId, range[0]],
    queryFn: ({ signal }) => readPriceHistory(lunch, seconds, POINTS, signal),
    refetchInterval: 15_000,
  })
  // The live price closes the line, so the chart moves with the pool between reads of its history.
  const points = useMemo(() => {
    const history = data ?? []
    return lunch.price ? [...history, { time: Math.floor(Date.now() / 1000), price: lunch.price }] : history
  }, [data, lunch.price])

  if (isError) return <p className="card p-6 text-muted">The chart couldn&apos;t load. It&apos;ll try again.</p>
  if (points.length < 2) return <div className="card h-[320px] animate-pulse" aria-busy="true" />

  const prices = points.map(point => point.price)
  const low = Math.min(...prices, RAISE_PRICE), high = Math.max(...prices, RAISE_PRICE)
  const span = high - low || high || 1
  const start = points[0].time, end = points[points.length - 1].time
  const x = (time: number) => PAD + ((time - start) / (end - start || 1)) * (W - 2 * PAD)
  const y = (price: number) => H - PAD - ((price - low) / span) * (H - 2 * PAD - 24)
  const line = points.map((point, i) => `${i ? 'L' : 'M'}${x(point.time).toFixed(1)},${y(point.price).toFixed(1)}`).join('')
  const shown = hover === null ? points[points.length - 1] : points[hover]
  const change = shown.price / points[0].price - 1
  const up = change >= 0
  const inRange = burns.filter(burn => burn.time >= start && burn.time <= end)
  // A burn sits on the line at the price nearest its time.
  const priceAt = (time: number) => points.reduce((best, point) => (Math.abs(point.time - time) < Math.abs(best.time - time) ? point : best)).price

  return (
    <section className="card p-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <div className="text-3xl font-bold tabular-nums">{formatPrice(shown.price)} ETH</div>
          <div className={`text-sm font-semibold ${up ? 'text-[#2e7d32]' : 'text-err'}`}>
            {formatChange(change)} <span className="font-normal text-muted">{hover === null ? `past ${range[0] === 'All' ? 'all time' : range[0]}` : clock(shown.time, true)}</span>
          </div>
        </div>
        <div className="flex gap-1" role="group" aria-label="Chart range">
          {RANGES.map(option => (
            <button key={option[0]} type="button" aria-pressed={option === range} onClick={() => { setRange(option); setHover(null) }}
              className={`min-h-[36px] rounded-lg px-3 text-sm font-semibold ${option === range ? 'bg-ink text-bg' : 'text-muted hover:text-ink'}`}>
              {option[0]}
            </button>
          ))}
        </div>
      </div>
      <svg viewBox={`0 0 ${W} ${H}`} className="mt-3 h-auto w-full touch-none select-none" role="img" aria-label={`${lunch.symbol} price in ETH`}
        onPointerMove={event => {
          const box = event.currentTarget.getBoundingClientRect()
          const time = start + ((event.clientX - box.left) / box.width) * (end - start)
          setHover(points.reduce((best, point, i) => (Math.abs(point.time - time) < Math.abs(points[best].time - time) ? i : best), 0))
        }}
        onPointerLeave={() => setHover(null)}>
        <path d={`${line}L${x(end)},${H}L${x(start)},${H}Z`} className={up ? 'fill-[#2e7d32]/10' : 'fill-err/10'} />
        <path d={line} fill="none" strokeWidth="2.5" strokeLinejoin="round" className={up ? 'stroke-[#2e7d32]' : 'stroke-err'} />
        <line x1={PAD} x2={W - PAD} y1={y(RAISE_PRICE)} y2={y(RAISE_PRICE)} className="stroke-muted" strokeDasharray="4 6" />
        {inRange.map(burn => (
          <g key={burn.txHash}>
            <title>{`🔥 ${formatTokens(BigInt(burn.amount))} ${lunch.symbol} burned, ${clock(burn.time, true)}`}</title>
            <text x={x(burn.time)} y={y(priceAt(burn.time)) - 8} textAnchor="middle" className="text-[16px]">🔥</text>
          </g>
        ))}
        {hover !== null ? (
          <>
            <line x1={x(shown.time)} x2={x(shown.time)} y1={0} y2={H} className="stroke-line" />
            <circle cx={x(shown.time)} cy={y(shown.price)} r="5" className={up ? 'fill-[#2e7d32]' : 'fill-err'} />
          </>
        ) : null}
      </svg>
      <div className="mt-1 flex justify-between text-xs text-muted">
        <span>{clock(start, end - start > 86400)}</span>
        <span>High {formatPrice(Math.max(...prices))}, low {formatPrice(Math.min(...prices))}</span>
        <span>{clock(end, end - start > 86400)}</span>
      </div>
      <p className="mt-2 text-sm text-muted">🔥 {inRange.length} {inRange.length === 1 ? 'burn' : 'burns'} in view. The dashed line is the raise price.</p>
    </section>
  )
}
