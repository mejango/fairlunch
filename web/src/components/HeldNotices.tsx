'use client'

import { HeldNotice } from '@/components/HeldNotice'
import { useWallet } from '@/hooks/useWallet'

/** The connected account's writes that need them, on every chain. */
export function HeldNotices() {
  const { address } = useWallet()
  return address ? <div className="mx-auto w-full max-w-5xl px-4"><HeldNotice account={address} /></div> : null
}
