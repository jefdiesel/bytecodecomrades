// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}        from "forge-std/Script.sol";
import {IPoolManager}            from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}                  from "v4-core/interfaces/IHooks.sol";
import {PoolKey}                 from "v4-core/types/PoolKey.sol";
import {Currency}                from "v4-core/types/Currency.sol";
import {TickMath}                from "v4-core/libraries/TickMath.sol";
import {StateLibrary}            from "v4-core/libraries/StateLibrary.sol";
import {PoolId}                  from "v4-core/types/PoolId.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts}        from "v4-periphery/libraries/LiquidityAmounts.sol";

interface IBCC { function approve(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }

/// Seed the Sepolia pool with the launch-curve LP (9500 BCC across 3 single-sided
/// positions matching the mainnet plan). Auto-corrects pool tick if it drifted.
contract SeedLaunchLP is Script {
    using StateLibrary for IPoolManager;

    int24 constant ANCHOR_TICK = -80040;  // ~$1/BCC at $3k ETH, aligned to spacing 60

    // Position 1: $1-$100   = ticks -80040..-34020,  7125 BCC (75%)
    // Position 2: $100-$400 = ticks -34020..-20160,  1710 BCC (18%)
    // Position 3: $400-$1111= ticks -20160..-9960,    665 BCC (7%)

    function run() external {
        address comrade = vm.envAddress("COMRADE");
        address poolMgr = vm.envAddress("POOL_MANAGER");
        address hook    = vm.envAddress("HOOK");
        address weth    = vm.envAddress("WETH");
        address lpRouter= vm.envAddress("LP_ROUTER");

        IPoolManager pm = IPoolManager(poolMgr);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(comrade), currency1: Currency.wrap(weth),
            fee: 3000, tickSpacing: 60, hooks: IHooks(hook)
        });
        PoolId pid = _id(key);

        (uint160 sqrtP, int24 currentTick,,) = pm.getSlot0(pid);
        console2.log("current tick:");
        console2.logInt(currentTick);
        console2.log("sqrtPriceX96:", sqrtP);

        require(currentTick <= ANCHOR_TICK, "tick above anchor - sell BCC into pool to recover first");

        vm.startBroadcast();
        IBCC(comrade).approve(lpRouter, type(uint256).max);

        // Position 1: 7125 BCC, ticks -80040..-34020
        _addPosition(lpRouter, key, -80040, -34020, 7125 ether);
        // Position 2: 1710 BCC, ticks -34020..-20160
        _addPosition(lpRouter, key, -34020, -20160, 1710 ether);
        // Position 3:  665 BCC, ticks -20160..-9960
        _addPosition(lpRouter, key, -20160, -9960, 665 ether);

        vm.stopBroadcast();

        uint256 remaining = IBCC(comrade).balanceOf(msg.sender);
        console2.log("BCC left in deployer wallet:", remaining / 1 ether);
    }

    function _addPosition(address lpRouter, PoolKey memory key, int24 lower, int24 upper, uint256 bccAmount) internal {
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(upper);
        // For single-sided token0 (BCC) when current tick < tickLower:
        // amount0 = L * (sqrtU - sqrtL) / (sqrtL * sqrtU / Q96)
        // Use the periphery helper:
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sqrtL, sqrtU, bccAmount);
        IPoolManager.ModifyLiquidityParams memory mlp = IPoolManager.ModifyLiquidityParams({
            tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liq)), salt: bytes32(0)
        });
        PoolModifyLiquidityTest(lpRouter).modifyLiquidity(key, mlp, "");
        console2.log("position added: BCC =", bccAmount / 1 ether, "liquidity =", liq);
    }

    function _id(PoolKey memory key) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }
}
