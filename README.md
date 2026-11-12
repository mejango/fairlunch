# Fair Lunch 🥪

A token launcher on Juicebox V6 and Uniswap V4. Someone raises ETH at a fixed price, keeps a capped share, and the rest becomes pool liquidity nobody can pull. After that it runs itself.

## How a lunch goes

| Phase | What happens |
| --- | --- |
| 🧑‍🍳 Cooking | Anyone pays ETH and gets 1,000,000 tokens per ETH until the deadline. No goal, no refunds, no cash outs. |
| 🍽️ Served | After the deadline anyone calls `serve` once. Juicebox's 2.5% fee comes off the raise. The creator gets their share of the rest (a percent, up to a cap), and what remains is paired with freshly minted tokens at the raise price in a full-range Uniswap V4 pool. The position stays in the contract for good. The creator's token share goes into a vesting wallet. |
| 🔥 Eating | Paying the project buys the token from the pool for the payer, and cashing out sells it there, both through the Juicebox buyback hook. A payer who wants a burn burns what they get. Anyone can call `burn` to buy and burn with money that reached the project another way, and `collect` to burn the pool's token fees and pay its ETH fees into JBP6 with the creator as beneficiary. |

The buyback hook holds a trade to the pool's 30 minute average price unless the trade names its own minimum. For the first 30 minutes after `serve`, only trades that name a minimum go through: a payment without one waits in the project for the next `burn`, and a cash out without one reverts.

## Chains

A lunch has one host chain, where its pool lives. It can also be created on other chains, joined to the host by Juicebox suckers. Payments on the other chains mint nothing. Anyone calls `sendHome` there to bridge the ETH to the host chain, where it counts as raised before `serve` and is used by `burn` after.

## Contracts

| Contract | Does |
| --- | --- |
| `FairLunch` | Owns every lunch's project and holds its pool position. |
| `FairLunchDataHook` | Every lunch's data hook: the fixed price and deadline while cooking, the buyback hook once served. Deployed by `FairLunch`. |
| `FairLunchVestingDeployer` | Deploys the creator's OpenZeppelin `VestingWallet`. Split out to keep `FairLunch` under the contract size limit. |

`FairLunch` has no owner and no admin. The one privileged call, `setChainSpecificConstants`, sets the chain's Uniswap V4 addresses once at deployment and can never run again.

## Develop

```bash
npm ci
forge build --deny warnings
forge test -j 1
```

The tests fork Base and Optimism at pinned blocks over their public RPCs. `-j 1` keeps them under the rate limits.

## Deploy

`script/Deploy.s.sol` proposes both contracts through Sphinx and sets each chain's Uniswap V4 addresses in the same proposal. `test/deployment/Deploy.t.sol` rehearses it on forks. See [RISKS.md](RISKS.md) before using it.
