'use client'

import { useEffect, useRef, useState } from 'react'
import { createConnectController, type ConnectOption } from '@bananapus/nana-sdk-connect/core'
import { JBConnectModal } from '@bananapus/nana-sdk-connect/react'
import { WalletFallbackMark } from '@/components/BrandMarks'
import { ViewAsForm } from '@/components/ViewAsForm'
import { useWallet } from '@/hooks/useWallet'
import { useMobileWallet } from '@/hooks/useMobileWallet'
import { useViewAs } from '@/lib/viewAs'
import { mobileWalletLinks } from '@/lib/walletLinks'

/** A wallet tile shows only an inline image: a remote icon URL would tell its host that this page was opened. */
const safeIcon = (icon: string | undefined) =>
  icon && /^data:image\/(?:png|svg\+xml|webp|jpeg|gif)[;,]/i.test(icon) ? icon : undefined

/** The way to look without signing in: an address to view the site as. */
function ViewAsAddress({ onDone }: { onDone: () => void }) {
  const { viewAs } = useViewAs()
  const [open, setOpen] = useState(false)
  return (
    <div className="mt-4 text-[13px]">
      {open ? (
        <ViewAsForm onDone={onDone} />
      ) : (
        <button type="button" className="btn-link" onClick={() => setOpen(true)}>
          {viewAs ? 'View as another account' : 'View as an address'}
        </button>
      )}
    </div>
  )
}

/** The user's own wallets through the shared wagmi stack, in the SDK's connect dialog. */
export function ExternalWalletDialog({ onClose }: { onClose: () => void }) {
  const { connectors, connectWith, isConnected } = useWallet()
  const mobileWallet = useMobileWallet()
  const [opener] = useState(() => typeof document !== 'undefined' && document.activeElement instanceof HTMLElement
    ? document.activeElement : null)
  useEffect(() => () => { if (opener?.isConnected) opener.focus({ preventScroll: true }) }, [opener])
  const latest = useRef({ connectWith, onClose })
  latest.current = { connectWith, onClose }
  useEffect(() => { if (isConnected) onClose() }, [isConnected, onClose])
  // Dialogs replace each other: a dialog the chooser opens over, like a flow's confirm asking for an external wallet,
  // paints nothing until the chooser closes (`[data-covered]` in globals.css, as ModalDialog does).
  useEffect(() => {
    const covered = [...document.querySelectorAll('dialog[open]:not([data-covered])')].filter(
      dialog => !dialog.classList.contains('lunch-connect'),
    )
    covered.forEach(dialog => dialog.setAttribute('data-covered', ''))
    return () => covered.forEach(dialog => dialog.removeAttribute('data-covered'))
  }, [])
  const [controller] = useState(() => {
    const framed = typeof window !== 'undefined' && window.self !== window.top
    const options: ConnectOption[] = []
    for (const connector of connectors) {
      if (connector.id === 'safe' && !framed) continue
      options.push({
        id: connector.id, name: connector.name, icon: safeIcon(connector.icon),
        async connect({ signal, handoff }) {
          const onMessage = ({ type, data }: { type: string; data?: unknown }) => {
            if (type === 'display_uri' && typeof data === 'string') handoff(data)
          }
          connector.emitter.on('message', onMessage)
          signal.addEventListener('abort', () => connector.emitter.off('message', onMessage))
          try { await latest.current.connectWith(connector.id) } finally { connector.emitter.off('message', onMessage) }
          latest.current.onClose()
        },
      })
    }
    return createConnectController(options)
  })

  return (
    <JBConnectModal open controller={controller} onClose={onClose} className="lunch-connect" title="Connect"
      renderIcon={option => <WalletFallbackMark id={option.id} className="h-5 w-5" />}
      renderHandoff={uri => <PairingCode uri={uri} />}>
      {mobileWallet === 'handoff' ? (
        <div className="mt-5">
          <p className="text-sm text-muted">Or open Fair Lunch in your wallet app.</p>
          <div className="mt-2 flex flex-wrap gap-2">
            {mobileWalletLinks(window.location.href).map(wallet => (
              <a key={wallet.name} href={wallet.url} className="btn-secondary px-3 py-2 text-sm">{wallet.name}</a>
            ))}
          </div>
        </div>
      ) : null}
      <ViewAsAddress onDone={onClose} />
    </JBConnectModal>
  )
}

function PairingCode({ uri }: { uri: string }) {
  const [image, setImage] = useState<string | null>(null)
  useEffect(() => {
    let live = true
    void import('qrcode')
      .then(qr => qr.toDataURL(uri, { margin: 1, width: 320, errorCorrectionLevel: 'M' }))
      .then(url => { if (live) setImage(url) })
      .catch(() => { /* The pairing link still works if QR rendering fails. */ })
    return () => { live = false }
  }, [uri])
  return (
    <div className="rounded-lg border border-line bg-card p-3 text-center">
      <p className="text-sm">Scan with your wallet app, or open it on this device.</p>
      {image ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={image} alt="WalletConnect pairing QR code" className="mx-auto my-3 w-full max-w-64" />
      ) : null}
      <a href={uri} className="text-sm underline">Open wallet</a>
    </div>
  )
}
