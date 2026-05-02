// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {UpegEthscriberOnChain} from "../src/UpegEthscriberOnChain.sol";

/// Deploy:
///   FEE_RECIPIENT=0x...
///   BASE_PRICE_WEI=500000000000000   (0.0005 ETH)
///   PRICE_STEP_WEI=10000000000000    (0.00001 ETH)
///   UPEG_HOOK=0xe54082DfBf044B6a8F584bdDdb90a22d5613C440
///   COLLECTION_ID=0x7d2154a90ce8def4fa18f66d1095ae2b147faf17705eb2a90caf50579589a5a7
///   forge script script/DeployUpegEthscriberOnChain.s.sol \
///     --rpc-url $RPC --private-key $PK --broadcast
contract DeployUpegEthscriberOnChain is Script {
    function run() external returns (UpegEthscriberOnChain e) {
        address payable feeRecipient = payable(vm.envAddress("FEE_RECIPIENT"));
        uint256 basePrice = vm.envUint("BASE_PRICE_WEI");
        uint256 priceStep = vm.envUint("PRICE_STEP_WEI");
        address upegHook = vm.envAddress("UPEG_HOOK");
        string memory collectionId = vm.envString("COLLECTION_ID");

        vm.startBroadcast();
        e = new UpegEthscriberOnChain(feeRecipient, basePrice, priceStep, upegHook, collectionId);
        vm.stopBroadcast();

        console.log("UpegEthscriberOnChain:", address(e));
        console.log("feeRecipient:", feeRecipient);
        console.log("upegHook:", upegHook);
        console.log("collectionId:", collectionId);
        console.log("basePrice (wei):", basePrice);
        console.log("priceStep (wei):", priceStep);
    }
}
