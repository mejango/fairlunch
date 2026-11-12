// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @notice Someone trading in a lunch's pool for themselves: swapping, trading around another call in the same
/// transaction, and making the pool early with their own liquidity. The fork tests use it as the adversary, and it's
/// deployed to testnets to measure the same things with real transactions. Only its deployer can use it.
contract PoolProbe is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    event Sandwich(address target, bool ethFirst, uint256 push, uint256 back, bytes result);
    event Seed(uint256 positionId, uint128 liquidity);
    event Swap(bool zeroForOne, uint256 amountIn, uint256 received);

    address internal immutable OWNER = msg.sender;
    IPoolManager internal immutable POOL_MANAGER;
    IPositionManager internal immutable POSITION_MANAGER;
    IAllowanceTransfer internal immutable PERMIT2;

    constructor(IPositionManager positionManager, IAllowanceTransfer permit2) {
        POSITION_MANAGER = positionManager;
        POOL_MANAGER = positionManager.poolManager();
        PERMIT2 = permit2;
    }

    modifier onlyOwner() {
        require(msg.sender == OWNER, "not the owner");
        _;
    }

    receive() external payable {}

    /// @notice Sell an exact amount of the pool's currency0 (`zeroForOne`) or of its currency1 into the pool, at any
    /// price.
    function swap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn
    )
        public
        payable
        onlyOwner
        returns (uint256 received)
    {
        if (amountIn == 0) return 0;
        received = abi.decode(POOL_MANAGER.unlock(abi.encode(key, zeroForOne, amountIn)), (uint256));
        emit Swap(zeroForOne, amountIn, received);
    }

    /// @notice Trade `push` into the pool, make a call, and trade what the push bought back out, all at once.
    /// @param ethFirst Whether the push sells the pool's currency0 (true), which is ETH in an ETH lunch, or its
    /// currency1.
    /// @return back What came back, in what was pushed. More than `push` is a profit.
    /// @return result What the call returned.
    function sandwich(
        PoolKey calldata key,
        bool ethFirst,
        uint256 push,
        address target,
        uint256 value,
        bytes calldata data
    )
        external
        payable
        onlyOwner
        returns (uint256 back, bytes memory result)
    {
        uint256 got = swap(key, ethFirst, push);
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        back = swap(key, !ethFirst, got);
        emit Sandwich(target, ethFirst, push, back, result);
    }

    /// @notice Make the pool at a price if nobody has, and put liquidity in a range of it.
    function seed(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0,
        uint128 amount1
    )
        external
        payable
        onlyOwner
        returns (uint256 positionId)
    {
        (uint160 current,,,) = POOL_MANAGER.getSlot0(key.toId());
        if (current == 0) {
            POOL_MANAGER.initialize(key, sqrtPriceX96);
            current = sqrtPriceX96;
        }
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            current, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount0, amount1
        );
        if (liquidity == 0) return 0;

        uint256 value = _allow(key.currency0, amount0);
        _allow(key.currency1, amount1);

        positionId = POSITION_MANAGER.nextTokenId();
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, tickLower, tickUpper, uint256(liquidity), amount0, amount1, address(this), "");
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this));
        POSITION_MANAGER.modifyLiquidities{value: value}(abi.encode(actions, params), block.timestamp);
        emit Seed(positionId, liquidity);
    }

    /// @notice Take a seeded position back out, with its fees.
    function unseed(PoolKey calldata key, uint256 positionId) external onlyOwner {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(positionId, uint128(0), uint128(0), "");
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @notice Send everything held back to the deployer.
    function withdraw(IERC20 token) external onlyOwner {
        if (address(token) != address(0)) {
            _call(address(token), abi.encodeCall(IERC20.transfer, (OWNER, token.balanceOf(address(this)))));
        }
        (bool ok,) = OWNER.call{value: address(this).balance}("");
        require(ok);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "not the pool manager");
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (Currency sold, Currency bought) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint256 owed = uint128(-(zeroForOne ? delta.amount0() : delta.amount1()));
        uint256 received = uint128(zeroForOne ? delta.amount1() : delta.amount0());
        if (sold.isAddressZero()) {
            POOL_MANAGER.settle{value: owed}();
        } else {
            POOL_MANAGER.sync(sold);
            _call(Currency.unwrap(sold), abi.encodeCall(IERC20.transfer, (address(POOL_MANAGER), owed)));
            POOL_MANAGER.settle();
        }
        POOL_MANAGER.take(bought, address(this), received);
        return abi.encode(received);
    }

    /// @notice Let the position manager pull an amount of a currency. Returns the ETH to send instead, if it's ETH.
    function _allow(Currency currency, uint128 amount) internal returns (uint256 value) {
        if (currency.isAddressZero()) return amount;
        address token = Currency.unwrap(currency);
        _call(token, abi.encodeCall(IERC20.approve, (address(PERMIT2), amount)));
        PERMIT2.approve(token, address(POSITION_MANAGER), amount, uint48(block.timestamp));
    }

    /// @notice Call a token without reading what it returns: some return nothing.
    function _call(address token, bytes memory data) internal {
        (bool ok,) = token.call(data);
        require(ok, "token call failed");
    }
}
