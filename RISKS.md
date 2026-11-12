# Risks

What Fair Lunch trusts, what can go wrong, and what was chosen on purpose.

## Trust

- **Juicebox V6 core, the omnichain deployer, suckers and the JB Uniswap V4 hook.** A lunch is a Juicebox project owned by `FairLunch`. A bug in any of these is a bug here.
- **The Juicebox buyback hook.** Once a lunch is served, its payments and cash outs trade through the buyback hook the registry gave its project when it was created, and that hook can mint the lunch's token. A lunch keeps that hook for good. Whoever owns the registry chooses the hook later lunches get.
- **Uniswap V4 and Permit2.** The liquidity lives in a V4 position held by `FairLunch`.
- **The bridge behind each sucker.** ETH sent home is only as safe as that bridge.
- **The deployer, once.** Whoever deploys `FairLunch` sets its Uniswap V4 addresses a single time. Wrong addresses there break or drain every lunch on that chain, and they can't be changed. The deploy rehearsal test pins the expected values.

Nobody can change a lunch after it's created, including its creator.

## By design

- **No refunds and no cash outs.** Money paid in stays in. Before `serve`, tokens can't be redeemed. After, the only exit is selling into the pool.
- **Liquidity is locked forever.** There is no function that removes it.
- **The creator's ETH is paid at `serve` in full.** Only their tokens vest.
- **Anyone can create the pool first.** If the pool exists at another price when `serve` runs, `serve` swaps it toward the raise price with at most half of either side, before adding liquidity. It stops 110 ticks (1.1%) short of the raise price, so a pool started off-price opens 1.1% beside it. The pool's 1% fee on those swaps goes to whoever put liquidity there, and stopping short keeps that fee from buying their tokens back for more than the raise charged, or selling them tokens for less. If the price can't be reached, the pool opens where it ended up. The leftover is burned (tokens) or kept in the project for buybacks (ETH).
- **A lunch's terms are part of its addresses.** Copies of a lunch on other chains bridge to each other only if the caller, salt, host chain, deadline, creator, keep, token share and vesting all match. A lunch can't choose its bridge peers.
- **A creator who can't receive ETH still serves.** Their payout stays in the project and goes to buybacks.

## Things to know

- **Trades through the project need a minimum.** A served lunch has no issuance price, so the buyback hook's own price check is too loose to trade by. A payment only buys, and a cash out only sells, if it names the least it will take. A payment without one waits in the project for `burn`. A cash out without one reverts. The website always names one. A caller who names a careless minimum can be traded against up to it.
- **Burns wait 30 minutes after `serve`.** The price average needs history the pool's creator couldn't have shaped.
- **Burns are bounded, not instant.** A `burn` stops 200 ticks above the 30 minute average, and 200 ticks above the price before the current block, whichever is the cheaper token. A large balance is spent over several calls. A trade slipped in ahead of a burn in the same block gains nothing from it. Someone willing to hold a position across blocks can still sell into a burn up to 2% higher, less the two 1% pool fees that costs.
- **A trade with a minimum can still be sandwiched inside it.** Someone can trade ahead of a buy or a sale, up to the minimum it named, and back out after. That costs them the pool's 1% fee twice, so it only pays against a trade that moves the price more than that. The website names the quote less 2%.
- **Nothing calls `burn` by itself.** A payment without a minimum waits until someone does.
- **Buybacks are free of Juicebox fees, with one exception.** ETH that reaches a lunch as another Juicebox project's payout pays its 2.5% fee when it's used. The JBP6 that buys goes to the creator.
- **Holders can bridge after `serve`.** A holder who bridges their tokens to another chain takes their share of any ETH waiting for a buyback along, into the lunch's project there.
- **Paying after `serve` with a minimum is buying.** The payer's beneficiary gets the tokens. Nothing is burned unless they burn it.
- **Remote chains hold ETH until someone calls `sendHome`.** The caller pays the bridge's transport cost and the sucker's fee, gets back what isn't used, and gets the JBP6 the fee buys. Bridged ETH then needs a `claim` on the host chain.
- **A copy needs a bridge that carries ETH to the host.** `createFor` checks the copy's ETH mapping is on, carries the right gas and arrives as ETH. It can't check that Chainlink moves ETH between the two chains. Where it doesn't, `sendHome` reverts and what's paid there stays. All twelve pairs among Ethereum, Base, Arbitrum and Optimism carried ETH on 2026-11-12. Among testnets only Sepolia and Arbitrum Sepolia do.
- **Make the host chain's lunch first.** ETH sent home before the host's lunch exists arrives at an address with nothing there to receive it, and stays there. Only the creator can create a lunch's copies, and the website makes the host's first.
- **ETH that arrives after the deadline but before `serve` is in the raise.** That includes bridged ETH. The pool is sized from the project's balance at `serve`.
- **Pool fees in ETH are paid into JBP6**, and the JBP6 tokens go to the creator. Pool fees in the token are burned.
- **ETH or tokens sent straight to the contract are lost.** It has no way to return them.
- **Nothing here is audited.**

## Not covered by tests

- A real bridge delivery. The host side of a claim is emulated by acting as the sucker.
- Chains other than Base and Optimism.
