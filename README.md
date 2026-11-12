# Fair Lunch 🥪

A token launcher on Juicebox V6 and Uniswap V4. Someone raises ETH at a fixed price, keeps a capped share, and the rest becomes pool liquidity nobody can pull. After that it runs itself.

## How a lunch goes

| Phase | What happens |
| --- | --- |
| 🧑‍🍳 Cooking | Anyone pays ETH and gets 1,000,000 tokens per ETH until the deadline. No goal. Until the deadline a payer can cash their tokens out for what they paid. After it, no refunds and no cash outs. |
| 🍽️ Served | After the deadline anyone calls `serve` once. Juicebox's 2.5% fee comes off the raise. The creator gets their share of the rest (a percent, up to a cap), and what remains is paired with freshly minted tokens at the raise price in a full-range Uniswap V4 pool. The position stays in the contract for good. The creator's token share goes into a vesting wallet. If the creator named a list of addresses, its share of the tokens goes to `FairLunchClaims`, where anyone can send each address its part. |
| 🔥 Eating | Paying the project with a minimum buys the token from the pool for the payer, and cashing out with a minimum sells it there, both through the Juicebox buyback hook. A payer who wants a burn burns what they get. Every other payment waits in the project. Anyone can call `burn` to buy and burn with what waits, and `collect` to burn the pool's token fees and pay its ETH fees into JBP6 with the creator as beneficiary. |

A `burn` never pushes the price more than 200 ticks (about 2%) above the pool's 30 minute average, or above where it stood before the current block. What can't be spent inside that bound waits for the next `burn`. A cash out without a minimum reverts.

## Chains

A lunch raises ETH or any ordinary ERC-20, named when it's made. Where this file says ETH, read the lunch's money. Every lunch also lists the Juicebox router terminal registry as a second terminal, so people can pay in other tokens and have them swapped into the lunch's money on the way in.

A lunch has one host chain, where its pool lives. It can also be created on other chains, joined to the host by Juicebox suckers. The other chains refuse payments until the deadline, since only the host sells tokens. After it, payments there mint nothing. Anyone calls `sendHome` there to bridge the money to the host chain, where `burn` uses it. The raise is only what payers paid on the host for their tokens: money that reaches the host's balance any other way before `serve` waits for `burn` too.

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
