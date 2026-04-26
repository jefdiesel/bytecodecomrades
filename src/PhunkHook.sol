// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks}        from "v4-core/interfaces/IHooks.sol";
import {IPoolManager}  from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}       from "v4-core/types/PoolKey.sol";
import {BalanceDelta}  from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

import {ISeedSource} from "./ISeedSource.sol";

/// @notice Re-rolls an on-chain seed every time the v4 PoolManager calls afterSwap.
/// Only afterSwap is enabled; every other hook reverts so a misconfigured pool
/// can't accidentally route through us.
contract PhunkHook is IHooks, ISeedSource {
    IPoolManager public immutable poolManager;

    bytes32 public override currentSeed;
    uint64  public override swapCount;

    error NotPoolManager();
    error HookNotImplemented();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _pm) {
        poolManager = _pm;
        currentSeed = keccak256(abi.encode(block.prevrandao, block.timestamp, block.number, address(this)));
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        unchecked { swapCount++; }
        currentSeed = keccak256(
            abi.encode(currentSeed, swapCount, block.prevrandao, block.timestamp, block.number)
        );
        return (IHooks.afterSwap.selector, 0);
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
