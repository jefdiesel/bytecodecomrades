// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ComradeSpriteData} from "./ComradeSpriteData.sol";
import {ComradeTaxonomy}   from "./ComradeTaxonomy.sol";

/// @notice Renders a Comrade by compositing CDC trait sprites in z-order.
///
/// Sprite encoding (from data/encode_sprites.py):
///   - 32x32 pixels, row-major
///   - Run-length pairs: (count: u8, paletteIdx: u16 BE)
///   - paletteIdx 0 = transparent, otherwise lookup in shared 1401-color RGBA palette
///
/// Renderer:
///   - Walks given sprite ids in order, decoding RLE and writing into a 32*32*4
///     RGBA pixel buffer. Later sprites overwrite earlier ones.
///   - Output: SVG with optional horizontal flip + background fill.
contract ComradeRenderer {
    ComradeSpriteData public immutable data;
    ComradeTaxonomy   public immutable taxonomy;

    constructor(ComradeSpriteData _data, ComradeTaxonomy _taxonomy) {
        data = _data;
        taxonomy = _taxonomy;
    }

    /// @notice Procedural pick: derive trait sprite IDs from a seed via the
    /// CDC-frequency-weighted taxonomy. Returns at least 3 ids (BG, Type, Eyes
    /// always required) and up to 9 ids (one per visual category).
    function pick(bytes32 seed) public view returns (uint16[] memory ids) {
        // Two-pass: first determine which categories are included, then pick values.
        bool[9] memory include;
        uint8 count = 0;
        for (uint8 cat = 0; cat < 9; cat++) {
            uint16 r = uint16(uint256(keccak256(abi.encode(seed, "incl", cat))));
            if (taxonomy.shouldInclude(cat, r)) {
                include[cat] = true;
                count++;
            }
        }

        // Draw order: BG, Type, Skin, Cloths, Head, Audio, Mouth, Eyes, Relics.
        // Head paints first among the face layers so big hats/hair don't cover
        // audio gear, the mouth, or glasses. Eyes paint last so glasses sit
        // on top of everything.
        uint8[9] memory drawOrder = [uint8(0),1,2,3,7,4,5,6,8];

        ids = new uint16[](count);
        uint8 idx = 0;
        for (uint8 i = 0; i < 9; i++) {
            uint8 cat = drawOrder[i];
            if (!include[cat]) continue;
            uint256 r = uint256(keccak256(abi.encode(seed, "val", cat)));
            ids[idx++] = taxonomy.pickValue(cat, r);
        }
    }

    /// @notice Render a procedurally-picked Comrade from a seed.
    function renderFromSeed(bytes32 seed) external view returns (string memory) {
        return _render(pick(seed), false, "");
    }

    /// @notice Build the data:application/json metadata blob for a Comrade.
    function tokenURI(uint256 id, bytes32 seed) external view returns (string memory) {
        uint16[] memory ids = pick(seed);
        string memory svg = _render(ids, false, "");
        // Build attributes from picked ids
        string memory attrs = "[";
        for (uint256 i = 0; i < ids.length; i++) {
            if (i > 0) attrs = string.concat(attrs, ",");
            attrs = string.concat(attrs,
                '{"trait_type":"', _categoryNameForSprite(ids[i]), '","value":"',
                data.name(ids[i]), '"}');
        }
        attrs = string.concat(attrs, "]");

        return string.concat(
            "data:application/json;utf8,",
            '{"name":"Bytecode Comrade #', _u(id),
            '","description":"On-chain Comrade. Procedurally generated using CDC trait sprites (CC0). Trait roll determined by Uniswap v4 swap activity.",',
            '"image":"data:image/svg+xml;utf8,', svg, '",',
            '"attributes":', attrs, '}'
        );
    }

    /// @dev Look up category metadata-name from a sprite id (for tokenURI traits).
    function _categoryNameForSprite(uint16 spriteId) internal pure returns (string memory) {
        // Boundaries from data/sprite_table.json (computed by encode_sprites.py):
        // 10_Backgrounds  starts at 0
        // 08_Type         starts at 22
        // 07_Skin Stuff   starts at 43
        // 06_Cloths       starts at 51
        // 04_Audio        starts at 85
        // 03_Mouth        starts at 101
        // 02_Eyes         starts at 172
        // 05_Head         starts at 239
        // 01_Relics       starts at 316
        if (spriteId < 22)  return "Background";
        if (spriteId < 43)  return "Type";
        if (spriteId < 51)  return "Skin Stuff";
        if (spriteId < 85)  return "Cloths";
        if (spriteId < 101) return "Audio Indexer Derivations";
        if (spriteId < 172) return "Mouth";
        if (spriteId < 239) return "Eyes";
        if (spriteId < 316) return "Head";
        return "Relics";
    }

    function _render(uint16[] memory spriteIds, bool flipHorizontal, string memory bgHex)
        internal view returns (string memory)
    {
        bytes memory pixels = new bytes(4096);
        bytes memory palette = data.palette();
        for (uint256 i = 0; i < spriteIds.length; i++) {
            _composite(pixels, palette, data.sprite(spriteIds[i]));
        }
        return _toSvg(pixels, flipHorizontal, bgHex);
    }

    /// @notice Composite given sprite indices into a 32*32*4 RGBA buffer.
    /// Sprites later in the array overwrite earlier ones (z-order = array order).
    function renderPixels(uint16[] memory spriteIds) external view returns (bytes memory pixels) {
        pixels = new bytes(4096);  // 32*32*4
        bytes memory palette = data.palette();
        for (uint256 i = 0; i < spriteIds.length; i++) {
            _composite(pixels, palette, data.sprite(spriteIds[i]));
        }
    }

    /// @notice Full SVG output. Optionally flip horizontal + add a bg fill.
    function renderSVG(uint16[] memory spriteIds, bool flipHorizontal, string memory bgHex)
        external view returns (string memory)
    {
        bytes memory pixels = new bytes(4096);
        bytes memory palette = data.palette();
        for (uint256 i = 0; i < spriteIds.length; i++) {
            _composite(pixels, palette, data.sprite(spriteIds[i]));
        }
        return _toSvg(pixels, flipHorizontal, bgHex);
    }

    // -------- internals --------

    /// @dev Walk RLE-encoded sprite, alpha-blend into the pixel buffer at the
    /// right position. Each run is 3 bytes: (count: u8, paletteIdx: u16 BE).
    /// Uses Porter-Duff "over" so semi-transparent palette pixels (lasers, lens
    /// tints, glows) blend with whatever has already been drawn underneath
    /// instead of overwriting it.
    function _composite(bytes memory pixels, bytes memory palette, bytes memory sprite_) internal pure {
        uint256 pos = 0;
        uint256 i = 0;
        uint256 spriteLen = sprite_.length;
        while (i < spriteLen) {
            uint256 count = uint8(sprite_[i]);
            uint256 idx = (uint256(uint8(sprite_[i + 1])) << 8) | uint256(uint8(sprite_[i + 2]));
            i += 3;
            if (idx == 0) {
                pos += count;
                continue;
            }
            uint256 colorOff = idx * 4;
            for (uint256 k = 0; k < count; k++) {
                _blendOne(pixels, (pos + k) * 4, palette, colorOff);
            }
            pos += count;
        }
    }

    /// @dev Porter-Duff "over": src is the palette pixel at `srcOff` (4 bytes:
    /// R,G,B,A), dst is `pixels[pixelOff..pixelOff+4]`. Writes the blended RGBA
    /// back to dst.
    function _blendOne(
        bytes memory pixels, uint256 pixelOff,
        bytes memory palette, uint256 srcOff
    ) private pure {
        uint256 sa = uint8(palette[srcOff + 3]);
        if (sa == 255) {
            pixels[pixelOff]     = palette[srcOff];
            pixels[pixelOff + 1] = palette[srcOff + 1];
            pixels[pixelOff + 2] = palette[srcOff + 2];
            pixels[pixelOff + 3] = bytes1(uint8(255));
            return;
        }
        uint256 da = uint8(pixels[pixelOff + 3]);
        if (da == 0) {
            pixels[pixelOff]     = palette[srcOff];
            pixels[pixelOff + 1] = palette[srcOff + 1];
            pixels[pixelOff + 2] = palette[srcOff + 2];
            pixels[pixelOff + 3] = palette[srcOff + 3];
            return;
        }
        // out_a = sa + da*(255 - sa)/255
        uint256 oneMinusSa = 255 - sa;
        uint256 oa = sa + (da * oneMinusSa) / 255;
        if (oa == 0) {
            pixels[pixelOff + 3] = 0;
            return;
        }
        // For each channel: out = (src*sa + dst*da*(255-sa)/255) / oa
        pixels[pixelOff]     = bytes1(uint8(_blendChan(uint8(palette[srcOff]),     uint8(pixels[pixelOff]),     sa, da, oneMinusSa, oa)));
        pixels[pixelOff + 1] = bytes1(uint8(_blendChan(uint8(palette[srcOff + 1]), uint8(pixels[pixelOff + 1]), sa, da, oneMinusSa, oa)));
        pixels[pixelOff + 2] = bytes1(uint8(_blendChan(uint8(palette[srcOff + 2]), uint8(pixels[pixelOff + 2]), sa, da, oneMinusSa, oa)));
        pixels[pixelOff + 3] = bytes1(uint8(oa));
    }

    function _blendChan(uint256 s, uint256 d, uint256 sa, uint256 da, uint256 oneMinusSa, uint256 oa)
        private pure returns (uint256)
    {
        uint256 num = s * sa * 255 + d * da * oneMinusSa;
        uint256 v = num / (oa * 255);
        return v > 255 ? 255 : v;
    }

    function _toSvg(bytes memory pixels, bool flipHorizontal, string memory bgHex)
        internal pure returns (string memory)
    {
        // NOTE: SVG uses SINGLE quotes throughout so it can be safely embedded
        // in a double-quoted JSON string field without escaping.
        string memory header = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32' shape-rendering='crispEdges' width='320' height='320'>",
            bytes(bgHex).length > 0
                ? string.concat("<rect width='32' height='32' fill='#", bgHex, "'/>")
                : "",
            flipHorizontal ? "<g transform='translate(32 0) scale(-1 1)'>" : ""
        );

        // Row-level RLE: walk each row, coalesce consecutive pixels that share
        // the same RGBA into one wider rect. Cuts rect count for backgrounds
        // from 1024 → 32. Sub-255 alpha emits fill-opacity so semi-transparent
        // pixels (lasers, lens tints, glow) render correctly instead of becoming
        // fully opaque.
        string memory body = "";
        for (uint256 y = 0; y < 32; y++) {
            uint256 x = 0;
            while (x < 32) {
                uint256 p = (y * 32 + x) * 4;
                uint8 a = uint8(pixels[p + 3]);
                if (a == 0) { x++; continue; }
                bytes1 r = pixels[p];
                bytes1 g = pixels[p + 1];
                bytes1 b = pixels[p + 2];
                uint256 w = 1;
                while (x + w < 32) {
                    uint256 q = (y * 32 + x + w) * 4;
                    if (uint8(pixels[q + 3]) != a) break;
                    if (pixels[q] != r || pixels[q+1] != g || pixels[q+2] != b) break;
                    w++;
                }
                body = string.concat(
                    body,
                    "<rect x='", _u(x), "' y='", _u(y),
                    "' width='", _u(w), "' height='1' fill='#",
                    _hex2(uint8(r)), _hex2(uint8(g)), _hex2(uint8(b)),
                    a == 255 ? "'/>" : string.concat("' fill-opacity='", _alphaFrac(a), "'/>")
                );
                x += w;
            }
        }

        return string.concat(
            header,
            body,
            flipHorizontal ? "</g></svg>" : "</svg>"
        );
    }

    bytes16 internal constant _HEX = "0123456789abcdef";

    /// @dev Convert a 0-255 alpha to a 0.000-1.000 fractional string (3 decimals).
    /// SVG accepts both `fill-opacity='0.5'` and percent forms; fraction keeps it small.
    function _alphaFrac(uint8 a) internal pure returns (string memory) {
        // 1000 * a / 255 — gives e.g. 128 → 502, render as "0.502"
        uint256 v = (uint256(a) * 1000) / 255;
        if (v >= 1000) return "1";
        // 3-digit zero-padded fractional
        bytes memory out = new bytes(5); // "0.xxx"
        out[0] = "0"; out[1] = ".";
        out[2] = bytes1(uint8(48 + (v / 100) % 10));
        out[3] = bytes1(uint8(48 + (v / 10) % 10));
        out[4] = bytes1(uint8(48 + v % 10));
        return string(out);
    }

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
}
