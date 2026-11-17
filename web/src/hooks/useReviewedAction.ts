'use client'

import { useEffect, useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { encodeFunctionData, type Abi, type Address, type Hex } from 'viem'
import {
  HELD_CONFIRMING_LINE,
  REVIEW_STOPPED_LINE,
  REVIEWED_ACCOUNT_CHANGED_LINE,
  ReviewLineError,
  WRITE_HOLD_UNCHECKED_LINE,
  type ReviewedCall,
  type ReviewedRunStatus,
} from '@bananapus/nana-sdk-core/review'
import { useReviewedRun } from '@bananapus/nana-sdk-core/review/react'
import { useWallet } from '@/hooks/useWallet'
import { holdIntent } from '@/lib/hold-intent'
import { loadReviewEngine } from '@/lib/review-engine'
import { isSafeConnection, SAFE_NONCE_GUIDANCE } from '@/lib/safe-connector'
import { getViewAs, VIEW_AS_WRITE_BLOCKED } from '@/lib/viewAs'
import { reviewedSendDeps } from '@/lib/wallet-core'
import { exitWarning, holds } from '@/lib/write-holds'
import { wagmiConfig } from '@/providers/Providers'

/** A run whose button left the page before the wallet's prompt: nothing is sent. */
const REVIEW_CLOSED_LINE = 'This review closed. Open the action again before sending.'

export type TxPhase =
  | 'idle'
  | 'review'
  | 'simulating'
  | 'signing'
  | 'pending'
  /** With a Safe, or held: the hold's own line says where it is. */
  | 'submitted'
  | 'success'
  | 'error'

/** The site's display phase for the SDK's run status: a held or proposed write shows its hold, and an exit that could
 * not be checked, or a review the account change withdrew, shows as an error. */
function txPhaseOf(status: ReviewedRunStatus, exitFailed: boolean): TxPhase {
  if (status === 'done') return 'success'
  if (status === 'proposed' || status === 'held') return 'submitted'
  if (status === 'receipt') return 'pending'
  if (status === 'review' || status === 'simulating' || status === 'signing') return status
  return status === 'failed' || status === 'stopped' || exitFailed ? 'error' : 'idle'
}

/** A contract write, as the builders in `fair-lunch/writes.ts` return it. */
export type TxRequest = {
  chainId: number
  address: `0x${string}`
  abi: Abi
  functionName: string
  args: readonly unknown[]
  value?: bigint
  label?: string
}

/**
 * The shared in-flight button copy: the fixed simulating/signing strings every
 * flow uses, the caller's `pending` progress text, and its `idle` label
 * (any non-in-flight phase falls through to `idle`). `confirm` overrides the
 * signing string for flows with more specific wallet copy.
 */
export function txPhaseLabel(
  phase: TxPhase,
  labels: { idle: string; pending: string; confirm?: string },
): string {
  if (phase === 'simulating') return 'Double-checking the transaction…'
  if (phase === 'signing') return labels.confirm ?? 'Confirm in your wallet…'
  if (phase === 'pending') return labels.pending
  return labels.idle
}

/** The reviewed call of a contract write request: its exact bytes, decoded for the review, under its hold key. */
function reviewedCall(request: TxRequest, account: Address): ReviewedCall {
  const intent = holdIntent(request, account)
  return {
    chainId: request.chainId,
    to: request.address,
    data: encodeFunctionData({ abi: request.abi, functionName: request.functionName, args: request.args as unknown[] }),
    value: request.value ?? 0n,
    abi: request.abi,
    functionName: request.functionName,
    args: request.args,
    ...(request.label ? { label: request.label } : {}),
    ...(intent ? { intent } : {}),
  }
}

/**
 * The site's one reviewed send, over the SDK's useReviewedRun: this site's wallet, chains, write hold and guard, with
 * the run's progress as the phases the confirm shows. The SDK reviews, simulates, holds, sends and follows the write
 * (a Safe's queued proposal of the same call is adopted, never proposed twice); this hook only maps its state for
 * display.
 */
export function useReviewedAction() {
  const queryClient = useQueryClient()
  const { address } = useWallet()
  /** The transaction the wallet returned for this run, until the run's own hash is known. */
  const [submitted, setSubmitted] = useState<Hex | null>(null)
  /** The user's exit could not be checked: the hold keeps the write. Or the account changed while the review was open. */
  const [exitError, setExitError] = useState<string | null>(null)
  const inFlight = useRef(false)
  /** Counts account changes: a run reviewed before one sends nothing after it, even once the account is back. */
  const accountEpoch = useRef(0)
  /** Ends the open run's review when the account changes: its call was built for the account before. */
  const aborts = useRef(new Set<AbortController>())
  useEffect(() => {
    accountEpoch.current += 1
    for (const abort of aborts.current) abort.abort()
  }, [address])
  /** Whether the button that runs the action is still on the page. */
  const open = useRef(true)
  useEffect(() => {
    open.current = true
    return () => { open.current = false }
  }, [])
  const runner = useReviewedRun({
    account: address,
    ...reviewedSendDeps,
    engine: loadReviewEngine,
    // A held write the person's dismiss closed confirmed later: the page's reads refresh.
    onDismissedSettled: () => void queryClient.invalidateQueries(),
    guard: () => {
      if (getViewAs()) throw new ReviewLineError(VIEW_AS_WRITE_BLOCKED)
    },
  })

  /** Reviews and sends `request` as `account`, the one it was built for: refused, before its review, unless connected. */
  const run = async (request: TxRequest, account: Address): Promise<void> => {
    if (inFlight.current) return
    inFlight.current = true
    setSubmitted(null)
    setExitError(null)
    const viaSafe = isSafeConnection(wagmiConfig)
    const epoch = accountEpoch.current
    const abort = new AbortController()
    aborts.current.add(abort)
    try {
      const description = [holds.reviewLine(), viaSafe ? SAFE_NONCE_GUIDANCE : null].filter(Boolean).join('\n\n')
      const ran = await runner.run({
        account,
        calls: [reviewedCall(request, account)],
        signal: abort.signal,
        ...(request.label ? { title: request.label } : {}),
        ...(description ? { description } : {}),
        ...(viaSafe ? { confirmLabel: 'Agree & continue to Safe' } : {}),
        // The SDK's last check before the wallet's prompt, after every await; review-engine.ts runs it again as the
        // request reaches the wallet.
        assertWriteState: () => {
          if (!open.current) throw new ReviewLineError(REVIEW_CLOSED_LINE)
          if (accountEpoch.current !== epoch) throw new ReviewLineError(REVIEWED_ACCOUNT_CHANGED_LINE)
        },
        onSubmitted: (_call, _step, hash, how) => { if (!how.safe) setSubmitted(hash) },
      })
      // A receipt still verifying is sent and pending until its hold ends the run; the hook shows how it ends.
      if (ran?.status === 'receipt') await ran.ended()
      // The account changed while the review was open: the SDK withdrew it, and the action says why.
      else if (!ran && abort.signal.aborted) setExitError(REVIEWED_ACCOUNT_CHANGED_LINE)
    } catch (reason) {
      // A request that cannot be encoded: nothing was reviewed or sent.
      setExitError(reason instanceof Error ? reason.message : 'Something went wrong.')
    } finally {
      aborts.current.delete(abort)
      inFlight.current = false
    }
  }

  const { held: shown } = runner
  /** Whether the held write is a Safe's proposal. */
  const heldSafe = !!shown?.state && shown.state.status !== 'clear' && shown.state.record.safe
  const phase = txPhaseOf(runner.status, !!exitError)

  /** Closes the confirm; nothing while the review or wallet is open. The SDK follows a hold it showed, detached. */
  function reset() {
    if (!runner.dismiss()) return
    setSubmitted(null)
    setExitError(null)
  }
  const runExit = () => {
    setExitError(null)
    void runner.exitAction?.run().then(released => { if (released) runner.reset() }).catch(() => setExitError(WRITE_HOLD_UNCHECKED_LINE))
  }
  const held = !shown
    ? null
    : runner.exitAction
      ? { line: shown.line ?? '', warning: exitWarning(shown) ?? '', label: runner.exitAction.label, notice: shown.notice, exit: runExit }
      : runner.sendAgainAction
        ? { line: shown.line ?? '', warning: '', label: runner.sendAgainAction.label, notice: shown.notice, exit: () => { void runner.sendAgainAction?.run().then(reset) } }
        // A direct write the wallet has held a while: the SDK's pending line, no exit.
        : shown.phase === 'confirming' && !heldSafe && shown.line && shown.line !== HELD_CONFIRMING_LINE
          ? { line: shown.line, warning: '', label: '', notice: shown.notice, exit: null }
          : null

  return {
    run,
    phase,
    /** True while the run is in flight: in review, simulating, signing or confirming in place; not while it only follows a hold. */
    busy: runner.busy,
    /** The one line a `submitted` confirm shows: the hold's. */
    notice: phase === 'submitted' ? shown?.line ?? null : null,
    /** A held write: its line, what sending again risks, and the user's exit (or its send-again). */
    held,
    /** The SDK's in-tab notice, whenever the hold carries one. */
    holdNotice: shown?.notice ?? null,
    error: exitError ?? (phase === 'error' ? runner.error ?? (runner.status === 'stopped' ? REVIEW_STOPPED_LINE : null) : null),
    /** The transaction that carried the write, once the wallet or the hold names it. */
    hash: runner.hash ?? submitted,
    safeNonceGuidance: phase === 'submitted' && runner.safeTxHash ? SAFE_NONCE_GUIDANCE : null,
    reset,
    /** Close the current confirmation. The hold keeps the write; dismissing is never evidence that it can be sent again. */
    dismiss: reset,
  }
}

export type ReviewedActionState = ReturnType<typeof useReviewedAction>
