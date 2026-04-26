// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager}     from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}           from "v4-core/interfaces/IHooks.sol";
import {PoolKey}          from "v4-core/types/PoolKey.sol";
import {Currency}         from "v4-core/types/Currency.sol";
import {TickMath}         from "v4-core/libraries/TickMath.sol";

/// @notice Initialize the Bytecode Comrades v4 pool with a weighted-curve LP plan.
///
/// Strategy: three concentrated-liquidity positions across $1-$1111, weighted
/// toward the low end so early buyers get fair pricing while preserving moonshot upside.
///
///   Position 1: $1   - $100    | 7500 tokens (75%) | thick depth
///   Position 2: $100 - $400    | 1800 tokens (18%) | medium depth
///   Position 3: $400 - $1111   |  700 tokens (7%)  | thin (moonshot)
///
/// This script INITIALIZES the pool at the bottom of the range. The actual three
/// LP deposits should be done via the Uniswap UI or a follow-up PositionManager
/// script — paste the printed (tickLower, tickUpper, amount) values for each.
///
/// Run:
///   COMRADE=<addr>  PAIR=<addr>  POOL_MANAGER=<addr>  HOOK=<addr> \
///   ETH_USD=3000 \
///   forge script script/InitComradePool.s.sol --rpc-url $RPC --private-key $PK --broadcast
contract InitComradePool is Script {
    uint24 constant FEE = 3000;          // 0.3% LP fee
    int24  constant TICK_SPACING = 60;   // standard for 0.3% pools

    // Range tops in USD
    uint256 constant POS1_LOW  = 1;
    uint256 constant POS1_HIGH = 100;
    uint256 constant POS2_LOW  = 100;
    uint256 constant POS2_HIGH = 400;
    uint256 constant POS3_LOW  = 400;
    uint256 constant POS3_HIGH = 1111;

    // Token allocations per position (percent of supply, basis points)
    uint16 constant POS1_BPS = 7500;  // 75%
    uint16 constant POS2_BPS = 1800;  // 18%
    uint16 constant POS3_BPS =  700;  // 7%

    function run() external {
        address comrade  = vm.envAddress("COMRADE");
        address pair     = vm.envAddress("PAIR");
        address poolMgr  = vm.envAddress("POOL_MANAGER");
        address hook     = vm.envAddress("HOOK");
        uint256 ethUsd   = vm.envOr("ETH_USD", uint256(3000));

        (address token0, address token1) = comrade < pair
            ? (comrade, pair)
            : (pair, comrade);
        bool comradeIsToken0 = (comrade < pair);

        console2.log("== Bytecode Comrades pool init ==");
        console2.log("BCC:               ", comrade);
        console2.log("Pair:              ", pair);
        console2.log("comrade is token0: ", comradeIsToken0);
        console2.log("ETH/USD assumed:   ", ethUsd);

        // Compute starting price at $1
        uint256 startingPriceFP = comradeIsToken0
            ? (POS1_LOW * 1e18) / ethUsd
            : (ethUsd * 1e18) / POS1_LOW;
        int24 startTick = _approxTick(startingPriceFP);
        startTick = (startTick / TICK_SPACING) * TICK_SPACING;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(startTick);

        console2.log("starting price ($1) tick:", startTick);
        console2.log("sqrtPriceX96:            ", sqrtPriceX96);

        PoolKey memory key = PoolKey({
            currency0:    Currency.wrap(token0),
            currency1:    Currency.wrap(token1),
            fee:          FEE,
            tickSpacing:  TICK_SPACING,
            hooks:        IHooks(hook)
        });

        vm.broadcast();
        IPoolManager(poolMgr).initialize(key, sqrtPriceX96);
        console2.log("");
        console2.log("Pool initialized.");

        // Print the three positions for the LP add step
        _printPosition(1, POS1_LOW, POS1_HIGH, POS1_BPS, ethUsd, comradeIsToken0);
        _printPosition(2, POS2_LOW, POS2_HIGH, POS2_BPS, ethUsd, comradeIsToken0);
        _printPosition(3, POS3_LOW, POS3_HIGH, POS3_BPS, ethUsd, comradeIsToken0);

        console2.log("");
        console2.log("== Next: deposit single-sided LP for each position above ==");
        console2.log("Use https://app.uniswap.org/pool or a PositionManager script.");
        console2.log("All three positions hold COMRADE only at launch (no ETH).");
        console2.log("Buyers fill them in order as price walks up through the range.");
    }

    function _printPosition(
        uint8 idx,
        uint256 lowUsd,
        uint256 highUsd,
        uint16 supplyBps,
        uint256 ethUsd,
        bool comradeIsToken0
    ) internal pure {
        uint256 lowFP  = comradeIsToken0
            ? (lowUsd  * 1e18) / ethUsd
            : (ethUsd  * 1e18) / lowUsd;
        uint256 highFP = comradeIsToken0
            ? (highUsd * 1e18) / ethUsd
            : (ethUsd  * 1e18) / highUsd;

        // Lower-priced bound corresponds to higher tick when comrade is token1, vice versa
        int24 tickLow  = _approxTick(comradeIsToken0 ? lowFP  : highFP);
        int24 tickHigh = _approxTick(comradeIsToken0 ? highFP : lowFP);
        tickLow  = (tickLow  / TICK_SPACING) * TICK_SPACING;
        tickHigh = (tickHigh / TICK_SPACING) * TICK_SPACING;

        // Tokens for this position out of 10000-supply BCC
        uint256 tokens = (10_000 * uint256(supplyBps)) / 10_000;

        console2.log("");
        console2.log("---- Position", idx, "----");
        console2.log("USD range low:     ", lowUsd);
        console2.log("USD range high:    ", highUsd);
        console2.log("supply allocation: ", uint256(supplyBps), "bps");
        console2.log("tokens to deposit: ", tokens);
        console2.log("tickLower:         ", tickLow);
        console2.log("tickUpper:         ", tickHigh);
    }

    function _approxTick(uint256 priceFP) internal pure returns (int24) {
        int24 lo = TickMath.MIN_TICK;
        int24 hi = TickMath.MAX_TICK;
        for (uint256 i = 0; i < 64; i++) {
            int24 mid = (lo + hi) / 2;
            uint160 sp = TickMath.getSqrtPriceAtTick(mid);
            uint256 sp2 = uint256(sp) * uint256(sp);
            uint256 lhs = sp2 / 2**96;
            uint256 rhs = (priceFP * 2**96) / 1e18;
            if (lhs < rhs) lo = mid + 1;
            else hi = mid;
            if (hi - lo <= 1) break;
        }
        return lo;
    }
}
