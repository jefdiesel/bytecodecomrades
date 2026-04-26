// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks}        from "v4-core/interfaces/IHooks.sol";
import {IPoolManager}  from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}       from "v4-core/types/PoolKey.sol";
import {BalanceDelta}  from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency}      from "v4-core/types/Currency.sol";

import {ISeedSource} from "./ISeedSource.sol";

/// @notice Re-rolls an on-chain seed every time the v4 PoolManager calls afterSwap.
/// Also captures a small protocol fee (default 0.1%) on every swap, taken in the
/// unspecified output currency. Fee accumulates inside the hook's currency balances
/// at the PoolManager and can be withdrawn by the owner.
///
/// REQUIRED ADDRESS BITS: afterSwap (1<<6) + afterSwapReturnsDelta (1<<2) = 0x44.
/// Mine via HookMiner before deploy (CREATE2 salt).
contract ComradeHook is IHooks, ISeedSource {
    IPoolManager public immutable poolManager;

    bytes32 public override currentSeed;
    uint64  public override swapCount;

    address public owner;
    /// @dev Fee in basis points (10000 = 100%). Default 10 = 0.1%.
    uint16  public feeBps = 10;

    error NotPoolManager();
    error NotOwner();
    error HookNotImplemented();
    error FeeTooHigh();

    event FeeBpsSet(uint16 bps);
    event FeesWithdrawn(Currency indexed currency, address indexed to, uint256 amount);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager _pm) {
        poolManager = _pm;
        owner = msg.sender;
        currentSeed = keccak256(abi.encode(block.prevrandao, block.timestamp, block.number, address(this)));
    }

    // -------- admin --------

    function setFeeBps(uint16 bps) external onlyOwner {
        if (bps > 100) revert FeeTooHigh(); // hard cap at 1%
        feeBps = bps;
        emit FeeBpsSet(bps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /// @notice Withdraw accumulated fees of a given currency from the PoolManager
    /// to a recipient. Hook's CurrencyDelta is settled via take().
    function withdrawFees(Currency currency, address to, uint256 amount) external onlyOwner {
        poolManager.unlock(abi.encode(currency, to, amount));
        emit FeesWithdrawn(currency, to, amount);
    }

    /// @notice PoolManager unlock callback. Called by manager.unlock() during withdrawFees.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        poolManager.take(currency, to, amount);
        return "";
    }

    // -------- hook entry point --------

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        unchecked { swapCount++; }
        currentSeed = keccak256(
            abi.encode(currentSeed, swapCount, block.prevrandao, block.timestamp, block.number)
        );

        // Compute fee on the OUTPUT side (unspecified currency).
        // For exactInput swap: amountSpecified < 0 (paid in), unspecified is the output amount.
        // For exactOutput swap: amountSpecified > 0 (received), unspecified is the input.
        // We want fee on what flowed back to the user. Use the absolute output of the swap.
        int128 unspecifiedDelta;
        if (params.amountSpecified < 0) {
            // exactInput: unspecified = amount1 if zeroForOne else amount0 (the side user receives)
            unspecifiedDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
        } else {
            // exactOutput: unspecified = amount0 if zeroForOne else amount1 (the side user pays)
            unspecifiedDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
        }
        uint128 absOut = unspecifiedDelta < 0 ? uint128(-unspecifiedDelta) : uint128(unspecifiedDelta);
        uint128 fee = uint128((uint256(absOut) * uint256(feeBps)) / 10_000);

        // Returning a positive delta means "the hook took this much from the swap output".
        // PoolManager will charge the swapper accordingly.
        return (IHooks.afterSwap.selector, int128(fee));
    }

    // -------- disabled hooks --------

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterAddLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external pure returns (bytes4, BeforeSwapDelta, uint24) { revert HookNotImplemented(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
}
