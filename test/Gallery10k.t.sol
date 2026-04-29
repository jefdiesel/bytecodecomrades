// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}        from "forge-std/Test.sol";
import {ComradeSpriteData}     from "../src/ComradeSpriteData.sol";
import {ComradeSpriteChunk0}   from "../src/ComradeSpriteChunk0.sol";
import {ComradeSpriteChunk1}   from "../src/ComradeSpriteChunk1.sol";
import {ComradeSpriteChunk2}   from "../src/ComradeSpriteChunk2.sol";
import {ComradeSpriteChunk3}   from "../src/ComradeSpriteChunk3.sol";
import {ComradeSpriteChunk4}   from "../src/ComradeSpriteChunk4.sol";
import {ComradeRenderer}       from "../src/ComradeRenderer.sol";
import {ComradeTaxonomy}       from "../src/ComradeTaxonomy.sol";

/// Render the full 10,000-Comrade preview to a single HTML at site/test/index.html.
contract Gallery10k is Test {
    ComradeRenderer renderer;

    function setUp() public {
        address[5] memory chunks = [
            address(new ComradeSpriteChunk0()),
            address(new ComradeSpriteChunk1()),
            address(new ComradeSpriteChunk2()),
            address(new ComradeSpriteChunk3()),
            address(new ComradeSpriteChunk4())
        ];
        ComradeSpriteData spriteData = new ComradeSpriteData(chunks);
        ComradeTaxonomy   taxonomy   = new ComradeTaxonomy();
        renderer = new ComradeRenderer(spriteData, taxonomy);
    }

    function test_render_10k_to_html() public {
        string memory path = "site/test/index.html";
        vm.writeFile(path, _header());

        for (uint256 i = 0; i < 10_000; i++) {
            bytes32 seed = keccak256(abi.encode("bcc-test-10k-v1", i));
            uint16[] memory ids = renderer.pick(seed);
            string memory svg = renderer.renderSVG(ids, false, "");
            string memory card = string.concat(
                "<div class='c'><div class='n'>#", _u(i), "</div>",
                "<div class='img'>", svg, "</div></div>"
            );
            vm.writeLine(path, card);
            if (i % 500 == 499) console2.log("rendered:", i + 1);
        }

        vm.writeLine(path, "</div></body></html>");
        console2.log("wrote site/test/index.html");
    }

    function _header() internal pure returns (string memory) {
        return string.concat(
            "<!doctype html><html><head><meta charset='utf-8'>",
            "<title>BCC test 10k</title>",
            "<link rel='icon' type='image/svg+xml' href='/favicon.svg'>",
            "<style>",
            "body{background:#0a0a0a;color:#e8e8e8;font:11px ui-monospace,monospace;padding:16px;margin:0;}",
            "h1{color:#c3ff00;font-size:18px;letter-spacing:2px;margin:0 0 8px;}",
            "p{color:#888;font-size:11px;margin:0 0 16px;}",
            ".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:4px;}",
            ".c{background:#000;border:1px solid #1a1a1a;border-radius:3px;}",
            ".n{padding:2px 4px;color:#888;font-size:9px;}",
            ".img{aspect-ratio:1;image-rendering:pixelated;background:#000;overflow:hidden;}",
            ".img svg{width:100%!important;height:100%!important;display:block;image-rendering:pixelated;image-rendering:crisp-edges;}",
            "</style></head><body>",
            "<h1>BCC TEST GALLERY - 10,000 PROCEDURAL COMRADES</h1>",
            "<p>Rendered offline by the same on-chain renderer. This is a static preview of the 10k pre-image space; the actual on-chain mints depend on swap-driven seeds.</p>",
            "<div class='grid'>"
        );
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
