// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm, console} from "forge-std/Test.sol";
import {UpegEthscriberOnChain} from "../src/UpegEthscriberOnChain.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @notice Validates the on-chain ethscriber emits a spec-compliant
/// AppChain collection Data URI. Spec source-of-truth:
/// /Users/jef/Downloads/appchain-erc721-collections.md
contract UpegEthscriberOnChainTest is Test {
    UpegEthscriberOnChain ethscriber;
    address payable treasury = payable(address(0xCAFE));
    string COLLECTION_ID = "0x7d2154a90ce8def4fa18f66d1095ae2b147faf17705eb2a90caf50579589a5a7";

    address mockHook;
    string mockSvg = "<svg xmlns='http://www.w3.org/2000/svg'><rect width='24' height='24'/></svg>";

    function setUp() public {
        MockHook hook = new MockHook(mockSvg);
        mockHook = address(hook);
        ethscriber = new UpegEthscriberOnChain(
            treasury,
            500_000_000_000_000,
            10_000_000_000_000,
            mockHook,
            COLLECTION_ID
        );
    }

    function test_specCompliance() public {
        uint256 upegId = 19125;
        uint256 seed = 2441525982659010410504976999095291821883392;

        vm.recordLogs();
        vm.deal(address(this), 1 ether);
        ethscriber.mint{value: 0.0005 ether}(upegId, seed);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ethscriptions_protocol_CreateEthscription(address,string)");
        string memory contentURI;
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) { contentURI = abi.decode(logs[i].data, (string)); break; }
        }
        require(bytes(contentURI).length > 0, "no event emitted");

        console.log("contentURI:");
        console.log(contentURI);

        // ===== STRUCTURE CHECKS (URI level) =====
        bytes memory uri = bytes(contentURI);
        require(_startsWith(uri, bytes("data:image/svg+xml;")), "bad mimetype prefix");
        require(_contains(uri, bytes(";rule=esip6;")), "MISSING rule=esip6");
        require(_contains(uri, bytes(";p=erc-721-ethscriptions-collection;")), "wrong protocol");
        require(_contains(uri, bytes(";op=add_self_to_collection;")), "wrong op");
        require(_contains(uri, bytes(";d=")), "missing d=");
        require(_contains(uri, bytes(";base64,")), "missing ;base64,");

        // Header order: data:<mime>;rule=esip6;p=...;op=...;d=...;base64,...
        require(_indexOf(uri, bytes(";rule=esip6;")) < _indexOf(uri, bytes(";p=")), "rule must come before p");
        require(_indexOf(uri, bytes(";p=")) < _indexOf(uri, bytes(";op=")), "p must come before op");
        require(_indexOf(uri, bytes(";op=")) < _indexOf(uri, bytes(";d=")), "op must come before d");
        require(_indexOf(uri, bytes(";d=")) < _indexOf(uri, bytes(";base64,")), "d must come before base64");

        // ===== JSON CHECKS (compare against expected base64) =====
        // Build the EXPECTED JSON exactly as the contract should
        bytes memory expectedJson = abi.encodePacked(
            '{"collection_id":"', COLLECTION_ID,
            '","item":{"item_index":"19125"',
            ',"name":"uPEG #19125"',
            ',"background_color":"0b0c10"',
            ',"description":"uPEG unicorn #19125. On-chain SVG, deterministic from seed."',
            ',"attributes":[{"trait_type":"upeg_id","value":"19125"},',
            '{"trait_type":"seed","value":"2441525982659010410504976999095291821883392"}]',
            ',"merkle_proof":[]}}'
        );
        string memory expectedJsonB64 = Base64.encode(expectedJson);
        require(_contains(uri, bytes(expectedJsonB64)),
            "emitted JSON does NOT match spec - check key order, item_index quotes, etc.");

        console.log("PASS: emitted Data URI matches spec, JSON byte-perfect");
    }

    // helpers
    function _startsWith(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint j = 0; j < needle.length; j++) if (hay[j] != needle[j]) return false;
        return true;
    }
    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint i = 0; i <= hay.length - needle.length; i++) {
            bool ok = true;
            for (uint j = 0; j < needle.length; j++) if (hay[i+j] != needle[j]) { ok = false; break; }
            if (ok) return true;
        }
        return false;
    }
    function _indexOf(bytes memory hay, bytes memory needle) internal pure returns (uint256) {
        for (uint i = 0; i <= hay.length - needle.length; i++) {
            bool ok = true;
            for (uint j = 0; j < needle.length; j++) if (hay[i+j] != needle[j]) { ok = false; break; }
            if (ok) return i;
        }
        revert("not found");
    }
}

contract MockHook {
    string svg;
    constructor(string memory _svg) { svg = _svg; }
    function generate(uint256) external view returns (string memory) { return svg; }
}
