/** @type {import('next').NextConfig} */
const { PHASE_DEVELOPMENT_SERVER } = require('next/constants')

// The app may be framed only by Safe.
const securityHeaders = [
  {
    key: 'Content-Security-Policy',
    value: 'frame-ancestors https://app.safe.global https://app.5afe.dev',
  },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  {
    key: 'Permissions-Policy',
    value: 'camera=(), microphone=(), geolocation=()',
  },
]

module.exports = phase => {
  return {
    // Emit a self-contained server tree for the production OCI image. Keep
    // tracing rooted here because the repository root also has a lockfile.
    output: 'standalone',
    outputFileTracingRoot: __dirname,
    // The git SHA is set at build and run time by the Dockerfile. Next appends it
    // to asset URLs and navigation requests, and hard-navigates a tab whose
    // deployment differs from the server's instead of failing on stale chunks.
    deploymentId: process.env.NEXT_PUBLIC_VERSION,
    // Keep development and production artifacts separate. Running `next build`
    // while the dev server is active otherwise leaves their webpack chunks
    // mixed together and causes intermittent MODULE_NOT_FOUND errors.
    distDir:
      process.env.NEXT_DIST_DIR ||
      (phase === PHASE_DEVELOPMENT_SERVER ? '.next-dev' : '.next'),
    reactStrictMode: true,
    poweredByHeader: false,
    experimental: {
      // Preserve the SDK's ergonomic barrels while compiling client routes from
      // the narrow v6 modules they actually use.
      optimizePackageImports: ['@bananapus/nana-sdk-core'],
    },
    images: {
      // Project media is content-addressed (IPFS), so optimized variants can be
      // cached aggressively. Bundled artwork uses hashed static imports and is
      // served immutable independently of this TTL.
      minimumCacheTTL: 60 * 60 * 24 * 365,
      remotePatterns: [
        { protocol: 'https', hostname: 'juicebox.center', pathname: '/ipfs/**' },
      ],
    },
    async headers() {
      return [
        { source: '/:path*', headers: securityHeaders },
        // ponytail: the hosted site is testnet only, so nothing is listed. Drop this when it serves mainnets.
        { source: '/:path*', headers: [{ key: 'X-Robots-Tag', value: 'noindex' }] },
      ]
    },
  }
}
