// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Phunk404} from "../src/Phunk404.sol";
import {ISeedSource} from "../src/ISeedSource.sol";

/// @notice A test-controlled seed source so we can isolate the Phunk404 mechanic
/// from the v4 PoolManager. The real PhunkHook implements the same interface.
contract MockSeedSource is ISeedSource {
    bytes32 public override currentSeed = bytes32(uint256(0xA11CE));
    uint64  public override swapCount;

    function bump(bytes32 newSeed) external {
        currentSeed = newSeed;
        unchecked { swapCount++; }
    }
}

contract Phunk404Test is Test {
    Phunk404      token;
    MockSeedSource seedSrc;

    address treasury = makeAddr("treasury");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address pool     = makeAddr("pool");

    uint256 constant TEST_CAP             = 32;
    uint256 constant TEST_TOKENS_PER_PHUNK = 1 ether; // 1 PHUNK == 1 Phunk for default tests

    function setUp() public {
        seedSrc = new MockSeedSource();
        token   = new Phunk404(seedSrc, treasury, TEST_CAP, TEST_TOKENS_PER_PHUNK);
        token.setSkip(pool, true);
    }

    function test_mint_one_phunk_when_crossing_first_threshold() public {
        vm.prank(treasury);
        token.transfer(alice, 1 ether);
        assertEq(token.phunksOwned(alice), 1);
        assertEq(token.balanceOf(alice), 1 ether);
    }

    function test_no_mint_when_below_threshold() public {
        vm.prank(treasury);
        token.transfer(alice, 0.7 ether);
        assertEq(token.phunksOwned(alice), 0);
    }

    function test_two_partial_transfers_mint_one_phunk_when_crossing() public {
        vm.prank(treasury);
        token.transfer(alice, 0.6 ether);
        assertEq(token.phunksOwned(alice), 0);

        vm.prank(treasury);
        token.transfer(alice, 0.5 ether);
        assertEq(token.phunksOwned(alice), 1);
    }

    function test_burn_when_dropping_below_threshold() public {
        vm.prank(treasury);
        token.transfer(alice, 2 ether);
        assertEq(token.phunksOwned(alice), 2);

        vm.prank(alice);
        token.transfer(bob, 1.5 ether);
        assertEq(token.phunksOwned(alice), 0);
        assertEq(token.phunksOwned(bob),   1);
    }

    function test_seed_at_mint_time_is_stamped_into_phunk() public {
        seedSrc.bump(bytes32(uint256(1)));
        vm.prank(treasury);
        token.transfer(alice, 1 ether);
        uint256 aliceId = token.inventoryOf(alice)[0];
        (bytes32 aliceSeed,,) = token.phunks(aliceId);

        for (uint256 i = 0; i < 5; ++i) {
            seedSrc.bump(keccak256(abi.encode(i)));
        }
        vm.prank(treasury);
        token.transfer(bob, 1 ether);
        uint256 bobId = token.inventoryOf(bob)[0];
        (bytes32 bobSeed,,) = token.phunks(bobId);

        assertTrue(aliceSeed != bobSeed);
    }

    function test_minted_seed_is_immutable_after_more_swaps() public {
        seedSrc.bump(bytes32(uint256(0xDEAD)));
        vm.prank(treasury);
        token.transfer(alice, 1 ether);
        uint256 id = token.inventoryOf(alice)[0];
        (bytes32 stampedAtMint,,) = token.phunks(id);

        for (uint256 i = 0; i < 20; ++i) {
            seedSrc.bump(keccak256(abi.encode("swap", i)));
        }
        (bytes32 stillStamped,,) = token.phunks(id);
        assertEq(stampedAtMint, stillStamped);
    }

    function test_lifo_burn_order() public {
        vm.prank(treasury);
        token.transfer(alice, 3 ether);

        uint256[] memory inv = token.inventoryOf(alice);
        uint256 last = inv[2];

        vm.prank(alice);
        token.transfer(bob, 1 ether);

        assertEq(token.phunkOwner(last), address(0));
        assertEq(token.phunksOwned(alice), 2);
    }

    function test_pool_does_not_receive_phunks() public {
        vm.prank(treasury);
        token.transfer(pool, 10 ether);
        assertEq(token.balanceOf(pool), 10 ether);
        assertEq(token.phunksOwned(pool), 0);

        vm.prank(pool);
        token.transfer(alice, 5 ether);
        assertEq(token.phunksOwned(alice), 5);
    }

    function test_total_phunks_bounded_by_max() public {
        uint256 supply = token.totalSupply();
        vm.prank(treasury);
        token.transfer(alice, supply);
        assertEq(token.phunksOwned(alice), token.maxPhunks());
    }

    function test_background_color_is_c3ff00() public view {
        assertEq(token.BACKGROUND_COLOR(), bytes3(0xc3ff00));
    }

    function test_flip_flag_is_horizontal() public view {
        assertTrue(token.FLIPPED_HORIZONTAL());
    }

    // ---- champion mechanic ----

    function test_solo_holder_has_their_only_phunk_as_champion() public {
        vm.prank(treasury);
        token.transfer(alice, 1 ether);
        uint256[] memory inv = token.inventoryOf(alice);
        assertEq(inv.length, 1);
        assertEq(token.championOf(alice), inv[0], "alice's only phunk is her champion");
    }

    function test_champion_is_oldest_phunk_in_wallet() public {
        vm.prank(treasury);
        token.transfer(alice, 5 ether);
        uint256[] memory inv = token.inventoryOf(alice);
        // inv[0] is the OG (oldest acquired); subsequent are newer
        assertEq(token.championOf(alice), inv[0]);
        assertTrue(inv[0] != inv[4], "different ids for diff slots");
    }

    function test_champion_persists_under_lifo_sells() public {
        vm.prank(treasury);
        token.transfer(alice, 5 ether);
        uint256 og = token.championOf(alice);

        // Sell 3 wholes — LIFO burn pops from end, og at index 0 stays
        vm.prank(alice);
        token.transfer(bob, 3 ether);

        assertEq(token.championOf(alice), og, "OG champion survives partial sells");
        assertEq(token.phunksOwned(alice), 2);
    }

    function test_champion_lost_when_holder_sells_all() public {
        vm.prank(treasury);
        token.transfer(alice, 2 ether);
        assertTrue(token.hasChampion(alice));
        uint256 og = token.championOf(alice);

        // Sell everything alice has
        vm.prank(alice);
        token.transfer(bob, 2 ether);

        assertFalse(token.hasChampion(alice), "no champion after liquidating");
        // OG phunk should no longer exist
        assertEq(token.phunkOwner(og), address(0), "OG phunk burned");
    }

    // ---- memecoin ratio: 10B PHUNK / 10k Phunks => 1M PHUNK per Phunk ----

    function test_memecoin_ratio_threshold_is_one_million_phunk() public {
        address treasury2 = makeAddr("treasury2");
        address whale     = makeAddr("whale");

        uint256 _maxPhunks      = 10;
        uint256 _tokensPerPhunk = 1_000_000 ether;
        Phunk404 mc = new Phunk404(seedSrc, treasury2, _maxPhunks, _tokensPerPhunk);

        vm.prank(treasury2);
        mc.transfer(whale, 999_999 ether);
        assertEq(mc.phunksOwned(whale), 0, "below 1M PHUNK => no Phunk");

        vm.prank(treasury2);
        mc.transfer(whale, 1 ether);
        assertEq(mc.phunksOwned(whale), 1, "1M PHUNK threshold crossed");

        vm.prank(treasury2);
        mc.transfer(whale, 1_000_000 ether);
        assertEq(mc.phunksOwned(whale), 2);
    }

    function test_memecoin_supply_is_ten_billion() public {
        Phunk404 prod = new Phunk404(seedSrc, makeAddr("t"), 10_000, 1_000_000 ether);
        assertEq(prod.totalSupply(), 10_000_000_000 ether);
        assertEq(prod.maxPhunks(), 10_000);
        assertEq(prod.tokensPerPhunk(), 1_000_000 ether);
    }
}
