// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}            from "forge-std/Test.sol";
import {Deployers}                 from "v4-core-test/utils/Deployers.sol";
import {SortTokens}                from "v4-core-test/utils/SortTokens.sol";
import {Hooks}                     from "v4-core/libraries/Hooks.sol";
import {IHooks}                    from "v4-core/interfaces/IHooks.sol";
import {IPoolManager}              from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}                   from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath}                  from "v4-core/libraries/TickMath.sol";
import {MockERC20}                 from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest}              from "v4-core/test/PoolSwapTest.sol";

import {PhunkHook}        from "../src/PhunkHook.sol";
import {Phunk404}         from "../src/Phunk404.sol";
import {PhunkSpriteData}  from "../src/PhunkSpriteData.sol";
import {PhunkRenderer}    from "../src/PhunkRenderer.sol";

/// @notice End-to-end: deploy hook to a flag-bit-correct CREATE2 address,
/// initialize a v4 pool with PHUNK + MockERC20, add liquidity, swap,
/// assert the hook's seed advanced.
contract PhunkHookIntegrationTest is Deployers {
    PhunkHook       hook;
    Phunk404        phunk;
    PhunkSpriteData spriteData;
    PhunkRenderer   renderer;
    MockERC20       other;

    PoolKey poolKey;

    function setUp() public {
        // 1. PoolManager + test routers
        deployFreshManagerAndRouters();

        // 2. Mine a salt so the hook deploys to an address with afterSwap bit set
        uint160 wantFlags = uint160(Hooks.AFTER_SWAP_FLAG);
        bytes memory ctorArgs = abi.encode(manager);
        (address hookAddr, bytes32 salt) =
            _mineSalt(address(this), wantFlags, type(PhunkHook).creationCode, ctorArgs);

        hook = new PhunkHook{salt: salt}(manager);
        require(address(hook) == hookAddr, "hook addr mismatch");

        // 3. Sprite data + renderer
        spriteData = new PhunkSpriteData();
        renderer   = new PhunkRenderer(spriteData);

        // 4. PHUNK token (test contract is treasury so it holds total supply)
        phunk = new Phunk404(hook, address(this), 32, 1 ether);
        phunk.setRenderer(renderer);

        // The PoolManager holds liquidity directly — exempt it from Phunk minting
        phunk.setSkip(address(manager), true);
        phunk.setSkip(address(modifyLiquidityRouter), true);
        phunk.setSkip(address(swapRouter), true);

        // 5. Pair currency
        other = new MockERC20("OTHER", "OTHER", 18);
        other.mint(address(this), 100 ether);

        // Approve routers
        phunk.approve(address(modifyLiquidityRouter), type(uint256).max);
        phunk.approve(address(swapRouter),           type(uint256).max);
        other.approve(address(modifyLiquidityRouter), type(uint256).max);
        other.approve(address(swapRouter),            type(uint256).max);

        // 6. Initialize pool — sort by address
        Currency c0; Currency c1;
        if (address(phunk) < address(other)) {
            c0 = Currency.wrap(address(phunk));
            c1 = Currency.wrap(address(other));
        } else {
            c0 = Currency.wrap(address(other));
            c1 = Currency.wrap(address(phunk));
        }

        (poolKey,) = initPoolAndAddLiquidity(c0, c1, hook, 3000, SQRT_PRICE_1_1);
    }

    // ---- the actual test ----

    function test_swap_advances_hook_seed() public {
        bytes32 seedBefore = hook.currentSeed();
        uint64  countBefore = hook.swapCount();

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1e15,                  // exact-input, small amount
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });
        // This calls into PoolManager which calls our hook's afterSwap
        swapRouter.swap(poolKey, params, PoolSwapTest_TestSettings(), bytes(""));

        bytes32 seedAfter = hook.currentSeed();
        uint64  countAfter = hook.swapCount();

        assertEq(countAfter, countBefore + 1, "swap counter incremented");
        assertTrue(seedAfter != seedBefore, "seed re-rolled");
    }

    function test_multiple_swaps_keep_advancing_seed() public {
        bytes32 prev = hook.currentSeed();
        for (uint256 i = 0; i < 3; ++i) {
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: i % 2 == 0,
                amountSpecified: -1e14,
                sqrtPriceLimitX96: i % 2 == 0 ? SQRT_PRICE_1_2 : SQRT_PRICE_2_1
            });
            swapRouter.swap(poolKey, params, PoolSwapTest_TestSettings(), bytes(""));
            bytes32 next = hook.currentSeed();
            assertTrue(next != prev, "seed advances each swap");
            prev = next;
        }
        assertEq(hook.swapCount(), 3);
    }

    // ---- helpers ----

    /// @dev Returns a PoolSwapTest.TestSettings struct. Inlined because the type lives
    /// inside PoolSwapTest, which Deployers imports for us.
    function PoolSwapTest_TestSettings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    /// @dev brute-force a CREATE2 salt so the resulting address has its lower 14 bits == flags
    function _mineSalt(address deployer, uint160 flags, bytes memory code, bytes memory args)
        internal pure returns (address, bytes32)
    {
        bytes32 codeHash = keccak256(abi.encodePacked(code, args));
        for (uint256 i = 0; i < 1_000_000; ++i) {
            bytes32 salt = bytes32(i);
            address a = address(uint160(uint256(keccak256(
                abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)
            ))));
            if (uint160(a) & uint160(0x3fff) == flags) {
                return (a, salt);
            }
        }
        revert("HookMiner: not found");
    }
}
