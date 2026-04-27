// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}        from "forge-std/Script.sol";
import {IPoolManager}            from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}                  from "v4-core/interfaces/IHooks.sol";
import {PoolKey}                 from "v4-core/types/PoolKey.sol";
import {Currency}                from "v4-core/types/Currency.sol";
import {TickMath}                from "v4-core/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ComradeSwap, IERC20Min, IWETH9} from "../src/ComradeSwap.sol";

interface IBCC {
    function approve(address, uint256) external returns (bool);
    function setSkip(address, bool) external;
    function balanceOf(address) external view returns (uint256);
}

interface IWETHFunds {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Wire up the Sepolia trade stack:
///   1) Deploy ComradeSwap (the swap router users hit from the site)
///   2) Set skipComrades=true on ComradeSwap so it doesn't accumulate stray 404 NFTs
///   3) Deploy PoolModifyLiquidityTest, add a small 2-sided LP bracket so swaps work
///
/// Run:
///   COMRADE=0x... POOL_MANAGER=0x... HOOK=0x... WETH=0x... \
///   forge script script/SetupSwap.s.sol --rpc-url $RPC --private-key $PK --broadcast
contract SetupSwap is Script {
    uint24 constant FEE = 3000;
    int24  constant TICK_SPACING = 60;

    function run() external {
        address comrade = vm.envAddress("COMRADE");
        address poolMgr = vm.envAddress("POOL_MANAGER");
        address hook    = vm.envAddress("HOOK");
        address weth    = vm.envAddress("WETH");

        require(comrade < weth, "BCC must be < WETH (token0)");
        PoolKey memory key = PoolKey({
            currency0:    Currency.wrap(comrade),
            currency1:    Currency.wrap(weth),
            fee:          FEE,
            tickSpacing:  TICK_SPACING,
            hooks:        IHooks(hook)
        });

        IPoolManager pm = IPoolManager(poolMgr);

        vm.startBroadcast();

        // 1. Deploy ComradeSwap
        ComradeSwap router = new ComradeSwap(pm, IWETH9(weth), IERC20Min(comrade), key);
        console2.log("ComradeSwap:", address(router));

        // 2. Skip the router so 404 NFTs don't flicker into existence during sells
        IBCC(comrade).setSkip(address(router), true);

        // 3. LP bootstrap — seed a small 2-sided bracket around the current tick.
        // Pool is at tick = -80040 (BCC = $1 at $3k ETH). Use a bracket -80100..-79980.
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(pm);
        IBCC(comrade).setSkip(address(lpRouter), true);
        console2.log("LP router:  ", address(lpRouter));

        // Approve BCC for the LP router and wrap some WETH so the bracket gets both sides
        IBCC(comrade).approve(address(lpRouter), type(uint256).max);
        IWETHFunds(weth).deposit{value: 0.005 ether}();
        IWETHFunds(weth).approve(address(lpRouter), type(uint256).max);

        // Tick range: -80100 to -79980 (60-spaced, brackets the $1 anchor)
        int24 tickLower = -80100;
        int24 tickUpper = -79980;
        // Tiny liquidity to start — just enough for someone to swap
        IPoolManager.ModifyLiquidityParams memory mlp = IPoolManager.ModifyLiquidityParams({
            tickLower:      tickLower,
            tickUpper:      tickUpper,
            liquidityDelta: 1e15, // small but functional
            salt:           bytes32(0)
        });
        lpRouter.modifyLiquidity(key, mlp, "");
        console2.log("LP seeded. tickLower:");
        console2.logInt(tickLower);
        console2.log("tickUpper:");
        console2.logInt(tickUpper);

        vm.stopBroadcast();
    }
}
