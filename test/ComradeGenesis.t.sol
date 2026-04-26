// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}    from "forge-std/Test.sol";
import {ComradeSpriteData} from "../src/ComradeSpriteData.sol";
import {ComradeRenderer}   from "../src/ComradeRenderer.sol";
import {ComradeTaxonomy}   from "../src/ComradeTaxonomy.sol";
import {ComradeGenesis}    from "../src/ComradeGenesis.sol";

contract ComradeGenesisTest is Test {
    ComradeSpriteData spriteData;
    ComradeTaxonomy   taxonomy;
    ComradeRenderer   renderer;
    ComradeGenesis    genesis;

    /// @dev Owner of CDC token-id 0 (Comrade #1) at the time of our holder snapshot.
    address constant CDC_OG = 0xEbfD774c1C2008E56cE40E0a4504Ebecc81b1921;

    function setUp() public {
        spriteData = new ComradeSpriteData();
        taxonomy   = new ComradeTaxonomy();
        renderer   = new ComradeRenderer(spriteData, taxonomy);
        genesis    = new ComradeGenesis(CDC_OG, renderer);
    }

    function test_minted_to_cdc_og_at_deploy() public view {
        assertEq(genesis.ownerOf(0), CDC_OG, "genesis goes to CDC #1 holder");
        assertEq(genesis.balanceOf(CDC_OG), 1);
    }

    function test_token_uri_renders() public view {
        string memory uri = genesis.tokenURI(0);
        assertTrue(bytes(uri).length > 1000, "non-trivial uri");
        // Loose checks on JSON content
        bytes memory u = bytes(uri);
        assertTrue(_contains(uri, '"name":"Genesis Bytecode Comrade #0"'));
        assertTrue(_contains(uri, '"value":"CDC #1"'));
        assertTrue(_contains(uri, '"Soulbound"'));
    }

    function test_soulbound_blocks_transferFrom() public {
        vm.prank(CDC_OG);
        vm.expectRevert(ComradeGenesis.Soulbound.selector);
        genesis.transferFrom(CDC_OG, address(0xBEEF), 0);
    }

    function test_soulbound_blocks_safeTransferFrom() public {
        vm.prank(CDC_OG);
        vm.expectRevert(ComradeGenesis.Soulbound.selector);
        genesis.safeTransferFrom(CDC_OG, address(0xBEEF), 0);
    }

    function test_soulbound_blocks_approve() public {
        vm.prank(CDC_OG);
        vm.expectRevert(ComradeGenesis.Soulbound.selector);
        genesis.approve(address(0xBEEF), 0);
    }

    function test_soulbound_blocks_setApprovalForAll() public {
        vm.prank(CDC_OG);
        vm.expectRevert(ComradeGenesis.Soulbound.selector);
        genesis.setApprovalForAll(address(0xBEEF), true);
    }

    /// @notice Dump the genesis SVG for visual inspection.
    function test_dump_genesis_svg() public {
        uint16[] memory ids = new uint16[](5);
        ids[0] = 13; ids[1] = 22; ids[2] = 69; ids[3] = 106; ids[4] = 175;
        string memory svg = renderer.renderSVG(ids, false, "");
        vm.writeFile("samples/comrade_genesis.svg", svg);
        console2.log("wrote samples/comrade_genesis.svg, size:", bytes(svg).length);
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
