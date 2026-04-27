// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}      from "forge-std/Test.sol";
import {ComradeSpriteData}   from "../src/ComradeSpriteData.sol";
import {ComradeSpriteChunk0} from "../src/ComradeSpriteChunk0.sol";
import {ComradeSpriteChunk1} from "../src/ComradeSpriteChunk1.sol";
import {ComradeSpriteChunk2} from "../src/ComradeSpriteChunk2.sol";
import {ComradeSpriteChunk3} from "../src/ComradeSpriteChunk3.sol";
import {ComradeSpriteChunk4} from "../src/ComradeSpriteChunk4.sol";
import {ComradeRenderer}     from "../src/ComradeRenderer.sol";
import {ComradeTaxonomy}     from "../src/ComradeTaxonomy.sol";

contract ComradeRenderTest is Test {
    ComradeSpriteData spriteData;
    ComradeTaxonomy   taxonomy;
    ComradeRenderer   renderer;

    function setUp() public {
        address[5] memory chunks = [
            address(new ComradeSpriteChunk0()),
            address(new ComradeSpriteChunk1()),
            address(new ComradeSpriteChunk2()),
            address(new ComradeSpriteChunk3()),
            address(new ComradeSpriteChunk4())
        ];
        spriteData = new ComradeSpriteData(chunks);
        taxonomy   = new ComradeTaxonomy();
        renderer   = new ComradeRenderer(spriteData, taxonomy);
    }

    function test_palette_size() public view {
        assertEq(spriteData.PALETTE_SIZE(), 1401, "1401-color palette");
    }

    function test_sprite_count() public view {
        assertEq(spriteData.SPRITE_COUNT(), 323, "323 sprites encoded");
    }

    function test_known_sprite_names() public view {
        assertEq(spriteData.name(13),  "Sir Pinkalot");
        assertEq(spriteData.name(22),  "Alien People");
        assertEq(spriteData.name(69),  "Hardbass Uniform");
        assertEq(spriteData.name(106), "Beard of the Gods");
        assertEq(spriteData.name(175), "Aviators");
    }

    /// @notice Render item #0 (CDC #1 homage) using the looked-up sprite IDs.
    function test_render_item_zero_to_disk() public {
        uint16[] memory ids = new uint16[](5);
        ids[0] = 13;   // Sir Pinkalot   (background)
        ids[1] = 22;   // Alien People   (body)
        ids[2] = 69;   // Hardbass Uniform (clothes)
        ids[3] = 106;  // Beard of the Gods (mouth)
        ids[4] = 175;  // Aviators       (eyes)

        string memory svg = renderer.renderSVG(ids, false, "");
        vm.writeFile("samples/comrade_0.svg", svg);
        console2.log("wrote samples/comrade_0.svg, size:", bytes(svg).length);

        // Sanity: SVG should be non-trivial
        assertTrue(bytes(svg).length > 1000, "non-trivial SVG output");
        // Check for expected content
        assertTrue(_contains(svg, "viewBox='0 0 32 32'"), "32x32 viewBox");
    }

    function test_picker_returns_required_categories() public view {
        // Required categories: Background (0..21), Type (22..42), Eyes (172..238)
        // The picker MUST always include these three.
        for (uint256 i = 0; i < 5; i++) {
            bytes32 seed = keccak256(abi.encode("seed", i));
            uint16[] memory ids = renderer.pick(seed);
            bool hasBg = false; bool hasType = false; bool hasEyes = false;
            for (uint256 k = 0; k < ids.length; k++) {
                uint16 id = ids[k];
                if (id < 22) hasBg = true;
                else if (id < 43) hasType = true;
                else if (id >= 172 && id < 239) hasEyes = true;
            }
            assertTrue(hasBg, "BG always included");
            assertTrue(hasType, "Type always included");
            assertTrue(hasEyes, "Eyes always included");
            assertGe(ids.length, 3);
            assertLe(ids.length, 9);
        }
    }

    function test_picker_distribution_matches_cdc() public view {
        // Sample 1000 picks. Trait counts should follow CDC's distribution
        // (peak at 6, range 3-9).
        uint256[10] memory counts;
        for (uint256 i = 0; i < 1000; i++) {
            bytes32 seed = keccak256(abi.encode("dist", i));
            uint16[] memory ids = renderer.pick(seed);
            counts[ids.length]++;
        }
        // Sanity: most should be 5-7 traits
        uint256 mid = counts[5] + counts[6] + counts[7];
        assertGt(mid, 700, "majority of picks have 5-7 traits");
    }

    function test_tokenURI_from_seed() public view {
        bytes32 seed = bytes32(uint256(0xCAFE));
        string memory uri = renderer.tokenURI(42, seed);
        assertTrue(_contains(uri, '"name":"Bytecode Comrade #42"'), "named correctly");
        assertTrue(_contains(uri, '"trait_type":"Background"'), "BG attribute");
        assertTrue(_contains(uri, '"trait_type":"Type"'), "Type attribute");
        assertTrue(_contains(uri, '"trait_type":"Eyes"'), "Eyes attribute");
    }

    function test_render_with_flip_and_bg() public {
        uint16[] memory ids = new uint16[](2);
        ids[0] = 13;  // Sir Pinkalot
        ids[1] = 22;  // Alien People

        string memory svg = renderer.renderSVG(ids, true, "c3ff00");
        assertTrue(_contains(svg, "#c3ff00"),                            "bg present");
        assertTrue(_contains(svg, "translate(32 0) scale(-1 1)"),        "flip transform");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) { ok = false; break; }
            }
            if (ok) return true;
        }
        return false;
    }
}
