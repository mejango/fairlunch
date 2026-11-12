# Fair Lunch implementation plan

> **For agentic workers:** execute task by task (superpowers:executing-plans, native, in the main session). Steps use checkbox syntax. Read the spec first; this plan argues from it.

**Goal:** A token launcher on Juicebox V6 and Uniswap V4: fixed-price fundraise, one permissionless launch into locked liquidity, then every inflow buys and burns, with a small site.

**Architecture:** One singleton contract, `FairLunch`, is project owner, extra data hook (through `JBOmnichainDeployer`), pay hook and holder of every LP position. The host project's terminal balance is the single sink for all revenue. The site is Sticky's web scaffolding without Signa.

**Tech stack:** Solidity 0.8.28, Foundry (via_ir, cancun), npm-installed V6 packages, Sphinx deploy script. Next 16, wagmi 3, viem 2, Tailwind 4, `@bananapus/nana-sdk-core`, Center RPC and pinning, Bendystraw.

**Spec:** `/Users/jango/Documents/jb/v6/evm/docs/superpowers/specs/2026-11-11-fair-lunch-design.md`

**Workspace resources (carry into any delegated work):** `/Users/jango/Documents/jb/v6/evm/AGENTS.md`, `/Users/jango/Documents/jb/v6/evm/workflow/ponytail/SKILL.md`, `/Users/jango/Documents/jb/v6/evm/docs/PLAN_REFINEMENT.md`, `/Users/jango/Documents/jb/v6/evm/tasks/lessons.md`, `/Users/jango/Documents/jb/v6/evm/STYLE_GUIDE.md`.

## Plan refinement

- **Objective:** Deliver the approved Fair Lunch spec (contracts, site, keeper job) in `extensions/fair-lunch`; success is the lifecycle fork tests green on Base, the site passing its full check at phone and desktop widths against a testnet deployment, and a reviewable PR; jango's decisions in the spec are facts, my marked calls stay open to correction.
- **System fit:** Outcome (launch a token with no duties) → capability (`FairLunch` over V6 core, omnichain deployer, suckers, JB V4 hook oracle) → evidence (fork tests against live V6, Bendystraw rows) → prepared action (SDK-built transactions in one review) → authority (user wallet signs; every later call permissionless) → verified result (receipts and indexed state on the project page) → learning (lessons and invariants as tests); owners reused are core, the omnichain deployer, the SDK and Center, and no existing consumer changes.
- **Reuse and simplicity:** Reused as is: `JBOmnichainDeployer`, suckers, `JBSwapLib`, `IGeomeanOracle`, OpenZeppelin `VestingWallet`, PositionManager action encoding copied from the LP split hook, Sticky's web scaffolding, revnet's SVG price chart, Homerun's `FundingProgress`; new is one contract because no existing piece burns on buyback or launches on a deadline, and three roles share one per-project record.
- **Evidence and unknowns:** Upstream `origin/main` of the hook repos (buyback 2.0.1, V4 router hook 2.0.1, LP split hook 1.5.2) and published npm versions are the source, local hook checkouts are stale; four unknowns in the spec are settled by Task 2 fork tests before dependent code; everything here is proposed, nothing is deployed, and no deploy, repo creation or merge is authorized by this plan.
- **Verification:** One test per spec invariant plus the Review focus cases, Base fork lifecycle test at a pinned block, two-fork `sendHome` test, forge fmt and warnings-denied build and sizes, STYLE_GUIDE check, two adversarial Codex passes before any push, web `npm run check` with Playwright at 390px and 1280px, and a render against live data.
- **Resource budget:** Contracts first because the site depends on the ABI; Task 2 spikes are the replanning trigger (a failed whole-balance cash out switches `burn` to the pay-hook-forward fallback named in the spec); one writer for this file, edits in the main session, subagents only for read-only research and review, fork tests bounded to one pinned block per chain.

## Global constraints

- Fee project and its token are called JBP6. No middots anywhere. Sentence case in UI.
- Fixed values: 1,000,000 tokens per ETH (weight `1_000_000e18`), pool fee `10_000`, tick spacing `200`, TWAP window `30 minutes`, price limit TWAP + `200` ticks, keep percent and token percent each at most 50%, vesting presets 26, 52, 104, 208 weeks (site offers these; contract stores the duration it is given).
- No cash outs for anyone but FairLunch in any phase. No admin function. No function removes liquidity.
- No tokens or ETH stranded by our own execution.
- User wallets only: injected, Coinbase Wallet, WalletConnect, Safe. No Signa, no Para.
- V6 STYLE_GUIDE: pragma 0.8.28 (interfaces and structs `^0.8.0`), named imports, banner sections in order, `FairLunch_ErrorName` errors in the contract, full NatSpec, named arguments for calls with two or more arguments.
- Contract PRs stay unmerged and undeployed until jango approves the final PR. Creating the GitHub repo, proposing a deployment and publishing the site each need a go-ahead.

## Review focus

Each line names the task whose tests pin it.

1. Deadline passes with nothing raised: `serve` reverts cleanly and pays stay rejected (Task 5).
2. Creator address is a contract that rejects ETH: `serve` still completes and the creator's ETH is not stranded in FairLunch (Task 5).
3. Pool initialized or funded by a stranger before launch at a wrong price: `serve` completes and never trades worse than the raise price (Task 5).
4. A pay far larger than pool liquidity after launch: pay succeeds, price moves at most to the limit, remainder waits in the balance (Task 6).
5. `sendHome` and host `claim` before `serve`: bridged ETH counts as raised and no token holder is diluted beyond 1 wei (Task 7).

## File map

- `src/FairLunch.sol`: the contract.
- `src/interfaces/IFairLunch.sol`: events, views, transactions.
- `src/structs/FairLunchConfig.sol`: creation input. `src/structs/FairLunchRecord.sol`: per-project record.
- `script/Deploy.s.sol`: Sphinx deploy, per-chain constants.
- `test/FairLunch.t.sol` (unit, mocks), `test/fork/FairLunchLifecycle.t.sol`, `test/fork/FairLunchSpikes.t.sol`, `test/fork/FairLunchCrossChain.t.sol`.
- `web/`: Next app (see Tasks 10 to 15).

## Interfaces fixed by this plan

The code is the record: `src/structs/FairLunchConfig.sol`, `src/structs/FairLunchRecord.sol`, `src/interfaces/IFairLunch.sol`.

Changes made while building, each forced by a test or a limit:

- `hostChainId` (uint64) replaces `isHost`, so a remote chain knows which sucker leads home.
- `createFor` is payable, to carry the project creation fee.
- `setChainSpecificConstants(positionManager, oracleHook)` sets the Uniswap V4 addresses once after deployment, since they differ per chain and constructor arguments must not (same address everywhere).
- `FairLunchVestingDeployer` creates the `VestingWallet`, and `Create` carries only `(projectId, hostChainId, creator, deadline, caller)`, both to fit the 24,576 byte limit.
- `sendHome` returns the bridge payment it doesn't use to the caller.

---

## Phase A: contracts

### Task 1: Scaffold the repo
- [x] `git init` in `extensions/fair-lunch`; `.gitignore`, `foundry.toml` (Homerun's settings, `libs = ["node_modules", "lib"]`), `package.json` with npm deps at published versions (`@bananapus/core-v6`, `buyback-hook-v6@2.0.1`, `univ4-router-v6@2.0.1`, `suckers-v6`, `omnichain-deployers-v6`, `721-hook-v6`, `permission-ids-v6`, `@openzeppelin/contracts`, `@uniswap/v4-core`, `v4-periphery`, `permit2`, forge-std, `@sphinx-labs/plugins`), `AGENTS.md` and `CLAUDE.md` pointing at the workspace resources, `STYLE_GUIDE.md` pointer.
- [x] `forge build` succeeds on an empty `FairLunch` stub. Commit.

### Task 2: Spikes that settle the spec's unknowns (fork, Base, pinned block)
File: `test/fork/FairLunchSpikes.t.sol`. Each test uses a throwaway harness contract in the test file.
- [x] `test_wholeBalanceCashOut`: a project launched through the live `JBOmnichainDeployer` with the harness as owner and extra data hook; the harness's `beforeCashOutRecordedWith` returns tax 0 and count = total supply for itself; assert the harness reclaims the entire balance with no fee, burning 1 wei of token (try 0 first), and that a stranger reclaims 0.
- [x] `test_wholeBalanceCashOutInsidePayHook`: same call made from `afterPayRecordedWith` during a pay; assert whether it succeeds.
- [x] `test_payoutFeeBeneficiary`: `sendPayoutsOf` with one split and a remainder; assert who receives the remainder and who receives the JBP6 from the fee.
- [x] `test_liveAddresses`: assert code exists at the V4 hook 2.0.x, PoolManager, PositionManager, Permit2, omnichain deployer and sucker registry addresses read from the packages' `deployments/` for Base, and that `IGeomeanOracle.hasObservationCoverage` exists on the hook.
- [x] Record results under "Spike results" below. If the whole-balance cash out fails, switch Task 6 to the fallback (forward pays through the pay hook, hold per-project pending ETH) and rerun the plan gate. Commit.

### Task 3: Structs, interface, constants
- [x] Create the two structs and `IFairLunch` exactly as in "Interfaces fixed by this plan". Constructor immutables: `CONTROLLER`, `DIRECTORY`, `TOKENS`, `OMNICHAIN_DEPLOYER`, `SUCKER_REGISTRY`, `POOL_MANAGER`, `POSITION_MANAGER`, `PERMIT2`, `ORACLE_HOOK`, `FEE_PROJECT_ID = 1`. `forge build`. Commit.

### Task 4: `createFor` and Cooking
- [x] Tests (`test/FairLunch.t.sol`, fork-backed where core is needed): `test_createFor_storesRecordOnce`; `test_createFor_revertsAboveHalfKeep` and `...AboveHalfTokens`; `test_createFor_revertsPastDeadline`; `test_pay_mintsOneMillionPerEth`; `test_pay_revertsAfterDeadline`; `test_cashOut_reclaimsNothing` (holder cashes out, receives 0 ETH); `test_remote_payMintsNothing`.
- [x] Implement `createFor`: launch through `OMNICHAIN_DEPLOYER` with owner and extra data hook = this, native ETH accounting context, `deployERC20For` with `keccak256(abi.encode(msg.sender, salt))`. Host ruleset: duration 0, weight `1_000_000e18`, reserved 0, cash out tax MAX, `scopeCashOutsToLocalBalances`, data hook for pay and cash out, `allowOwnerMinting`. Remote ruleset: same but weight 0, and map the native token on its suckers. Host suckers get no token mapping.
- [x] Implement `beforePayRecordedWith` (host and not served: revert `FairLunch_Closed` after `deadline`; otherwise pass weight through), `beforeCashOutRecordedWith` (holder == this: tax 0, count = total supply; else pass the ruleset's values), `hasMintPermissionFor` (false), `supportsInterface`, `onERC721Received`.
- [x] Tests pass. Commit.

### Task 5: `serve`
- [x] Tests (`test/fork/FairLunchLifecycle.t.sol`): `test_serve_revertsBeforeDeadline`; `test_serve_revertsWithNothingRaised` (focus 1); `test_serve_revertsTwice`; `test_serve_revertsOnRemote`; `test_serve_keepBelowCap` (raised 10 ETH, keep 20%, cap 5 ETH: creator receives 2 ETH less 2.5%); `test_serve_keepAboveCap` (cap 1 ETH: creator receives 1 ETH less 2.5%); `test_serve_poolOpensAtRaisePrice` (pool `sqrtPriceX96` within one tick spacing of 1,000,000 tokens per ETH; pool tokens = pool ETH x 1,000,000); `test_serve_creatorTokensVest` (vesting wallet holds t/(1-t) x (sold + pool tokens), releases linearly, beneficiary is creator); `test_serve_creatorReceivesJbp6`; `test_serve_leavesNothingBehind` (FairLunch holds 0 ETH and 0 project tokens after); `test_serve_creatorRejectsEth` (focus 2); `test_serve_hostilePoolLow`, `test_serve_hostilePoolHigh`, `test_serve_strangerLiquidity` (focus 3: stranger pre-initializes at 100x and 0.01x the raise price, with and without liquidity; serve completes, and ETH spent per token acquired or received is never worse than the raise price).
- [x] Implement `serve(projectId)`: checks; queue the forever ruleset through `OMNICHAIN_DEPLOYER.queueRulesetsOf` (weight 0, tax MAX, payout limit = balance, one split to creator sized min(keepPercent x raised, keepCap), remainder to owner); `sendPayoutsOf`; forward JBP6 received to creator; mint creator tokens to a new `VestingWallet(creator, block.timestamp, vestingDuration)`; mint pool tokens; `_openPool` (initialize if needed, swap toward the raise price with that price as the limit, mint the full-range position with the LP split hook's action encoding, burn leftover tokens, `addToBalanceOf` leftover ETH); map the native token on the host suckers; write `servedAt`, `positionId`, `vestingWallet`; emit `Serve`.
- [x] Tests pass. Commit.

### Task 6: buyback on pay, `burn`, `collect`
- [x] Tests: `test_pay_afterServe_holdsFor30Minutes` (pay succeeds, nothing bought, ETH in balance); `test_pay_buysAndBurnsSameTx` (after 30 minutes and some swaps: total supply drops, payer gets 0 tokens, balance 0 after); `test_pay_oversized_stopsAtLimit` (focus 4: pay 100x pool ETH; pool tick ends at most TWAP tick + 200, remainder in balance, later `burn` calls spend more as the TWAP follows); `test_pay_succeedsWhenManagerUnlocked`; `test_burn_revertsBefore30Minutes`; `test_burn_burnsHeldTokens`; `test_burn_neverTradesAboveLimit` (fuzz the pre-trade pool price); `test_collect_burnsTokenSidePaysEthToJbp6` (creator's JBP6 balance rises, FairLunch holds nothing); `test_noLiquidityRemovalSelector` (interface has no decrease path with nonzero liquidity).
- [x] Implement: post-serve `beforePayRecordedWith` returns weight 0 and one zero-amount spec to this; `afterPayRecordedWith` (caller must be a terminal of the project) calls `this.burn` in try/catch; `burn` (require host, served, `block.timestamp >= servedAt + 30 minutes`; cash out the whole balance to this; price limit from the oracle's 30-minute mean tick + 200 via `TickMath`; exact-input swap inside `unlock`; burn all tokens held; `addToBalanceOf` unspent ETH); `collect` (DECREASE_LIQUIDITY 0 + TAKE_PAIR, burn tokens, `pay` project 1 with beneficiary creator).
- [x] Tests pass. Commit.

### Task 7: cross-chain
- [x] Tests (`test/fork/FairLunchCrossChain.t.sol`, Base and Optimism forks): `test_hostPrepare_revertsBeforeServe`; `test_sendHome_mintsOneWeiWhenRemoteSupplyZero`; `test_sendHome_thenClaim_beforeServe_countsAsRaised` (focus 5: holders' token share unchanged beyond 1 wei, host balance up by the bridged amount); `test_sendHome_thenClaim_afterServe_feedsBurn` (FairLunch's claimed tokens burned, ETH bought and burned); `test_sendHome_revertsOnHost`.
- [x] Implement `sendHome`: require remote; mint 1 wei if remote supply is 0, else 1,000,000 x supply; approve and `prepare` to the host FairLunch as beneficiary on each sucker of the project, then `toRemote{value: msg.value}`; emit.
- [x] Tests pass. Commit.

### Task 8: deploy script and contract gates
- [x] `script/Deploy.s.sol` in the Sticky and Homerun Sphinx shape, constructor arguments from the packages' deployment records; a rehearsal test that runs it on a fork. No proposal is sent.
- [x] `forge fmt --check`, warnings-denied build, `forge build --sizes` under 24,576 bytes, STYLE_GUIDE pass over every declaration, `README.md`, `RISKS.md` (singleton custody, 7-day bridge, TWAP limit behaviour).
- [x] Two adversarial Codex passes (`gpt-6.1-sol`, read-only, stdin closed); fix; rerun affected tests. Commit.
- [ ] Check-in with jango: repo creation and PR. On hold, and testnet deployment too, until jango says (2026-11-12).

## Phase B: website

### Task 10: scaffold `web/` from `extensions/sticky/web`
- [x] Copied scaffolding and shared infrastructure (providers, wallet files, transaction review set, Center RPC), with every Signa file and branch and all Sticky product code removed. `nana-sdk-connect` stayed: its dialog is the one that lists the user's own wallets. No `COPIED.md`; `web/README.md` says where things come from.
- [x] `npm run check` passes (audit, lint, types, tests, build).

### Task 11: domain modules (one home per rule)
- [x] `abi.ts` (synced by `scripts/sync-abi.mjs`), `deployments.json`, `phase.ts`, `split.ts`, `reads.ts`, `writes.ts` (holds the per-chain `createFor`), `indexed.ts`.
- [x] Vitest for `phase.ts` and `split.ts`.

### Task 12: home and create
- [x] Home: list with logo, name, phase, raised; one "Make lunch" button.
- [x] Create: native inputs, logo and metadata pinned through Center, one review per chain. Several chains are one `createFor` each, host first, not a Relayr bundle. No Playwright spec; `scripts/shots.mjs` checks both widths for overflow and console errors.

### Task 13: project page
- [x] Phase and countdown, what was raised and how it splits, one card: Pay while cooking, Swap after serve (buy and sell, Permit2 approvals for sells), Serve, Burn and Collect buttons.
- [x] Other chains on the lunch's page: what waits on each copy, Send home (the SDK's transport amounts, simulated; the contract refunds the rest), what's on the way, and Bring in for delivered ETH (the SDK's verified claim). A copy's own URL points at its host.
- [x] Component tests for card state per phase (`web/test/lunch-view.test.tsx`).

### Task 14: chart
- [x] Price from the pool's own oracle in one call (no indexer, no log scan), range buttons, crosshair, raise-price line, burn marks from Bendystraw.
- [ ] Volume bars. Not buildable in the site: Base RPCs cap `eth_getLogs` at 500 to 1,000 blocks and a day is 43,200, and Bendystraw records swaps only for registered buyback pools. Needs a Bendystraw handler for Fair Lunch pools once there is a deployed address.

### Task 15: web gates
- [x] `npm run check`; copy pass.
- [ ] Render against a testnet deployment (needs the deployment go-ahead). Check-in with jango.

## Phase C: automation

### Task 16: keeper job
- Deferred by jango 2026-11-12: anyone can call upkeep from the site, no automation for now.
- [ ] Read `extensions/keeper/DESIGN.md`; add the smallest job that calls `serve`, `burn`, `collect`, `sendHome` and sucker `claim` when `dueCalls` says so, through its existing Relayr execution. Tests with a mocked chain. Check-in with jango.

## Spike results

Base fork at block 56,216,000, `test/fork/FairLunchSpikes.t.sol`, 7 passing (2026-11-11):

- Whole-balance cash out works: with the extra data hook returning tax 0 and count = total supply for itself, FairLunch reclaims the entire balance fee-free while burning 0 tokens. No mint needed.
- It also works from inside `afterPayRecordedWith` during a pay, so the buyback can run in the pay's own transaction. No fallback needed.
- A stranger's cash out reclaims 0 at tax MAX and does not revert.
- Payout: the split beneficiary receives its share less 2.5%; the remainder goes to the project owner (FairLunch) less 2.5%; the fee's JBP6 is minted to the project owner. `serve` forwards FairLunch's JBP6 (ERC-20 and credits) to the creator.
- `OMNICHAIN_DEPLOYER.queueRulesetsOf` works from the owner with no extra permission grant, and the queued ruleset is current in the same transaction after a 1 second warp from launch.
- Project creation charges `PROJECTS.creationFee()`; `createFor` is payable and forwards it.
- A weight-0 pay mints nothing and lands in the balance.
- Still open: whether Bendystraw indexes this pool's swaps (checked in Task 14).

## Review

### Phase A, Codex pass 1 (2026-11-11)

| Finding | Verdict | What changed |
|---|---|---|
| High: a copy of a lunch with other terms, or a chosen peer, bridges unbacked tokens into the host | Confirmed | The salt binds caller, host chain, deadline, creator, keep, token share and vesting. A chosen peer reverts. Tests: `test_createFor_bindsTermsIntoAddresses`, `test_copyWithOtherTerms_isNotAPeer`, `test_createFor_revertsWithAChosenPeer` |
| Medium: deep stranger liquidity makes every `serve` revert | Confirmed | Normalization spends at most half of either side. Test: `test_serve_deepStrangerLiquidityCantBlockIt` |
| Medium: normalization pays the pool's 1% fee | Accepted, documented in RISKS | None: bounded at 1% of what's swapped, paid to the stranger's liquidity |
| Medium: a same-block front-run profits from a buyback when spot is far under the average | Confirmed | The bound also holds 200 ticks from the price a second ago. Test: `test_burn_ignoresPriceMovedInItsOwnBlock`. A position held across blocks is documented |
| Medium: creator share computed before the pool settles | Confirmed | Minted after the pool opens and leftovers burn. Test: `test_serve_creatorShareHoldsOverHostilePool` |
| Medium: JBP6 from the sucker's fee or a deferred payout fee stays in the contract | Confirmed | `sendHome` forwards it to the caller, `burn` to the creator |
| Low: a failed sucker fee stays in the sucker | Confirmed | `sendHome` claims it back into the caller's refund |
| Info: bridging moves backing, unsolicited assets are lost | Documented in RISKS | None |
| Weak tests | Confirmed | Spikes deleted (the lifecycle suite asserts what they logged), `collect` earns fees on both sides and checks liquidity |

Not done: a claim through real bridge delivery (listed in RISKS).

### Phase A, Codex pass 2 (2026-11-11)

All five fixes from pass 1 held. New:

| Finding | Verdict | What changed |
|---|---|---|
| Medium: a remote lunch with no sucker or no ETH mapping traps what it's paid | Confirmed (creator mistake) | `createFor` on a remote requires a sucker to the host with ETH mapped. Test: `test_createFor_remoteNeedsARouteHome` |
| Medium: `sendHome` before the host's lunch exists strands WETH at the future sucker address | Confirmed, not fixable on chain without a cross-chain acknowledgement | Documented in RISKS. Only the creator can create copies, and the site creates the host first |
| Low: a 1 wei raise over a hostile empty pool can't be served until another wei arrives | Dismissed: dust, recoverable | None |

### Found by walking a local fork with wallet-estimated gas (2026-11-11)

Payments after `serve` went through without buying: the buyback sat in a try/catch, and gas estimation settles on the least gas that lets the transaction succeed, which is the amount at which the caught call runs out. Forge tests never see this because they send ample gas. `afterPayRecordedWith` now skips the buyback only when it's too early or the pool manager is unlocked, and otherwise calls `burn` uncaught. Test: `test_pay_revertsRatherThanStarveTheBuyback`. Proof: four `cast send` payments on the fork left only what the price bound wouldn't take.

Verdict from Codex was no merge until the two Mediums are addressed. One is fixed, one is documented with the site enforcing the order. This is the open call for jango at the PR.

### Phase A, Codex pass 3 on the uncaught buyback (2026-11-11)

No way found for a stranger to make payments revert, to skip buybacks for anyone but themselves, or to lock host claims (those use `addToBalanceOf`, which runs no pay hook).

| Finding | Verdict | What changed |
|---|---|---|
| Low: a payment made from inside another Fair Lunch call (a creator contract spending its payout on another lunch) reverts on the shared reentrancy guard | Confirmed | The hook also waits when the guard is entered. Test: `test_pay_fromInsideAnotherLunchsCallWaits` |
| Conditional Medium: JBP6 credits parked on the contract plus a JBP6 pause of credit transfers reverts every payment into every served lunch | Needs project 1's own ruleset to pause, but cheap to remove | Credits are claimed into the ERC-20 before sending; credits are only sent as credits when JBP6 has no ERC-20. Test: `test_pay_goesThroughWhileJbp6CreditTransfersArePaused` |
| Extreme ticks could make the price bound invalid | Dismissed: needs unrealistic capital against the locked full-range position | None |

`FairLunch` is now 24,480 bytes, 96 under the limit.

### Phase B, website (2026-11-11)

Checked against a local Base fork (`script/Rehearse.s.sol`, anvil, an RPC shim standing in for Center), not a live deployment.

| Check | Result |
|---|---|
| `npm run check` | Passes: audit clean, lint, types, 5 tests, production build |
| Pages at 1280 and 390 wide (`/`, `/create`, a cooking lunch, a served lunch) | No overflow, no console errors |
| Chart | Draws the oracle's price: raise price, then a step per buyback |
| Sell through the SDK's Permit2 and router builders (`web/scripts/sell-check.mjs`) | ETH received equals the quote, from a clean account |
| Wallet-driven flows (connect, pay, create, swap) in a real browser wallet | Not run: needs a wallet session |

Found on the way:

- The copied lockfile pinned Next 16.3.8, which has critical advisories. Now 16.4.6, with `follow-redirects` and `zod` overridden to patched versions. Sticky and juicebox-money are still on 16.3.8.
- The fork's default test account has a 7702 delegation on Base that forwards incoming ETH, so a sale from it looks like it paid nothing. Use a fresh funded account for sell checks.
- Bendystraw doesn't index a fork, so the home list and burn marks are empty locally. Whether it indexes FairLunch's projects on a live chain is unchecked.

### Phase B, other chains (2026-11-12)

Checked on two local forks, Base as host and Optimism as copy, with Fair Lunch at the same address on both (`Rehearse.deployOnly()`), through `web/scripts/copy-check.mjs`.

| Check | Result |
|---|---|
| Two-chain lunch made host first, copy paid 0.3 ETH | Host page lists Optimism with 0.3 ETH waiting and Send home; the copy's URL points at the host |
| `sendHome` with the SDK's transport amounts | Went through offering 0.05 ETH. The bridge and sucker fee took 0.023 ETH, the rest came back. Copy balance 0, one pending movement of 0.3 ETH to Fair Lunch |
| Bring in (the host's `claim`) | Not run: a fork can't deliver the bridge's message. The claim comes from the SDK's root-verified movements |
| `npm run check` | Passes with 13 tests |

Found on the way:

- Sending 0.3 ETH home from Optimism cost 0.023 ETH on the fork. Small copies cost more to send than they hold; whoever automates `sendHome` needs a threshold.
- A bare gas estimate for `createFor` ran out of gas every other run. The creation fee's JBP6 buyback writes an oracle slot once per second, so an estimate made in the same second as another JBP6 swap is 22,100 gas short of a later block. The site sends with the SDK's headroom, so it is covered; a script sending bare estimates is not.
- The SDK's fallback log scan asks for 45,000 blocks, which the public Optimism RPC behind the fork rejects (10,000 cap). Center's RPC limit for the same scan is unchecked.

### Phase B, Codex pass on the site's transactions (2026-11-12)

`gpt-6.1-sol`, read-only, over `writes.ts`, `reads.ts`, `LunchView.tsx`, `CreateForm.tsx`, `TxAction.tsx` against the contract and SDK 2.41.3.

| Finding | Call | Result |
|---|---|---|
| High: a cooking payment carried no minimum, so one still waiting when the lunch is served would pay into a buyback and mint nothing | Real | `payTx` asks for `amount x 1,000,000` tokens. On the fork: the exact amount passes, one wei more reverts, a served lunch reverts |
| Low: Send home reviewed a balance up to 60 s old and could pay the bridge to send nothing | Real | The balance is reread when the call is prepared; zero refuses; the review shows the reread amount. A send racing another in the same block is not covered |
| Low: a sale approves Permit2 for the maximum | Kept, confirmed by jango 2026-11-12 | It is Uniswap's own convention, the router's allowance is exact and 30 minutes, and an exact approval adds a press to every sale |

Codex confirmed the swap calldata (recipient, amounts, minimum, deadline), the matching terms and host-first order of a multi-chain create, and that claims use registry pairs and verified proofs.

Second pass, on the fixed tree and the create form. It confirmed the minimum is exact for every amount and found no High.

| Finding | Call | Result |
|---|---|---|
| Medium: a Safe's swap expired in 10 minutes and its sale allowance in 30, shorter than co-signing takes | Real | Swaps use the SDK's `swapDeadline(isSafe)`; the allowance lasts 20 minutes past it, and the review states when it ends |
| Medium: a multi-chain create lost its terms and salt on reload, so the remaining chains could never pair | Real | The attempt is kept in the browser until every chain is made, and restored on return |
| Medium (contract): a copy could not be created after the deadline, so a chain that failed in time was lost for good | Real | `createFor` requires a future deadline on the host only. Test `test_createFor_copyAfterTheDeadline`. 45 tests pass, 24,501 bytes, 75 margin |
| Low: Collect could be signed with no fees to collect | Real | Simulated when prepared; an empty collect is refused |
| Low: the create review's keep reads as ETH received | Real | Says "before the 2.5% fee" |
| Low: Send home can still race another send while the wallet prompt is open | Accepted by jango 2026-11-12 | A zero-balance check inside `sendHome` is reasonable but not necessary. Not built |

Codex pass 4, on the late-copy contract change alone: no findings, verdict MERGE for the diff. It notes a copy made with no host behind it is the already documented host-first risk, and that late creation after `serve` through delivery and burn has no test.


## Review: Codex Astra pass on the whole tree (2026-11-12)

Asked for by jango: is the code complete and safe. Two read-only `gpt-6-astra` runs, one on the contracts and one on the site, each against the spec. No High in either.

Contracts:

| Finding | Call | Result |
|---|---|---|
| Medium: a copy could be created with its ETH mapping set and then switched off, since the sucker's `isMapped` stays true. It would take ETH and never send it home | Real, needs a creator's own odd configuration | `createFor` reads the mapping's `enabled` flag through `ISuckerRoute`, one word, because the full struct put the contract 16 bytes over the limit. Test in `test_createFor_remoteNeedsARouteHome`. 24,501 bytes, 75 margin |
| No test: `sendHome` with holders on the remote | Real gap | `test_sendHome_withHoldersOnTheRemote`: a millionth stays, holders untouched, carriers burned |
| No test: cash outs while ready to serve and while eating | Real gap | Added to `test_cashOut_reclaimsNothing_everyPhase` |
| No test: the unlock callback's caller | Real gap | `test_unlockCallback_onlyPoolManager` |
| No test: failed sucker fee recovery, hostile pool history followed by a buyback, the one-wei dilution bound asserted exactly | Not built | Each needs a mock or a longer fork walk. Listed for the PR |

47 tests pass. Astra found the creator's limits, the locked position, the buyback bound, bridge accounting and reentrancy sound.

Site:

| Finding | Call | Result |
|---|---|---|
| Medium: a create that finishes while the page is closed, or in a Safe after co-signing, never marked its chain made, so the other chains stayed locked | Real, and the normal case for a Safe | The form asks the chain: `createFor` puts the token at an address fixed by the terms, so `findMade` derives it and reads its project. Checked against lunch 46 on the fork, pinned in `test/writes.test.ts` |
| Medium: a Safe's sale could promise a deadline past its allowance's end | Real | The sale's deadline is capped at the allowance's end, a Safe needs a day left on one to reuse it, and the review says when the swap must run by |
| Low: Burn could be signed when the price limit stops it buying anything | Real | Simulated when prepared; a burn that would spend and burn nothing is refused |
| Low: logos could load from any https address, telling its owner who looks | Real | Only `ipfs://` through Center's gateway |
| Low: the chart asked the oracle for more history than it keeps | Real, and bigger than Low. The oracle keeps 1,801 observations, one per second the pool trades in, so a busy pool keeps as little as half an hour | The range is cut to `observationCoverageOf` and the chart says older prices aren't kept. Real history needs the pool's swaps indexed, the same Bendystraw handler the volume bars need |
| Low: burn marks and the count stayed stale after a transaction | Real | The page's server reads refresh when a transaction confirms |
| Low: the list showed "Nothing cooking yet" when the index failed, and one chain's bridge history failing hid every copy | Real | The list says it couldn't load; a failed history leaves the copy and its balance showing |
| Spec: creator cap progress, facts row (burned, liquidity, vesting), Collect before buybacks start, 44px controls | Missing | Built |
| Spec: chart left and card right on desktop, an editable payout address, one Relayr bundle for a multi-chain create | Not built | The first two are small and jango's call; Relayr is already open |
| The list reads the newest 200 projects and the burned total the newest 500 burns | Kept | Marked `ponytail:` in `indexed.ts` with the way up |

`npm run check` passes with 18 tests. Rendered `/base:39` and `/base:40` at 390px and 1280px: no overflow, no console errors.

## Review: follow-ups jango asked for, and the testnet walk (2026-11-12)

- Create form: "Pay your share to", prefilled with the connected wallet. The signing wallet (`sender`) and the paid address (`creator`) are separate in the terms and in the create recovery.
- Three contract tests: `test_sendHome_returnsAFeeTheSuckerCouldntPay`, `test_burn_ignoresPriceHistoryFromBeforeServing`, and the carrier assertion in `test_host_claimBeforeServe_countsAsRaised`. 49 tests pass.

Codex pass 5, on the route-home change: MERGE for the diff. It found one older gap.

| Finding | Call | Result |
|---|---|---|
| Medium, older: a copy's ETH mapping could carry gas no bridge message can hold, so it could never send | Real, a creator's own odd configuration | `createFor` requires the mapping's gas to be `_SUCKER_MIN_GAS`. Normalizing the input instead cost 135 bytes and didn't fit. 24,554 bytes, 22 margin |

Codex pass 6, on that change and the three tests: the gas check is sound; verdict HOLD for one more route condition.

| Finding | Call | Result |
|---|---|---|
| Medium, conditional: a copy could map ETH to wrapped ETH on the host, which the host can't credit | Open, for jango | It needs the sucker registry to approve that mapping, which Codex did not establish any deployment does. The check is one more word, and puts the contract 9 bytes over the limit |
| Low: the fee test would pass with the fee lost | Real | Compares against the same call with the fee paid: exactly the fee more |
| Low: the carrier test proved conservation, not zero dilution | Real | Compares the supply against a serve of the same ETH with no carrier: equal to the wei |

Testnet, from a throwaway key (`~/.config/fair-lunch/testnet-deployer.key`), not the Sphinx deployment. Fair Lunch is at `0x5b572319a362683a6735a00876709e3dd10b0557` on Sepolia, Base Sepolia and Arbitrum Sepolia. Walk with `web/scripts/testnet-walk.mjs`: host project 9 on Arbitrum Sepolia, copy project 17 on Sepolia.

| Step | Result |
|---|---|
| Create on both, pay 0.05 ETH on the host and 0.02 ETH on the copy | Went through |
| `sendHome` from Sepolia | Sent 0.02 ETH, the bridge took 0.0015 ETH, the copy is empty |
| `serve` on the host | Went through, 2 wei left in the balance |
| Chainlink delivery, then `claim` on the host | Claimable about 25 minutes after sending. The host's balance rose by exactly 0.02 ETH |

What the testnets showed:

- Chainlink carries ETH between Sepolia and Arbitrum Sepolia only. Base Sepolia's wrapped ETH has no pool, and Sepolia's pool has no Base Sepolia lane. A copy on Sepolia with a Base Sepolia host (projects 16 and 64) was created and paid, and its `sendHome` reverts with `ChainNotAllowed`. All twelve mainnet pairs carry ETH. In RISKS.
- Sepolia runs Glamsterdam. Deploying Fair Lunch there took 38.2M gas against about 8M elsewhere, and forge's estimate failed twice. Sent with the node's estimate. `createFor` took 5.6M there against 1.55M on Arbitrum Sepolia.

## Buyback hook rework (2026-11-12)

jango: "lets do it", and a payment after serve is a purchase: "the payer is responsible for then burning if it wishes to (revenue-paying applications will)".

Plan, as built:

- [x] After `serve`, payments and cash outs forward to the Juicebox buyback hook registry. A payment buys for its beneficiary, a cash out sells into the pool. The served ruleset keeps weight 0 and the 100% cash out tax, so the pool is the only source and sink.
- [x] `serve` registers the pool with the project's buyback hook. `createFor` on the host requires that hook to price with the pool's oracle, so `serve` can't get stuck on it.
- [x] `burn` keeps its 30 minute wait, takes the balance, pays it back in with Fair Lunch as beneficiary and burns what it holds. Gone: the pay hook, Fair Lunch's own price bound and `TWAP_MAX_DEVIATION`.
- [x] For 30 minutes after `serve` only trades that name a minimum are forwarded. An unquoted payment waits in the balance, an unquoted cash out reverts. A cash out the hook wouldn't sell reverts instead of burning tokens for nothing.
- [x] The rules moved to `FairLunchDataHook`, deployed by `FairLunch`: forwarding in place put `FairLunch` 2,327 bytes over the limit. Now 23,048 bytes (1,528 spare) and 5,319.
- [x] With the room, pass 6's open Medium is closed: a copy's ETH mapping must arrive on the host as ETH. On the forks the CCIP sucker already refuses a wrapped mapping, so the test only asserts no such lunch can be made.
- [x] Site: Buy is the terminal's `pay` and Sell is `cashOutTokensOf`, each with the pool's quote less 2% in the buyback metadata (SDK builders). Permit2, the router and the approval steps are gone.
- [x] 53 contract tests and 18 site tests pass. `npm run check` passes.
- [x] Codex pass 7 on the rework: HOLD, one High.
- [x] Redeploy to the testnets and walk it, with buy and sell.

Found on the way: the oracle hook reports no history until a pool has observations at two timestamps. In a served pool nothing has traded in, the buyback hook buys at the current price for small payments only, and won't sell without a named minimum. A trade slipped in ahead of `burn` writes the second observation, and the burn then holds to the average (`test_burn_doesntChaseAPushedPrice`).

Codex pass 7 (2026-11-12):

| Finding | Call | Result |
|---|---|---|
| High: with weight 0 there is no issuance floor, and the buyback hook's own tolerance widens with trade size. A 4 ETH buy ahead of a 1 ETH `burn` or unquoted payment, sold after, made about 0.44 ETH | Real | `burn` is back on Fair Lunch's own bounded swap (200 ticks past the 30 minute average and the last block's price, partial fills). Only trades that name a minimum go through the hook, at any time: an unquoted payment waits for `burn`, an unquoted cash out reverts. `test_burn_sandwichLosesMoney` runs the whole round trip |
| Tests: the sandwich test never sold back, the plain-payment test had no second observation, the burn fuzz checked conservation only | Real | Replaced by the round trip above and the restored bound tests |
| Test: the wrapped-ETH mapping test accepts any revert | Kept | The CCIP sucker refuses the mapping first on every fork, so Fair Lunch's check can't be reached there. Said so in the test |

This changes what jango approved in one way: a payment without a minimum is not a purchase. It waits and is burned by the next `burn`, as before the rework. A payment with a minimum is a purchase for the payer. `FairLunch` is 23,766 bytes (810 spare), the hook 5,113. 52 tests pass.

Codex pass 8, on the fix: the High is closed, no new actionable finding, **MERGE for the rework as a whole** (468e7f0 through 2df4f87). One informational note, dismissed: a caller who writes both a registry-keyed and a hook-keyed entry into their own metadata can shadow their own minimum, which is the same as naming a careless one.

Testnet, reworked contract at `0xa309e08ddc1098f67d6a6cb6e4ef4b2b1a9bef5e` on Arbitrum Sepolia and Sepolia, from the throwaway key. Host project 10, copy project 18 (`~/.config/fair-lunch/walk3.json`). `script/Deploy.s.sol` now reuses a vesting deployer that's already at its address.

| Step | Result |
|---|---|
| Create on both, pay, `sendHome`, `serve` | Went through. `serve` took 2.24M gas |
| Buy 0.002 ETH with a minimum of 1,856.6 tokens | The payer got 1,894.5 tokens. Nothing reached the balance |
| Sell 1,000 tokens with a minimum, no approval | The seller got 0.00104 ETH |
| Pay 0.01 ETH without a minimum | Waits in the balance |

Local site on a rebuilt Base fork: the trade card quotes a buy and a sell, shows one Buy or Sell button with no approval step, and logs no errors at 390px.

## Pool and sandwich testing on testnets (2026-11-12)

jango: "thoroughly test LPing and buybacks and everything related to pools on testnets too", "especially be mindful about mitigating sandwich attacks during permissionless pool related transactions".

The permissionless calls that touch a pool are `serve`, `burn`, `collect`, and payments and cash outs through the buyback hook. One tool measures all of them: `test/PoolProbe.sol`, an attacker that trades ahead of any call and back out after it in one transaction, and that can make a pool early with its own liquidity. The fork tests use it as a gate, and it is deployed to Arbitrum Sepolia for real transactions. Evidence is the attacker's round-trip result per case.

- [x] `PoolProbe` replaces the test-only `Trader`. No behavior change, tests green.
- [x] Fork gates: `testFuzz_burn_sandwichNeverProfits` (push either way, same block or a block ahead; fails when the bound is loosened to 2,000 ticks), `testFuzz_serve_earlyPoolNeverProfits` (bids or offers, any depth and range, with a fundraise stake), `test_serve_buysNoTokenOverTheRaisePrice`, `test_serve_sellsNoTokenUnderTheRaisePrice`. Quoted trades past their minimum already had a test. `collect` doesn't trade in the lunch's pool, so it's measured on testnet only.
- [x] Testnet, clean lunch (project 10 on `0xa309…ef5e`, Arbitrum Sepolia, probe `0xa64b7C7Ab98368037E03081Cb4ddFda7a17Ed237`).
- [x] Testnet, hostile lunches (projects 11 to 14).
- [x] Found and fixed: `serve` paid early liquidity above the raise price. See below.

### Results

Clean lunch, real transactions:

| Case | Result |
|---|---|
| Bridge claim | 0.02 ETH sent from Sepolia arrived and was claimed into the balance |
| `collect` | Burned 12.3 tokens of fees, paid 0.000123 ETH into JBP6 |
| `burn` with the price pushed 36% above the average | Spent nothing, the ETH kept waiting |
| `burn` after the price came back | Spent 0.00047 ETH and stopped at its bound. The next block's burn did the same |
| Same-block sandwich of `burn`, 0.003 ETH push | Burn spent nothing. Attacker lost 0.000058 ETH |
| Same-block sandwich of `burn`, 0.0002 ETH push | Burn spent 0.00027 ETH inside its bound. Attacker lost 0.0000017 ETH |
| Buy a block ahead of `burn`, sell after | Burn spent nothing. Attacker lost 0.000039 ETH |
| Token-first sandwich of `burn`, 500 tokens | Burn bought 901 tokens cheap. Attacker lost 31 tokens |
| Sandwich of `collect`, 0.002 ETH push | Attacker lost 0.000039 ETH, the two pool fees |
| Sandwich of a quoted 0.005 ETH buy, push inside its 2% minimum | Attacker made 0.000055 ETH. This is the ordinary sandwich of a trade that moves the price more than the fees. RISKS.md says so now |
| Same, push past the minimum | Reverts, `JBBuybackHook_SpecifiedSlippageExceeded` |
| Sandwich of a quoted 200 token sale, push inside its minimum | Attacker lost 0.2 tokens |
| Same, push past the minimum | Reverts the same way |

Hostile lunches, pool made before `serve`:

| Case | Result |
|---|---|
| Pool started 100x too cheap, no liquidity | Opened at the raise price |
| Pool started 100x too dear, no liquidity | Opened at the raise price |
| 0.02 ETH of bids across the raise price | Opened 0.8% dear with 0.0156 ETH left for burns. Attacker lost 0.0039 of 0.02 ETH |
| 30,000 fundraise tokens offered just under the raise price | **`serve` bought 5,721 of them for 0.005768 ETH, 0.82% more than they cost.** The 1% pool fee goes to the offerer. Selling the rest still lost money overall |

### The fix

`serve` now stops its price-moving swap 1% short of the raise price on either side, so the fee it pays early liquidity never makes the trade worse than the fundraise's price. A pool someone started off-price opens 1% beside the raise price instead of on it, and about 1% of the pool's ETH (or tokens) is left for burns. First built as a 110 tick margin, then made exact after pass 9. 59 contract tests pass.

- [x] Codex pass 9 on the fix: HOLD, one Low it introduced and one Medium that was already there.

| Finding | Decision |
|---|---|
| Low: at the edge of the 110-tick margin, a pool opens 1.1% off and a fundraise holder sells into it 0.05% above cost (0.000022 ETH on a 100 ETH raise) | Fixed. The limits are now the exact prices where a trade costs the raise price after the 1% fee, as constants. `FairLunch` is 23,806 bytes, 770 spare. `test_serve_openingBesideTheRaisePriceGivesNoFreeTrade_dear` and `_cheap` |
| `test_serve_buysNoTokenOverTheRaisePrice` started inside the margin, so it proved nothing | Fixed: it starts outside now and `serve` trades through the offers |
| Medium, already there: liquidity added just ahead of a `burn` and removed after sells into it and earns its fee. 0.0004 ETH from a burn that spent 0.1 | Reproduced in `test_burn_liquidityAddedAheadTakesNoMoreThanTheBound`, which holds it under 2% of the burn's spend. Not fixed: any LP earns a burn's fee, and the bound is what limits the rest. In RISKS.md. **Open for jango:** tighten the 200 tick bound, or leave it |

- [x] Testnet recheck on the fixed contract (`0x3c4baf80021d73fba39d31b5d1abc065cd964ba1`, Arbitrum Sepolia only, projects 15 and 16). The same 30,000 offered tokens: `serve` bought none, and all 30,000 came back to the attacker with no ETH. That pool opened 0.4% cheap. The pool started 100x too cheap opened 1.1% cheap, with 0.00017 of 0.0156 ETH left for burns.

Testnet recheck of the exact limits (`0xb0444b7cb03dc5926a441a6967845cd22f0310cb`, Arbitrum Sepolia only, projects 17 and 18):

| Case | Result |
|---|---|
| Pool started 100x too cheap | Opened at 1,010,037 tokens per ETH, the cheap limit. 0.000156 of 0.0156 ETH left for burns |
| Pool started exactly at the dear limit | Opened there, 989,937 tokens per ETH, nothing left over |
| Buy 0.001 ETH from the cheap-limit pool | 939.8 tokens, under the fundraise's 1,000 |
| Sell 1,000 fundraise tokens into the dear-limit pool | 0.00094 ETH, under the 0.001 they cost |
| Liquidity added ahead of a `burn` on project 10, removed after | Attacker put in 0.000614 ETH and took out 0.000623: 0.000009 gained from a burn that spent 0.00102 (0.9%) |

- [x] Codex pass 10 on the exact limits (run on Daybreak Blue: gpt-6.1-sol withheld it for the hardware key). The serve Low is closed, rounding and all six boundary cases correct, no new revert, no profitable `serve` or `collect` sequence. **HOLD** on one thing: I had called 2% of a burn's spend the ceiling on what added liquidity takes. That holds from a quiet price (1.985%). Inventory bought cheaply after someone else's large sale takes more: 2.8% after a 600 tick drop, 4.7% after 1,000. RISKS.md and the test's name and comment now say so. Codex: a tighter bound doesn't make a ceiling, and hard prevention needs a different way to execute burns.

**Open for jango:** accept liquidity added ahead of burns as described in RISKS.md, or change how burns execute.

Site nits from jango (2026-11-12): action card left and numbers right, a two-sided swap box where either side can be typed with an arrow to switch, buttons as wide as their text, the phase card as wide as its text, "Cooking lunch" and "🥪 Lunch is served", a bar for the fundraise's time gone, "Lunch ingredients" on the create form, small Burn and Collect buttons beside what they'd move (with a new pool fees number), and a link to the pool on Uniswap. The pool's quoter only answers for an exact input, so typing the other side asks it a few times (`quoteSwapFor`).


## Router terminal and ERC-20 fundraises (2026-11-12)

jango: "juiceboxes can be set with a router terminal (use the registry) so that people can pay in other tokens and it resolves to the project's desired currency. make sure we support this. also allow lunch fundraises to be in ETH, USDC, or other ERC-20 with the whole system continuing to work as expected, well tested."

Refinement record. Objective: a lunch names one fundraise token (ETH or an ERC-20), every phase works the same in it, and anyone can pay in another token through the router terminal registry. System fit: the registry is a second terminal after `JBMultiTerminal` with no accounting contexts, as `REVDeployer` and `HomerunDeployer` wire it, so the router converts and then pays the project in its own token and the data hook sees a normal payment. Reuse: buyback hook 2.0.1 already sorts the pool's currencies and takes any terminal token, CCIP suckers already carry ERC-20s, core already scales weight by the token's decimals. Evidence: two research reports in this session (router at `origin/main` 1.4.1, registry `0xe0427f250fdb0379c8e98e884ee4570521208cbc` on every chain with the gateway as default, checked on-chain 2026-11-12; a full list of the ETH assumptions in `src` and `web`). Unknowns: whether JBP6 takes a given ERC-20 as a fee, and which CCIP lanes carry a given token. Verification: the lifecycle fork tests run for ETH, USDC (6 decimals) and an 18-decimal ERC-20 on both sides of the token ordering, a routed payment test, two Codex passes, a testnet walk. Budget: contracts first, the site after the ABI settles; replan if `FairLunch` can't get under the size limit with the pool moved out.

Decisions taken, open to jango's correction:

- Price stays 1,000,000 tokens per whole unit of the fundraise token (per ETH, per USDC), whatever its decimals.
- The pool's work (open, corrective swap, burn's swap, collect, the price bound) moves to its own contract that only `FairLunch` can call and that holds every position. `FairLunch` has 770 bytes spare and token ordering makes every direction two-sided.
- An ERC-20 lunch with copies names each chain's token address in its config. Nothing on chain can check that two addresses are the same asset, so a wrong one strands what's paid on that copy, the same as a pair Chainlink doesn't carry today. Payers on copies get no tokens either way.
- If JBP6 can't take the token: `collect` adds the money-side pool fees to the lunch's balance instead of paying JBP6, and the payout fee at `serve` is held by the router terminal gateway as a pending call that refunds to the lunch's balance after three failures over three days (traced on a fork, 2026-11-12). With USDC the fee reaches JBP6 and the creator gets its tokens.
- A token that takes a fee on transfer or rebases isn't supported: `createFor` can't detect it, RISKS.md says so.

Tasks:

- [x] Refactor, no behavior change: move pool code to `FairLunchPool`, 59 tests green.
- [x] Add the registry as the second terminal on hosts and copies; test a USDC payment into an ETH lunch while cooking and a quoted one after serve.
- [x] `token` in the config and record; accounting context, base currency, payouts, balance reads, add to balance, sucker mappings and `sendHome` use it.
- [x] Pool: sorted currencies, raise price and serve limits from decimals and ordering, both-direction settle, burn bound on the right side.
- [x] Tests: the lifecycle suite parameterized over ETH, USDC and an 18-decimal token ground to each ordering; cross-chain USDC; fuzz the sandwich and early-pool cases in each.
- [x] Site: token choice on create, amounts in the token's decimals and symbol, approvals for ERC-20 pays, "pay with another token" through the registry with a router quote.
- [x] RISKS.md, README, two Codex passes, testnet redeploy and walk.

Review so far (2026-11-12):

- Codex pass 11: no findings. Pass 12: five items, all addressed in `4280ba5`: the pool takes at most `type(uint120).max` tokens' worth of money and the rest waits for `burn`; `buy` spends nothing when its bound falls off the price range; `collect` adds the money to the lunch's balance if JBP6 refuses it; the raise price keeps full precision below 1; RISKS.md names pausable, blockable and upgradeable tokens. Pass 13: those four fixes correct, one Medium left (a token with more than 24 decimals could block `serve`), closed by rejecting it in `createFor`.
- Testnet: `0x62e3f452f43315a26de300652760f1a51fb55264` on Arbitrum Sepolia and Sepolia, deployed before the pass 12 and 13 fixes. Lunch 19 with copy 19 walked end to end: create on both, pay both, send home, serve, buy, claim, burn (bounded, 0.00027 of 0.024 ETH), collect. Sepolia needed `--gas-estimate-multiplier 800` for the deploy under its newer gas rules.
- Not yet redeployed to testnet with the pass 12 and 13 fixes.

- Contracts: `FairLunchPool` holds every position and does every swap, callable only by `FairLunch`. `FairLunch` takes `config.token`, lists the router terminal registry second, rejects JBP6 as money. Sizes: FairLunch 19,725 bytes, FairLunchPool 10,389.
- Tests: the 59 ETH tests unchanged and green. New `test/fork/FairLunchErc20.t.sol` runs create, pay, serve, buy, burn, the burn bound, collect, an early pool at either extreme, and fuzzed sandwiches and raises for USDC (6 decimals), an 18-decimal token sorted before the lunch's token and one sorted after. Routed payments both ways (USDC into an ETH lunch, ETH into a USDC lunch, cooking and served), the terminal order, the JBP6 rejection, and a USDC copy on Optimism sending home, all pass.
- The tests are not literally the lifecycle suite parameterized: the ETH suite stays as it was and the ERC-20 suite is a shorter one run three times. The ETH-only cases it doesn't repeat are the ones about ETH itself (a creator that rejects ETH, locked payers, JBP6 credit pauses).
- Site: amounts in the lunch's money everywhere, "Raise in" on create (ETH, USDC, or one token address on a single chain), an Allow step before an ERC-20 payment, and paying a cooking lunch in the other of ETH and USDC through the router terminal with a 99% minimum from a simulation. 19 site tests green, and the token address derivation was checked against a lunch the new contract made on the fork.
- Not in the site: buying a served lunch's token with another token (two swaps, two minimums). Uniswap's own page covers it.
- Found on the way: where JBP6's router can't swap a lunch's money, the 2.5% fee on the raise sits in the router gateway for three days of failed retries before it can be refunded into the lunch's balance. RISKS.md says so.



## Airdrop claims by merkle root (2026-11-12)

jango: "we should make it easy for someone to upload a merklee root for claims that get distributed at the start of the lunch is served phase."

Refinement record. Objective: a chef names a share of the supply and a list of addresses at creation; at `serve` that share is minted for the list, and anyone can deliver an address its part. System fit: one more mint beside the chef's vested one, sized from the same settled supply, so the pool, the fixed price and the burns don't change. Reuse: OpenZeppelin `MerkleProof`, the vesting mint's place in `serve`, Center's `pinJson` for the list. Evidence: `serve` already mints the chef's share from the final supply; `FairLunch` is 20,021 bytes with 4,555 spare, so the claims live in their own small contract as the vesting deployer does. Unknowns: how large a list the site can pin and read comfortably. Verification: fork tests for create, serve and claim (valid, repeated, wrong proof, unlisted), a fuzz over shares, a JS tree test whose root and proofs the contract accepts on the local fork, one Codex pass, the site tests. Budget: contract first, site after the ABI settles.

Decisions taken, open to jango's correction:

- The airdrop is its own share (`claimsPercent`), apart from the chef's vested tokens. jango (2026-11-12): no 50% or 90% caps, the only rule is that chef tokens plus airdrop come to under 100% of supply. The chef's keep of the raise stays capped at 50%.
- A list entry is an address and its share of the airdrop out of 1e18. The site turns a CSV of `address,amount` into shares. The root is fixed at creation and is part of the terms that set the token's address.
- Claims are on the host chain, open from `serve`, never expire, and anyone can send one: the tokens go to the listed address. Nobody can change or reclaim the list.
- The list is pinned to IPFS and named in the lunch's metadata so the site can build proofs.

- [x] `FairLunchClaims` and the `claimsPercent`, `claimsRoot` terms; `serve` mints and funds; tests.
- [x] RISKS.md and README; Codex pass.
- [x] Site: CSV on the create form, the airdrop in the token pie, a claim row on the served page; tests.
- [x] Local fork check with a real list.

Review. Codex pass 14 on `56858ae` said hold: High, a lunch with no chef tokens and no airdrop divided by zero in `serve` (fixed, `test_serve_noCreatorShares` passes again); Medium, the committed site used the old create call (the site wiring lands with this change); Low, a root naming an address twice pays only the entry claimed first (the site's list builder merges duplicates, RISKS.md says so for roots made elsewhere). Full suite before the cap change: 109 of 111, the two failures being test bounds, fixed and rerun. On the Base fork, lunch 42 took a 30% airdrop, and a proof built by the site's `claimProofOf` delivered a listed address its 40%. Not checked: the Claim button with a connected wallet, since the fork lunch has no pinned list.

Follow-ups the same day. jango: show the airdrop on the ready-to-serve and served pages with the recipients expandable, show the starting token pie on the served page, food emojis for the airdrop fields. Done: an expandable Airdrop row on both pages lists recipients (20 at a time, find by address, Claim per row once served, the list checked against the on-chain root), `readServed` reads the lunch's `Serve` event for the served page's pie, and `assetUrl` uses the configured Center origin. Codex pass 15 on the cap removal said hold for one Medium: at shares near 100% a raise in a token with around 5e29 units paid could exceed Juicebox's uint208 supply cap and fail to serve. Not changed in code, since it needs both an absurd token and absurd shares; RISKS.md says so. Open for jango: accept that, or bound the shares (99% would give a 100x ceiling). Its Low (duplicate addresses) was already documented, and its note that claims can be one token-wei short is left alone.


## Other chains closed during the raise (2026-11-12)

jango: "maybe better to only allow funds on home chain during the raise phase", then "do it. also, can you mitigate the side effect?" (money delivered between the deadline and serve counting as raised).

Refinement record. Objective: nobody can pay a lunch's copy and get nothing while the host sells tokens, and only money that bought tokens is the raise. System fit: one check in the data hook's pay path on copies (the deadline is in every copy's terms, no message needed), and `serve` sizes the raise from the supply payers hold instead of the whole balance. Not changed: `sendHome`, the bridge route checks, what copies do after the deadline.

- [x] Data hook refuses a copy's payments until the deadline (`FairLunchDataHook_NotOpenYet`).
- [x] `serve` burns carrier tokens first and takes `min(balance, supply at the fixed price)` as the raise; the rest waits for `burn`.
- [x] Tests: `test_remote_refusesPaymentsUntilTheDeadline`, `test_host_claimBeforeServe_waitsForTheBurn`; remote tests pay after the deadline.
- [x] Site: `raisedOf` for the Raised number, pies and phase; Delivery hidden while cooking. README and RISKS.md.
- [x] Codex pass, local fork rebuild, testnet redeploy.

Codex pass 16 said hold: Medium, the raise follows the supply, so payers burning their own tokens before serve move their money to the burn, and a lunch whose every payer burned everything can't be served; Low, a router that holds failed payments can deliver a copy payment made during the raise after the deadline for nothing. Neither changed in code: the first costs the burner their whole payment and strands only what the burners paid, the second ends where any post-deadline copy payment does. Both are in RISKS.md. Open for jango: accept, or record payments in a pay hook as Codex suggests.

Review. Full suite 112 of 112. Site 22 of 22. A lunch nobody funded on the host can't be served, as before, and money paid on its copies after the deadline stays there; RISKS.md says so.

Testnet. `0x9770a2cae790e496a449b38e18f8778ce2737860` on Arbitrum Sepolia and Sepolia, from the testnet key, with everything through `de65473`. Lunch 20 with copy 20, a 60% airdrop: the copy refused a payment during the raise (`FairLunchDataHook_NotOpenYet`), took 0.004 ETH after the deadline and sent it home, `serve` minted 35,600 tokens for the list from a 0.01 ETH raise (10,000 sold, 7,800 pooled, 60% of the final supply), and a proof from the site's `claimProofOf` delivered one listed address its 40%. The bridged 0.004 ETH was still on its way at the end of the walk.

## Refunds during the fundraise

jango: "allow user refunds during the fund period only. this makes sense as they reassess the market cap".

- [x] `FairLunchDataHook.beforeCashOutRecordedWith`: on the host, before `serve`, a cash out up to the deadline pays back the fixed price with no tax. The count is scaled down when the balance holds more than the tokens were sold for, so donated money isn't refundable. After the deadline and before `serve` it reverts `FairLunchDataHook_Closed` instead of burning for nothing.
- [x] Tests: `test_refund_duringTheRaise` for ETH and the three ERC-20 setups.
- [x] Site: "You hold" row with a Refund button on the funding card, copy changed from "No refunds".
- [x] README and RISKS: refunds end at the deadline, a raise can shrink at the last second.
- [x] Codex review, pass 17: HOLD for two Mediums and a stale test. Fixed: a refund count rounded down twice could pay nothing with donated money in the balance (now rounded up, `test_refund_ofTheSmallestPayment`), and the stale test is gone. Accepted and written into RISKS.md: Juicebox's 2.5% fee on refunds up to the fee-free surplus another project pays in. The site's refund asks for at least 97% of the price.

## The clock in rulesets

jango: "can we move the clock into the rulesets too?" then "do it".

- [x] Host: funding ruleset lasting to the deadline (sells, untaxed cash outs), then a closed one (payments paused). Copies: paused to the deadline, then open at weight 0. `serve` needs the closed ruleset current and queues the last as before.
- [x] `FairLunchRecord` drops `deadline` and `servedAt`. `FairLunch.servedAtOf` reads the served time from the current ruleset; `burn`, `collect` and the hook use it.
- [x] Hook: an untaxed ruleset means refund, a priced one means sell, and anything else is closed unless served. A cash out on a copy now reverts where it burned for nothing.
- [x] Site: `readClock` derives started, deadline and served times from the current ruleset. Cooking ends at the deadline's own second.
- [x] Tests updated, duration bound test added. 108 non-fuzz tests passed on first run.
- [x] Codex pass 18: DO NOT MERGE for a Medium in the refund count (rounding up could hand a 24-decimal lunch's single token the whole balance), a Low (a one-second fundraise couldn't be served in its first second) and stale record docs. Fixed in `eb4decb`: the count is the largest that pays no more than the price, a refund of nothing reverts, host deadlines are two seconds out at least. Ruleset mechanics verified against the pinned core.
- [x] Codex pass 19: HOLD for a Medium (a same-terminal payout buys tokens fee-free and the next refund pays its fee). Fixed in `80be76c`: a selling lunch refuses payouts.
- [x] Codex pass 20: no findings, MERGE, 121 tests passed in its run. Verdict only: the PR stays unmerged until jango approves.
- [x] Local fork rebuilt on the new contract. Refund of 1M tokens returned exactly 1 ETH, copy payment refused by the pause, pages render.
- [ ] Testnet redeploy and walk.
