// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}        from "forge-std/Script.sol";
import {IPoolManager}            from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}                  from "v4-core/interfaces/IHooks.sol";
import {PoolKey}                 from "v4-core/types/PoolKey.sol";
import {Currency}                from "v4-core/types/Currency.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

interface IBCC { function approve(address, uint256) external returns (bool); function setSkip(address,bool) external; }
interface IWETHFunds { function deposit() external payable; function approve(address,uint256) external returns (bool); }

/// Add a thicker LP position that won't exhaust on small test swaps.
/// Range: ~720 ticks wide, liquidity 1e17 (100x the seed). Plenty for testnet poking.
contract AddMoreLP is Script {
    function run() external {
        address comrade = vm.envAddress("COMRADE");
        address poolMgr = vm.envAddress("POOL_MANAGER");
        address hook    = vm.envAddress("HOOK");
        address weth    = vm.envAddress("WETH");
        address lpRouter= vm.envAddress("LP_ROUTER");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(comrade), currency1: Currency.wrap(weth),
            fee: 3000, tickSpacing: 60, hooks: IHooks(hook)
        });

        vm.startBroadcast();
        IBCC(comrade).approve(lpRouter, type(uint256).max);
        IWETHFunds(weth).deposit{value: 0.1 ether}();
        IWETHFunds(weth).approve(lpRouter, type(uint256).max);

        // Wide bracket with enough liquidity to absorb dozens of test buys.
        // Range -82000..-78000 (4000 ticks), liquidity 1e19 → many BCC of capacity.
        IPoolManager.ModifyLiquidityParams memory mlp = IPoolManager.ModifyLiquidityParams({
            tickLower: -82020, tickUpper: -78000, liquidityDelta: 1e19, salt: bytes32(0)
        });
        PoolModifyLiquidityTest(lpRouter).modifyLiquidity(key, mlp, "");
        vm.stopBroadcast();
        console2.log("Added LP, liquidity 1e19 across [-82000, -78000]");
    }
}
