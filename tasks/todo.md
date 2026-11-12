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
- [ ] Codex pass 7 on the rework.
- [ ] Redeploy to the testnets and walk it, with buy and sell.

Found on the way: the oracle hook reports no history until a pool has observations at two timestamps. In a served pool nothing has traded in, the buyback hook buys at the current price for small payments only, and won't sell without a named minimum. A trade slipped in ahead of `burn` writes the second observation, and the burn then holds to the average (`test_burn_doesntChaseAPushedPrice`).
