import { notFound } from 'next/navigation'
import { LunchView } from '@/components/LunchView'
import { burnsOf, logoOf } from '@/lib/fair-lunch/indexed'
import { parseUrn } from '@/lib/urn'

export default async function LunchPage({ params }: { params: Promise<{ urn: string }> }) {
  const lunch = parseUrn((await params).urn)
  if (!lunch) notFound()
  // The index adds the logo and the burn marks. The page works without it.
  const [burns, logoUri] = await Promise.all([
    burnsOf(lunch.chainId, lunch.projectId).catch(() => []),
    logoOf(lunch.chainId, lunch.projectId).catch(() => null),
  ])
  return <LunchView chainId={lunch.chainId} projectId={lunch.projectId} burns={burns} logoUri={logoUri} />
}
