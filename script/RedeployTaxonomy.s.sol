// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}    from "forge-std/Script.sol";
import {ComradeTaxonomy}     from "../src/ComradeTaxonomy.sol";
import {ComradeRenderer}     from "../src/ComradeRenderer.sol";
import {ComradeSpriteData}   from "../src/ComradeSpriteData.sol";

interface IComrade404Set {
    function setRenderer(address) external;
}

/// @notice Deploy a new ComradeTaxonomy (with the alias-fixed weight blob),
/// a fresh ComradeRenderer pointing at it + the existing SpriteData, then
/// re-wire Comrade404.
///
/// Run:
///   SPRITE_DATA=0x... COMRADE404=0x... \
///   forge script script/RedeployTaxonomy.s.sol --rpc-url $RPC --private-key $PK --broadcast
contract RedeployTaxonomy is Script {
    function run() external {
        address spriteData = vm.envAddress("SPRITE_DATA");
        address token      = vm.envAddress("COMRADE404");

        vm.startBroadcast();
        ComradeTaxonomy tax = new ComradeTaxonomy();
        ComradeRenderer rnd = new ComradeRenderer(ComradeSpriteData(spriteData), tax);
        IComrade404Set(token).setRenderer(address(rnd));
        vm.stopBroadcast();

        console2.log("new taxonomy:", address(tax));
        console2.log("new renderer:", address(rnd));
    }
}
