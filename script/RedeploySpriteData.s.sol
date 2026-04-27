// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}    from "forge-std/Script.sol";
import {ComradeSpriteData}   from "../src/ComradeSpriteData.sol";
import {ComradeRenderer}     from "../src/ComradeRenderer.sol";
import {ComradeTaxonomy}     from "../src/ComradeTaxonomy.sol";

interface IComrade404Set {
    function setRenderer(address) external;
    function rare() external view returns (address);
}

/// @notice Redeploy ComradeSpriteData (with the cross-chunk-aware reader) and
/// a fresh ComradeRenderer pointing at it. Then re-wire Comrade404 (and the
/// Rare contract if deployed).
///
/// Run:
///   TAXONOMY=0x... COMRADE404=0x... \
///   forge script script/RedeploySpriteData.s.sol --rpc-url $RPC --private-key $PK --broadcast
contract RedeploySpriteData is Script {
    function run() external {
        address taxonomy   = vm.envAddress("TAXONOMY");
        address token      = vm.envAddress("COMRADE404");

        // Existing chunk addresses on Sepolia — unchanged, just reused.
        address[5] memory chunks = [
            address(0x30d2aEc3A6aE23a4e6E139d37805d14E680C27f8),
            address(0x3861b8BA7d1ceBa72077B92170175d0a6a1fDaDD),
            address(0xC68B223530fFa73CCE602aDAe8a9ACC567043196),
            address(0xB3E87F3B718048EDf040b6F2f237cCA4C2FAD55e),
            address(0x8622F755Fd86c04A192EC1C74B544476243A3d93)
        ];

        vm.startBroadcast();
        ComradeSpriteData data = new ComradeSpriteData(chunks);
        ComradeRenderer renderer = new ComradeRenderer(data, ComradeTaxonomy(taxonomy));
        IComrade404Set(token).setRenderer(address(renderer));
        vm.stopBroadcast();

        console2.log("new spriteData:", address(data));
        console2.log("new renderer:  ", address(renderer));
        // Note: ComradeClaimed.setRenderer is gated to onlyComrade404. Use
        // Comrade404.setClaimedRenderer() to re-point existing Claimed NFTs at
        // the new renderer.
    }
}
