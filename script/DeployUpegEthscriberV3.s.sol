// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {UpegEthscriberV3} from "../src/UpegEthscriberV3.sol";

contract DeployUpegEthscriberV3 is Script {
    function run() external returns (UpegEthscriberV3 e) {
        address payable feeRecipient = payable(vm.envAddress("FEE_RECIPIENT"));
        uint256 basePrice = vm.envUint("BASE_PRICE_WEI");
        uint256 priceStep = vm.envUint("PRICE_STEP_WEI");
        address upegHook = vm.envAddress("UPEG_HOOK");
        string memory collectionId = vm.envString("COLLECTION_ID");

        vm.startBroadcast();
        e = new UpegEthscriberV3(feeRecipient, basePrice, priceStep, upegHook, collectionId);
        vm.stopBroadcast();

        console.log("UpegEthscriberV3:", address(e));
        console.log("collectionId:    ", collectionId);
    }
}
