// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {UpegGrinder, UpegSeedDecoder} from "../src/UpegGrinder.sol";

interface IUpegRead {
    function OwnerUpegsCount(address) external view returns (uint256);
    function OwnerUpeg(address, uint256) external view returns (uint256, uint256);
}

contract UpegGrinderTest is Test {
    UpegGrinder grinder;
    address user = address(0xBEEF);
    address constant UPEG = 0x44b28991B167582F18BA0259e0173176ca125505;

    function setUp() public {
        // Fork mainnet at a recent block (only runs if FORK_URL env set)
        vm.createSelectFork(vm.envOr("FORK_URL", string("")));
        grinder = new UpegGrinder();
        vm.deal(user, 100 ether);
    }

    function test_grindWithoutFilterAlwaysSucceeds() public {
        // No criteria — first attempt should succeed (whatever you mint matches).
        UpegGrinder.Criteria memory open = UpegGrinder.Criteria({
            requireWings: false,
            requireHorn: false,
            requireHair: false,
            requireGround: false,
            requireTail: false,
            requireAccessories: false,
            maxOptional: 6,
            requireBgValue: 0,
            requireBg: false
        });

        uint256 balBefore = user.balance;
        uint256 countBefore = IUpegRead(UPEG).OwnerUpegsCount(user);

        vm.prank(user);
        grinder.grind{value: 50 ether}(50 ether, open);

        uint256 countAfter = IUpegRead(UPEG).OwnerUpegsCount(user);
        assertEq(countAfter, countBefore + 1, "should mint exactly 1");
        assertLt(user.balance, balBefore, "ETH spent");

        (, uint256 seed) = IUpegRead(UPEG).OwnerUpeg(user, countBefore);
        UpegSeedDecoder.Traits memory t = UpegSeedDecoder.decode(seed);
        console.log("minted seed body:", t.body, "wings:", t.wings);
    }

    function test_grindForWingsRevertsIfNoMatch() public {
        UpegGrinder.Criteria memory wantWings = UpegGrinder.Criteria({
            requireWings: true,
            requireHorn: false,
            requireHair: false,
            requireGround: false,
            requireTail: false,
            requireAccessories: false,
            maxOptional: 6,
            requireBgValue: 0,
            requireBg: false
        });

        // Compute what the next mint WOULD give us (using current hook seed).
        // If it doesn't have wings, grind() must revert with NoMatch.
        uint256 countBefore = IUpegRead(UPEG).OwnerUpegsCount(user);

        bool reverted = false;
        try this.callGrind(50 ether, wantWings) {
            uint256 countAfter = IUpegRead(UPEG).OwnerUpegsCount(user);
            // If it didn't revert, the mint must satisfy criteria
            (, uint256 seed) = IUpegRead(UPEG).OwnerUpeg(user, countBefore);
            UpegSeedDecoder.Traits memory t = UpegSeedDecoder.decode(seed);
            assertGt(t.wings, 0, "succeeded but no wings - bug");
            console.log("got lucky on first try, wings:", t.wings);
        } catch {
            reverted = true;
            console.log("reverted as expected (this seed has no wings)");
        }

        // Either reverted (no wings in next seed) or succeeded with wings.
        // Both are correct contract behavior.
        uint256 countAfter2 = IUpegRead(UPEG).OwnerUpegsCount(user);
        if (reverted) assertEq(countAfter2, countBefore, "revert should undo mint");
    }

    function callGrind(uint256 maxEth, UpegGrinder.Criteria calldata c) external payable {
        vm.prank(user);
        grinder.grind{value: maxEth}(maxEth, c);
    }
}
