'use client'

import { JBCenterClient } from '@bananapus/nana-sdk-core/jbcenter'
import { useRouter } from 'next/navigation'
import { useQuery } from '@tanstack/react-query'
import { useEffect, useState, type FormEvent } from 'react'
import { getAddress, isAddress, isAddressEqual, parseEther, parseEventLogs, toHex, zeroAddress, type Hex } from 'viem'
import { TxAction } from '@/components/TxAction'
import { TxError } from '@/components/ui/TxError'
import { useWallet } from '@/hooks/useWallet'
import { environmentForChainIds, PRODUCTION_CHAINS, TESTNET_CHAINS } from '@/lib/chains'
import { fairLunchAbi } from '@/lib/fair-lunch/abi'
import { deploymentOn } from '@/lib/fair-lunch/deployments'
import { createTx, madeOn, type LunchTerms } from '@/lib/fair-lunch/writes'
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
  const [busy, setBusy] = useState(false)
  const [hostId, setHostId] = useState<number>(CHAINS[0]?.id ?? 0)
  const [made, setMade] = useState<Record<number, Hex | null>>({})
  const [hostPath, setHostPath] = useState<string | null>(null)

  // Pick an unfinished create back up, and keep it as it moves.
  const [restored, setRestored] = useState(false)
  useEffect(() => {
    const attempt = loadAttempt()
    if (attempt) { setTerms(attempt.terms); setMade(attempt.made); setHostPath(attempt.hostPath) }
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

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!isConnected || !address) return void openSignIn()
    const form = new FormData(event.currentTarget)
    const text = (name: string) => String(form.get(name) ?? '').trim()
    const days = whole(text('days'), 1, 365), keep = whole(text('keep'), 0, 50), share = whole(text('share'), 0, 50)
    let cap: bigint
    try { cap = parseEther(text('cap') || '0') } catch { return setError('Enter the most ETH to keep as a number.') }
    if (!text('name') || !text('symbol')) return setError('Give it a name and a ticker.')
    if (days === null) return setError('Raise for 1 to 365 days.')
    if (keep === null || share === null) return setError('Keep 0 to 50 percent.')
    // Strict: all lowercase or a right checksum, so a mistyped address is caught here, not paid.
    const payout = text('payout')
    if (!isAddress(payout) || isAddressEqual(payout, zeroAddress)) return setError('Enter the address to pay as 0x and 40 characters.')
    setError(null)
    setBusy(true)
    try {
      const center = new JBCenterClient({ baseUrl: jbCenterBaseUrl() })
      const logo = form.get('logo')
      const logoUri = logo instanceof File && logo.size ? (await center.pinImage(logo, { filename: logo.name })).uri : undefined
      const { uri } = await center.pinJson({ name: text('name'), ...(logoUri ? { logoUri } : {}) })
      setTerms({
        name: text('name'), symbol: text('symbol').toUpperCase(), projectUri: uri,
        hostChainId: hostId, otherChainIds: others.filter(chain => form.get(`also-${chain.id}`)).map(chain => chain.id),
        deadline: Math.floor(Date.now() / 1000) + days * 86_400, sender: address, creator: getAddress(payout),
        keepPercent: keep, keepCapWei: cap, tokenPercent: share, vestingSeconds: Number(text('vesting')) * WEEK,
        salt: toHex(crypto.getRandomValues(new Uint8Array(32))),
      })
    } catch {
      setError('The logo or name couldn’t be saved. Try again.')
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
                      { label: 'You keep', value: `${terms.keepPercent}% of the raise, up to ${text18(terms.keepCapWei)} ETH, before the 2.5% fee` },
                      { label: 'Your tokens', value: `${terms.tokenPercent}% over ${terms.vestingSeconds / WEEK} weeks` },
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
    <form onSubmit={event => void submit(event)} className="card mx-auto max-w-xl space-y-4 p-5">
      <h1 className="text-2xl font-bold">🛒 Ingredients</h1>
      <ul className="list-disc space-y-1 pl-5 text-sm text-muted">
        <li>Sell a new token at a fixed price until the deadline. No refunds.</li>
        <li>You get your share of the raise, the rest is locked in a liquidity pool.</li>
        <li>Tokens go to funders, to the pool to match the money it gets, and some to you.</li>
        <li>Later payments on any chain buy the token on the main chain and burn it.</li>
      </ul>
      <div className="grid gap-4 sm:grid-cols-2">
        <label className="field">🍞 Name<input name="name" className="input" maxLength={32} required placeholder="Sandwich" /></label>
        <label className="field">🥓 Ticker<input name="symbol" className="input uppercase" maxLength={10} required placeholder="SAND" /></label>
      </div>
      <label className="field">🍅 Logo<input name="logo" type="file" accept="image/png,image/jpeg,image/webp,image/gif"
        className="block w-full cursor-pointer rounded-xl border border-dashed border-line p-3 text-sm font-normal text-muted file:mr-3 file:cursor-pointer file:rounded-lg file:border file:border-solid file:border-line file:bg-card file:px-3 file:py-1.5 file:font-semibold file:text-ink hover:border-ink" /></label>
      <div className="grid gap-4 sm:grid-cols-2">
        <label className="field">🧅 Chain
          <select name="host" className="input select-caret" value={hostId} onChange={event => setHostId(Number(event.target.value))}>
            {CHAINS.map(chain => <option key={chain.id} value={chain.id}>{chainName(chain.id)}</option>)}
          </select>
        </label>
        <label className="field">🍳 Days to raise<input name="days" className="input" inputMode="numeric" defaultValue="7" required /></label>
      </div>
      {others.length ? (
        <fieldset className="text-sm">
          <legend className="font-semibold">🥗 Also accept payments and bridge from</legend>
          <div className="mt-1 flex flex-wrap gap-x-4 gap-y-2">
            {others.map(chain => <label key={chain.id} className="flex min-h-[44px] items-center gap-2"><input type="checkbox" name={`also-${chain.id}`} /> {chainName(chain.id)}</label>)}
          </div>
        </fieldset>
      ) : null}
      <div className="grid gap-4 sm:grid-cols-2">
        <label className="field">🧀 You keep, % of the raise<input name="keep" className="input" inputMode="numeric" defaultValue="10" required /></label>
        <label className="field">🧈 But no more than, ETH<input name="cap" className="input" inputMode="decimal" defaultValue="10" required /></label>
        <label className="field">🥬 Your tokens, % of supply<input name="share" className="input" inputMode="numeric" defaultValue="10" required /></label>
        <label className="field">🥒 Unlocking over
          <select name="vesting" className="input select-caret" defaultValue="52">
            {VESTING_WEEKS.map(weeks => <option key={weeks} value={weeks}>{weeks >= 52 ? `${weeks / 52} ${weeks === 52 ? 'year' : 'years'}` : '6 months'}</option>)}
          </select>
        </label>
      </div>
      <label className="field">🥑 Pay your share to
        <input key={address} name="payout" className="input font-mono text-sm" defaultValue={address ?? ''} placeholder="0x…" autoComplete="off" spellCheck={false} maxLength={42} required />
      </label>
      <p className="text-sm text-muted">🔒 Nothing can be changed after.</p>
      <TxError error={error} />
      <button type="submit" className="btn-primary min-h-[48px] px-5 text-lg" disabled={busy}>{busy ? 'Saving…' : 'Start cooking'}</button>
    </form>
  )
}

const text18 = (wei: bigint) => (Number(wei) / 1e18).toString()

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
