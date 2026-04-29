// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}    from "forge-std/Script.sol";
import {IPoolManager}        from "v4-core/interfaces/IPoolManager.sol";
import {IHooks}              from "v4-core/interfaces/IHooks.sol";
import {PoolKey}             from "v4-core/types/PoolKey.sol";
import {Currency}            from "v4-core/types/Currency.sol";
import {TickMath}            from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts}    from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IPositionManager}    from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions}             from "v4-periphery/libraries/Actions.sol";
import {ComradeLPLocker}     from "../src/ComradeLPLocker.sol";

interface IBCC { function approve(address, uint256) external returns (bool); }
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
interface IERC721Min {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function nextTokenId() external view returns (uint256);
}

/// @notice Mainnet-grade launch LP setup.
///
///   1) Deploy ComradeLPLocker (immutable feeRecipient = treasury)
///   2) Approve BCC to Permit2; approve Permit2 to PositionManager
///   3) Mint the 3 launch curve positions via PositionManager (NFTs to deployer)
///   4) Transfer all 3 LP NFTs into the locker
///
/// After this runs:
///   - 10,000 BCC of liquidity locked forever (locker has no removeLiquidity path)
///   - Pool fees still collectable via locker.collectFees → feeRecipient
///   - Anyone can verify on Etherscan: locker source has no rug path
contract SeedLaunchLPMainnet is Script {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        address comrade  = vm.envAddress("COMRADE");
        address poolMgr  = vm.envAddress("POOL_MANAGER");
        address hook     = vm.envAddress("HOOK");
        address weth     = vm.envAddress("WETH");
        address posMgr   = vm.envAddress("POSITION_MANAGER");
        address feeTo    = vm.envAddress("FEE_RECIPIENT");

        require(comrade < weth, "BCC must be < WETH");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(comrade),
            currency1: Currency.wrap(weth),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        vm.startBroadcast();

        // 1. Deploy locker
        ComradeLPLocker locker = new ComradeLPLocker(IPositionManager(posMgr), feeTo);
        console2.log("LP Locker:", address(locker));
        console2.log("feeRecipient (immutable):", feeTo);

        // 2. Approval chain: BCC → Permit2 → PositionManager
        IBCC(comrade).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(comrade, posMgr, type(uint160).max, type(uint48).max);

        // 3. Mint the three launch positions
        uint256 t1 = _mintPosition(posMgr, key, -80040, -34020, 7125 ether);
        uint256 t2 = _mintPosition(posMgr, key, -34020, -20160, 1710 ether);
        uint256 t3 = _mintPosition(posMgr, key, -20160,  -9960, 1165 ether);
        // Total: 7125 + 1710 + 1165 = 10000 — full supply locked
        console2.log("position 1 tokenId:", t1);
        console2.log("position 2 tokenId:", t2);
        console2.log("position 3 tokenId:", t3);

        // 4. Transfer all three to the locker (irrevocable)
        IERC721Min(posMgr).safeTransferFrom(msg.sender, address(locker), t1);
        IERC721Min(posMgr).safeTransferFrom(msg.sender, address(locker), t2);
        IERC721Min(posMgr).safeTransferFrom(msg.sender, address(locker), t3);

        vm.stopBroadcast();

        console2.log("");
        console2.log("== LAUNCH LP LOCKED ==");
        console2.log("Locker holds 3 LP NFTs covering $1-$1111 launch curve.");
        console2.log("Fees are collectable via locker.collectFees(tokenId, c0, c1).");
        console2.log("Principal can never be removed.");
    }

    function _mintPosition(
        address posMgr,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 bccAmount
    ) internal returns (uint256 tokenId) {
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sqrtL, sqrtU, bccAmount);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        // MINT_POSITION(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData)
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liq),
            uint128(bccAmount + bccAmount / 100),  // 1% slop on amount0Max
            uint128(0),                            // amount1Max=0 (single-sided BCC)
            msg.sender,                            // recipient = deployer (we'll forward to locker)
            bytes("")
        );
        // SETTLE_PAIR(currency0, currency1)
        params[1] = abi.encode(key.currency0, key.currency1);

        // Read the next token id, then mint
        tokenId = IERC721Min(posMgr).nextTokenId();
        IPositionManager(posMgr).modifyLiquidities(abi.encode(actions, params), block.timestamp + 600);
    }
}
