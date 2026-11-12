'use client'

import { useQuery } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { formatUnits, parseEther } from 'viem'
import { ChainIcon } from '@/components/ChainIcon'
import { PriceChart, type Burn } from '@/components/PriceChart'
import { TxAction } from '@/components/TxAction'
import { assetUrl, formatEth, formatPrice, formatTokens } from '@/lib/format'
import { countdown, PHASE_LABEL, phaseOf, REST_SECONDS, type Phase } from '@/lib/fair-lunch/phase'
import { readCopies, readHostOf, readLunch, type Lunch } from '@/lib/fair-lunch/reads'
import { PERCENT_TOTAL, splitOf, TOKENS_PER_ETH } from '@/lib/fair-lunch/split'
import { claimTx, payTx, quoteSwap, sellApprovalTx, sendHomeTx, swapTx, upkeepTx } from '@/lib/fair-lunch/writes'
import { useWallet } from '@/hooks/useWallet'
import Link from 'next/link'
import { chainName, projectPath } from '@/lib/urn'

/** Refuse a buy that returns more than this much less than quoted. */
const SLIPPAGE_BPS = 200n

function useNow(): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))
  useEffect(() => {
    const timer = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000)
    return () => clearInterval(timer)
  }, [])
  return now
}

const amountOf = (text: string): bigint => {
  try { return parseEther(text.trim() || '0') } catch { return 0n }
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-sm text-muted">{label}</dt>
      <dd className="text-xl font-bold tabular-nums">{value}</dd>
    </div>
  )
}

function AmountInput({ label = 'ETH', value, onChange }: { label?: string; value: string; onChange: (text: string) => void }) {
  return (
    <label className="field">
      {label}
      <input className="input text-xl" inputMode="decimal" placeholder="0.1" value={value} onChange={event => onChange(event.target.value)} />
    </label>
  )
}

/** While cooking: ETH in, tokens out at the fixed price. */
function PayCard({ lunch }: { lunch: Lunch }) {
  const [text, setText] = useState('')
  const amount = amountOf(text)
  return (
    <section className="card space-y-3 p-4">
      <h2 className="text-lg font-bold">🍴 Pay</h2>
      <AmountInput value={text} onChange={setText} />
      <p className="text-sm text-muted">You get {formatTokens(amount * TOKENS_PER_ETH)} {lunch.symbol}. No refunds.</p>
      <TxAction chainId={lunch.chainId} label="Pay" title={`Pay ${lunch.name}`} doneTitle="Paid" onDone={() => setText('')}
        prepare={async account => {
          if (amount === 0n) throw new Error('Enter an amount.')
          return { request: await payTx(lunch, amount, account), rows: [
            { label: 'You pay', value: `${formatEth(amount)} ETH`, strong: true },
            { label: 'You get', value: `${formatTokens(amount * TOKENS_PER_ETH)} ${lunch.symbol}` },
            { label: 'Refunds', value: 'None' },
          ] }
        }} />
    </section>
  )
}

/** Once served: buy from the pool, or sell back to it. A sale's approvals come first, one press each. */
function SwapCard({ lunch }: { lunch: Lunch }) {
  const { address } = useWallet()
  const [selling, setSelling] = useState(false)
  const [text, setText] = useState('')
  const amount = amountOf(text)
  const [from, to] = selling ? [lunch.symbol, 'ETH'] : ['ETH', lunch.symbol]
  const format = (wei: bigint, unit: string) => `${unit === 'ETH' ? formatEth(wei) : formatTokens(wei)} ${unit}`
  const key = [lunch.chainId, lunch.projectId, selling, amount.toString()]
  const quote = useQuery({
    queryKey: ['fair-lunch', 'quote', ...key],
    queryFn: () => quoteSwap(lunch, amount, selling),
    enabled: amount > 0n,
    refetchInterval: 15_000,
  })
  const approval = useQuery({
    queryKey: ['fair-lunch', 'sell-approval', ...key, address],
    queryFn: () => sellApprovalTx(lunch, address!, amount),
    enabled: selling && amount > 0n && !!address,
  })
  const step = selling ? approval.data?.label : undefined
  const verb = step === 'Approve' ? `Approve ${lunch.symbol}` : step === 'Allow' ? 'Allow this sale' : `${selling ? 'Sell' : 'Buy'} ${lunch.symbol}`
  return (
    <section className="card space-y-3 p-4">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-bold">🍴 Swap</h2>
        <div className="flex gap-1" role="group" aria-label="Direction">
          {[false, true].map(sell => (
            <button key={String(sell)} type="button" aria-pressed={selling === sell} onClick={() => { setSelling(sell); setText('') }}
              className={`min-h-[36px] rounded-lg px-3 text-sm font-semibold ${selling === sell ? 'bg-ink text-bg' : 'text-muted hover:text-ink'}`}>
              {sell ? 'Sell' : 'Buy'}
            </button>
          ))}
        </div>
      </div>
      <AmountInput label={from} value={text} onChange={setText} />
      <p className="text-sm text-muted">
        {amount === 0n ? (selling ? `Sell ${lunch.symbol} to the pool.` : `Buy ${lunch.symbol} from the pool.`)
          : quote.data !== undefined ? `You get about ${format(quote.data, to)}.${step ? ' Approve first.' : ''}`
          : quote.isError ? 'No quote right now.' : 'Getting a quote…'}
      </p>
      <TxAction chainId={lunch.chainId} label={verb} title={verb} doneTitle="Done" onDone={() => { if (!step) setText('') }}
        prepare={async account => {
          if (amount === 0n) throw new Error('Enter an amount.')
          const approve = selling ? await sellApprovalTx(lunch, account, amount) : null
          if (approve) {
            return { request: approve, rows: [
              { label: 'Does', value: approve.label === 'Approve' ? `Lets Uniswap move your ${lunch.symbol} when you sell` : `Lets this sale take ${format(amount, from)} for 30 minutes` },
              { label: 'Costs you', value: 'Network fee only' },
            ] }
          }
          const out = await quoteSwap(lunch, amount, selling)
          const minimum = out - (out * SLIPPAGE_BPS) / 10_000n
          return { request: swapTx(lunch, amount, minimum, account, selling), rows: [
            { label: 'You pay', value: format(amount, from), strong: true },
            { label: 'You get at least', value: format(minimum, to) },
          ] }
        }} />
    </section>
  )
}

/** The calls anyone can make to move a lunch along, shown only when there's something for them to do. */
function Upkeep({ lunch, phase }: { lunch: Lunch; phase: Phase }) {
  const call = (functionName: 'serve' | 'burn' | 'collect', says: string) => async () => ({
    request: { ...(await upkeepTx(lunch.chainId, lunch.projectId, functionName)), label: says },
    rows: [{ label: 'Does', value: says }, { label: 'Costs you', value: 'Network fee only' }],
  })
  const secondary = 'btn-secondary min-h-[44px] w-full px-5'
  if (phase === 'ready') {
    return <TxAction chainId={lunch.chainId} label="🍽️ Serve it" title="Serve lunch" doneTitle="Served" prepare={call('serve', 'Pays the creator, opens the pool, locks the liquidity')} />
  }
  if (phase !== 'eating') return null
  return (
    <div className="grid gap-2 sm:grid-cols-2">
      {lunch.balance > 0n ? (
        <TxAction chainId={lunch.chainId} className={secondary} label={`🔥 Burn with ${formatEth(lunch.balance)} ETH`} title="Buy and burn" doneTitle="Burned"
          prepare={call('burn', `Buys ${lunch.symbol} from the pool and burns it`)} />
      ) : null}
      <TxAction chainId={lunch.chainId} className={secondary} label="🧾 Collect pool fees" title="Collect pool fees" doneTitle="Collected"
        prepare={call('collect', `Burns the pool's ${lunch.symbol} fees, pays its ETH fees into JBP6 for the creator`)} />
    </div>
  )
}

/** The lunch's other chains: what waits there, what's on the way, and the buttons anyone can press to move it. */
function Copies({ lunch }: { lunch: Lunch }) {
  const { data: copies } = useQuery({
    queryKey: ['fair-lunch', 'copies', lunch.chainId, lunch.projectId],
    queryFn: ({ signal }) => readCopies(lunch, signal),
    refetchInterval: 60_000,
  })
  if (!copies?.length) return null
  const host = chainName(lunch.chainId)
  const secondary = 'btn-secondary min-h-[44px] px-4'
  return (
    <section className="card space-y-3 p-4">
      <h2 className="text-lg font-bold">🚚 Other chains</h2>
      <p className="text-sm text-muted">ETH paid on these chains gets no tokens. It goes to {host}.</p>
      <ul className="divide-y divide-line">
        {copies.map(copy => {
          const arrived = copy.claims[0]
          return (
            <li key={copy.chainId} className="flex flex-wrap items-center justify-between gap-3 py-3">
              <div>
                <p className="flex items-center gap-1.5 font-semibold"><ChainIcon chainId={copy.chainId} /> {chainName(copy.chainId)}</p>
                <p className="text-sm tabular-nums text-muted">
                  {formatEth(copy.balance)} ETH waiting{copy.onTheWay > 0n ? `, ${formatEth(copy.onTheWay)} ETH on the way` : ''}
                </p>
              </div>
              <div className="flex flex-wrap gap-2">
                {copy.balance > 0n ? (
                  <TxAction chainId={copy.chainId} className={secondary} label="Send home" title={`Send to ${host}`} doneTitle="Sent"
                    prepare={async account => {
                      const { sending, ...request } = await sendHomeTx(copy, account)
                      return { request, rows: [
                        { label: 'Sends', value: `${formatEth(sending)} ETH to ${lunch.name} on ${host}`, strong: true },
                        { label: 'You pay up to', value: `${formatEth(request.value)} ETH for the bridge` },
                        { label: 'You get back', value: "What the bridge doesn't use" },
                      ] }
                    }} />
                ) : null}
                {arrived ? (
                  <TxAction chainId={lunch.chainId} className={secondary} label={`Bring in ${formatEth(arrived.leaf.terminalTokenAmount)} ETH`} title="Bring it in" doneTitle="Brought in"
                    prepare={async () => ({ request: claimTx(lunch.chainId, copy, arrived), rows: [
                      { label: 'Adds', value: `${formatEth(arrived.leaf.terminalTokenAmount)} ETH to ${lunch.name}`, strong: true },
                      { label: 'Costs you', value: 'Network fee only' },
                    ] })} />
                ) : null}
              </div>
            </li>
          )
        })}
      </ul>
    </section>
  )
}

/** A project that isn't a lunch here may be one's copy: point at the lunch. */
function NoLunch({ chainId, projectId }: { chainId: number; projectId: number }) {
  const { data: host } = useQuery({
    queryKey: ['fair-lunch', 'host-of', chainId, projectId],
    queryFn: ({ signal }) => readHostOf(chainId, projectId, signal),
  })
  if (!host) return <p className="card p-6">🫙 No lunch here.</p>
  return (
    <p className="card p-6">
      This lunch is on {chainName(host.chainId)}. <Link className="underline" href={projectPath(host.chainId, host.projectId)}>Go to it</Link>
    </p>
  )
}

const percent = (value: bigint) => `${Number((value * 1000n) / PERCENT_TOTAL) / 10}%`

export function LunchView({ chainId, projectId, burns, logoUri }: { chainId: number; projectId: number; burns: readonly Burn[]; logoUri: string | null }) {
  const now = useNow()
  const { data: lunch, isError, isPending } = useQuery({
    queryKey: ['fair-lunch', 'lunch', chainId, projectId],
    queryFn: ({ signal }) => readLunch(chainId, projectId, signal),
    refetchInterval: 15_000,
  })
  if (isPending) return <div className="card h-64 animate-pulse" aria-busy="true" />
  if (isError) return <p className="card p-6">This lunch couldn&apos;t load. It&apos;ll try again.</p>
  if (!lunch) return <NoLunch chainId={chainId} projectId={projectId} />

  const phase = phaseOf(lunch, lunch.balance, now)
  const split = splitOf(lunch.balance, lunch.supply, lunch)
  const logo = assetUrl(logoUri)
  const timer =
    phase === 'cooking' ? `${countdown(lunch.deadline - now)} left`
    : phase === 'resting' ? `buybacks start in ${countdown(lunch.servedAt + REST_SECONDS - now)}`
    : null

  return (
    <div className="space-y-4">
      <header className="flex items-center gap-3">
        {logo ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={logo} alt="" className="h-14 w-14 rounded-xl border border-line object-cover" />
        ) : <div className="flex h-14 w-14 items-center justify-center rounded-xl border border-line bg-card text-2xl">🥪</div>}
        <div className="min-w-0">
          <h1 className="truncate text-2xl font-bold">{lunch.name}</h1>
          <p className="flex items-center gap-1.5 text-muted">{lunch.symbol} on <ChainIcon chainId={chainId} /> {chainName(chainId)}</p>
        </div>
      </header>

      <section className="card p-5 text-center">
        <p className="text-3xl font-bold sm:text-4xl">{PHASE_LABEL[phase]}</p>
        {timer ? <p className="mt-1 text-xl tabular-nums text-muted">{timer}</p> : null}
      </section>

      {lunch.servedAt ? <PriceChart lunch={lunch} burns={burns} /> : null}

      <div className="grid gap-4 md:grid-cols-2">
        <section className="card p-4">
          {lunch.servedAt ? (
            <dl className="grid grid-cols-2 gap-4">
              <Stat label="Price" value={lunch.price ? `${formatPrice(lunch.price)} ETH` : '…'} />
              <Stat label="Supply" value={formatTokens(lunch.supply)} />
              <Stat label="Waiting to burn" value={`${formatEth(lunch.balance)} ETH`} />
              <Stat label="Burns" value={String(burns.length)} />
            </dl>
          ) : (
            <dl className="grid grid-cols-2 gap-4">
              <div className="col-span-2">
                <dt className="text-sm text-muted">Raised</dt>
                <dd className="text-4xl font-bold tabular-nums">{formatEth(lunch.balance)} ETH</dd>
              </div>
              <Stat label="🔒 To the pool" value={`${formatEth(split.poolEth)} ETH`} />
              <Stat label="👩‍🍳 To the creator" value={`${formatEth(split.creatorEth)} ETH`} />
            </dl>
          )}
          <p className="mt-4 text-sm text-muted">
            Creator keeps {percent(lunch.keepPercent)} of the raise, up to {formatUnits(lunch.keepCap, 18)} ETH, and gets {percent(lunch.tokenPercent)} of the tokens over {Math.round(lunch.vestingDuration / 604800)} weeks. The rest is locked in the pool.
          </p>
        </section>
        <div className="space-y-3">
          {phase === 'cooking' ? <PayCard lunch={lunch} /> : null}
          {lunch.servedAt ? <SwapCard lunch={lunch} /> : null}
          <Upkeep lunch={lunch} phase={phase} />
        </div>
      </div>

      <Copies lunch={lunch} />
    </div>
  )
}
