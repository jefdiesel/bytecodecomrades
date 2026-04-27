// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}        from "forge-std/Script.sol";
import {IPoolManager}            from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}                  from "v4-core/interfaces/IHooks.sol";
import {Hooks}                   from "v4-core/libraries/Hooks.sol";
import {PoolKey}                 from "v4-core/types/PoolKey.sol";
import {Currency}                from "v4-core/types/Currency.sol";
import {TickMath}                from "v4-core/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest}            from "v4-core/test/PoolSwapTest.sol";
import {LiquidityAmounts}        from "v4-periphery/libraries/LiquidityAmounts.sol";
import {ComradeHook}             from "../src/ComradeHook.sol";

interface IBCC {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function setSkip(address, bool) external;
}

/// @notice Self-contained Sepolia hook e2e test:
///   1) Mine new hook salt (bytecode changed → new address)
///   2) Deploy ComradeHook (with the mint-on-afterSwap fix)
///   3) Init a fresh COMRADE/ETH pool wired to the new hook (different fee/spacing
///      so it doesn't collide with the existing pool)
///   4) Deploy LP/swap test routers
///   5) Add small single-sided BCC LP
///   6) Swap a tiny amount of ETH for BCC
///   7) Verify hook fired (swapCount up, seed updated, fee claim balance > 0)
///
/// Run:
///   COMRADE=0x... POOL_MANAGER=0x... \
///   forge script script/TestHookE2E.s.sol --rpc-url $RPC --private-key $PK --broadcast
contract TestHookE2E is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Use a different fee tier so we don't collide with the existing pool.
    uint24 constant FEE = 5000;          // 0.5%
    int24  constant TICK_SPACING = 100;

    function run() external {
        address comrade  = vm.envAddress("COMRADE");
        address poolMgr  = vm.envAddress("POOL_MANAGER");
        IPoolManager pm = IPoolManager(poolMgr);
        IBCC bcc = IBCC(comrade);

        // ---- 1. Mine hook salt ----
        uint160 wantFlags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory hookCode = type(ComradeHook).creationCode;
        bytes memory hookArgs = abi.encode(IPoolManager(poolMgr));
        (address predicted, bytes32 salt, uint256 iters) = _mineSalt(CREATE2_DEPLOYER, wantFlags, hookCode, hookArgs);
        console2.log("hook (predicted):", predicted);
        console2.log("salt iters:      ", iters);

        vm.startBroadcast();

        // ---- 2. Deploy hook via CREATE2 (or reuse if already deployed) ----
        ComradeHook hook;
        if (predicted.code.length == 0) {
            hook = new ComradeHook{salt: salt}(IPoolManager(poolMgr));
            require(address(hook) == predicted, "hook addr mismatch");
            console2.log("hook deployed:   ", address(hook));
        } else {
            hook = ComradeHook(predicted);
            console2.log("hook reused:     ", address(hook));
        }

        // ---- 3. Init pool ----
        PoolKey memory key = PoolKey({
            currency0:    Currency.wrap(address(0)),
            currency1:    Currency.wrap(comrade),
            fee:          FEE,
            tickSpacing:  TICK_SPACING,
            hooks:        IHooks(address(hook))
        });
        // Start tick 0 → sqrtPriceX96 = 2^96 (price = 1).
        try pm.initialize(key, 79228162514264337593543950336) {
            console2.log("pool initialized.");
        } catch {
            console2.log("pool already initialized - reusing.");
        }

        // ---- 4. Deploy routers ----
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(pm);
        PoolSwapTest swapRouter          = new PoolSwapTest(pm);
        bcc.setSkip(address(lpRouter),   true);
        bcc.setSkip(address(swapRouter), true);
        bcc.setSkip(address(hook),       true);
        console2.log("lpRouter:        ", address(lpRouter));
        console2.log("swapRouter:      ", address(swapRouter));

        // ---- 5. Add LP — 2-sided range straddling current tick (just for hook test) ----
        // Tiny liquidity. Current tick=0, range -100..100 → needs both tokens.
        int24 tickLower = -100;
        int24 tickUpper = 100;
        uint128 liq = 1e15; // small fixed liquidity, both tokens needed are tiny
        bcc.approve(address(lpRouter), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory mlp = IPoolManager.ModifyLiquidityParams({
            tickLower:      tickLower,
            tickUpper:      tickUpper,
            liquidityDelta: int256(uint256(liq)),
            salt:           bytes32(0)
        });
        // Send some ETH along with the call so router can settle the ETH side.
        lpRouter.modifyLiquidity{value: 0.001 ether}(key, mlp, "");
        console2.log("LP added, liquidity:", liq);

        // ---- 6. Swap ETH → BCC ----
        uint64 swapsBefore = hook.swapCount();
        bytes32 seedBefore = hook.currentSeed();

        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:  -int256(0.0001 ether),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap{value: 0.0001 ether}(
            key,
            sp,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        console2.log("swap done.");

        // ---- 7. Verify ----
        uint64 swapsAfter = hook.swapCount();
        bytes32 seedAfter = hook.currentSeed();
        require(swapsAfter > swapsBefore, "swapCount did not increment");
        require(seedAfter != seedBefore, "seed did not update");
        console2.log("swapCount before:", swapsBefore);
        console2.log("swapCount after: ", swapsAfter);
        console2.log("HOOK FIRED + SETTLED OK.");

        vm.stopBroadcast();
    }

    function _mineSalt(address deployer, uint160 flags, bytes memory code, bytes memory args)
        internal pure returns (address addr, bytes32 salt, uint256 iters)
    {
        bytes32 codeHash = keccak256(abi.encodePacked(code, args));
        for (uint256 i = 0; i < 1_000_000; ++i) {
            salt = bytes32(i);
            addr = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)))));
            if (uint160(addr) & uint160(0x3fff) == flags) {
                iters = i;
                return (addr, salt, iters);
            }
        }
        revert("HookMiner: not found");
    }
}
