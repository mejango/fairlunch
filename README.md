# Fair Lunch 🥪

A token launcher on Juicebox V6 and Uniswap V4. Someone raises ETH at a fixed price, keeps a capped share, and the rest becomes pool liquidity nobody can pull. After that it runs itself.

## How a lunch goes

| Phase | What happens |
| --- | --- |
| 🧑‍🍳 Cooking | Anyone pays ETH and gets 1,000,000 tokens per ETH until the deadline. No goal, no refunds, no cash outs. |
| 🍽️ Served | After the deadline anyone calls `serve` once. Juicebox's 2.5% fee comes off the raise. The creator gets their share of the rest (a percent, up to a cap), and what remains is paired with freshly minted tokens at the raise price in a full-range Uniswap V4 pool. The position stays in the contract for good. The creator's token share goes into a vesting wallet. |
| 🔥 Eating | Every payment into the project buys the token from the pool and burns it in the same transaction. Anyone can call `burn` for money that arrived another way, and `collect` to burn the pool's token fees and pay its ETH fees into JBP6 with the creator as beneficiary. |

A buy never pushes the price more than 200 ticks (about 2%) above the pool's 30 minute average, or above where it stood before the current block. What can't be spent inside that bound waits in the project for the next `burn`.

## Chains

A lunch has one host chain, where its pool lives. It can also be created on other chains, joined to the host by Juicebox suckers. Payments on the other chains mint nothing. Anyone calls `sendHome` there to bridge the ETH to the host chain, where it counts as raised before `serve` and is used to buy and burn after.

## Contracts

| Contract | Does |
| --- | --- |
| `FairLunch` | Owns every lunch's project, is its data hook and pay hook, holds its pool position. |
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
