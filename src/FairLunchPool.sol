// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice The holder of every lunch's liquidity, and the only thing that trades for a lunch in its pool.
/// @dev A pool pairs the lunch's token with what the lunch raises in, called the money here: ETH or an ERC-20. Which
/// of the two is the pool's currency0 depends on their addresses, so every function takes `moneyIs0` and works in
/// either order.
/// @dev `FairLunch` deploys this and is the only caller it takes. Each call is handed what to work with and hands back
/// everything that's left, so this contract holds positions and nothing else between calls. No function removes
/// liquidity.
contract FairLunchPool is IUnlockCallback, IERC721Receiver {
    // A library that reverts instead of truncating when narrowing a number.
    using SafeCast for uint256;

    // A library that adds default safety checks to ERC-20 functionality.
    using SafeERC20 for IERC20;

    // A library that derives a Uniswap V4 pool's ID from its key.
    using PoolIdLibrary for PoolKey;

    // A library that reads Uniswap V4 pool state.
    using StateLibrary for IPoolManager;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error FairLunchPool_NoLiquidity();
    error FairLunchPool_Unauthorized(address caller);

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice How far a pool's square root price sits from the fundraise's where trading costs exactly the
    /// fundraise's price once the pool's 1% fee is counted: the square roots of 100/99 and of 99/100, with 36
    /// decimals. `open` only trades through a pool someone made early outside of these, and a pool that opens between
    /// them gives no trade against it that beats the fundraise.
    uint256 internal constant _FEE_NEUTRAL_UP = 1_005_037_815_259_212_075_489_373_556_566_874_752;
    uint256 internal constant _FEE_NEUTRAL_DOWN = 994_987_437_106_619_954_734_479_821_001_206_006;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The only address this contract takes calls from.
    address public immutable LUNCH;

    /// @notice The Permit2 contract the position manager pulls tokens through.
    IAllowanceTransfer public immutable PERMIT2;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The Uniswap V4 hook every lunch's pool uses, which records the price history buybacks are bounded by.
    /// @dev Set once by `LUNCH`. Zero until then.
    IGeomeanOracle public ORACLE_HOOK;

    /// @notice The Uniswap V4 pool manager.
    /// @dev Set once by `LUNCH`. Zero until then.
    IPoolManager public POOL_MANAGER;

    /// @notice The Uniswap V4 position manager.
    /// @dev Set once by `LUNCH`. Zero until then.
    IPositionManager public POSITION_MANAGER;

    //*********************************************************************//
    // ---------------------------- modifiers ---------------------------- //
    //*********************************************************************//

    modifier onlyLunch() {
        if (msg.sender != LUNCH) revert FairLunchPool_Unauthorized(msg.sender);
        _;
    }

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param permit2 The Permit2 contract the position manager pulls tokens through.
    constructor(IAllowanceTransfer permit2) {
        LUNCH = msg.sender;
        PERMIT2 = permit2;
    }

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    /// @notice Accept ETH from `LUNCH`, the pool manager and the position manager.
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Buy a lunch's token from its pool, as far as the price bound allows.
    /// @dev The buy stops `maxDeviation` ticks past the reference from `_boundTickOf`. The tokens bought and the money
    /// the buy couldn't spend go back to `LUNCH`.
    /// @param key The pool's key.
    /// @param moneyIs0 Whether the money is the pool's currency0.
    /// @param amount The amount of money to buy with, already sent to this contract (as `msg.value` if it's ETH).
    /// @param twapWindow The number of seconds of price history the buy is bounded by.
    /// @param maxDeviation The farthest the buy can push the price past that history's average, in ticks.
    /// @return spent The amount of money spent.
    function buy(
        PoolKey calldata key,
        bool moneyIs0,
        uint256 amount,
        uint32 twapWindow,
        int24 maxDeviation
    )
        external
        payable
        onlyLunch
        returns (uint256 spent)
    {
        // The bound sits `maxDeviation` ticks dearer than the reference, which is measured in ticks that rise as the
        // token gets cheaper. The pool's own ticks run that way when the money is currency0, and the other way when
        // it isn't.
        int24 boundTick = _boundTickOf({key: key, moneyIs0: moneyIs0, twapWindow: twapWindow}) - maxDeviation;
        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(moneyIs0 ? boundTick : -boundTick);

        // Buy only while the token is cheaper than the bound.
        // slither-disable-next-line unused-return
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        if (moneyIs0 ? sqrtPriceX96 > sqrtPriceLimitX96 : sqrtPriceX96 < sqrtPriceLimitX96) {
            (spent,) = _swap({key: key, zeroForOne: moneyIs0, amountIn: amount, sqrtPriceLimitX96: sqrtPriceLimitX96});
        }

        _returnAll(key);
    }

    /// @notice Collect a position's fees and send both sides to `LUNCH`.
    /// @dev The position's liquidity is never touched.
    /// @param key The pool's key.
    /// @param positionId The ID of the position.
    function collect(PoolKey calldata key, uint256 positionId) external onlyLunch {
        // Decreasing liquidity by zero collects the position's fees without touching its principal.
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, uint256(0), uint128(0), uint128(0), "");
        params[1] = abi.encode(key.currency0, key.currency1, LUNCH);
        POSITION_MANAGER.modifyLiquidities({unlockData: abi.encode(actions, params), deadline: block.timestamp});
    }

    /// @notice Accept only liquidity positions.
    /// @dev Part of `IERC721Receiver`.
    function onERC721Received(address, address, uint256, bytes calldata) external view override returns (bytes4) {
        if (msg.sender != address(POSITION_MANAGER)) revert FairLunchPool_Unauthorized(msg.sender);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Put the money and the tokens this contract was given into a lunch's pool as one full-range position.
    /// @dev The fundraise's price is `tokens` per `money`. Anyone can create the pool, or add liquidity to it, before
    /// the lunch is served. So before adding liquidity, this trades toward the fundraise's price. An empty pool moves
    /// there for free. Any liquidity in the way is traded against at a price better for the lunch than the
    /// fundraise's price: tokens offered below it are bought, and money bid above it is sold to. Whatever the price
    /// didn't take goes back to `LUNCH`.
    /// @param key The pool's key.
    /// @param moneyIs0 Whether the money is the pool's currency0.
    /// @param money The amount of money to pool, already sent to this contract (as `msg.value` if it's ETH).
    /// @param tokens The number of tokens to pool, already sent to this contract.
    /// @return positionId The ID of the position.
    function open(
        PoolKey calldata key,
        bool moneyIs0,
        uint256 money,
        uint256 tokens
    )
        external
        payable
        onlyLunch
        returns (uint256 positionId)
    {
        // The pool's price is its currency1 per currency0. Its square root, as a Q64.96, at the fundraise's price:
        uint160 raiseSqrtPriceX96 = (Math.sqrt(
                    moneyIs0 ? Math.mulDiv(tokens, 1 << 128, money) : Math.mulDiv(money, 1 << 128, tokens)
                ) << 32)
        .toUint160();

        // The prices where the token is 1% cheaper and 1% dearer than the fundraise's, each rounded toward it.
        // Cheaper is a higher price when the money is currency0, and a lower one when it isn't.
        uint160 cheapestSqrtPriceX96 = (moneyIs0
                ? Math.mulDiv(raiseSqrtPriceX96, _FEE_NEUTRAL_UP, 1e36)
                : Math.mulDiv(raiseSqrtPriceX96, _FEE_NEUTRAL_DOWN, 1e36, Math.Rounding.Ceil))
        .toUint160();
        uint160 dearestSqrtPriceX96 = (moneyIs0
                ? Math.mulDiv(raiseSqrtPriceX96, _FEE_NEUTRAL_DOWN, 1e36, Math.Rounding.Ceil)
                : Math.mulDiv(raiseSqrtPriceX96, _FEE_NEUTRAL_UP, 1e36))
        .toUint160();

        // slither-disable-next-line unused-return
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());

        if (sqrtPriceX96 == 0) {
            // Nobody made the pool yet. Open it at the fundraise's price.
            // slither-disable-next-line unused-return
            POOL_MANAGER.initialize({key: key, sqrtPriceX96: raiseSqrtPriceX96});
        } else {
            // Trade toward the fundraise's price only where the pool's price beats it by more than the pool's fee.
            // The fee goes to whoever left liquidity there, so trading any closer would sell them tokens for less
            // than the fundraise charged, or buy tokens back from them for more.
            if (moneyIs0 ? sqrtPriceX96 > cheapestSqrtPriceX96 : sqrtPriceX96 < cheapestSqrtPriceX96) {
                // Tokens are cheaper than that. Buy them up to it, with at most half the money so there's always a
                // position left to make however much liquidity is in the way.
                (uint256 spent, uint256 received) = _swap({
                    key: key, zeroForOne: moneyIs0, amountIn: money / 2, sqrtPriceLimitX96: cheapestSqrtPriceX96
                });
                money -= spent;
                tokens += received;
            } else if (moneyIs0 ? sqrtPriceX96 < dearestSqrtPriceX96 : sqrtPriceX96 > dearestSqrtPriceX96) {
                // Tokens are dearer than that. Sell them down to it, with at most half the tokens.
                (uint256 spent, uint256 received) = _swap({
                    key: key, zeroForOne: !moneyIs0, amountIn: tokens / 2, sqrtPriceLimitX96: dearestSqrtPriceX96
                });
                tokens -= spent;
                money += received;
            }
        }

        (uint256 amount0, uint256 amount1) = moneyIs0 ? (money, tokens) : (tokens, money);

        // Size the position at wherever the price ended up.
        // slither-disable-next-line unused-return
        (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts({
            sqrtPriceX96: sqrtPriceX96,
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(tickUpper),
            amount0: amount0,
            amount1: amount1
        });

        // Someone traded one whole side away at a better-than-fundraise price. Arbitrage will clear that; try again.
        if (liquidity == 0) revert FairLunchPool_NoLiquidity();

        // Let the position manager pull each side through Permit2, for this call only. ETH is sent with the call.
        _approve({currency: key.currency0, amount: amount0});
        _approve({currency: key.currency1, amount: amount1});

        // Mint the position to this contract, settle both sides, and sweep back what the price didn't take.
        positionId = POSITION_MANAGER.nextTokenId();
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liquidity), amount0.toUint128(), amount1.toUint128(), address(this), ""
        );
        params[1] = abi.encode(key.currency0, uint256(0), true);
        params[2] = abi.encode(key.currency1, uint256(0), true);
        params[3] = abi.encode(key.currency0, address(this));
        params[4] = abi.encode(key.currency1, address(this));
        POSITION_MANAGER.modifyLiquidities{value: key.currency0.isAddressZero() ? amount0 : 0}({
            unlockData: abi.encode(actions, params), deadline: block.timestamp
        });

        // Leave no pull authority behind.
        _approve({currency: key.currency0, amount: 0});
        _approve({currency: key.currency1, amount: 0});

        _returnAll(key);
    }

    /// @notice One-shot setter for this chain's Uniswap V4 addresses.
    /// @dev `LUNCH` calls this once, from its own one-shot setter.
    /// @param positionManager The Uniswap V4 position manager. The pool manager is read from it.
    /// @param oracleHook The Uniswap V4 hook every lunch's pool uses.
    function setChainSpecificConstants(IPositionManager positionManager, IGeomeanOracle oracleHook) external onlyLunch {
        POSITION_MANAGER = positionManager;
        POOL_MANAGER = positionManager.poolManager();
        ORACLE_HOOK = oracleHook;
    }

    /// @notice Swaps inside the pool manager's lock.
    /// @dev Part of `IUnlockCallback`. Only reachable through `_swap`.
    /// @param data The encoded pool key, direction, input amount and price limit.
    /// @return The encoded amounts spent and received.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert FairLunchPool_Unauthorized(msg.sender);

        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 sqrtPriceLimitX96) =
            abi.decode(data, (PoolKey, bool, uint256, uint160));

        // A negative amount means exact input. The swap stops early if it reaches the price limit.
        BalanceDelta delta = POOL_MANAGER.swap({
            key: key,
            params: SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            hookData: ""
        });

        // The input side is owed to the pool manager (negative) and the output side is owed to this contract.
        (int128 deltaIn, int128 deltaOut) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 spent = uint256(uint128(-deltaIn));
        uint256 received = uint256(uint128(deltaOut));

        if (spent != 0) {
            Currency currencyIn = zeroForOne ? key.currency0 : key.currency1;
            if (currencyIn.isAddressZero()) {
                // slither-disable-next-line unused-return
                POOL_MANAGER.settle{value: spent}();
            } else {
                POOL_MANAGER.sync(currencyIn);
                IERC20(Currency.unwrap(currencyIn)).safeTransfer({to: address(POOL_MANAGER), value: spent});
                // slither-disable-next-line unused-return
                POOL_MANAGER.settle();
            }
        }

        if (received != 0) {
            POOL_MANAGER.take({
                currency: zeroForOne ? key.currency1 : key.currency0, to: address(this), amount: received
            });
        }

        return abi.encode(spent, received);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Let the position manager pull an amount of an ERC-20 from this contract through Permit2, or stop it.
    /// @dev Does nothing for ETH.
    /// @param currency The currency to approve.
    /// @param amount The amount to allow. Zero takes the allowance away.
    function _approve(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) return;

        IERC20 token = IERC20(Currency.unwrap(currency));
        token.forceApprove({spender: address(PERMIT2), value: amount});
        PERMIT2.approve({
            token: address(token),
            spender: address(POSITION_MANAGER),
            amount: amount.toUint160(),
            expiration: amount == 0 ? 1 : uint48(block.timestamp)
        });
    }

    /// @notice Send everything this contract holds of a pool's two currencies to `LUNCH`.
    /// @param key The pool's key.
    function _returnAll(PoolKey calldata key) internal {
        _returnAllOf(key.currency0);
        _returnAllOf(key.currency1);
    }

    /// @notice Send everything this contract holds of a currency to `LUNCH`.
    /// @param currency The currency to send.
    function _returnAllOf(Currency currency) internal {
        if (currency.isAddressZero()) {
            uint256 eth = address(this).balance;
            if (eth != 0) Address.sendValue({recipient: payable(LUNCH), amount: eth});
            return;
        }

        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 balance = token.balanceOf(address(this));
        if (balance != 0) token.safeTransfer({to: LUNCH, value: balance});
    }

    /// @notice Swap an exact input in a lunch's pool, stopping at a price limit.
    /// @param key The pool's key.
    /// @param zeroForOne Whether the pool's currency0 is being sold for its currency1 (true) or the other way.
    /// @param amountIn The most to sell.
    /// @param sqrtPriceLimitX96 The price at which the swap stops.
    /// @return spent The amount sold.
    /// @return received The amount bought.
    function _swap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    )
        internal
        returns (uint256 spent, uint256 received)
    {
        if (amountIn == 0) return (0, 0);

        return
            abi.decode(
                POOL_MANAGER.unlock(abi.encode(key, zeroForOne, amountIn, sqrtPriceLimitX96)), (uint256, uint256)
            );
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice The tick a buyback's price bound is measured from: the pool's average tick over the last `twapWindow`,
    /// or its tick a second ago if the token was cheaper then.
    /// @dev Measured in ticks that rise as the token gets cheaper, whichever order the pool's currencies are in. The
    /// average keeps a buyback from chasing a price that was pushed up over several blocks. The tick a second ago is
    /// the price before anything traded in this block, which keeps a buyback from chasing a price that was pushed up
    /// just ahead of it. Reverts if the pool's history doesn't reach `twapWindow` back.
    /// @param key The pool's key.
    /// @param moneyIs0 Whether the money is the pool's currency0.
    /// @param twapWindow The number of seconds to average over.
    /// @return tick The reference tick, rounded toward negative infinity.
    function _boundTickOf(PoolKey calldata key, bool moneyIs0, uint32 twapWindow) internal view returns (int24 tick) {
        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 1;

        // slither-disable-next-line unused-return
        (int56[] memory tickCumulatives,) = ORACLE_HOOK.observe({key: key, secondsAgos: secondsAgos});

        // Over one second the cumulative's change is the tick itself.
        int56 delta = tickCumulatives[2] - tickCumulatives[0];
        int24 lastTick = int24(tickCumulatives[2] - tickCumulatives[1]);

        // The pool's ticks fall as the token gets cheaper when the token is currency0.
        if (!moneyIs0) (delta, lastTick) = (-delta, -lastTick);

        tick = int24(delta / int56(uint56(twapWindow)));
        if (delta < 0 && delta % int56(uint56(twapWindow)) != 0) tick--;

        if (lastTick > tick) tick = lastTick;
    }
}
