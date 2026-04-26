// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ComradeBloom} from "../src/ComradeBloom.sol";

contract ComradeBloomTest is Test {
    ComradeBloom bloom;

    function setUp() public {
        bloom = new ComradeBloom();
    }

    function test_constants() public view {
        assertEq(bloom.M_BITS(), 262144);
        assertEq(bloom.M_BYTES(), 32768);
        assertEq(bloom.K(), 14);
    }

    /// @notice Sort + pack of CDC #0 (Comrade #1):
    ///   Background: Sir Pinkalot     -> sprite 13
    ///   Type:       Scriboor         -> need to look up
    ///   Mouth:      Beard of the Gods -> 106
    ///   Eyes:       Aviators         -> 175
    /// Sorted ids: [13, 106, 175, ?Scriboor]. We compute Scriboor's ID below.
    function test_known_cdc_fingerprint_hits() public view {
        // CDC #0 has 4 visual traits. Scriboor is a Type sprite.
        // Type starts at id 22 in our sprite_table; sprites are alphabetical.
        // Looking up: Alien People (22), Black & White Zombie (23), Blue People (24),
        // Bone People (25), Ethernals (26), Ghost Chain People (27), Golden (28),
        // Human, Melanin Level 30 (29), Human, Melanin Level 80 (30),
        // Human, Melanin Level Goth (31), Kombucha Mushroom People Exiled (32),
        // Kombucha Mushroom People (33), Omega Block Zealots (34), Pepe People (35),
        // Pork People (36), Purple People (37), Purr People (38), Scriboor (39),
        // We The People (40), Yeti People (41), Zombie (42)
        uint16[] memory ids = new uint16[](4);
        ids[0] = 13;   // Sir Pinkalot
        ids[1] = 39;   // Scriboor
        ids[2] = 106;  // Beard of the Gods
        ids[3] = 175;  // Aviators

        bytes32 fp = bloom.fingerprintOf(ids);
        assertTrue(bloom.mightContain(fp), "CDC #0 must be in the filter");
    }

    function test_obviously_novel_combo_misses() public view {
        // Random fingerprint — almost certainly not in the filter
        bytes32 fp = keccak256("not a real CDC item ever 123456");
        assertFalse(bloom.mightContain(fp), "novel fingerprint should miss");
    }

    function test_picks_from_our_10k_miss() public view {
        // Spot-check: a few of our generated 10k items should NOT match
        // anything in the bloom (we already verified zero collisions off-chain).
        uint16[] memory ids = new uint16[](5);
        ids[0] = 13;   // Sir Pinkalot
        ids[1] = 22;   // Alien People (item #0 traits)
        ids[2] = 69;   // Hardbass Uniform
        ids[3] = 106;  // Beard of the Gods
        ids[4] = 175;  // Aviators
        bytes32 fp = bloom.fingerprintOf(ids);
        assertFalse(bloom.mightContain(fp), "our generated #0 must miss CDC+CRC");
    }
}
