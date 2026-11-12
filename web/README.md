# Fair Lunch web

The site for [Fair Lunch](../README.md): make a lunch, pay into one while it cooks, and trade it once it's served.

- `/` lists lunches. `/create` makes one. `/<chain>:<projectId>` is a lunch's page: phase, time left, the Pay card that becomes a Swap card, the pool's price chart, what was raised, and the lunch's other chains with their Send home and Bring in buttons.
- Wallets are the user's own: MetaMask, Coinbase Wallet, WalletConnect, Safe.
- Chain reads go through JB Center. The lunch list, logos and burn marks come from Bendystraw on the server.
- Sending, reviewing and Safe handling come from `@bananapus/nana-sdk-core`. The connect dialog comes from `@bananapus/nana-sdk-connect`.

## Run

Node 26, npm 12.

```bash
npm ci
npm run dev        # http://127.0.0.1:8790
npm run check      # audit, lint, types, tests, build
```

Environment names are in `.env.example`.

## After a contract change

```bash
node scripts/sync-abi.mjs     # rewrites src/lib/fair-lunch/abi.ts from ../artifacts
```

After a deployment, add each chain's address to `src/lib/fair-lunch/deployments.json` as `{ "<chainId>": { "address": "0x…" } }`.

## Against a local fork

`../script/Rehearse.s.sol` deploys Fair Lunch and two lunches to an anvil fork of Base. Point the site at it with `NEXT_PUBLIC_FAIR_LUNCH_ADDRESS` and a `NEXT_PUBLIC_JBCENTER_URL` that serves the fork's RPC. `scripts/shots.mjs` screenshots pages at desktop and phone widths, and `scripts/sell-check.mjs` sells on the fork with the same swap builders the site uses. Bendystraw doesn't index a fork, so the list and burn marks stay empty there.

For a lunch with a copy on another chain, fork that chain too, run `Rehearse.deployOnly()` on it from the same sender (Fair Lunch lands at the same address), and serve each chain's RPC at `<NEXT_PUBLIC_JBCENTER_URL>/v1/rpc/<chainId>`. `scripts/copy-check.mjs` then makes a two-chain lunch, pays its copy and sends that home. A fork can't deliver the bridge's message, so bringing the ETH in on the host is not covered.

## Not built yet

- A lunch on several chains is one `createFor` per chain, sent one after another, not one bundle.
- The chart has no volume bars. Swap volume needs an index: public RPCs cap log scans far below a day of blocks, and Bendystraw only records swaps for registered buyback pools.
- No production domain is chosen, so every page is marked `noindex` in `next.config.js`.
