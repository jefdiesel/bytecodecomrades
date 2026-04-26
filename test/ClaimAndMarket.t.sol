// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2}  from "forge-std/Test.sol";
import {Phunk404}        from "../src/Phunk404.sol";
import {PhunkRare}       from "../src/PhunkRare.sol";
import {PhunkMarket}     from "../src/PhunkMarket.sol";
import {PhunkRenderer}   from "../src/PhunkRenderer.sol";
import {PhunkSpriteData} from "../src/PhunkSpriteData.sol";
import {ISeedSource}     from "../src/ISeedSource.sol";
import {IPhunkRare}      from "../src/IPhunkRare.sol";
import {IERC20Min}       from "../src/IERC20Min.sol";
import {IERC721}         from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

contract MockSeed is ISeedSource {
    bytes32 public override currentSeed = bytes32(uint256(0xC0FFEE));
    uint64  public override swapCount   = 1;
}

contract ClaimAndMarketTest is Test {
    Phunk404        token;
    PhunkRare       rare;
    PhunkMarket     market;
    PhunkRenderer   renderer;
    PhunkSpriteData spriteData;
    MockSeed        seedSrc;

    address treasury = makeAddr("treasury");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address feeRecv  = makeAddr("feeRecv");

    function setUp() public {
        seedSrc    = new MockSeed();
        spriteData = new PhunkSpriteData();
        renderer   = new PhunkRenderer(spriteData);
        token      = new Phunk404(seedSrc, treasury, 32, 1 ether);
        token.setRenderer(renderer);

        rare = new PhunkRare(address(token), renderer);
        token.setRare(IPhunkRare(address(rare)));

        market = new PhunkMarket(IERC721(address(rare)), IERC20Min(address(token)), feeRecv, 250); // 2.5% fee
    }

    // ---- claim ----

    function test_claim_creates_rare_and_burns_404_phunk() public {
        vm.prank(treasury);
        token.transfer(alice, 1 ether);

        uint256 phunkId = token.inventoryOf(alice)[0];
        (bytes32 originalSeed,,) = token.phunks(phunkId);

        vm.prank(alice);
        uint256 rareId = token.claim(phunkId);

        // 404 Phunk burned
        assertEq(token.phunkOwner(phunkId), address(0), "404 phunk burned");
        assertEq(token.phunksOwned(alice), 0, "alice's 404 inventory empty");

        // Rare minted
        assertEq(rare.ownerOf(rareId), alice, "rare owned by alice");
        (bytes32 rareSeed,,, ) = rare.rares(rareId);
        assertEq(rareSeed, originalSeed, "rare keeps the same seed");

        // PHUNK locked: alice's balance dropped, contract holds the wrapped amount
        assertEq(token.balanceOf(alice), 0, "alice's PHUNK consumed");
        assertEq(token.balanceOf(address(token)), 1 ether, "PHUNK locked in token contract");
    }

    function test_claim_records_locked_tier() public {
        // Give alice 100 Phunks → tier 1 holder
        vm.prank(treasury);
        token.transfer(alice, 32 ether); // alice owns 32 (full TEST_CAP)
        // She's not at tier 1 (needs 100), so champion is tier 0 — claim locks tier 0.

        uint256 phunkId = token.inventoryOf(alice)[0]; // her champion (oldest)
        vm.prank(alice);
        uint256 rareId = token.claim(phunkId);

        (, uint8 lockedTier,, ) = rare.rares(rareId);
        assertEq(lockedTier, 0, "tier locked at champion's effective value");
    }

    function test_claim_reverts_if_not_holder() public {
        vm.prank(treasury);
        token.transfer(alice, 1 ether);
        uint256 phunkId = token.inventoryOf(alice)[0];

        vm.expectRevert(Phunk404.NotPhunkHolder.selector);
        vm.prank(bob);
        token.claim(phunkId);
    }

    // ---- unclaim ----

    function test_unclaim_returns_phunk_and_phunk_token() public {
        vm.prank(treasury);
        token.transfer(alice, 1 ether);
        uint256 phunkId = token.inventoryOf(alice)[0];
        (bytes32 origSeed,,) = token.phunks(phunkId);

        vm.prank(alice);
        uint256 rareId = token.claim(phunkId);

        vm.prank(alice);
        uint256 newPhunkId = token.unclaim(rareId);

        // Rare burned
        vm.expectRevert();
        rare.ownerOf(rareId);

        // Alice has a fresh 404 Phunk again, PHUNK returned
        assertEq(token.balanceOf(alice), 1 ether, "PHUNK refunded");
        assertEq(token.phunksOwned(alice), 1, "alice has 1 phunk");
        (bytes32 newSeed,,) = token.phunks(newPhunkId);
        assertEq(newSeed, origSeed, "art ancestry preserved across roundtrip");
    }

    // ---- market list/buy ----

    function test_market_list_and_buy() public {
        // Alice claims a rare
        vm.prank(treasury);
        token.transfer(alice, 1 ether);
        uint256 phunkId = token.inventoryOf(alice)[0];
        vm.prank(alice);
        uint256 rareId = token.claim(phunkId);

        // Alice approves market and lists for 5 PHUNK
        vm.prank(alice);
        rare.setApprovalForAll(address(market), true);

        uint256 listPrice = 5 ether;
        vm.prank(alice);
        market.list(rareId, listPrice);
        assertTrue(market.isListed(rareId));
        assertEq(market.priceOf(rareId), listPrice);

        // Bob has PHUNK (give him some) and approves market to spend
        vm.prank(treasury);
        token.transfer(bob, 10 ether);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);

        // Bob buys
        uint256 aliceBefore  = token.balanceOf(alice);
        uint256 feeBefore    = token.balanceOf(feeRecv);
        vm.prank(bob);
        market.buy(rareId);

        // Rare moved
        assertEq(rare.ownerOf(rareId), bob, "bob owns rare");
        // Money split: 2.5% fee
        uint256 expectedFee = (listPrice * 250) / 10000;
        assertEq(token.balanceOf(feeRecv) - feeBefore, expectedFee, "fee paid");
        assertEq(token.balanceOf(alice) - aliceBefore, listPrice - expectedFee, "seller paid");
    }

    function test_market_cancel() public {
        vm.prank(treasury);
        token.transfer(alice, 1 ether);
        uint256 phunkId = token.inventoryOf(alice)[0];
        vm.prank(alice);
        uint256 rareId = token.claim(phunkId);
        vm.prank(alice);
        rare.setApprovalForAll(address(market), true);
        vm.prank(alice);
        market.list(rareId, 1 ether);

        vm.prank(alice);
        market.cancelListing(rareId);
        assertFalse(market.isListed(rareId));
    }

    function test_market_buy_reverts_when_seller_moved_rare() public {
        vm.prank(treasury);
        token.transfer(alice, 1 ether);
        uint256 phunkId = token.inventoryOf(alice)[0];
        vm.prank(alice);
        uint256 rareId = token.claim(phunkId);
        vm.prank(alice);
        rare.setApprovalForAll(address(market), true);
        vm.prank(alice);
        market.list(rareId, 1 ether);

        // Alice transfers the rare out from under the market
        vm.prank(alice);
        rare.transferFrom(alice, bob, rareId);

        // Buyer tries to buy — should revert
        vm.prank(treasury);
        token.transfer(makeAddr("buyer"), 5 ether);
        address buyer = makeAddr("buyer");
        vm.prank(buyer);
        token.approve(address(market), type(uint256).max);

        vm.prank(buyer);
        vm.expectRevert(PhunkMarket.NotSeller.selector);
        market.buy(rareId);
    }

    function test_market_buy_reverts_when_paused() public {
        vm.prank(treasury);
        token.transfer(alice, 1 ether);
        uint256 phunkId = token.inventoryOf(alice)[0];
        vm.prank(alice);
        uint256 rareId = token.claim(phunkId);
        vm.prank(alice);
        rare.setApprovalForAll(address(market), true);
        vm.prank(alice);
        market.list(rareId, 1 ether);

        market.setPaused(true);
        vm.expectRevert(PhunkMarket.Paused.selector);
        market.buy(rareId);
    }
}

