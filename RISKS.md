# Risks

What Fair Lunch trusts, what can go wrong, and what was chosen on purpose.

## Trust

- **Juicebox V6 core, the omnichain deployer, suckers and the JB Uniswap V4 hook.** A lunch is a Juicebox project owned by `FairLunch`. A bug in any of these is a bug here.
- **Uniswap V4 and Permit2.** The liquidity lives in a V4 position held by `FairLunch`.
- **The bridge behind each sucker.** ETH sent home is only as safe as that bridge.
- **The deployer, once.** Whoever deploys `FairLunch` sets its Uniswap V4 addresses a single time. Wrong addresses there break or drain every lunch on that chain, and they can't be changed. The deploy rehearsal test pins the expected values.

Nobody can change a lunch after it's created, including its creator.

## By design

- **No refunds and no cash outs.** Money paid in stays in. Before `serve`, tokens can't be redeemed. After, the only exit is selling into the pool.
- **Liquidity is locked forever.** There is no function that removes it.
- **The creator's ETH is paid at `serve` in full.** Only their tokens vest.
- **Anyone can create the pool first.** If the pool exists at another price when `serve` runs, `serve` swaps it toward the raise price, stopping at that price, with at most half of either side, before adding liquidity. Those swaps pay the pool's 1% fee to whoever put liquidity there. If the price can't be reached, the pool opens where it ended up, and the leftover is burned (tokens) or kept in the project for buybacks (ETH).
- **A lunch's terms are part of its addresses.** Copies of a lunch on other chains bridge to each other only if the caller, salt, host chain, deadline, creator, keep, token share and vesting all match. A lunch can't choose its bridge peers.
- **A creator who can't receive ETH still serves.** Their payout stays in the project and goes to buybacks.

## Things to know

- **Buybacks wait 30 minutes after `serve`.** The price average needs history the pool's creator couldn't have shaped.
- **Buybacks are bounded, not instant.** A buy stops 200 ticks above the 30 minute average, and 200 ticks above the price before the current block, whichever is the cheaper token. A large payment is spent over several calls. A trade slipped in ahead of a buy in the same block gains nothing from it. Someone willing to hold a position across blocks can still sell into a buy up to 2% higher, less the two 1% pool fees that costs.
- **Buybacks are free of Juicebox fees, with one exception.** ETH that reaches a lunch as another Juicebox project's payout pays its 2.5% fee when it's used. The JBP6 that buys goes to the creator.
- **Holders can bridge after `serve`.** A holder who bridges their tokens to another chain takes their share of any ETH waiting for a buyback along, into the lunch's project there.
- **A payment after `serve` mints the payer nothing.** The website must say so before they pay.
- **Remote chains hold ETH until someone calls `sendHome`.** The caller pays the bridge's transport cost and the sucker's fee, gets back what isn't used, and gets the JBP6 the fee buys. Bridged ETH then needs a `claim` on the host chain.
- **ETH that arrives after the deadline but before `serve` is in the raise.** That includes bridged ETH. The pool is sized from the project's balance at `serve`.
- **Pool fees in ETH are paid into JBP6**, and the JBP6 tokens go to the creator. Pool fees in the token are burned.
- **ETH or tokens sent straight to the contract are lost.** It has no way to return them.
- **Nothing here is audited.**

## Not covered by tests

- A real bridge delivery. The host side of a claim is emulated by acting as the sucker.
- Chains other than Base and Optimism.
