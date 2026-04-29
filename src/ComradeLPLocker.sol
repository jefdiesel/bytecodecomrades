// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {Currency}         from "v4-core/types/Currency.sol";
import {Actions}          from "v4-periphery/libraries/Actions.sol";

/// @notice Permanent LP locker for the BCC v4 launch positions.
///
/// Holds v4 PositionManager LP NFTs forever. There is **no function in this
/// contract that can remove principal liquidity or transfer the NFT out.**
/// Anyone reading this source can verify there's no rug path.
///
/// What CAN happen:
///   - `collectFees` — harvest accrued 0.3% pool fees and forward to the
///     immutable `feeRecipient`. Calls PositionManager with DECREASE_LIQUIDITY
///     of zero (which v4 documents as the fee-collection pattern) plus
///     TAKE_PAIR routing the harvest to feeRecipient.
///
/// What CANNOT happen:
///   - decreaseLiquidity with a non-zero amount (no caller-supplied liquidity arg)
///   - burnPosition (no entrypoint)
///   - LP NFT transfer (no `transferFrom` wrapper, no `setApproval`)
///   - feeRecipient change (immutable)
///   - posMgr change (immutable)
///   - any owner / admin override
contract ComradeLPLocker {
    IPositionManager public immutable posMgr;
    /// @notice Where harvested fees are sent. Immutable — set at construction, never changeable.
    address public immutable feeRecipient;

    event PositionLocked(uint256 indexed tokenId);
    event FeesCollected(uint256 indexed tokenId, address recipient);

    error NotPositionManager();

    constructor(IPositionManager _posMgr, address _feeRecipient) {
        require(address(_posMgr) != address(0), "posMgr=0");
        require(_feeRecipient != address(0), "feeRecipient=0");
        posMgr = _posMgr;
        feeRecipient = _feeRecipient;
    }

    /// @notice ERC-721 receiver — accept LP NFTs only from the v4 PositionManager.
    /// Rejects NFTs from any other source so the locker can't be polluted.
    function onERC721Received(
        address /* operator */,
        address /* from */,
        uint256 tokenId,
        bytes calldata /* data */
    ) external returns (bytes4) {
        if (msg.sender != address(posMgr)) revert NotPositionManager();
        emit PositionLocked(tokenId);
        return this.onERC721Received.selector;
    }

    /// @notice Harvest accrued pool fees from a locked position to feeRecipient.
    /// Anyone can call this — it always pays out to `feeRecipient`, never elsewhere.
    /// Uses DECREASE_LIQUIDITY with zero liquidity (canonical v4 fee-collect pattern)
    /// + TAKE_PAIR routing both currencies to feeRecipient.
    function collectFees(uint256 tokenId, Currency currency0, Currency currency1) external {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        // DECREASE_LIQUIDITY(tokenId, liquidity=0, amount0Min=0, amount1Min=0, hookData=empty)
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        // TAKE_PAIR(currency0, currency1, recipient=feeRecipient)
        params[1] = abi.encode(currency0, currency1, feeRecipient);

        posMgr.modifyLiquidities(abi.encode(actions, params), block.timestamp + 600);
        emit FeesCollected(tokenId, feeRecipient);
    }

    // Intentionally:
    //  - no fallback that forwards calls to posMgr
    //  - no admin function
    //  - no NFT transfer wrapper
    //  - no removeLiquidity
    //  - no upgradeability
}
