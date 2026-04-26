// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ComradeRenderer} from "./ComradeRenderer.sol";

/// @notice The Genesis Comrade — a soulbound homage to CDC #1 (Comrade #1).
/// Single token (id 0) airdropped at deploy to the wallet that owned CDC #1
/// at launch. Same Background, Eyes, and Mouth (Beard of the Gods) as CDC #1;
/// distinct Type and Cloths. Permanently locked to its initial recipient.
///
/// Traits are immutable. The token cannot be transferred, burned, or redeemed
/// for fungible value. It exists as a fixed cultural artifact, separate from
/// the procedural 404 collection.
contract ComradeGenesis is ERC721 {
    /// @dev Sprite indices in ComradeSpriteData
    /// 13  = Sir Pinkalot (background — same as CDC #1)
    /// 22  = Alien People (body — our pick, contrasts with CDC #1's Scriboor)
    /// 69  = Hardbass Uniform (cloths — our pick; CDC #1 has none)
    /// 106 = Beard of the Gods (mouth — same as CDC #1)
    /// 175 = Aviators (eyes — same as CDC #1)
    uint16 public constant SPRITE_BG     = 13;
    uint16 public constant SPRITE_TYPE   = 22;
    uint16 public constant SPRITE_CLOTHS = 69;
    uint16 public constant SPRITE_MOUTH  = 106;
    uint16 public constant SPRITE_EYES   = 175;

    address public immutable initialRecipient;
    ComradeRenderer public immutable renderer;

    error Soulbound();

    constructor(address _initialRecipient, ComradeRenderer _renderer)
        ERC721("Genesis Bytecode Comrade", "GENESIS-BCC")
    {
        initialRecipient = _initialRecipient;
        renderer = _renderer;
        _mint(_initialRecipient, 0);
    }

    /// @dev Block all transfers, including approvals. The token can only ever
    /// move once — from the zero address (mint) to initialRecipient.
    function _update(address to, uint256 tokenId, address auth)
        internal override returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function approve(address, uint256) public pure override {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        uint16[] memory ids = new uint16[](5);
        ids[0] = SPRITE_BG;
        ids[1] = SPRITE_TYPE;
        ids[2] = SPRITE_CLOTHS;
        ids[3] = SPRITE_MOUTH;
        ids[4] = SPRITE_EYES;
        string memory svg = renderer.renderSVG(ids, false, "");
        return string.concat(
            "data:application/json;utf8,",
            '{"name":"Genesis Bytecode Comrade #0",',
            '"description":"Soulbound homage to Call Data Comrades #1. Airdropped at launch to the original holder. Cannot be transferred.",',
            '"image":"data:image/svg+xml;utf8,', svg, '",',
            '"attributes":[',
                '{"trait_type":"Background","value":"Sir Pinkalot"},',
                '{"trait_type":"Type","value":"Alien People"},',
                '{"trait_type":"Cloths","value":"Hardbass Uniform"},',
                '{"trait_type":"Mouth","value":"Beard of the Gods"},',
                '{"trait_type":"Eyes","value":"Aviators"},',
                '{"trait_type":"Tribute","value":"CDC #1"},',
                '{"trait_type":"Soulbound","value":"true"}',
            ']}'
        );
    }
}
