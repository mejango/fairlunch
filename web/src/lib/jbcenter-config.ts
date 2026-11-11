import { JBCENTER_DEFAULT_URL } from '@bananapus/nana-sdk-core/jbcenter'

/** The JB Center this deployment talks to. A deployment can supply its own. */
export function jbCenterBaseUrl(): string {
  return process.env.NEXT_PUBLIC_JBCENTER_URL?.trim() || JBCENTER_DEFAULT_URL
}

/** Browser requests use the browser's real Origin header. Server requests must
 * identify this deployment too; JB Center must explicitly allow this origin. */
export function jbCenterAppOrigin(siteUrl = process.env.NEXT_PUBLIC_SITE_URL): string {
  return new URL(siteUrl || 'http://localhost:8790').origin
}
