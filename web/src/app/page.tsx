import Link from 'next/link'
import type { ReactNode } from 'react'
import { ChainIcon } from '@/components/ChainIcon'
import { assetUrl, formatChange, formatEth, formatPrice } from '@/lib/format'
import { RAISE_PRICE } from '@/lib/fair-lunch/split'
import { listLunches } from '@/lib/fair-lunch/indexed'
import { countdown, PHASE_LABEL, phaseOf } from '@/lib/fair-lunch/phase'
import { projectPath } from '@/lib/urn'

export const dynamic = 'force-dynamic'

export default async function Home() {
  const lists = await Promise.allSettled([listLunches('mainnet'), listLunches('testnet')])
  const lunches = lists.flatMap(list => (list.status === 'fulfilled' ? list.value : []))
  const failed = lists.some(list => list.status === 'rejected')
  const now = Math.floor(Date.now() / 1000)
  return (
    <div className="space-y-6">
      <section className="py-6 text-center">
        <p aria-hidden className="text-8xl leading-none sm:text-9xl">🥪</p>
        <h1 className="mt-4 text-2xl font-bold sm:text-3xl">Everyone deserves a fair lunch</h1>
        <Link href="/create" className="btn-primary mt-5 min-h-[48px] px-6 text-lg">Get cooking</Link>
      </section>
      {lunches.length ? (
        <ul className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {lunches.map(lunch => {
            const logo = assetUrl(lunch.logoUri)
            const paidIn = BigInt(lunch.paidIn)
            return (
              <li key={`${lunch.chainId}:${lunch.projectId}`}>
                <Link href={projectPath(lunch.chainId, lunch.projectId)} className="card block p-4 hover:border-ink">
                  <Card name={lunch.name ?? `Lunch ${lunch.projectId}`} chainId={lunch.chainId} status={statusOf(lunch, paidIn, now)} {...figureOf(lunch.price, `${formatEth(paidIn, lunch.money.decimals)} ${lunch.money.symbol}`, lunch.money.symbol)}
                    logo={logo ? (
                      // eslint-disable-next-line @next/next/no-img-element
                      <img src={logo} alt="" className="h-12 w-12 rounded-lg border border-line object-cover" />
                    ) : '🥪'} />
                </Link>
              </li>
            )
          })}
        </ul>
      ) : failed ? <p className="card p-6 text-center text-muted">The list couldn’t load. Try again soon.</p> : (
        <section>
          <p className="mb-3 text-center text-muted">🍽️ Nothing cooking yet. Lunches will look like these examples.</p>
          <ul aria-label="Examples" className="grid gap-3 opacity-70 sm:grid-cols-2 lg:grid-cols-3">
            {EXAMPLES.map(example => <li key={example.name} className="card p-4"><Card {...example} /></li>)}
          </ul>
        </section>
      )}
    </div>
  )
}

/** What an empty list shows instead: made-up lunches, labeled as examples and going nowhere. */
const EXAMPLES = [
  { logo: '🌯', name: 'Burrito', chainId: 8453, status: 'Cooking, 3d 4h left', ...figureOf(null, '12.5 ETH') },
  { logo: '🥟', name: 'Dumpling', chainId: 1, status: 'Served 2d ago', ...figureOf(0.00000137, '') },
  { logo: '🍜', name: 'Ramen', chainId: 42161, status: 'Served 12d ago', ...figureOf(0.00000092, '') },
]

/** A card's line for where its lunch is: time left while cooking, how long ago it was served after. */
function statusOf(lunch: { deadline: number; servedAt: number }, raised: bigint, now: number): string {
  const phase = phaseOf(lunch, raised, now)
  if (phase === 'cooking') return `Cooking, ${countdown(lunch.deadline - now)} left`
  if (phase === 'ready') return 'Ready to serve'
  if (phase === 'empty') return PHASE_LABEL.empty
  return `Served ${countdown(now - lunch.servedAt)} ago`
}

/** A card's number: the market price and how far it is from the fundraise's once there's a pool, the raise before. */
function figureOf(price: number | null, raised: string, symbol = 'ETH'): { figure: ReactNode; note: string } {
  if (price === null) return { figure: raised, note: 'raised' }
  const change = price / RAISE_PRICE - 1
  return { figure: <span className={change >= 0 ? 'text-[#2e7d32]' : 'text-accent'}>{formatChange(change)}</span>, note: `${formatPrice(price)} ${symbol}` }
}

function Card({ logo, name, chainId, status, figure, note }: { logo: ReactNode; name: string; chainId: number; status: string; figure: ReactNode; note: string }) {
  return (
    <span className="flex items-center gap-3">
      {typeof logo === 'string' ? <span className="flex h-12 w-12 items-center justify-center rounded-lg border border-line text-xl">{logo}</span> : logo}
      <span className="min-w-0 flex-1">
        <span className="flex items-center gap-1.5 font-bold"><span className="truncate">{name}</span> <ChainIcon chainId={chainId} /></span>
        <span className="block whitespace-nowrap text-sm text-muted">{status}</span>
      </span>
      <span className="shrink-0 text-right"><span className="block font-bold tabular-nums">{figure}</span><span className="block text-xs tabular-nums text-muted">{note}</span></span>
    </span>
  )
}
