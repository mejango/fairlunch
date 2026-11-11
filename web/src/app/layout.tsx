import type { Metadata } from 'next'
import type { ReactNode } from 'react'
import './globals.css'
import { SiteHeader } from '@/components/SiteHeader'
import { jbCenterAppOrigin } from '@/lib/jbcenter-config'
import { Providers } from '@/providers/Providers'

const description = 'Raise ETH, launch a token, lock the liquidity. It runs itself after that.'

export const metadata: Metadata = {
  metadataBase: new URL(jbCenterAppOrigin()),
  title: 'Fair Lunch',
  description,
  openGraph: { type: 'website', title: 'Fair Lunch', description },
}

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <SiteHeader />
          <main className="mx-auto w-full max-w-5xl px-4 pb-16">{children}</main>
        </Providers>
      </body>
    </html>
  )
}
