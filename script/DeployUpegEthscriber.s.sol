// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {UpegEthscriber} from "../src/UpegEthscriber.sol";

/// @notice Deploy the UpegEthscriber. Standalone, no constructor args.
/// Usage:
///   forge script script/DeployUpegEthscriber.s.sol \
///     --rpc-url $MAINNET_RPC --private-key $PK --broadcast
contract DeployUpegEthscriber is Script {
    function run() external returns (UpegEthscriber e) {
        vm.startBroadcast();
        e = new UpegEthscriber();
        vm.stopBroadcast();
    }
}
