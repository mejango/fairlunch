import Link from 'next/link'
import { HeldNotices } from '@/components/HeldNotices'
import { WalletButton } from '@/components/WalletButton'

export function SiteHeader() {
  return (
    <>
      <header className="mx-auto flex w-full max-w-5xl items-center justify-between gap-3 px-4 py-4">
        <Link href="/" className="text-xl font-bold">🥪 Fair Lunch</Link>
        <WalletButton />
      </header>
      <HeldNotices />
    </>
  )
}
