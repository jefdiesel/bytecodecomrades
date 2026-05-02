// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager}     from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback}  from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks}           from "v4-core/interfaces/IHooks.sol";
import {PoolKey}          from "v4-core/types/PoolKey.sol";
import {Currency}         from "v4-core/types/Currency.sol";
import {BalanceDelta}     from "v4-core/types/BalanceDelta.sol";
import {TickMath}         from "v4-core/libraries/TickMath.sol";

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
}
interface IWETH9 {
    function deposit() external payable;
    function transfer(address, uint256) external returns (bool);
}
interface IUpegToken {
    function OwnerUpegsCount(address owner) external view returns (uint256);
    function OwnerUpeg(address owner, uint256 index) external view returns (uint256 id, uint256 seed);
}

/// @notice Inlined seed decoder mirroring the live UpegMetadata layout.
library UpegSeedDecoder {
    struct Traits {
        uint8 backgroundColor;   // byte 0
        uint8 horn;              // byte 1  - 0 = none
        uint8 accessories;       // byte 2  - 0 = none
        uint8 hair;              // byte 3  - 0 = none
        uint8 wings;             // byte 4  - 0 = none
        uint8 tail;              // byte 5  - 0 = none
        uint8 legsFront;         // byte 6
        uint8 legsBack;          // byte 7
        uint8 eyes;              // byte 8
        uint8 body;              // byte 9
        uint8 ground;            // byte 10 - 0 = none
        uint8 bodyColor;
        uint8 eyesColor;
        uint8 hairColor;
        uint8 hornColor;
        uint8 groundColor;
        uint8 accessoriesColor;
        uint8 tailColor;
    }
    function decode(uint256 seed) internal pure returns (Traits memory t) {
        t.backgroundColor  = uint8( seed        & 0xFF);
        t.horn             = uint8((seed >> 8)  & 0xFF);
        t.accessories      = uint8((seed >> 16) & 0xFF);
        t.hair             = uint8((seed >> 24) & 0xFF);
        t.wings            = uint8((seed >> 32) & 0xFF);
        t.tail             = uint8((seed >> 40) & 0xFF);
        t.legsFront        = uint8((seed >> 48) & 0xFF);
        t.legsBack         = uint8((seed >> 56) & 0xFF);
        t.eyes             = uint8((seed >> 64) & 0xFF);
        t.body             = uint8((seed >> 72) & 0xFF);
        t.ground           = uint8((seed >> 80) & 0xFF);
        t.bodyColor        = uint8((seed >> 88) & 0xFF);
        t.eyesColor        = uint8((seed >> 96) & 0xFF);
        t.hairColor        = uint8((seed >> 104)& 0xFF);
        t.hornColor        = uint8((seed >> 112)& 0xFF);
        t.groundColor      = uint8((seed >> 120)& 0xFF);
        t.accessoriesColor = uint8((seed >> 128)& 0xFF);
        t.tailColor        = uint8((seed >> 136)& 0xFF);
    }
}

/// @title UpegGrinder
/// @notice Atomic seed-grinder for uPEG unicorns.
///
/// User calls `grind{value: maxEthIn}(criteria)`. The contract:
///   1. unlocks the v4 PoolManager
///   2. swaps WETH -> exactly 1.0 uPEG (which mints a unicorn to the user)
///   3. inspects the just-minted unicorn's traits
///   4. reverts (NoMatch) if traits don't meet criteria → entire swap unwinds,
///      user pays only gas, no ETH spent
///   5. otherwise: settles WETH, refunds unspent ETH, swap stands
///
/// This exploits the deterministic seed in `UpegHook._randomSeed` — by paying
/// only gas on misses, you can probe many seeds cheaply until one matches.
///
/// MEV reality check: this competes with searchers in the public mempool.
/// Builders see your tx and may bundle it with their own to steal the rare
/// you're about to mint. For competitive grinding, route via Flashbots /
/// MEV-Share private mempool.
contract UpegGrinder is IUnlockCallback {
    using UpegSeedDecoder for uint256;

    IPoolManager constant PM    = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IUpegToken   constant UPEG  = IUpegToken(0x44b28991B167582F18BA0259e0173176ca125505);
    IWETH9       constant WETH  = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IHooks       constant HOOK  = IHooks(0xe54082DfBf044B6a8F584bdDdb90a22d5613C440);

    PoolKey public key;

    /// @notice Pack a "rarity gate". A unicorn matches if ALL non-zero
    /// requirements hold.
    /// - requireWings, requireHorn, ...: must be present (>0) in seed
    /// - maxOptional: cap on number of optional categories present (lower = rarer)
    /// - requireBg / requireBgValue: pin background_color to a specific value (0xFF = any)
    struct Criteria {
        bool   requireWings;
        bool   requireHorn;
        bool   requireHair;
        bool   requireGround;
        bool   requireTail;
        bool   requireAccessories;
        uint8  maxOptional;        // 0..6 (6 = no cap)
        uint8  requireBgValue;     // 0..255; 0xFF = any
        bool   requireBg;
    }

    struct CB {
        address  sender;
        uint256  maxWeth;
        uint256  ethProvided;
        uint256  countBefore;
        Criteria criteria;
    }

    error WrongCallback();
    error UnexpectedDelta();
    error MaxInputExceeded();
    error NoMint();
    error NoMatch();
    error RefundFailed();

    constructor() {
        // UPEG (0x44b2...) < WETH (0xC02a...) → UPEG = currency0, WETH = currency1
        require(address(UPEG) < address(WETH), "address ordering");
        key = PoolKey({
            currency0:   Currency.wrap(address(UPEG)),
            currency1:   Currency.wrap(address(WETH)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       HOOK
        });
    }

    /// @notice Atomic grind: buy exactly 1 uPEG, mint, check, revert on miss.
    /// @param maxEthIn  Max ETH willing to spend on this swap (slippage cap)
    /// @param c         Rarity criteria — only matching mints pass
    function grind(uint256 maxEthIn, Criteria calldata c) external payable {
        require(msg.value >= maxEthIn, "msg.value < maxEthIn");
        uint256 countBefore = UPEG.OwnerUpegsCount(msg.sender);
        PM.unlock(abi.encode(CB({
            sender:      msg.sender,
            maxWeth:     maxEthIn,
            ethProvided: msg.value,
            countBefore: countBefore,
            criteria:    c
        })));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(PM)) revert WrongCallback();
        CB memory p = abi.decode(raw, (CB));

        // Exact-output 1.0 uPEG. zeroForOne=false (WETH→UPEG; UPEG=currency0).
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne:        false,
            amountSpecified:   int256(1e18),                    // positive = exact-output
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        BalanceDelta delta = PM.swap(key, sp, "");
        int256 d0 = int256(delta.amount0());  // UPEG
        int256 d1 = int256(delta.amount1());  // WETH

        // Buying UPEG: pool gives us +d0 UPEG, we owe -d1 WETH
        if (d0 <= 0 || d1 >= 0) revert UnexpectedDelta();
        uint256 wethOwed = uint256(-d1);
        if (wethOwed > p.maxWeth) revert MaxInputExceeded();

        // Settle WETH (wrap from ETH on hand)
        PM.sync(key.currency1);
        WETH.deposit{value: wethOwed}();
        require(WETH.transfer(address(PM), wethOwed), "weth.transfer");
        PM.settle();

        // Take UPEG → user. This triggers UpegToken._afterTokenTransfer (from=PM,
        // to=user) which mints fresh unicorns to the user using the hook's
        // current seed.
        uint256 upegOut = uint256(d0);
        PM.take(key.currency0, p.sender, upegOut);

        // Inspect what was minted
        uint256 countAfter = UPEG.OwnerUpegsCount(p.sender);
        if (countAfter <= p.countBefore) revert NoMint();

        bool match_;
        for (uint256 i = p.countBefore; i < countAfter; i++) {
            (, uint256 seed) = UPEG.OwnerUpeg(p.sender, i);
            if (_matches(seed, p.criteria)) { match_ = true; break; }
        }
        if (!match_) revert NoMatch();   // <-- entire tx reverts → swap & mint undone, user only paid gas

        // Hit. Refund unspent ETH.
        uint256 refund;
        unchecked { refund = p.ethProvided - wethOwed; }
        if (refund > 0) {
            (bool ok, ) = p.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
        return "";
    }

    function _matches(uint256 seed, Criteria memory c) internal pure returns (bool) {
        UpegSeedDecoder.Traits memory t = seed.decode();
        if (c.requireWings       && t.wings       == 0) return false;
        if (c.requireHorn        && t.horn        == 0) return false;
        if (c.requireHair        && t.hair        == 0) return false;
        if (c.requireGround      && t.ground      == 0) return false;
        if (c.requireTail        && t.tail        == 0) return false;
        if (c.requireAccessories && t.accessories == 0) return false;
        if (c.requireBg          && t.backgroundColor != c.requireBgValue) return false;
        uint256 opts = (t.horn>0?1:0)+(t.accessories>0?1:0)+(t.hair>0?1:0)
                     + (t.wings>0?1:0)+(t.tail>0?1:0)+(t.ground>0?1:0);
        if (opts > c.maxOptional) return false;
        return true;
    }

    /// @notice View-only: would `seed` pass these criteria? Useful for
    /// dry-running rarity rules before grinding.
    function check(uint256 seed, Criteria calldata c) external pure returns (bool) {
        return _matches(seed, c);
    }

    receive() external payable {}
}
