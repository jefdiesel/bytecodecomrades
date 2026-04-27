// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}    from "forge-std/Test.sol";
import {Comrade404}          from "../src/Comrade404.sol";
import {ComradeRenderer}     from "../src/ComradeRenderer.sol";
import {ComradeSpriteData}   from "../src/ComradeSpriteData.sol";
import {ComradeSpriteChunk0} from "../src/ComradeSpriteChunk0.sol";
import {ComradeSpriteChunk1} from "../src/ComradeSpriteChunk1.sol";
import {ComradeSpriteChunk2} from "../src/ComradeSpriteChunk2.sol";
import {ComradeSpriteChunk3} from "../src/ComradeSpriteChunk3.sol";
import {ComradeSpriteChunk4} from "../src/ComradeSpriteChunk4.sol";
import {ComradeTaxonomy}     from "../src/ComradeTaxonomy.sol";
import {ISeedSource}       from "../src/ISeedSource.sol";
import {IComradeRenderer}  from "../src/IComradeRenderer.sol";

contract MockSeed is ISeedSource {
    bytes32 public override currentSeed = bytes32(uint256(0xC0FFEE));
    uint64  public override swapCount   = 1;
    function bump(bytes32 s) external { currentSeed = s; unchecked { swapCount++; } }
}

contract Comrade404Test is Test {
    Comrade404        token;
    ComradeRenderer   renderer;
    ComradeSpriteData spriteData;
    ComradeTaxonomy   taxonomy;
    MockSeed          seedSrc;

    address treasury = makeAddr("treasury");
    address alice    = makeAddr("alice");

    function setUp() public {
        seedSrc    = new MockSeed();
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
        // 32 max comrades, 1 token each (simple ratio for tests)
        token      = new Comrade404(seedSrc, payable(treasury), 32, 1 ether);
        token.setRenderer(IComradeRenderer(address(renderer)));
    }

    function test_initial_state() public view {
        assertEq(token.totalSupply(), 32 ether);
        assertEq(token.maxComrades(), 32);
        assertEq(token.balanceOf(treasury), 32 ether);
        assertTrue(token.skipComrades(treasury));
    }

    function test_threshold_mint() public {
        vm.prank(treasury);
        token.transfer(alice, 1 ether);
        assertEq(token.comradesOwned(alice), 1);
    }

    function test_tokenURI_renders_procedurally() public {
        vm.prank(treasury);
        token.transfer(alice, 1 ether);
        uint256 id = token.inventoryOf(alice)[0];
        string memory uri = token.tokenURI(id);
        assertTrue(bytes(uri).length > 1000, "non-trivial uri");
        assertTrue(_contains(uri, "Bytecode Comrade #"), "named");
    }

    function test_lifo_burn() public {
        vm.prank(treasury);
        token.transfer(alice, 5 ether);
        uint256 og = token.inventoryOf(alice)[0];

        vm.prank(alice);
        token.transfer(makeAddr("bob"), 3 ether);

        // alice still has 2; her oldest survives
        assertEq(token.comradesOwned(alice), 2);
        assertEq(token.inventoryOf(alice)[0], og, "OG survives partial sells");
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
