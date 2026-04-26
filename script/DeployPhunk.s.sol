// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks}            from "v4-core/libraries/Hooks.sol";
import {IPoolManager}     from "v4-core/interfaces/IPoolManager.sol";

import {PhunkHook}        from "../src/PhunkHook.sol";
import {Phunk404}         from "../src/Phunk404.sol";
import {PhunkSpriteData}  from "../src/PhunkSpriteData.sol";
import {PhunkRenderer}    from "../src/PhunkRenderer.sol";

/// @notice Deploy the full Phunk stack to a target chain.
///
/// Run:
///   forge script script/DeployPhunk.s.sol --rpc-url $RPC --broadcast \
///     --private-key $PK
///
/// Config via env (all optional, sensible defaults):
///   POOL_MANAGER     — v4 PoolManager (defaults by chain id; see _defaultPoolManager)
///   TREASURY         — initial supply recipient (defaults to deployer)
///   MAX_PHUNKS       — total Phunk count cap (default 10_000)
///   TOKENS_PER_PHUNK — wei of PHUNK per Phunk threshold (default 1_000_000 ether)
contract DeployPhunk is Script {
    /// @dev Foundry / forge-std default CREATE2 factory. Pre-deployed on mainnet
    /// and most testnets at this canonical address.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address deployer  = msg.sender;
        address treasury  = _envAddrOr("TREASURY", deployer);
        address poolMgr   = _envAddrOr("POOL_MANAGER", _defaultPoolManager(block.chainid));
        require(poolMgr != address(0), "POOL_MANAGER not set and no default for this chain");

        uint256 maxPhunks      = _envUintOr("MAX_PHUNKS",      10_000);
        uint256 tokensPerPhunk = _envUintOr("TOKENS_PER_PHUNK", 1_000_000 ether);

        console2.log("== Phunk deploy ==");
        console2.log("chainId:        ", block.chainid);
        console2.log("deployer:       ", deployer);
        console2.log("treasury:       ", treasury);
        console2.log("poolManager:    ", poolMgr);
        console2.log("maxPhunks:      ", maxPhunks);
        console2.log("tokensPerPhunk: ", tokensPerPhunk);

        // 1. Mine hook salt off-broadcast (pure computation, no tx)
        uint160 wantFlags = uint160(Hooks.AFTER_SWAP_FLAG);
        bytes memory hookCreationCode = type(PhunkHook).creationCode;
        bytes memory hookCtorArgs = abi.encode(IPoolManager(poolMgr));
        (address predicted, bytes32 salt, uint256 iters) =
            _mineSalt(CREATE2_DEPLOYER, wantFlags, hookCreationCode, hookCtorArgs);
        console2.log("hook (predicted):", predicted);
        console2.log("salt iterations: ", iters);

        // 2. Broadcast deploys
        vm.startBroadcast();

        PhunkSpriteData data     = new PhunkSpriteData();
        PhunkRenderer   renderer = new PhunkRenderer(data);
        PhunkHook       hook     = new PhunkHook{salt: salt}(IPoolManager(poolMgr));
        require(address(hook) == predicted, "hook addr mismatch");

        Phunk404 token = new Phunk404(hook, treasury, maxPhunks, tokensPerPhunk);
        token.setRenderer(renderer);

        // PoolManager holds liquidity directly in v4 — exempt it from Phunk minting.
        token.setSkip(poolMgr, true);

        vm.stopBroadcast();

        console2.log("");
        console2.log("== addresses ==");
        console2.log("PhunkSpriteData:", address(data));
        console2.log("PhunkRenderer: ", address(renderer));
        console2.log("PhunkHook:     ", address(hook));
        console2.log("Phunk404:      ", address(token));
        console2.log("");
        console2.log("Treasury holds ", token.totalSupply(), " wei of PHUNK");
    }

    // -------- env helpers --------

    function _envAddrOr(string memory key, address dflt) internal view returns (address) {
        try vm.envAddress(key) returns (address v) { return v; } catch { return dflt; }
    }

    function _envUintOr(string memory key, uint256 dflt) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) { return v; } catch { return dflt; }
    }

    /// @dev Known v4 PoolManager deployments (last verified ~early 2026).
    /// Override with POOL_MANAGER env var if any have changed.
    function _defaultPoolManager(uint256 chainId) internal pure returns (address) {
        if (chainId == 1)        return 0x000000000004444c5dc75cB358380D2e3dE08A90; // mainnet
        if (chainId == 8453)     return 0x498581fF718922c3f8e6A244956aF099B2652b2b; // base
        if (chainId == 42161)    return 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32; // arbitrum
        if (chainId == 10)       return 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3; // optimism
        if (chainId == 137)      return 0x67366782805870060151383F4BbFF9daB53e5cD6; // polygon
        if (chainId == 11155111) return 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543; // sepolia
        if (chainId == 84532)    return 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408; // base sepolia
        return address(0);
    }

    // -------- hook salt mining --------

    /// @dev Brute-force a CREATE2 salt so the resulting hook address has its
    /// lower 14 bits == flags. Deterministic, ~16k iterations on average for one flag bit.
    function _mineSalt(address deployer, uint160 flags, bytes memory code, bytes memory args)
        internal pure returns (address addr, bytes32 salt, uint256 iters)
    {
        bytes32 codeHash = keccak256(abi.encodePacked(code, args));
        for (uint256 i = 0; i < 1_000_000; ++i) {
            salt = bytes32(i);
            addr = address(uint160(uint256(keccak256(
                abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)
            ))));
            if (uint160(addr) & uint160(0x3fff) == flags) {
                iters = i;
                return (addr, salt, iters);
            }
        }
        revert("HookMiner: not found");
    }
}
