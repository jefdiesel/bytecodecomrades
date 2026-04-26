// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPhunkRenderer}  from "./IPhunkRenderer.sol";
import {PhunkSpriteData} from "./PhunkSpriteData.sol";

/// @notice Composites canonical CryptoPunks sprite data into a horizontally-mirrored
/// 24x24 SVG with a chartreuse (#c3ff00) background. Reads sprites from PhunkSpriteData.
/// Pure view function — no storage, no owner.
contract PhunkRenderer is IPhunkRenderer {
    PhunkSpriteData public immutable data;

    string constant BG_HEX = "c3ff00";

    // Index ranges in the canonical asset table:
    //   1..11   = base types (Male 1-4, Female 1-4, Zombie, Ape, Alien)
    //   12..99  = additional attributes (hats, glasses, beards, mouths, etc.)
    uint8 constant BASE_MIN  = 1;
    uint8 constant BASE_MAX  = 11;
    uint8 constant ATTR_MIN  = 12;
    uint8 constant ATTR_MAX  = 133;

    constructor(PhunkSpriteData _data) {
        data = _data;
    }

    struct Picks {
        uint8 base;
        uint8 attr1;
        uint8 attr2;
        uint8 attr3;
    }

    function tokenURI(uint256 id, bytes32 seed, uint256 holderPhunkCount) external view returns (string memory) {
        uint8 tier = _tier(holderPhunkCount);
        Picks memory p = _pick(seed, tier);
        string memory svgB64 = _b64(bytes(_renderFromPicks(p)));
        string memory attrs = string.concat(
            '[',
                '{"trait_type":"Tier","value":"',    _tierName(tier),         '"},',
                '{"trait_type":"Type","value":"',    data.assetName(p.base),  '"},',
                '{"trait_type":"Trait 1","value":"', data.assetName(p.attr1), '"},',
                '{"trait_type":"Trait 2","value":"', data.assetName(p.attr2), '"},',
                '{"trait_type":"Trait 3","value":"', data.assetName(p.attr3), '"}',
            ']'
        );
        string memory json = string.concat(
            '{"name":"Phunk #', _u(id),
            '","description":"On-chain Phunk minted by trading activity on Uniswap v4. Trait pool gated by holder size. Sprite data sourced from CryptoPunksData (CC0).",',
            '"image":"data:image/svg+xml;base64,', svgB64, '",',
            '"attributes":', attrs, '}'
        );
        return string.concat("data:application/json;base64,", _b64(bytes(json)));
    }

    function renderSVG(bytes32 seed, uint256 holderPhunkCount) public view returns (string memory) {
        return _renderFromPicks(_pick(seed, _tier(holderPhunkCount)));
    }

    // -------- tier system --------

    /// @notice Holder tier from Phunk count.
    /// 0 = ≥1 (base humans, common attrs)
    /// 1 = ≥100  (+ chains, top hats, clown hair)
    /// 2 = ≥1000 (+ earrings, 3D glasses)
    /// 3 = ≥10000 (+ hoodies, beanies, aliens/zombies/apes)
    function _tier(uint256 phunkCount) internal pure returns (uint8) {
        if (phunkCount >= 10000) return 3;
        if (phunkCount >= 1000)  return 2;
        if (phunkCount >= 100)   return 1;
        return 0;
    }

    function _tierName(uint8 t) internal pure returns (string memory) {
        if (t == 0) return "Common";
        if (t == 1) return "Notable";
        if (t == 2) return "Rare";
        return "Legendary";
    }

    /// @dev Minimum tier required to use a given asset index. 0 = always available.
    function _tierForAsset(uint8 idx) internal pure returns (uint8) {
        // Rare base types (Zombie, Ape, Alien) — Legendary
        if (idx == 9 || idx == 10 || idx == 11) return 3;

        // Tier 3: hoodies and beanies
        if (idx == 67) return 3;            // Hoodie
        if (idx == 37 || idx == 113) return 3; // Beanie, Knitted Cap (female beanie)

        // Tier 2: earrings, 3D glasses
        if (idx == 61 || idx == 125) return 2; // Earring (male/female)
        if (idx == 72 || idx == 84)  return 2; // 3D Glasses (male/female)

        // Tier 1: chains, top hats, clown hair
        if (idx == 33 || idx == 68) return 1;     // Silver Chain, Gold Chain
        if (idx == 46) return 1;                   // Top Hat
        if (idx == 14 || idx == 104) return 1;    // Clown Hair Green (male/female)

        return 0;
    }

    /// @dev Derive a 256-bit slot from (seed, slotId) so picks are independent
    /// per slot but deterministic per (seed, tier).
    function _slot(bytes32 seed, uint8 slotId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, slotId)));
    }

    function _pick(bytes32 seed, uint8 tier) internal pure returns (Picks memory p) {
        // Base types: 1..8 always (humans). Tier 3 unlocks 9-11 too.
        uint8 baseMax = tier >= 3 ? 11 : 8;
        p.base = uint8((_slot(seed, 0) % baseMax) + 1);

        p.attr1 = _pickAttr(seed, 1, tier);
        p.attr2 = _pickAttr(seed, 2, tier);
        p.attr3 = _pickAttr(seed, 3, tier);
    }

    /// @dev Pick a single attribute with bounded retries. If we can't find one
    /// allowed at the tier in 32 attempts we return a guaranteed-tier-0 attr.
    function _pickAttr(bytes32 seed, uint8 slotId, uint8 tier) internal pure returns (uint8) {
        uint16 range = uint16(ATTR_MAX) - uint16(ATTR_MIN) + 1;
        uint256 s = _slot(seed, slotId);
        for (uint256 i = 0; i < 32; i++) {
            uint8 candidate = uint8((s % range) + ATTR_MIN);
            if (_tierForAsset(candidate) <= tier) return candidate;
            // reshuffle bits and try again
            s = uint256(keccak256(abi.encode(s, i)));
        }
        return ATTR_MIN; // Rosy Cheeks — guaranteed tier 0
    }

    function _renderFromPicks(Picks memory p) internal view returns (string memory) {
        bytes memory pixels = new bytes(2304); // 24*24*4 RGBA
        _composite(pixels, p.base);
        _composite(pixels, p.attr1);
        _composite(pixels, p.attr2);
        _composite(pixels, p.attr3);
        return _toSvg(pixels);
    }

    /// @notice Verification helper. Composites the given asset indices in order
    /// and returns the raw 2304-byte (24*24 RGBA) pixel buffer — same format as
    /// CryptopunksData.punkImage(uint16). Useful for byte-for-byte equivalence tests.
    function renderPixels(uint8[] memory indices) external view returns (bytes memory pixels) {
        pixels = new bytes(2304);
        for (uint256 i = 0; i < indices.length; i++) {
            _composite(pixels, indices[i]);
        }
    }

    /// @dev Apply asset[idx] sprite onto the pixel buffer.
    /// Encoding: every 3 bytes = (xBlock<<4|yBlock, paletteIdx, opaqueMask<<4|blackMask).
    /// Each entry covers a 2x2 block, with bits indicating which sub-pixels to paint.
    function _composite(bytes memory pixels, uint8 idx) internal view {
        if (idx == 0) return;
        bytes memory a = data.asset(idx);
        bytes memory pal = data.palette();
        uint256 n = a.length / 3;
        for (uint256 i = 0; i < n; i++) {
            uint8 b0 = uint8(a[i * 3]);
            uint8 pIdx = uint8(a[i * 3 + 1]);
            uint8 b2 = uint8(a[i * 3 + 2]);
            uint256 xb = (b0 >> 4) & 0xf;
            uint256 yb = b0 & 0xf;
            uint8 opaque = (b2 >> 4) & 0xf;
            uint8 black  = b2 & 0xf;

            for (uint256 dx = 0; dx < 2; dx++) {
                for (uint256 dy = 0; dy < 2; dy++) {
                    uint256 p = ((2 * yb + dy) * 24 + (2 * xb + dx)) * 4;
                    uint8 bit = uint8(dx * 2 + dy);
                    if (opaque & (uint8(1) << bit) != 0) {
                        // palette[pIdx*4 .. +4]
                        uint256 off = uint256(pIdx) * 4;
                        uint8 alpha = uint8(pal[off + 3]);
                        if (alpha == 0xff) {
                            pixels[p]     = pal[off];
                            pixels[p + 1] = pal[off + 1];
                            pixels[p + 2] = pal[off + 2];
                            pixels[p + 3] = bytes1(uint8(0xff));
                        }
                        // semi-transparent (composites table) — skip in v1
                    } else if (black & (uint8(1) << bit) != 0) {
                        pixels[p]     = 0;
                        pixels[p + 1] = 0;
                        pixels[p + 2] = 0;
                        pixels[p + 3] = bytes1(uint8(0xff));
                    }
                }
            }
        }
    }

    function _toSvg(bytes memory pixels) internal pure returns (string memory) {
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" shape-rendering="crispEdges" width="240" height="240">',
            '<rect width="24" height="24" fill="#', BG_HEX, '"/>',
            '<g transform="translate(24 0) scale(-1 1)">'
        );
        for (uint256 y = 0; y < 24; y++) {
            for (uint256 x = 0; x < 24; x++) {
                uint256 p = (y * 24 + x) * 4;
                if (uint8(pixels[p + 3]) > 0) {
                    svg = string.concat(
                        svg,
                        '<rect x="', _u(x), '" y="', _u(y),
                        '" width="1" height="1" fill="#',
                        _hex2(uint8(pixels[p])),
                        _hex2(uint8(pixels[p + 1])),
                        _hex2(uint8(pixels[p + 2])),
                        '"/>'
                    );
                }
            }
        }
        return string.concat(svg, '</g></svg>');
    }

    // -------- helpers --------

    bytes16 internal constant _HEX = "0123456789abcdef";

    function _hex2(uint8 v) internal pure returns (string memory) {
        bytes memory b = new bytes(2);
        b[0] = _HEX[v >> 4];
        b[1] = _HEX[v & 0x0f];
        return string(b);
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j = v; uint256 len;
        while (j != 0) { len++; j /= 10; }
        bytes memory b = new bytes(len);
        while (v != 0) { len--; b[len] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }

    function _b64(bytes memory dataBytes) internal pure returns (string memory) {
        if (dataBytes.length == 0) return "";
        string memory tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 encodedLen = 4 * ((dataBytes.length + 2) / 3);
        bytes memory result = new bytes(encodedLen);
        assembly {
            let tablePtr := add(tbl, 1)
            let dataPtr  := dataBytes
            let endPtr   := add(dataPtr, mload(dataBytes))
            let resultPtr := add(result, 32)
            for {} lt(dataPtr, endPtr) {} {
                dataPtr := add(dataPtr, 3)
                let input := mload(dataPtr)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(18, input), 0x3F)))) resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(12, input), 0x3F)))) resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr( 6, input), 0x3F)))) resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(        input,  0x3F)))) resultPtr := add(resultPtr, 1)
            }
            switch mod(mload(dataBytes), 3)
            case 1 {
                mstore8(sub(resultPtr, 1), 0x3d)
                mstore8(sub(resultPtr, 2), 0x3d)
            }
            case 2 {
                mstore8(sub(resultPtr, 1), 0x3d)
            }
        }
        return string(result);
    }
}
