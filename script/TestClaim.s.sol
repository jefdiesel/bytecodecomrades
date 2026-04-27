// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2}    from "forge-std/Script.sol";
import {ComradeRare}         from "../src/ComradeRare.sol";
import {IComradeRenderer}    from "../src/IComradeRenderer.sol";

interface IBCC {
    function rare() external view returns (address);
    function setRare(address) external;
    function setSkip(address, bool) external;
    function setClaimFee(uint256) external;
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function inventoryOf(address) external view returns (uint256[] memory);
    function comradeOwner(uint256) external view returns (address);
    function tokensPerComrade() external view returns (uint256);
    function claim(uint256) external payable returns (uint256);
    function tokenURI(uint256) external view returns (string memory);
    function renderer() external view returns (address);
}

/// @notice End-to-end claim test:
///   1) Deploy ComradeRare (if not already wired)
///   2) setRare on Comrade404
///   3) setClaimFee
///   4) Generate a holder wallet, fund it from deployer
///   5) Transfer 1 BCC from deployer → holder (mints 1 in-404 NFT)
///   6) Holder calls claim() — pays fee to treasury, receives a Rare ERC-721
///   7) Print the new Rare id + tokenURI
///
/// Run:
///   COMRADE404=0x... forge script script/TestClaim.s.sol \
///     --rpc-url $RPC --private-key $DEPLOY_PRIVATE_KEY --broadcast
contract TestClaim is Script {
    function run() external {
        address bccAddr   = vm.envAddress("COMRADE404");
        uint256 deployerPk = vm.envUint("DEPLOY_PRIVATE_KEY");
        address deployer  = vm.addr(deployerPk);
        IBCC bcc = IBCC(bccAddr);

        // ---- 1. Deploy + wire Rare if missing ----
        address rareAddr = bcc.rare();
        if (rareAddr == address(0)) {
            vm.startBroadcast(deployerPk);
            ComradeRare rare = new ComradeRare(bccAddr, IComradeRenderer(bcc.renderer()));
            bcc.setRare(address(rare));
            // Small ETH claim fee so we exercise the fee flow.
            bcc.setClaimFee(0.0001 ether);
            vm.stopBroadcast();
            rareAddr = address(rare);
            console2.log("deployed Rare:", rareAddr);
        } else {
            console2.log("Rare already wired:", rareAddr);
        }
        // Treasury (deployer) MUST stay skipComrades=true — its balance never
        // matches its (empty) inventory, so un-skipping causes mint/burn
        // arithmetic to underflow on the next transfer.
        vm.startBroadcast(deployerPk);
        bcc.setSkip(deployer, true);
        vm.stopBroadcast();

        // ---- 2. Make a fresh holder ----
        // Deterministic so reruns hit the same wallet.
        uint256 holderPk = uint256(keccak256(abi.encode("BCC_TEST_HOLDER_v1")));
        address holder = vm.addr(holderPk);
        console2.log("test holder:", holder);

        // Fund the holder with enough ETH for claim fee + gas.
        vm.startBroadcast(deployerPk);
        (bool ok, ) = holder.call{value: 0.002 ether}("");
        require(ok, "fund holder");

        // ---- 3. Transfer 1 BCC to the holder → mints 1 in-404 NFT ----
        uint256 perComrade = bcc.tokensPerComrade();
        bcc.transfer(holder, perComrade);
        vm.stopBroadcast();

        uint256[] memory inv = bcc.inventoryOf(holder);
        require(inv.length >= 1, "no NFT minted");
        uint256 cId = inv[inv.length - 1];
        console2.log("holder got Comrade id:", cId);

        // ---- 4. Holder calls claim() ----
        vm.startBroadcast(holderPk);
        uint256 rareId = bcc.claim{value: 0.0001 ether}(cId);
        vm.stopBroadcast();
        console2.log("claimed rare id:", rareId);

        // ---- 5. Verify ----
        address ownerAfter = bcc.comradeOwner(cId);
        require(ownerAfter == address(0), "404 NFT not burned");
        console2.log("404 NFT burned OK");

        ComradeRare rareC = ComradeRare(rareAddr);
        address rareOwner = rareC.ownerOf(rareId);
        require(rareOwner == holder, "rare not owned by holder");
        string memory uri = rareC.tokenURI(rareId);
        console2.log("rare owner:", rareOwner);
        console2.log("rare tokenURI bytes:", bytes(uri).length);
    }
}
