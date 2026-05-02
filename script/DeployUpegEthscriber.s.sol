// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {UpegEthscriber} from "../src/UpegEthscriber.sol";

/// Deploy:
///   FEE_RECIPIENT=0x...                              \
///   BASE_PRICE_WEI=1000000000000000   (0.001 ETH)    \
///   PRICE_STEP_WEI=10000000000000     (0.00001 ETH)  \
///   forge script script/DeployUpegEthscriber.s.sol   \
///     --rpc-url $MAINNET_RPC --private-key $PK --broadcast --verify
contract DeployUpegEthscriber is Script {
    function run() external returns (UpegEthscriber e) {
        address payable feeRecipient = payable(vm.envAddress("FEE_RECIPIENT"));
        uint256 basePrice = vm.envUint("BASE_PRICE_WEI");
        uint256 priceStep = vm.envUint("PRICE_STEP_WEI");
        require(feeRecipient != address(0), "FEE_RECIPIENT unset");

        vm.startBroadcast();
        e = new UpegEthscriber(feeRecipient, basePrice, priceStep);
        vm.stopBroadcast();

        console.log("UpegEthscriber:", address(e));
        console.log("feeRecipient:  ", feeRecipient);
        console.log("basePrice (wei):", basePrice);
        console.log("priceStep (wei):", priceStep);
    }
}
