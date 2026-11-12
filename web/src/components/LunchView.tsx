'use client'

import { useQuery } from '@tanstack/react-query'
import { useEffect, useState, type ReactNode } from 'react'
import { formatUnits, parseUnits } from 'viem'
import { useWallet } from '@/hooks/useWallet'
import { ChainIcon } from '@/components/ChainIcon'
import { PriceChart, type Burn } from '@/components/PriceChart'
import { TxAction } from '@/components/TxAction'
import { assetUrl, formatEth, formatPrice, formatTokens } from '@/lib/format'
import { countdown, PHASE_LABEL, phaseOf, REST_SECONDS, type Phase } from '@/lib/fair-lunch/phase'
import { uniswapV4PoolId } from '@bananapus/nana-sdk-core/v6/uniswap-v4'
import { readCopies, readHostOf, readLunch, readPoolFees, type Lunch } from '@/lib/fair-lunch/reads'
import { PERCENT_TOTAL, splitOf, tokensFor } from '@/lib/fair-lunch/split'
import { allowanceShortOf, allowTx, claimTx, otherMoneyOf, payTx, routedPayTx, quoteSwap, quoteSwapFor, sendHomeTx, tradeTx, upkeepTx } from '@/lib/fair-lunch/writes'
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

const amountOf = (text: string, decimals = 18): bigint => {
  try { return parseUnits(text.trim() || '0', decimals) } catch { return 0n }
}

/** An amount of a lunch's money, with its symbol. */
const moneyText = (lunch: Pick<Lunch, 'money'>, amount: bigint) => `${formatEth(amount, lunch.money.decimals)} ${lunch.money.symbol}`

/** How much of its money a wallet still has to let the terminal take before it can pay `amount`. Zero for ETH. */
function useShort(lunch: Lunch, amount: bigint, paying: Lunch['money'] = lunch.money): bigint {
  const { address } = useWallet()
  const { data } = useQuery({
    queryKey: ['fair-lunch', 'allowance', lunch.chainId, paying.address, address, amount.toString()],
    queryFn: () => allowanceShortOf(lunch, address!, amount, paying),
    enabled: Boolean(address) && amount > 0n,
  })
  return data ?? 0n
}

/** The step before paying an ERC-20: letting the terminal take exactly what's about to be paid. */
function Allow({ lunch, amount, paying = lunch.money }: { lunch: Lunch; amount: bigint; paying?: Lunch['money'] }) {
  return (
    <TxAction chainId={lunch.chainId} label={`Allow ${paying.symbol}`} title={`Allow ${paying.symbol}`} doneTitle="Allowed"
      prepare={async () => ({ request: await allowTx(lunch, amount, paying), rows: [
        { label: 'Allows', value: `Paying ${moneyText({ money: paying }, amount)} into ${lunch.name}`, strong: true },
        { label: 'Costs you', value: 'Network fee only' },
      ] })} />
  )
}

function Stat({ label, value, action }: { label: ReactNode; value: string; action?: ReactNode }) {
  return (
    <div>
      <dt className="text-sm text-muted">{label}</dt>
      <dd className="whitespace-pre-line text-xl font-bold tabular-nums">{value}</dd>
      {action ? <dd className="mt-2">{action}</dd> : null}
    </div>
  )
}

/** The pie's colors: where a raise goes. */
const POOL = '#2e7d32', CREATOR = '#f5b942', FUNDERS = '#2f6fed'
const Swatch = ({ color }: { color: string }) => <span aria-hidden className="mr-1.5 inline-block h-2.5 w-2.5 rounded-full" style={{ background: color }} />

/** Uniswap's own page for a lunch's pool, on the chains its app shows. */
const UNISWAP_CHAIN: Record<number, string> = { 1: 'ethereum', 10: 'optimism', 8453: 'base', 42161: 'arbitrum' }

/** A wei amount as text for an input: six significant digits, no grouping. */
const inputText = (wei: bigint, decimals = 18) => String(Number(Number(formatUnits(wei, decimals)).toPrecision(6)))

/** While cooking: money in, tokens out at the fixed price. Another token is swapped into the money on the way in. */
function PayCard({ lunch, status }: { lunch: Lunch; status: ReactNode }) {
  const [text, setText] = useState('')
  const other = otherMoneyOf(lunch)
  const [routed, setRouted] = useState(false)
  const paying = routed && other ? other : lunch.money
  const amount = amountOf(text, paying.decimals)
  const tokens = tokensFor(amount, lunch.money.decimals)
  const short = useShort(lunch, amount, paying)
  return (
    <section className="card space-y-3 p-4">
      {status}
      <label className="field">
        Pay
        <span className="flex gap-2">
          <input className="input min-w-0 flex-1 text-xl" inputMode="decimal" placeholder="0.1" value={text} onChange={event => setText(event.target.value)} />
          {other ? (
            <select aria-label="Pay with" className="input select-caret w-auto" value={paying.symbol} onChange={event => setRouted(event.target.value === other.symbol)}>
              <option>{lunch.money.symbol}</option>
              <option>{other.symbol}</option>
            </select>
          ) : <span className="self-center font-semibold">{lunch.money.symbol}</span>}
        </span>
      </label>
      <p className="text-sm text-muted">
        {routed ? `Swapped to ${lunch.money.symbol} first, then 1M ${lunch.symbol} per ${lunch.money.symbol}. No refunds.` : `You get ${formatTokens(tokens)} ${lunch.symbol}. No refunds.`}
      </p>
      <div className="flex flex-col items-end gap-2">
        {short > 0n ? <Allow lunch={lunch} amount={short} paying={paying} /> : <TxAction chainId={lunch.chainId} label="Fund" title={`Fund ${lunch.name}`} doneTitle="Funded" onDone={() => setText('')}
          prepare={async account => {
            if (amount === 0n) throw new Error('Enter an amount.')
            const pay = { label: 'You pay', value: moneyText({ money: paying }, amount), strong: true }
            if (!routed) return { request: await payTx(lunch, amount, account), rows: [pay, { label: 'You get', value: `${formatTokens(tokens)} ${lunch.symbol}` }, { label: 'Refunds', value: 'None' }] }
            const { request, minimum } = await routedPayTx(lunch, paying, amount, account)
            return { request, rows: [pay, { label: 'You get at least', value: `${formatTokens(minimum)} ${lunch.symbol}` }, { label: 'Refunds', value: 'None' }] }
          }} />}
      </div>
    </section>
  )
}

/** Once served: buy from the pool, or sell back to it, through the lunch's project. Either side can be typed. */
function SwapCard({ lunch }: { lunch: Lunch }) {
  const [selling, setSelling] = useState(false)
  // Which side was typed: what's paid, or what's wanted.
  const [typed, setTyped] = useState<{ side: 'pay' | 'get'; text: string }>({ side: 'pay', text: '' })
  const money = lunch.money.symbol
  // What's paid is the token when selling and money when buying. What's got is the other.
  const decimalsOf = (side: 'pay' | 'get') => ((side === 'pay') === selling ? 18 : lunch.money.decimals)
  const amount = amountOf(typed.text, decimalsOf(typed.side))
  const [from, to] = selling ? [lunch.symbol, money] : [money, lunch.symbol]
  const format = (wei: bigint, side: 'pay' | 'get') => ((side === 'pay') === selling ? `${formatTokens(wei)} ${lunch.symbol}` : moneyText(lunch, wei))
  const quote = useQuery({
    queryKey: ['fair-lunch', 'quote', lunch.chainId, lunch.projectId, selling, typed.side, amount.toString()],
    queryFn: async () => typed.side === 'pay'
      ? { pay: amount, get: await quoteSwap(lunch, amount, selling) }
      : { pay: await quoteSwapFor(lunch, amount, selling), get: amount },
    enabled: amount > 0n,
    refetchInterval: 15_000,
  })
  const other = (side: 'pay' | 'get') => (amount > 0n && quote.data ? inputText(quote.data[side], decimalsOf(side)) : '')
  // A buy sized by what it gets may need a little more money than the quote by the time it lands.
  const paying = selling ? 0n : typed.side === 'pay' ? amount : ((quote.data?.pay ?? 0n) * 101n) / 100n
  const short = useShort(lunch, paying)
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
      <div className="flex flex-col items-end gap-2">
        {short > 0n ? <Allow lunch={lunch} amount={short} /> : <TxAction chainId={lunch.chainId} label={verb} title={verb} doneTitle="Done" onDone={() => setTyped({ side: 'pay', text: '' })}
          prepare={async account => {
            if (amount === 0n) throw new Error('Enter an amount.')
            const pay = typed.side === 'pay' ? amount : await quoteSwapFor(lunch, amount, selling)
            const out = await quoteSwap(lunch, pay, selling)
            const minimum = out - (out * SLIPPAGE_BPS) / 10_000n
            return { request: await tradeTx(lunch, pay, minimum, account, selling), rows: [
              { label: 'You pay', value: format(pay, 'pay'), strong: true },
              { label: 'You get at least', value: format(minimum, 'get') },
            ] }
          }} />}
      </div>
    </section>
  )
}

/** A call anyone can make to move a lunch along. */
const upkeep = (lunch: Lunch, functionName: 'serve' | 'burn' | 'collect', says: string) => async (account: `0x${string}`) => ({
  request: { ...(await upkeepTx(lunch.chainId, lunch.projectId, functionName, account)), label: says },
  rows: [{ label: 'Does', value: says }, { label: 'Costs you', value: 'Network fee only' }],
})
const SMALL = 'btn-secondary min-h-[36px] px-3 text-sm'

/** A number on its own row with the button that moves it at its right. */
const ACTION_ROW = 'col-span-2 flex flex-wrap items-end justify-between gap-3'

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
        <Stat label="Current price" value={lunch.price ? `${formatPrice(lunch.price)} ${lunch.money.symbol}` : '…'} />
        <Stat label="Supply" value={formatTokens(lunch.supply)} />
        <Stat label="🔒 In the pool" value={lunch.pooled === null ? '…' : moneyText(lunch, lunch.pooled)} />
        <Stat label="Waiting to buy and burn" value={moneyText(lunch, lunch.balance)} />
        <div className={ACTION_ROW}>
          <Stat label="🔥 Burned" value={formatTokens(burns.reduce((sum, burn) => sum + BigInt(burn.amount), 0n))} />
          {phase === 'eating' && lunch.balance > 0n ? (
            <TxAction chainId={lunch.chainId} className={SMALL} label="🔥 Buy and burn" title="Buy and burn" doneTitle="Burned"
              prepare={upkeep(lunch, 'burn', `Buys ${lunch.symbol} from the pool and burns it`)} />
          ) : null}
        </div>
        <div className={ACTION_ROW}>
          <Stat label="🧾 Pool fees" value={fees ? `${moneyText(lunch, fees.money)} + ${formatTokens(fees.tokens)} ${lunch.symbol}` : '…'} />
          {fees && (fees.money > 0n || fees.tokens > 0n) ? (
            <TxAction chainId={lunch.chainId} className={SMALL} label="Collect" title="Collect pool fees" doneTitle="Collected"
              prepare={upkeep(lunch, 'collect', `Burns the pool's ${lunch.symbol} fees, pays its ${lunch.money.symbol} fees into JBP6 for the chef`)} />
          ) : null}
        </div>
        <Stat label="👩‍🍳 Chef tokens vested" value={lunch.tokenPercent === 0n ? 'None' : `${Math.min(100, Math.floor(((now - lunch.servedAt) * 100) / (lunch.vestingDuration || 1)))}%`} />
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
    return (
    <section className="mt-4 border-t border-line pt-3">
      <h2 className="text-sm text-muted">🚚 Delivery</h2>
      <ul>
        {copies.map(copy => {
          const arrived = copy.claims[0]
          return (
            <li key={copy.chainId} className="flex flex-wrap items-center justify-between gap-3 pt-2">
              <div>
                <p className="flex items-center gap-1.5 font-semibold"><ChainIcon chainId={copy.chainId} /> {chainName(copy.chainId)}</p>
                <p className="text-sm tabular-nums text-muted">
                  {moneyText(copy, copy.balance)} waiting{copy.onTheWay > 0n ? `, ${moneyText(copy, copy.onTheWay)} on the way` : ''}
                </p>
              </div>
              <div className="flex flex-wrap gap-2">
                {copy.balance > 0n ? (
                  <TxAction chainId={copy.chainId} className={SMALL} label="Deliver" title={`Send to ${host}`} doneTitle="Sent"
                    prepare={async account => {
                      const { sending, ...request } = await sendHomeTx(copy, account)
                      return { request, rows: [
                        { label: 'Sends', value: `${moneyText(copy, sending)} to ${lunch.name} on ${host}`, strong: true },
                        { label: 'You pay up to', value: `${formatEth(request.value)} ETH for the bridge` },
                        { label: 'You get back', value: "What the bridge doesn't use" },
                      ] }
                    }} />
                ) : null}
                {arrived ? (
                  <TxAction chainId={lunch.chainId} className={SMALL} label={`Bring in ${moneyText(lunch, arrived.leaf.terminalTokenAmount)}`} title="Bring it in" doneTitle="Brought in"
                    prepare={async () => ({ request: claimTx(lunch.chainId, copy, arrived), rows: [
                      { label: 'Adds', value: `${moneyText(lunch, arrived.leaf.terminalTokenAmount)} to ${lunch.name}`, strong: true },
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
  const split = splitOf(lunch.balance, lunch.supply, lunch, lunch.money.decimals)
  const logo = assetUrl(logoUri)
  // Each part of the raise as a percent of it, for the pie.
  const slice = (wei: bigint) => (lunch.balance > 0n ? Number((wei * 10_000n) / lunch.balance) / 100 : 0)
  const tokenTotal = lunch.supply + split.poolTokens + split.creatorTokens
  const part = (tokens: bigint) => (tokenTotal > 0n ? Number((tokens * 10_000n) / tokenTotal) / 100 : 0)
  const timer =
    phase === 'cooking' ? `${countdown(lunch.deadline - now)} left`
    : phase === 'resting' ? `buybacks start in ${countdown(lunch.servedAt + REST_SECONDS - now)}`
    : null

  // Where the lunch is, shown at the top of the card that phase is about.
  const status = (
    <div>
      <h2 className="text-3xl font-bold sm:text-4xl">{PHASE_LABEL[phase]}</h2>
      {timer ? <p className="mt-1 text-xl tabular-nums text-muted">{timer}</p> : null}
      {phase === 'cooking' && lunch.deadline > lunch.startedAt ? (
        <progress className="progress-time mt-2 block h-2 w-full" aria-label="Time gone of the fundraise"
          max={lunch.deadline - lunch.startedAt} value={Math.max(0, now - lunch.startedAt)} />
      ) : null}
    </div>
  )

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

      {lunch.servedAt ? <section className="card space-y-3 p-4">{status}<PriceChart lunch={lunch} burns={burns} /></section> : null}

      <div className="grid gap-4 md:grid-cols-2">
        <div className="space-y-3">
          {phase === 'cooking' ? <PayCard lunch={lunch} status={status} /> : null}
          {lunch.servedAt ? <SwapCard lunch={lunch} /> : null}
          {phase === 'ready' || phase === 'empty' ? (
            <section className="card space-y-3 p-4">
              {status}
              {phase === 'ready' ? (
                <div className="flex flex-col items-end gap-2">
                  <TxAction chainId={lunch.chainId} label="🍽️ Serve it" title="Serve lunch" doneTitle="Served" prepare={upkeep(lunch, 'serve', 'Pays the creator, opens the pool, locks the liquidity')} />
                </div>
              ) : null}
            </section>
          ) : null}
        </div>
        <section className="card p-4">
          {lunch.servedAt ? (
            <ServedStats lunch={lunch} burns={burns} now={now} phase={phase} />
          ) : (
            <>
              <p className="text-sm text-muted">Raised</p>
              <p className="text-4xl font-bold tabular-nums">{moneyText(lunch, lunch.balance)}</p>
              <div className="mt-4 flex items-center gap-5">
                {lunch.balance > 0n ? (
                  <div role="img" aria-label="Where the raise goes" className="h-24 w-24 shrink-0 rounded-full border border-line"
                    style={{ background: `conic-gradient(${POOL} 0 ${slice(split.poolEth)}%, ${CREATOR} 0)` }} />
                ) : null}
                <dl className="space-y-2">
                  <Stat label={<><Swatch color={POOL} />🔒 To the pool</>} value={moneyText(lunch, split.poolEth)} />
                  <Stat label={<><Swatch color={CREATOR} />👩‍🍳 To the chef</>} value={moneyText(lunch, split.creatorEth + split.fee)} />
                </dl>
              </div>
              <p className="mt-3 text-sm text-muted">
                The chef keeps {percent(lunch.keepPercent)} of the raise, up to {formatUnits(lunch.keepCap, lunch.money.decimals)} {lunch.money.symbol}. The rest is locked in the pool.
              </p>
              {tokenTotal > 0n ? (
                <>
                  <p className="mt-5 text-sm text-muted">Tokens if served now</p>
                  <p className="text-2xl font-bold tabular-nums">{formatTokens(tokenTotal)} {lunch.symbol}</p>
                  <div className="mt-3 flex items-center gap-5">
                    <div role="img" aria-label="Who gets the tokens" className="h-24 w-24 shrink-0 rounded-full border border-line"
                      style={{ background: `conic-gradient(${FUNDERS} 0 ${part(lunch.supply)}%, ${POOL} 0 ${part(lunch.supply + split.poolTokens)}%, ${CREATOR} 0)` }} />
                    <dl className="space-y-2">
                      <Stat label={<><Swatch color={FUNDERS} />🥬 Funders</>} value={formatTokens(lunch.supply)} />
                      <Stat label={<><Swatch color={POOL} />🔒 The pool</>} value={formatTokens(split.poolTokens)} />
                      <Stat label={<><Swatch color={CREATOR} />👩‍🍳 The chef, vested</>} value={formatTokens(split.creatorTokens)} />
                    </dl>
                  </div>
                </>
              ) : null}
            </>
          )}
          <p className="mt-3 text-sm text-muted">
            {lunch.servedAt
              ? `The chef kept ${percent(lunch.keepPercent)} of the raise, up to ${formatUnits(lunch.keepCap, lunch.money.decimals)} ${lunch.money.symbol}, and got ${percent(lunch.tokenPercent)} of the tokens, unlocking over ${Math.round(lunch.vestingDuration / 604800)} weeks. The rest was locked in the pool.`
              : `Funders get 1M ${lunch.symbol} per ${lunch.money.symbol}, fixed. The pool gets the same for its ${lunch.money.symbol}. The chef gets ${percent(lunch.tokenPercent)} of the tokens, unlocking over ${Math.round(lunch.vestingDuration / 604800)} weeks.`}
          </p>
          <Copies lunch={lunch} />
        </section>
      </div>
    </div>
  )
}
