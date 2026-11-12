'use client'

import { useQuery } from '@tanstack/react-query'
import { useEffect, useState, type ReactNode } from 'react'
import { formatUnits, parseEther } from 'viem'
import { ChainIcon } from '@/components/ChainIcon'
import { PriceChart, type Burn } from '@/components/PriceChart'
import { TxAction } from '@/components/TxAction'
import { assetUrl, formatEth, formatPrice, formatTokens } from '@/lib/format'
import { countdown, PHASE_LABEL, phaseOf, REST_SECONDS, type Phase } from '@/lib/fair-lunch/phase'
import { uniswapV4PoolId } from '@bananapus/nana-sdk-core/v6/uniswap-v4'
import { readCopies, readHostOf, readLunch, readPoolFees, type Lunch } from '@/lib/fair-lunch/reads'
import { PERCENT_TOTAL, splitOf, TOKENS_PER_ETH } from '@/lib/fair-lunch/split'
import { claimTx, payTx, quoteSwap, quoteSwapFor, sendHomeTx, tradeTx, upkeepTx } from '@/lib/fair-lunch/writes'
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

function Stat({ label, value, action }: { label: string; value: string; action?: ReactNode }) {
  return (
    <div>
      <dt className="text-sm text-muted">{label}</dt>
      <dd className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xl font-bold tabular-nums">{value}{action}</dd>
    </div>
  )
}

/** Uniswap's own page for a lunch's pool, on the chains its app shows. */
const UNISWAP_CHAIN: Record<number, string> = { 1: 'ethereum', 10: 'optimism', 8453: 'base', 42161: 'arbitrum' }

/** A wei amount as text for an input: six significant digits, no grouping. */
const inputText = (wei: bigint) => String(Number(Number(formatUnits(wei, 18)).toPrecision(6)))

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

/** Once served: buy from the pool, or sell back to it, through the lunch's project. Either side can be typed. */
function SwapCard({ lunch }: { lunch: Lunch }) {
  const [selling, setSelling] = useState(false)
  // Which side was typed: what's paid, or what's wanted.
  const [typed, setTyped] = useState<{ side: 'pay' | 'get'; text: string }>({ side: 'pay', text: '' })
  const amount = amountOf(typed.text)
  const [from, to] = selling ? [lunch.symbol, 'ETH'] : ['ETH', lunch.symbol]
  const format = (wei: bigint, unit: string) => `${unit === 'ETH' ? formatEth(wei) : formatTokens(wei)} ${unit}`
  const quote = useQuery({
    queryKey: ['fair-lunch', 'quote', lunch.chainId, lunch.projectId, selling, typed.side, amount.toString()],
    queryFn: async () => typed.side === 'pay'
      ? { pay: amount, get: await quoteSwap(lunch, amount, selling) }
      : { pay: await quoteSwapFor(lunch, amount, selling), get: amount },
    enabled: amount > 0n,
    refetchInterval: 15_000,
  })
  const other = (side: 'pay' | 'get') => (amount > 0n && quote.data ? inputText(quote.data[side]) : '')
  const verb = `${selling ? 'Sell' : 'Buy'} ${lunch.symbol}`
  const side = (which: 'pay' | 'get', label: string, unit: string) => (
    <label className="block rounded-xl border border-line p-3 focus-within:border-ink">
      <span className="text-sm text-muted">{label}</span>
      <span className="flex items-center gap-2">
        <input className="min-w-0 flex-1 bg-transparent text-2xl font-bold tabular-nums outline-none" inputMode="decimal" placeholder="0"
          value={typed.side === which ? typed.text : other(which)} onChange={event => setTyped({ side: which, text: event.target.value })} />
        <span className="rounded-full border border-line px-3 py-1 font-semibold">{unit}</span>
      </span>
    </label>
  )
  return (
    <section className="card space-y-3 p-4">
      <h2 className="text-lg font-bold">🍴 Swap</h2>
      <div>
        {side('pay', 'Sell', from)}
        <button type="button" aria-label="Switch direction" onClick={() => { setSelling(!selling); setTyped({ side: 'pay', text: '' }) }}
          className="relative z-10 mx-auto -my-3 flex h-10 w-10 items-center justify-center rounded-lg border border-line bg-card text-lg hover:border-ink">↓</button>
        {side('get', 'Buy', to)}
      </div>
      {amount > 0n && !quote.data ? <p className="text-sm text-muted">{quote.isError ? 'No quote right now.' : 'Getting a quote…'}</p> : null}
      <TxAction chainId={lunch.chainId} label={verb} title={verb} doneTitle="Done" onDone={() => setTyped({ side: 'pay', text: '' })}
        prepare={async account => {
          if (amount === 0n) throw new Error('Enter an amount.')
          const pay = typed.side === 'pay' ? amount : await quoteSwapFor(lunch, amount, selling)
          const out = await quoteSwap(lunch, pay, selling)
          const minimum = out - (out * SLIPPAGE_BPS) / 10_000n
          return { request: await tradeTx(lunch, pay, minimum, account, selling), rows: [
            { label: 'You pay', value: format(pay, from), strong: true },
            { label: 'You get at least', value: format(minimum, to) },
          ] }
        }} />
    </section>
  )
}

/** A call anyone can make to move a lunch along. */
const upkeep = (lunch: Lunch, functionName: 'serve' | 'burn' | 'collect', says: string) => async (account: `0x${string}`) => ({
  request: { ...(await upkeepTx(lunch.chainId, lunch.projectId, functionName, account)), label: says },
  rows: [{ label: 'Does', value: says }, { label: 'Costs you', value: 'Network fee only' }],
})
const SMALL = 'btn-secondary min-h-[36px] px-3 text-sm'

/** A served lunch's numbers, with the calls anyone can make beside what they'd move. */
function ServedStats({ lunch, burns, now, phase }: { lunch: Lunch; burns: readonly Burn[]; now: number; phase: Phase }) {
  const { data: fees } = useQuery({
    queryKey: ['fair-lunch', 'pool-fees', lunch.chainId, lunch.projectId],
    queryFn: ({ signal }) => readPoolFees(lunch, signal),
    refetchInterval: 60_000,
  })
  const uniswap = UNISWAP_CHAIN[lunch.chainId]
  return (
    <>
      <dl className="grid grid-cols-2 gap-4">
        <Stat label="Price" value={lunch.price ? `${formatPrice(lunch.price)} ETH` : '…'} />
        <Stat label="Supply" value={formatTokens(lunch.supply)} />
        <Stat label="Waiting to burn" value={`${formatEth(lunch.balance)} ETH`} action={phase === 'eating' && lunch.balance > 0n ? (
          <TxAction chainId={lunch.chainId} className={SMALL} label="🔥 Burn" title="Buy and burn" doneTitle="Burned"
            prepare={upkeep(lunch, 'burn', `Buys ${lunch.symbol} from the pool and burns it`)} />
        ) : null} />
        <Stat label="🔥 Burned" value={formatTokens(burns.reduce((sum, burn) => sum + BigInt(burn.amount), 0n))} />
        <Stat label="🔒 In the pool" value={lunch.pooledEth === null ? '…' : `${formatEth(lunch.pooledEth)} ETH`} />
        <Stat label="🧾 Pool fees" value={fees ? `${formatEth(fees.eth)} ETH, ${formatTokens(fees.tokens)} ${lunch.symbol}` : '…'} action={fees && (fees.eth > 0n || fees.tokens > 0n) ? (
          <TxAction chainId={lunch.chainId} className={SMALL} label="Collect" title="Collect pool fees" doneTitle="Collected"
            prepare={upkeep(lunch, 'collect', `Burns the pool's ${lunch.symbol} fees, pays its ETH fees into JBP6 for the creator`)} />
        ) : null} />
        <Stat label="👩‍🍳 Creator tokens unlocked" value={lunch.tokenPercent === 0n ? 'None' : `${Math.min(100, Math.floor(((now - lunch.servedAt) * 100) / (lunch.vestingDuration || 1)))}%`} />
      </dl>
      {uniswap ? (
        <p className="mt-4 text-sm">
          <a className="text-accent underline" target="_blank" rel="noreferrer" href={`https://app.uniswap.org/explore/pools/${uniswap}/${uniswapV4PoolId(lunch.poolKey)}`}>See the pool on Uniswap</a>
        </p>
      ) : null}
    </>
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
  // The creator's share before the fee, as it fills toward its cap.
  const uncapped = (lunch.balance * lunch.keepPercent) / PERCENT_TOTAL
  const kept = uncapped < lunch.keepCap ? uncapped : lunch.keepCap
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

      <section className="card w-fit max-w-full px-5 py-4">
        <p className="text-3xl font-bold sm:text-4xl">{PHASE_LABEL[phase]}</p>
        {timer ? <p className="mt-1 text-xl tabular-nums text-muted">{timer}</p> : null}
        {phase === 'cooking' && lunch.deadline > lunch.startedAt ? (
          <progress className="mt-2 block h-2 w-full" aria-label="Time gone of the fundraise"
            max={lunch.deadline - lunch.startedAt} value={Math.max(0, now - lunch.startedAt)} />
        ) : null}
      </section>

      {lunch.servedAt ? <PriceChart lunch={lunch} burns={burns} /> : null}

      <div className="grid gap-4 md:grid-cols-2">
        <div className="space-y-3">
          {phase === 'cooking' ? <PayCard lunch={lunch} /> : null}
          {lunch.servedAt ? <SwapCard lunch={lunch} /> : null}
          {phase === 'ready' ? (
            <TxAction chainId={lunch.chainId} label="🍽️ Serve it" title="Serve lunch" doneTitle="Served" prepare={upkeep(lunch, 'serve', 'Pays the creator, opens the pool, locks the liquidity')} />
          ) : null}
        </div>
        <section className="card p-4">
          {lunch.servedAt ? (
            <ServedStats lunch={lunch} burns={burns} now={now} phase={phase} />
          ) : (
            <dl className="grid grid-cols-2 gap-4">
              <div className="col-span-2">
                <dt className="text-sm text-muted">Raised</dt>
                <dd className="text-4xl font-bold tabular-nums">{formatEth(lunch.balance)} ETH</dd>
              </div>
              <Stat label="🔒 To the pool" value={`${formatEth(split.poolEth)} ETH`} />
              <Stat label="👩‍🍳 To the creator" value={`${formatEth(split.creatorEth)} ETH`} />
              {lunch.keepPercent > 0n && lunch.keepCap > 0n ? (
                <progress className="col-span-2 h-2 w-full" aria-label="The creator's share, toward its cap"
                  max={Number(formatUnits(lunch.keepCap, 18))} value={Number(formatUnits(kept, 18))} />
              ) : null}
            </dl>
          )}
          <p className="mt-4 text-sm text-muted">
            Creator keeps {percent(lunch.keepPercent)} of the raise, up to {formatUnits(lunch.keepCap, 18)} ETH, and gets {percent(lunch.tokenPercent)} of the tokens over {Math.round(lunch.vestingDuration / 604800)} weeks. The rest is locked in the pool.
          </p>
        </section>
      </div>

      <Copies lunch={lunch} />
    </div>
  )
}
