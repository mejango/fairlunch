'use client'

import { JBCenterClient } from '@bananapus/nana-sdk-core/jbcenter'
import { useRouter } from 'next/navigation'
import { useQuery } from '@tanstack/react-query'
import { useEffect, useRef, useState, type FormEvent } from 'react'
import { NATIVE_TOKEN, USDC_ADDRESSES, type JBChainId } from '@bananapus/nana-sdk-core'
import { formatUnits, getAddress, isAddress, isAddressEqual, parseEventLogs, parseUnits, toHex, zeroAddress, zeroHash, type Address, type Hex, type PublicClient } from 'viem'
import { TxAction } from '@/components/TxAction'
import { TxError } from '@/components/ui/TxError'
import { useWallet } from '@/hooks/useWallet'
import { environmentForChainIds, PRODUCTION_CHAINS, TESTNET_CHAINS } from '@/lib/chains'
import { fairLunchAbi } from '@/lib/fair-lunch/abi'
import { deploymentOn } from '@/lib/fair-lunch/deployments'
import { readMoney } from '@/lib/fair-lunch/reads'
import { claimEntriesOf, claimsRootOf, type ClaimEntry } from '@/lib/fair-lunch/claims'
import { projectedCapOf, tokensFor } from '@/lib/fair-lunch/split'
import { createTx, madeOn, type LunchTerms } from '@/lib/fair-lunch/writes'
import { formatEth } from '@/lib/format'
import { jbCenterBaseUrl } from '@/lib/jbcenter-config'
import { jbCenterPublicClient } from '@/lib/jbcenter-rpc'
import { chainName, projectPath } from '@/lib/urn'

/** Ethereum, Base, Arbitrum, Optimism, then their testnets, wherever Fair Lunch is deployed. */
const ORDER = [1, 8453, 42161, 10, 11155111, 84532, 421614, 11155420]
const CHAINS = [...PRODUCTION_CHAINS, ...TESTNET_CHAINS]
  .filter(chain => deploymentOn(chain.id))
  .sort((a, b) => ORDER.indexOf(a.id) - ORDER.indexOf(b.id))

const VESTING_WEEKS = [26, 52, 104, 208]
const WEEK = 604_800
/** The choices for how long tokens unlock over, the same for the chef's and the airdrop's. */
const UNLOCK_OPTIONS = [0, ...VESTING_WEEKS].map(weeks => <option key={weeks} value={weeks}>{weeks >= 52 ? `${weeks / 52} ${weeks === 52 ? 'year' : 'years'}` : weeks ? '6 months' : 'Right away'}</option>)

const whole = (text: string, min: number, max: number): number | null => {
  const value = Number(text)
  return Number.isInteger(value) && value >= min && value <= max ? value : null
}

/** Ten plain fields, then one transaction per chain. The terms are fixed the moment the form is submitted, so every
 * chain gets the same ones. */
export function CreateForm() {
  const router = useRouter()
  const { address, isConnected, openSignIn } = useWallet()
  const [terms, setTerms] = useState<LunchTerms | null>(null)
  const [error, setError] = useState<string | null>(null)
  const formRef = useRef<HTMLFormElement>(null)
  // Bumped on every edit so the preview reads the form again.
  const [typed, setTyped] = useState(0)
  const [hypothetical, setHypothetical] = useState('')
  const [busy, setBusy] = useState(false)
  const [hostId, setHostId] = useState<number>(CHAINS[0]?.id ?? 0)
  const [raiseIn, setRaiseIn] = useState<'ETH' | 'USDC' | 'other'>('ETH')
  const [made, setMade] = useState<Record<number, Hex | null>>({})
  const [hostPath, setHostPath] = useState<string | null>(null)

  // Pick an unfinished create back up, and keep it as it moves.
  const [restored, setRestored] = useState(false)
  useEffect(() => {
    const attempt = loadAttempt()
    // An attempt saved before lunches could raise other tokens can't be finished as it was.
    if (attempt?.terms.tokenOn) { setTerms(attempt.terms); setMade(attempt.made); setHostPath(attempt.hostPath) }
    setRestored(true)
  }, [])
  useEffect(() => {
    if (!restored) return
    const finished = terms && [terms.hostChainId, ...terms.otherChainIds].every(chainId => chainId in made)
    saveAttempt(terms && !finished ? { terms, made, hostPath } : null)
  }, [restored, terms, made, hostPath])

  // A create can finish while this page is closed, or in a Safe after its other owners sign. The chain knows.
  const unmade = terms ? [terms.hostChainId, ...terms.otherChainIds].filter(chainId => !(chainId in made)) : []
  const { data: found } = useQuery({
    queryKey: ['fair-lunch', 'made', terms?.salt, unmade.join()],
    queryFn: ({ signal }) => Promise.all(unmade.map(async chainId => [chainId, await madeOn(terms!, chainId, signal).catch(() => null)] as const)),
    enabled: restored && unmade.length > 0,
    refetchInterval: 15_000,
  })
  useEffect(() => {
    for (const [chainId, projectId] of found ?? []) {
      if (projectId === null) continue
      setMade(before => (chainId in before ? before : { ...before, [chainId]: null }))
      if (chainId === terms?.hostChainId) setHostPath(before => before ?? projectPath(chainId, projectId))
    }
  }, [found, terms?.hostChainId])

  if (!CHAINS.length) return <p className="card p-6">🧑‍🍳 Fair Lunch isn&apos;t live yet.</p>
  const others = CHAINS.filter(chain => chain.id !== hostId && environmentForChainIds([chain.id]) === environmentForChainIds([hostId]))

  // What the token would start at if the fundraise raised a made-up amount, under the terms typed so far.
  const moneySymbol = raiseIn === 'other' ? 'tokens' : raiseIn
  const moneyDecimals = raiseIn === 'USDC' ? 6 : 18
  const preview = (() => {
    void typed
    const form = formRef.current && new FormData(formRef.current)
    const field = (name: string) => String(form?.get(name) ?? '').trim()
    const keep = whole(field('keep'), 0, 99), share = whole(field('share'), 0, 99)
    const airdrop = share === null ? null : whole(field('airdrop') || '0', 0, 99 - share)
    if (!form || keep === null || share === null || airdrop === null) return null
    try {
      const raised = parseUnits(hypothetical.trim() || '0', moneyDecimals)
      if (raised === 0n) return null
      return projectedCapOf(raised, tokensFor(raised, moneyDecimals), {
        keepPercent: BigInt(keep) * 10_000_000n, keepCap: parseUnits(field('cap') || '0', moneyDecimals),
        tokenPercent: BigInt(share) * 10_000_000n, claimsPercent: BigInt(airdrop) * 10_000_000n,
        vestingDuration: Number(field('vesting')) * WEEK, claimsVestingDuration: Number(field('airdropVesting')) * WEEK,
      }, moneyDecimals)
    } catch { return null }
  })()

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!isConnected || !address) return void openSignIn()
    const form = new FormData(event.currentTarget)
    const text = (name: string) => String(form.get(name) ?? '').trim()
    const days = whole(text('days'), 1, 365), keep = whole(text('keep'), 0, 99), share = whole(text('share'), 0, 99)
    const otherChainIds = others.filter(chain => form.get(`also-${chain.id}`)).map(chain => chain.id)
    const chainIds = [hostId, ...otherChainIds]
    // ETH and USDC have a known address on every chain. Any other token is only known where the creator names it.
    const custom = text('money')
    if (raiseIn === 'other' && (!isAddress(custom) || isAddressEqual(custom, zeroAddress))) return setError('Enter the token to raise as 0x and 40 characters.')
    if (raiseIn === 'other' && otherChainIds.length) return setError('Raise ETH or USDC to accept payments on other chains.')
    const tokenOn = Object.fromEntries(chainIds.map(chainId => [chainId,
      raiseIn === 'ETH' ? NATIVE_TOKEN as Address : raiseIn === 'USDC' ? USDC_ADDRESSES[chainId as JBChainId] : getAddress(custom)]))
    if (chainIds.some(chainId => !tokenOn[chainId])) return setError('USDC isn’t on one of those chains.')
    if (!text('name') || !text('symbol')) return setError('Give it a name and a ticker.')
    if (days === null) return setError('Raise for 1 to 365 days.')
    if (keep === null) return setError('Keep 0 to 99 percent of the raise.')
    const airdrop = share === null ? null : whole(text('airdrop') || '0', 0, 99 - share)
    if (share === null || airdrop === null) return setError('Your tokens and the airdrop have to add up to 99 percent or less.')
    const list = form.get('list')
    let entries: ClaimEntry[] = []
    if (airdrop) {
      if (!(list instanceof File) || !list.size) return setError('Add the airdrop list: a file of address,amount lines.')
      try { entries = claimEntriesOf(await list.text()) } catch (cause) { return setError(cause instanceof Error ? cause.message : 'The list couldn’t be read.') }
    }
    // Strict: all lowercase or a right checksum, so a mistyped address is caught here, not paid.
    const payout = text('payout')
    if (!isAddress(payout) || isAddressEqual(payout, zeroAddress)) return setError('Enter the address to pay as 0x and 40 characters.')
    setError(null)
    setBusy(true)
    try {
      let money: { symbol: string; decimals: number }
      try { money = await readMoney(jbCenterPublicClient(hostId) as PublicClient, tokenOn[hostId]) } catch { return setError('That token couldn’t be read on this chain.') }
      let cap: bigint
      try { cap = parseUnits(text('cap') || '0', money.decimals) } catch { return setError(`Enter the most ${money.symbol} to keep as a number.`) }
      const center = new JBCenterClient({ baseUrl: jbCenterBaseUrl() })
      const logo = form.get('logo')
      const logoUri = logo instanceof File && logo.size ? (await center.pinImage(logo, { filename: logo.name })).uri : undefined
      const claimsUri = entries.length ? (await center.pinJson({ claims: entries.map(([account, shares]) => [account, shares]) })).uri : undefined
      const { uri } = await center.pinJson({ name: text('name'), ...(logoUri ? { logoUri } : {}), ...(claimsUri ? { claimsUri } : {}) })
      setTerms({
        name: text('name'), symbol: text('symbol').toUpperCase(), projectUri: uri,
        hostChainId: hostId, otherChainIds, tokenOn, money: { symbol: money.symbol, decimals: money.decimals },
        deadline: Math.floor(Date.now() / 1000) + days * 86_400, sender: address, creator: getAddress(payout),
        keepPercent: keep, keepCapWei: cap, tokenPercent: share, vestingSeconds: Number(text('vesting')) * WEEK,
        claimsPercent: airdrop, claimsRoot: entries.length ? claimsRootOf(entries) : zeroHash, claimsCount: entries.length, claimsVestingSeconds: airdrop ? Number(text('airdropVesting')) * WEEK : 0,
        salt: toHex(crypto.getRandomValues(new Uint8Array(32))),
      })
    } catch {
      setError('The logo, name or list couldn’t be saved. Try again.')
    } finally {
      setBusy(false)
    }
  }

  if (terms) {
    const chains = [terms.hostChainId, ...terms.otherChainIds]
    return (
      <section className="card space-y-4 p-5">
        <h1 className="text-2xl font-bold">🧑‍🍳 {terms.name}</h1>
        <p className="text-muted">{chains.length > 1 ? 'One transaction per chain, from the same wallet.' : 'One transaction.'}</p>
        <ol className="space-y-3">
          {chains.map((chainId, index) => (
            <li key={chainId}>
              {chainId in made ? <p className="font-semibold">✅ {chainName(chainId)}</p> : (
                <TxAction chainId={chainId} disabled={index > 0 && !(terms.hostChainId in made)}
                  label={index === 0 ? `Make lunch on ${chainName(chainId)}` : `Also collect on ${chainName(chainId)}`}
                  title={`Make ${terms.name}`} doneTitle="Lunch is cooking"
                  prepare={async account => {
                    if (account !== terms.sender) throw new Error('Use the wallet you started with.')
                    return { request: await createTx(terms, chainId), rows: [
                      { label: 'Token', value: `${terms.name} (${terms.symbol})` },
                      { label: 'Raise ends', value: new Date(terms.deadline * 1000).toLocaleString() },
                      { label: 'You keep', value: `${terms.keepPercent}% of the raise, up to ${formatUnits(terms.keepCapWei, terms.money.decimals)} ${terms.money.symbol}, before the 2.5% fee` },
                      { label: 'Your tokens', value: `${terms.tokenPercent}%, ${terms.vestingSeconds ? `over ${terms.vestingSeconds / WEEK} weeks` : 'at serve'}` },
                      ...(terms.claimsPercent ? [{ label: 'Airdrop', value: `${terms.claimsPercent}% of supply to ${terms.claimsCount} addresses, ${terms.claimsVestingSeconds ? `over ${terms.claimsVestingSeconds / WEEK} weeks` : 'at serve'}` }] : []),
                      { label: 'Paid to', value: isAddressEqual(terms.creator, account) ? 'This wallet' : terms.creator },
                      { label: 'Can change later', value: 'Nothing', strong: true },
                    ] }
                  }}
                  onDone={hash => {
                    setMade(before => ({ ...before, [chainId]: hash }))
                    if (index !== 0 || !hash) return
                    void jbCenterPublicClient(chainId).getTransactionReceipt({ hash }).then(receipt => {
                      const [created] = parseEventLogs({ abi: fairLunchAbi, eventName: 'Create', logs: receipt.logs })
                      if (created) setHostPath(projectPath(chainId, created.args.projectId))
                    }).catch(() => undefined)
                  }} />
              )}
            </li>
          ))}
        </ol>
        {terms.hostChainId in made ? (
          <button type="button" className="btn-secondary min-h-[44px] px-5" onClick={() => router.push(hostPath ?? '/')}>🥪 See your lunch</button>
        ) : (
          <button type="button" className="btn-link" onClick={() => { setTerms(null); setMade({}) }}>Back</button>
        )}
      </section>
    )
  }

  return (
    <form ref={formRef} onInput={() => setTyped(count => count + 1)} onSubmit={event => void submit(event)} className="card mx-auto max-w-xl space-y-4 p-5">
      <h1 className="text-2xl font-bold">🛒 Ingredients</h1>
      <ul className="list-disc space-y-1 pl-5 text-sm text-muted">
        <li>Sell a new token at a fixed price until the deadline. Funders can take refunds until then.</li>
        <li>You get your share of the raise, the rest is locked in a liquidity pool.</li>
        <li>Tokens go to funders, to the pool, to an airdrop, and some to you.</li>
        <li>Later payments on any chain buy the token on the main chain and burn it.</li>
      </ul>
      <div className="flex gap-4">
        <label className="field min-w-0 flex-1">🍞 Name<input name="name" className="input" maxLength={32} required placeholder="Sandwich" /></label>
        <label className="field w-32 shrink-0">🥓 Ticker<input name="symbol" className="input uppercase" maxLength={10} required placeholder="SAND" /></label>
      </div>
      <label className="field">🍅 Logo<input name="logo" type="file" accept="image/png,image/jpeg,image/webp,image/gif"
        className="block w-fit max-w-full cursor-pointer rounded-xl border border-dashed border-line p-3 text-sm font-normal text-muted file:mr-3 file:cursor-pointer file:rounded-lg file:border file:border-solid file:border-line file:bg-card file:px-3 file:py-1.5 file:font-semibold file:text-ink hover:border-ink" /></label>
      <label className="field w-52 max-w-full">🧅 Chain
        <select name="host" className="input select-caret" value={hostId} onChange={event => setHostId(Number(event.target.value))}>
          {CHAINS.map(chain => <option key={chain.id} value={chain.id}>{chainName(chain.id)}</option>)}
        </select>
      </label>
      {others.length ? (
        <fieldset className="text-sm">
          <legend className="font-semibold">🥗 Also accept payments and bridge from</legend>
          <div className="mt-1 flex flex-wrap gap-x-4 gap-y-2">
            {others.map(chain => <label key={chain.id} className="flex min-h-[44px] items-center gap-2"><input type="checkbox" name={`also-${chain.id}`} /> {chainName(chain.id)}</label>)}
          </div>
        </fieldset>
      ) : null}
      <div className="flex gap-4">
        <label className="field w-32 shrink-0">🍋 Raise in
          <select className="input select-caret" value={raiseIn} onChange={event => setRaiseIn(event.target.value as typeof raiseIn)}>
            <option value="ETH">ETH</option>
            <option value="USDC">USDC</option>
            <option value="other">Other</option>
          </select>
        </label>
        {raiseIn === 'other' ? (
          <label className="field min-w-0 flex-1">🧂 Token address
            <input name="money" className="input font-mono text-sm" placeholder="0x…" autoComplete="off" spellCheck={false} maxLength={42} required />
          </label>
        ) : null}
      </div>
      <label className="field w-32">🍳 Days to raise<input name="days" className="input" inputMode="numeric" defaultValue="7" required /></label>
      <div className="grid gap-4 sm:grid-cols-2">
        <label className="field">🧀 You keep, % of the raise<input name="keep" className="input" inputMode="numeric" defaultValue="10" required /></label>
        <label className="field">🧈 But no more than, {raiseIn === 'other' ? 'tokens' : raiseIn}<input name="cap" className="input" inputMode="decimal" defaultValue="10" required /></label>
        <label className="field">🥬 Your tokens, % of supply<input name="share" className="input" inputMode="numeric" defaultValue="10" required /></label>
        <label className="field">🥒 Unlocking over
          <select name="vesting" className="input select-caret" defaultValue="52">
            {UNLOCK_OPTIONS}
          </select>
        </label>
        <label className="field">🫒 Airdrop, % of supply<input name="airdrop" className="input" inputMode="numeric" defaultValue="0" /></label>
        <label className="field">🫑 Unlocking over
          <select name="airdropVesting" className="input select-caret" defaultValue="0">
            {UNLOCK_OPTIONS}
          </select>
        </label>
      </div>
      <label className="field">🥜 Airdrop list<input name="list" type="file" accept=".csv,.txt,text/csv,text/plain"
        className="block w-fit max-w-full cursor-pointer rounded-xl border border-dashed border-line p-3 text-sm font-normal text-muted file:mr-3 file:cursor-pointer file:rounded-lg file:border file:border-solid file:border-line file:bg-card file:px-3 file:py-1.5 file:font-semibold file:text-ink hover:border-ink" /></label>
      <p className="-mt-2 text-sm text-muted">One address,amount per line.</p>
      <label className="field">🥑 Pay your share to
        <input key={address} name="payout" className="input font-mono text-sm" defaultValue={address ?? ''} placeholder="0x…" autoComplete="off" spellCheck={false} maxLength={42} required />
      </label>
      <div className="rounded-xl border border-line/60 p-3">
        <label className="field">🍽️ Preview: if it raises, {moneySymbol}
          <input className="input" inputMode="decimal" placeholder="10" value={hypothetical} onChange={event => setHypothetical(event.target.value)} />
        </label>
        <p className="mt-2 text-sm text-muted" aria-live="polite">
          {preview === null ? 'Enter an amount to see the market cap the token would start at.' : `The token would start at a market cap of ${formatEth(preview.circulating, moneyDecimals)} ${moneySymbol}${preview.diluted === preview.circulating ? '' : `, or ${formatEth(preview.diluted, moneyDecimals)} ${moneySymbol} fully diluted`}.`}
        </p>
      </div>
      <p className="text-sm text-muted">🔒 Nothing can be changed after.</p>
      <TxError error={error} />
      <button type="submit" className="btn-primary min-h-[48px] px-5 text-lg" disabled={busy}>{busy ? 'Saving…' : 'Start cooking'}</button>
    </form>
  )
}


/** A create in progress, kept in this browser: a lunch's chains only pair if every one gets these exact terms, so a
 * reload between chains must not make new ones. */
const ATTEMPT_KEY = 'fair-lunch:create:v1'
type Attempt = { terms: LunchTerms; made: Record<number, Hex | null>; hostPath: string | null }
function saveAttempt(attempt: Attempt | null) {
  try {
    if (!attempt) return localStorage.removeItem(ATTEMPT_KEY)
    localStorage.setItem(ATTEMPT_KEY, JSON.stringify(attempt, (_, value) => (typeof value === 'bigint' ? value.toString() : value)))
  } catch { /* private window: the create still works in this tab */ }
}
function loadAttempt(): Attempt | null {
  try {
    const attempt = JSON.parse(localStorage.getItem(ATTEMPT_KEY) ?? 'null') as Attempt | null
    return attempt ? { ...attempt, terms: { ...attempt.terms, sender: attempt.terms.sender ?? attempt.terms.creator, keepCapWei: BigInt(attempt.terms.keepCapWei) } } : null
  } catch { return null }
}
