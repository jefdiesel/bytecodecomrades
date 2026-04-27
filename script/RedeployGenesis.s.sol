// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}    from "forge-std/Script.sol";
import {ComradeGenesis}      from "../src/ComradeGenesis.sol";
import {ComradeRenderer}     from "../src/ComradeRenderer.sol";

/// @notice Deploy a fresh ComradeGenesis pointing at the current renderer.
/// The original Genesis contract is left on-chain but unused — its renderer
/// is immutable and pointed at the buggy first deploy.
///
/// Run:
///   RECIPIENT=0xEbfD... RENDERER=0x... \
///   forge script script/RedeployGenesis.s.sol --rpc-url $RPC --private-key $PK --broadcast
contract RedeployGenesis is Script {
    function run() external {
        address recipient = vm.envAddress("RECIPIENT");
        address renderer  = vm.envAddress("RENDERER");

        vm.startBroadcast();
        ComradeGenesis g = new ComradeGenesis(recipient, ComradeRenderer(renderer));
        vm.stopBroadcast();

        console2.log("new Genesis:", address(g));
        console2.log("recipient:  ", recipient);
        console2.log("renderer:   ", renderer);
    }
}
