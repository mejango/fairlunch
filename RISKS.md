# Risks

What Fair Lunch trusts, what can go wrong, and what was chosen on purpose.

## Trust

- **Juicebox V6 core, the omnichain deployer, suckers and the JB Uniswap V4 hook.** A lunch is a Juicebox project owned by `FairLunch`. A bug in any of these is a bug here.
- **The Juicebox buyback hook.** Once a lunch is served, its payments and cash outs trade through the buyback hook the registry gave its project when it was created, and that hook can mint the lunch's token. A lunch keeps that hook for good. Whoever owns the registry chooses the hook later lunches get.
- **Uniswap V4 and Permit2.** The liquidity lives in a V4 position held by `FairLunch`.
- **The bridge behind each sucker.** ETH sent home is only as safe as that bridge.
- **The router terminal.** Every lunch lists the router terminal registry as its second terminal, so people can pay in other tokens. Whichever router the registry gives the project swaps what's paid into the lunch's money and pays it in. It never holds a lunch's balance. A bad router could only lose what's paid through it.
- **The deployer, once.** Whoever deploys `FairLunch` sets its Uniswap V4 addresses a single time. Wrong addresses there break or drain every lunch on that chain, and they can't be changed. The deploy rehearsal test pins the expected values.

Nobody can change a lunch after it's created, including its creator.

## By design

- **No refunds and no cash outs.** Money paid in stays in. Before `serve`, tokens can't be redeemed. After, the only exit is selling into the pool.
- **Liquidity is locked forever.** There is no function that removes it.
- **The creator's ETH is paid at `serve` in full.** Only their tokens vest.
- **A creator and their list can get almost all of the supply.** The only limit is that the creator's share and the list's share add up to under 100%; payers and the pool share what's left, so read a lunch's split before paying. The creator's own share vests. A list of addresses the creator fixes at creation (`claimsPercent`, `claimsRoot`) gets its share at serve, and those tokens don't vest: anyone can send a listed address its tokens from `serve` on. Funders can see both shares before paying. They can't see who is on the list unless the creator publishes it, and a creator can list themselves.
- **A list is the creator's to get right.** Nobody can change it. An address is paid once, so a list naming the same address twice pays only the entry claimed first. Shares that add up to less than the whole leave tokens in `FairLunchClaims` forever, and shares that add up to more run out before the last claims.
- **Anyone can create the pool first.** If the pool exists at another price when `serve` runs, `serve` swaps it toward the raise price with at most half of either side, before adding liquidity. It stops where the price is 1% better than the raise price, so a pool started off-price opens 1% beside it, and a pool started inside that 1% opens where it was started. The pool's 1% fee on those swaps goes to whoever put liquidity there, and stopping there keeps that fee from buying their tokens back for more than the raise charged, or selling them tokens for less. Nobody trading against a pool that opened inside that 1% beats the raise price either, once they pay the fee. If the price can't be reached, the pool opens where it ended up. The leftover is burned (tokens) or kept in the project for buybacks (ETH).
- **A lunch's terms are part of its addresses.** Copies of a lunch on other chains bridge to each other only if the caller, salt, host chain, deadline, creator, keep, token share, vesting and claims all match. A lunch can't choose its bridge peers.
- **A creator who can't receive ETH still serves.** Their payout stays in the project and goes to buybacks.

## Things to know

- **Trades through the project need a minimum.** A served lunch has no issuance price, so the buyback hook's own price check is too loose to trade by. A payment only buys, and a cash out only sells, if it names the least it will take. A payment without one waits in the project for `burn`. A cash out without one reverts. The website always names one. A caller who names a careless minimum can be traded against up to it.
- **Burns wait 30 minutes after `serve`.** The price average needs history the pool's creator couldn't have shaped.
- **Burns are bounded, not instant.** A `burn` stops 200 ticks above the 30 minute average, and 200 ticks above the price before the current block, whichever is the cheaper token. A large balance is spent over several calls. A trade slipped in ahead of a burn in the same block gains nothing from it. Someone willing to hold a position across blocks can still sell into a burn up to 2% higher, less the two 1% pool fees that costs.
- **Liquidity added just ahead of a burn takes a cut of it.** Someone can buy a little, add it as liquidity right where a burn is about to buy, and remove it after. They sell into the burn up to its bound and earn its 1% fee instead of paying one. From a quiet price this took 0.4% of what a burn spent in a test, and can't pass 2%. The bound limits the price a burn pays, not what a seller paid for their tokens: someone who bought cheaply after another holder's large sale keeps that gain too, which a review put at 2.8% of the burn's spend after a 6% drop. The fee they earn would otherwise have gone to the lunch's own position. A tighter bound would shrink the first part and make burns slower.
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
- **A lunch raises one kind of money: ETH or an ERC-20.** The price is 1,000,000 tokens per whole unit of it, whatever its decimals. Everything this file says about ETH goes for an ERC-20 lunch's money too, except where it says otherwise below.
- **A lunch's money is only as dependable as its token.** `createFor` takes any ERC-20. One whose transfers can be paused, blocked per address or changed by an upgrade can lock a lunch at `serve` or after, and whoever controls that token controls that. Check what a lunch raises before paying it.
- **A pool opens with at most about 1.3 trillion whole units of money.** That's the most Uniswap V4 can always account for at 1,000,000 tokens per unit. A bigger raise pools that much and the rest waits in the balance for `burn`.
- **Tokens that take a fee on transfer or rebase aren't supported.** `createFor` can't tell, and a lunch that raises one can get stuck. `createFor` rejects a token with more than 24 decimals, and JBP6 itself.
- **Paying in another token is a swap.** The router terminal prices its swap from the pools it finds unless the payer names a minimum for it. Name one.
- **An ERC-20 lunch's token stays on its host chain.** `serve` opens the bridges to holders only for ETH lunches. Copies still send their money home.
- **An ERC-20 lunch's copy names that chain's address for the money.** Nothing on chain can check that two addresses on two chains are the same asset. `createFor` checks the bridge carries the copy's token home as the host's money, and nothing more.
- **Where JBP6 can't take a lunch's money, fees go to burns instead, some of them late.** The money side of pool fees goes into the lunch's balance. The 2.5% Juicebox fee on the raise is paid to JBP6 through its router terminal. If the router can't swap the token, its gateway holds the fee, and gives it back to the lunch's balance once the swap has failed three times over three days and someone calls the gateway to finalize it. The creator gets no JBP6 for either.
- **Nothing here is audited.**

## Not covered by tests

- A real bridge delivery. The host side of a claim is emulated by acting as the sucker.
- Chains other than Base and Optimism.
