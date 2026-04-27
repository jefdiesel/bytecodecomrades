// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}    from "forge-std/Script.sol";
import {ComradeRenderer}     from "../src/ComradeRenderer.sol";
import {ComradeSpriteData}   from "../src/ComradeSpriteData.sol";
import {ComradeTaxonomy}     from "../src/ComradeTaxonomy.sol";

interface IComrade404Set {
    function setRenderer(address) external;
}

/// @notice Deploy a new ComradeRenderer pointing at the existing sprite data + taxonomy,
/// then call setRenderer on the existing Comrade404 to activate it.
///
/// Run:
///   SPRITE_DATA=0x... TAXONOMY=0x... COMRADE404=0x... \
///   forge script script/RedeployRenderer.s.sol --rpc-url $RPC --private-key $PK --broadcast
contract RedeployRenderer is Script {
    function run() external {
        address spriteData = vm.envAddress("SPRITE_DATA");
        address taxonomy   = vm.envAddress("TAXONOMY");
        address token      = vm.envAddress("COMRADE404");

        vm.startBroadcast();
        ComradeRenderer r = new ComradeRenderer(
            ComradeSpriteData(spriteData),
            ComradeTaxonomy(taxonomy)
        );
        IComrade404Set(token).setRenderer(address(r));
        vm.stopBroadcast();

        console2.log("new renderer:", address(r));
    }
}
