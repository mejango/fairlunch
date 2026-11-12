// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGeomeanOracle} from "@bananapus/univ4-router-v6/src/interfaces/IGeomeanOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
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

    /// @notice The pool price that matches the fundraise's price: the square root of 1,000,000 tokens per ETH, as a
    /// Q64.96. ETH is always currency0, so the pool's price is tokens per ETH.
    uint160 internal constant _RAISE_SQRT_PRICE_X96 = 1000 << 96;

    /// @notice The pool prices where trading costs exactly the fundraise's price once the pool's 1% fee is counted:
    /// 1% more tokens per ETH than the fundraise gave (`_SERVE_CHEAPEST_SQRT_PRICE_X96`) and 1% fewer
    /// (`_SERVE_DEAREST_SQRT_PRICE_X96`). `open` only trades through a pool someone made early outside of these, and a
    /// pool that opens between them gives no trade against it that beats the fundraise.
    uint160 internal constant _SERVE_CHEAPEST_SQRT_PRICE_X96 = 79_627_299_360_338_032_629_969_613_668_148;
    uint160 internal constant _SERVE_DEAREST_SQRT_PRICE_X96 = 78_831_026_366_734_652_303_669_917_531_468;

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

    /// @notice Accept ETH from the pool manager and the position manager.
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Buy a lunch's token from its pool with the ETH sent, as far as the price bound allows.
    /// @dev The buy stops at a price `maxDeviation` ticks above the reference from `_boundTickOf`. The tokens bought
    /// and the ETH the buy couldn't spend go back to `LUNCH`.
    /// @param key The pool's key.
    /// @param twapWindow The number of seconds of price history the buy is bounded by.
    /// @param maxDeviation The farthest the buy can push the price past that history's average, in ticks.
    /// @return spent The amount of ETH spent.
    function buy(
        PoolKey calldata key,
        uint32 twapWindow,
        int24 maxDeviation
    )
        external
        payable
        onlyLunch
        returns (uint256 spent)
    {
        // Buying the token lowers the pool's tokens-per-ETH price, so the bound sits below the reference.
        uint160 sqrtPriceLimitX96 =
            TickMath.getSqrtPriceAtTick(_boundTickOf({key: key, twapWindow: twapWindow}) - maxDeviation);

        // slither-disable-next-line unused-return
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        if (sqrtPriceX96 > sqrtPriceLimitX96) {
            (spent,) = _swap({key: key, zeroForOne: true, amountIn: msg.value, sqrtPriceLimitX96: sqrtPriceLimitX96});
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

    /// @notice Put the ETH sent and the tokens this contract was given into a lunch's pool as one full-range position.
    /// @dev Anyone can create the pool, or add liquidity to it, before the lunch is served. So before adding liquidity,
    /// this trades toward the fundraise's price with that price as the limit. An empty pool moves there for free. Any
    /// liquidity in the way is traded against at a price better for the lunch than the fundraise's price: tokens
    /// offered below it are bought, and ETH bid above it is sold to. Whatever the price didn't take goes back to
    /// `LUNCH`.
    /// @param key The pool's key.
    /// @param tokens The number of tokens to pool, already sent to this contract.
    /// @return positionId The ID of the position.
    function open(PoolKey calldata key, uint256 tokens) external payable onlyLunch returns (uint256 positionId) {
        uint256 eth = msg.value;

        // slither-disable-next-line unused-return
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());

        if (sqrtPriceX96 == 0) {
            // Nobody made the pool yet. Open it at the fundraise's price.
            // slither-disable-next-line unused-return
            POOL_MANAGER.initialize({key: key, sqrtPriceX96: _RAISE_SQRT_PRICE_X96});
        } else {
            // Trade toward the fundraise's price only where the pool's price beats it by more than the pool's fee.
            // The fee goes to whoever left liquidity there, so trading any closer would sell them tokens for less
            // than the fundraise charged, or buy tokens back from them for more.
            if (sqrtPriceX96 > _SERVE_CHEAPEST_SQRT_PRICE_X96) {
                // Tokens are cheaper than that. Buy them down to it, with at most half the ETH so there's always a
                // position left to make however much liquidity is in the way.
                (uint256 spent, uint256 received) = _swap({
                    key: key, zeroForOne: true, amountIn: eth / 2, sqrtPriceLimitX96: _SERVE_CHEAPEST_SQRT_PRICE_X96
                });
                eth -= spent;
                tokens += received;
            } else if (sqrtPriceX96 < _SERVE_DEAREST_SQRT_PRICE_X96) {
                // Tokens are dearer than that. Sell them up to it, with at most half the tokens.
                (uint256 spent, uint256 received) = _swap({
                    key: key, zeroForOne: false, amountIn: tokens / 2, sqrtPriceLimitX96: _SERVE_DEAREST_SQRT_PRICE_X96
                });
                tokens -= spent;
                eth += received;
            }
        }

        // Size the position at wherever the price ended up.
        // slither-disable-next-line unused-return
        (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts({
            sqrtPriceX96: sqrtPriceX96,
            sqrtPriceAX96: TickMath.getSqrtPriceAtTick(tickLower),
            sqrtPriceBX96: TickMath.getSqrtPriceAtTick(tickUpper),
            amount0: eth,
            amount1: tokens
        });

        // Someone traded one whole side away at a better-than-fundraise price. Arbitrage will clear that; try again.
        if (liquidity == 0) revert FairLunchPool_NoLiquidity();

        // Let the position manager pull the tokens through Permit2, for this call only.
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        token.forceApprove({spender: address(PERMIT2), value: tokens});
        PERMIT2.approve({
            token: address(token),
            spender: address(POSITION_MANAGER),
            amount: tokens.toUint160(),
            expiration: uint48(block.timestamp)
        });

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
            key, tickLower, tickUpper, uint256(liquidity), eth.toUint128(), tokens.toUint128(), address(this), ""
        );
        params[1] = abi.encode(key.currency0, uint256(0), true);
        params[2] = abi.encode(key.currency1, uint256(0), true);
        params[3] = abi.encode(key.currency0, address(this));
        params[4] = abi.encode(key.currency1, address(this));
        POSITION_MANAGER.modifyLiquidities{value: eth}({
            unlockData: abi.encode(actions, params), deadline: block.timestamp
        });

        // Leave no pull authority behind.
        PERMIT2.approve({token: address(token), spender: address(POSITION_MANAGER), amount: 0, expiration: 1});
        token.forceApprove({spender: address(PERMIT2), value: 0});

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
            if (zeroForOne) {
                // slither-disable-next-line unused-return
                POOL_MANAGER.settle{value: spent}();
            } else {
                POOL_MANAGER.sync(key.currency1);
                IERC20(Currency.unwrap(key.currency1)).safeTransfer({to: address(POOL_MANAGER), value: spent});
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

    /// @notice Send everything this contract holds of a pool's two currencies to `LUNCH`.
    /// @param key The pool's key.
    function _returnAll(PoolKey calldata key) internal {
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        uint256 tokens = token.balanceOf(address(this));
        if (tokens != 0) token.safeTransfer({to: LUNCH, value: tokens});

        uint256 eth = address(this).balance;
        if (eth != 0) Address.sendValue({recipient: payable(LUNCH), amount: eth});
    }

    /// @notice Swap an exact input in a lunch's pool, stopping at a price limit.
    /// @param key The pool's key.
    /// @param zeroForOne Whether ETH is being sold for tokens (true) or tokens for ETH (false).
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
    /// or its tick a second ago if that's higher (cheaper tokens).
    /// @dev The average keeps a buyback from chasing a price that was pushed up over several blocks. The tick a second
    /// ago is the price before anything traded in this block, which keeps a buyback from chasing a price that was
    /// pushed up just ahead of it. Reverts if the pool's history doesn't reach `twapWindow` back.
    /// @param key The pool's key.
    /// @param twapWindow The number of seconds to average over.
    /// @return tick The reference tick, rounded toward negative infinity.
    function _boundTickOf(PoolKey calldata key, uint32 twapWindow) internal view returns (int24 tick) {
        uint32[] memory secondsAgos = new uint32[](3);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 1;

        // slither-disable-next-line unused-return
        (int56[] memory tickCumulatives,) = ORACLE_HOOK.observe({key: key, secondsAgos: secondsAgos});

        int56 delta = tickCumulatives[2] - tickCumulatives[0];
        tick = int24(delta / int56(uint56(twapWindow)));
        if (delta < 0 && delta % int56(uint56(twapWindow)) != 0) tick--;

        // Over one second the cumulative's change is the tick itself.
        int24 lastTick = int24(tickCumulatives[2] - tickCumulatives[1]);
        if (lastTick > tick) tick = lastTick;
    }
}
