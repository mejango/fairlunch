import Link from 'next/link'
import { ChainIcon } from '@/components/ChainIcon'
import { assetUrl, formatEth } from '@/lib/format'
import { listLunches } from '@/lib/fair-lunch/indexed'
import { PHASE_LABEL, phaseOf } from '@/lib/fair-lunch/phase'
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
        <h1 className="text-4xl font-bold sm:text-5xl">Raise. Launch. Walk away. 🥪</h1>
        <p className="mx-auto mt-3 max-w-md text-muted">Sell a token at one price. Keep a share. The rest becomes liquidity nobody can pull.</p>
        <Link href="/create" className="btn-primary mt-5 min-h-[48px] px-6 text-lg">Make lunch</Link>
      </section>
      {lunches.length ? (
        <ul className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {lunches.map(lunch => {
            const logo = assetUrl(lunch.logoUri)
            const paidIn = BigInt(lunch.paidIn)
            return (
              <li key={`${lunch.chainId}:${lunch.projectId}`}>
                <Link href={projectPath(lunch.chainId, lunch.projectId)} className="card flex items-center gap-3 p-4 hover:border-ink">
                  {logo ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={logo} alt="" className="h-12 w-12 rounded-lg border border-line object-cover" />
                  ) : <span className="flex h-12 w-12 items-center justify-center rounded-lg border border-line text-xl">🥪</span>}
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center gap-1.5 font-bold"><span className="truncate">{lunch.name ?? `Lunch ${lunch.projectId}`}</span> <ChainIcon chainId={lunch.chainId} /></span>
                    <span className="block text-sm text-muted">{PHASE_LABEL[phaseOf(lunch, paidIn, now)]}</span>
                  </span>
                  <span className="text-right font-bold tabular-nums">{formatEth(paidIn)} ETH</span>
                </Link>
              </li>
            )
          })}
        </ul>
      ) : <p className="card p-6 text-center text-muted">{failed ? 'The list couldn’t load. Try again soon.' : '🍽️ Nothing cooking yet.'}</p>}
    </div>
  )
}
