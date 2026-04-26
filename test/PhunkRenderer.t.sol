// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}  from "forge-std/Test.sol";
import {Phunk404}        from "../src/Phunk404.sol";
import {PhunkRenderer}   from "../src/PhunkRenderer.sol";
import {PhunkSpriteData} from "../src/PhunkSpriteData.sol";
import {ISeedSource}     from "../src/ISeedSource.sol";
import {IPhunkRenderer}  from "../src/IPhunkRenderer.sol";

contract MockSeed is ISeedSource {
    bytes32 public override currentSeed = bytes32(uint256(0xC0FFEE));
    uint64  public override swapCount   = 1;
    function bump(bytes32 s) external { currentSeed = s; unchecked { swapCount++; } }
}

contract PhunkRendererTest is Test {
    Phunk404      token;
    PhunkRenderer renderer;
    MockSeed      seedSrc;
    address treasury = makeAddr("treasury");
    address alice    = makeAddr("alice");

    PhunkSpriteData spriteData;

    function setUp() public {
        seedSrc    = new MockSeed();
        spriteData = new PhunkSpriteData();
        renderer   = new PhunkRenderer(spriteData);
        token      = new Phunk404(seedSrc, treasury, 32, 1 ether);
        token.setRenderer(renderer);
    }

    function test_svg_contains_background_and_flip() public view {
        string memory svg = renderer.renderSVG(bytes32(uint256(1)), 1);
        assertTrue(_contains(svg, '#c3ff00'), "background color present");
        assertTrue(_contains(svg, 'translate(24 0) scale(-1 1)'), "horizontal flip present");
        assertTrue(_contains(svg, 'viewBox="0 0 24 24"'), "24x24 viewBox");
        assertTrue(bytes(svg).length > 200, "non-trivial pixel rects emitted");
    }

    function test_token_uri_returns_base64_data_uri() public {
        seedSrc.bump(bytes32(uint256(0xBEEF)));
        vm.prank(treasury);
        token.transfer(alice, 1 ether);

        uint256 id = token.inventoryOf(alice)[0];
        string memory uri = token.tokenURI(id);

        assertTrue(_contains(uri, 'data:application/json;base64,'), "data URI prefix");
    }

    function test_renderer_emits_named_attributes_in_metadata() public {
        // Render direct (renderer.tokenURI) so we can decode and inspect the JSON.
        // Use a seed that picks known-existing trait names.
        bytes32 seed = bytes32(uint256(1));
        string memory uri = renderer.tokenURI(42, seed, 1);
        // strip "data:application/json;base64," prefix and decode
        string memory prefix = "data:application/json;base64,";
        bytes memory uriB = bytes(uri);
        bytes memory pre  = bytes(prefix);
        bytes memory b64  = new bytes(uriB.length - pre.length);
        for (uint256 i = 0; i < b64.length; ++i) b64[i] = uriB[pre.length + i];
        string memory json = string(_b64decode(b64));

        assertTrue(_contains(json, '"trait_type":"Type"'),    "Type attr present");
        assertTrue(_contains(json, '"trait_type":"Trait 1"'), "Trait 1 attr present");
        assertTrue(_contains(json, '"trait_type":"Trait 2"'), "Trait 2 attr present");
        assertTrue(_contains(json, '"trait_type":"Trait 3"'), "Trait 3 attr present");
        assertTrue(_contains(json, '"name":"Phunk #42"'),     "name with id");
    }

    function test_assetName_returns_canonical_names() public view {
        assertEq(spriteData.assetName(1),  "Male 1");
        assertEq(spriteData.assetName(11), "Alien");
        assertEq(spriteData.assetName(45), "Wild Hair");
        assertEq(spriteData.assetName(35), "Big Shades");
        assertEq(spriteData.assetName(67), "Hoodie");
    }

    function _b64decode(bytes memory s) internal pure returns (bytes memory) {
        bytes memory tbl = new bytes(123);
        bytes memory chars = bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");
        for (uint256 i = 0; i < chars.length; ++i) tbl[uint8(chars[i])] = bytes1(uint8(i));
        uint256 pad = 0;
        if (s.length >= 1 && s[s.length - 1] == "=") pad++;
        if (s.length >= 2 && s[s.length - 2] == "=") pad++;
        bytes memory out = new bytes((s.length / 4) * 3 - pad);
        uint256 j;
        for (uint256 i = 0; i + 3 < s.length; i += 4) {
            uint256 v = (uint256(uint8(tbl[uint8(s[i])]))     << 18)
                      | (uint256(uint8(tbl[uint8(s[i + 1])])) << 12)
                      | (uint256(uint8(tbl[uint8(s[i + 2])])) << 6)
                      |  uint256(uint8(tbl[uint8(s[i + 3])]));
            if (j     < out.length) out[j]     = bytes1(uint8((v >> 16) & 0xff));
            if (j + 1 < out.length) out[j + 1] = bytes1(uint8((v >>  8) & 0xff));
            if (j + 2 < out.length) out[j + 2] = bytes1(uint8(v & 0xff));
            j += 3;
        }
        return out;
    }

    function test_two_seeds_produce_different_svgs() public view {
        string memory a = renderer.renderSVG(bytes32(uint256(0xAAAA)), 1);
        string memory b = renderer.renderSVG(bytes32(uint256(0xBBBB)), 1);
        assertTrue(keccak256(bytes(a)) != keccak256(bytes(b)), "different seeds => different SVGs");
    }

    /// @notice Dump 8 sample SVGs to disk so you can open them in a browser.
    /// Run: `forge test --mt test_dump_samples -vv`
    function test_dump_samples() public {
        // Dump the same seed at each tier so you can see the tier-gating effect.
        bytes32 seed = keccak256(abi.encode("phunk-sample", uint256(1)));
        uint256[4] memory tierThresholds = [uint256(1), 100, 1000, 10000];
        for (uint256 t = 0; t < 4; ++t) {
            string memory svg = renderer.renderSVG(seed, tierThresholds[t]);
            string memory path = string.concat("samples/phunk_tier", _u(t), ".svg");
            vm.writeFile(path, svg);
            console2.log("wrote", path);
        }
        // Also dump 4 different seeds at tier 1
        for (uint256 i = 0; i < 4; ++i) {
            bytes32 s = keccak256(abi.encode("phunk-sample", i));
            string memory svg = renderer.renderSVG(s, 100);
            string memory path = string.concat("samples/phunk_", _u(i), ".svg");
            vm.writeFile(path, svg);
            console2.log("wrote", path);
        }
    }

    // ---- helpers ----

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

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j = v; uint256 len;
        while (j != 0) { len++; j /= 10; }
        bytes memory b = new bytes(len);
        while (v != 0) { len--; b[len] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }
}
