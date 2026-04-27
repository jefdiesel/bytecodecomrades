// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}        from "forge-std/Script.sol";
import {IPoolManager}            from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}                  from "v4-core/interfaces/IHooks.sol";
import {PoolKey}                 from "v4-core/types/PoolKey.sol";
import {Currency}                from "v4-core/types/Currency.sol";
import {ComradeSwap, IERC20Min, IWETH9} from "../src/ComradeSwap.sol";

interface IBCC { function setSkip(address, bool) external; }

contract RedeploySwap is Script {
    function run() external {
        address comrade = vm.envAddress("COMRADE");
        address poolMgr = vm.envAddress("POOL_MANAGER");
        address hook    = vm.envAddress("HOOK");
        address weth    = vm.envAddress("WETH");
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(comrade), currency1: Currency.wrap(weth),
            fee: 3000, tickSpacing: 60, hooks: IHooks(hook)
        });
        vm.startBroadcast();
        ComradeSwap router = new ComradeSwap(IPoolManager(poolMgr), IWETH9(weth), IERC20Min(comrade), key);
        IBCC(comrade).setSkip(address(router), true);
        vm.stopBroadcast();
        console2.log("ComradeSwap:", address(router));
    }
}
