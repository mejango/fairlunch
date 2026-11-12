'use client'

import { useQueryClient } from '@tanstack/react-query'
import { useRouter } from 'next/navigation'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import type { Address, Hex } from 'viem'
import { TxConfirmDialog, type TxConfirmRow } from '@/components/ui/TxConfirmDialog'
import { TxError } from '@/components/ui/TxError'
import { confirmAction, sendingStatus, stepsIntro, ViewTransactionLink } from '@/components/ui/TxProgress'
import { useSafeTx, type TxRequest } from '@/hooks/useSafeTx'
import { useWallet } from '@/hooks/useWallet'
import { chainName } from '@/lib/urn'
import { getViewAs, VIEW_AS_WRITE_BLOCKED } from '@/lib/viewAs'

type Review = { account: Address; plan: TxRequest | null; rows: readonly TxConfirmRow[]; error: string | null }

/**
 * One button for one wallet write, the same for every action on the site: press, the call is prepared against the
 * chain as it is now, the review shows what it does, the wallet confirms, and the page's reads refresh.
 * `prepare` throws a sentence to refuse (nothing to pay, say).
 */
export function TxAction({ chainId, label, title, doneTitle, prepare, onDone, disabled, className = 'btn-primary min-h-[44px] px-5' }: {
  chainId: number
  label: ReactNode
  title: string
  doneTitle: string
  /** The call and what the review says about it, built for the connected account. */
  prepare: (account: Address) => Promise<{ request: TxRequest; rows: readonly TxConfirmRow[] }>
  /** Called once with the confirmed transaction's hash. */
  onDone?: (hash: Hex | null) => void
  disabled?: boolean
  className?: string
}) {
  const { address, isConnected, openSignIn } = useWallet()
  const tx = useSafeTx(chainId)
  const client = useQueryClient()
  const router = useRouter()
  const [review, setReview] = useState<Review | null>(null)
  const attempt = useRef(0)
  const current = review && review.account === address ? review : null
  const sending = tx.busy || tx.phase === 'review'
  const complete = tx.phase === 'success'
  const done = useRef(onDone)
  done.current = onDone

  useEffect(() => {
    if (!complete) return
    void client.invalidateQueries()
    // What the server read for this page (the burn marks) is as stale as the client's reads.
    router.refresh()
    done.current?.(tx.hash)
    // eslint-disable-next-line react-hooks/exhaustive-deps -- once per confirmation, with the hash it confirmed
  }, [complete, client])

  async function start() {
    if (!isConnected || !address) return void openSignIn()
    const account = address
    if (getViewAs()) return setReview({ account, plan: null, rows: [], error: VIEW_AS_WRITE_BLOCKED })
    const mine = ++attempt.current
    tx.reset()
    setReview({ account, plan: null, rows: [], error: null })
    try {
      const { request, rows } = await prepare(account)
      if (attempt.current === mine) setReview({ account, plan: request, rows: [...rows, { label: 'On', value: chainName(chainId) }], error: null })
    } catch (reason) {
      if (attempt.current === mine) setReview({ account, plan: null, rows: [], error: reason instanceof Error ? reason.message : 'Something went wrong. Try again.' })
    }
  }

  function close() {
    attempt.current += 1
    setReview(null)
    if (!complete) tx.dismiss()
  }

  const open = current && !current.error
  return (
    <>
      <button type="button" className={className} disabled={disabled || sending || !!(open && !current.plan)} onClick={() => void start()}>
        {label}
      </button>
      <TxError error={current?.error} />
      {open ? (
        <TxConfirmDialog
          open
          preparing={!current.plan}
          onClose={close}
          title={complete ? doneTitle : title}
          rows={current.plan ? current.rows : undefined}
          steps={[{ title }]}
          activeIndex={0}
          stepsIntro={stepsIntro(1, complete ? 1 : 0)}
          complete={complete}
          settled={tx.phase === 'submitted'}
          busy={sending}
          action={confirmAction(tx.phase, tx.phase === 'error' ? 'Retry' : 'Confirm')}
          onConfirm={() => { if (current.plan && !sending) void tx.send(current.plan, { reviewedAccount: current.account }) }}
          status={complete ? <ViewTransactionLink chainId={chainId} hash={tx.hash} /> : !current.plan ? 'Getting it ready…' : (sendingStatus(tx) ?? undefined)}
          error={tx.error}
        />
      ) : null}
    </>
  )
}
