// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks}            from "v4-core/libraries/Hooks.sol";
import {IPoolManager}     from "v4-core/interfaces/IPoolManager.sol";

import {ComradeHook}           from "../src/ComradeHook.sol";
import {Comrade404}            from "../src/Comrade404.sol";
import {ComradeSpriteData}     from "../src/ComradeSpriteData.sol";
import {ComradeTaxonomy}       from "../src/ComradeTaxonomy.sol";
import {ComradeRenderer}       from "../src/ComradeRenderer.sol";
import {ComradeGenesis}        from "../src/ComradeGenesis.sol";
import {IComradeRenderer}      from "../src/IComradeRenderer.sol";

/// @notice Full-stack deploy for the Comrade launch.
///
/// Run:
///   POOL_MANAGER=<addr> CDC_OG=<addr> \
///   forge script script/DeployComrade.s.sol --rpc-url $RPC --private-key $PK --broadcast --verify
///
/// Env (all optional, defaults built in):
///   POOL_MANAGER     — v4 PoolManager (chain-id presets, mainnet/Base/etc.)
///   TREASURY         — initial supply recipient (defaults to deployer)
///   CDC_OG           — owner of CDC #1 (defaults to current snapshot value)
///   MAX_COMRADES     — collection cap (default 10000)
///   TOKENS_PER_COMRADE — wei per Comrade (default 1e18 — simple 1:1)
contract DeployComrade is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Snapshot taken at the time of the holder extraction. Override with CDC_OG env if it moved.
    address constant DEFAULT_CDC_OG = 0xEbfD774c1C2008E56cE40E0a4504Ebecc81b1921;

    function run() external {
        address deployer = msg.sender;
        address treasury = _envAddrOr("TREASURY", deployer);
        address poolMgr  = _envAddrOr("POOL_MANAGER", _defaultPoolManager(block.chainid));
        address cdcOg    = _envAddrOr("CDC_OG", DEFAULT_CDC_OG);
        require(poolMgr != address(0), "POOL_MANAGER not set and no default for chain");

        uint256 maxComrades      = _envUintOr("MAX_COMRADES",       10_000);
        uint256 tokensPerComrade = _envUintOr("TOKENS_PER_COMRADE", 1 ether);

        console2.log("== Comrade deploy ==");
        console2.log("chainId:           ", block.chainid);
        console2.log("deployer/treasury: ", deployer);
        console2.log("poolManager:       ", poolMgr);
        console2.log("CDC OG (genesis):  ", cdcOg);
        console2.log("maxComrades:       ", maxComrades);
        console2.log("tokensPerComrade:  ", tokensPerComrade);

        // 1. Mine hook salt (afterSwap + afterSwapReturnsDelta = 0x44 lower 14 bits)
        uint160 wantFlags = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory hookCode = type(ComradeHook).creationCode;
        bytes memory hookArgs = abi.encode(IPoolManager(poolMgr));
        (address predicted, bytes32 salt, uint256 iters) =
            _mineSalt(CREATE2_DEPLOYER, wantFlags, hookCode, hookArgs);
        console2.log("hook (predicted):  ", predicted);
        console2.log("salt iterations:   ", iters);

        // 2. Broadcast deploys
        vm.startBroadcast();

        ComradeSpriteData spriteData = new ComradeSpriteData();
        ComradeTaxonomy   taxonomy   = new ComradeTaxonomy();
        ComradeRenderer   renderer   = new ComradeRenderer(spriteData, taxonomy);

        ComradeHook hook = new ComradeHook{salt: salt}(IPoolManager(poolMgr));
        require(address(hook) == predicted, "hook addr mismatch");

        Comrade404 token = new Comrade404(hook, payable(treasury), maxComrades, tokensPerComrade);
        token.setRenderer(IComradeRenderer(address(renderer)));
        token.setSkip(poolMgr, true);  // PoolManager holds liquidity, exempt from minting
        token.setClaimFee(0.001111 ether);  // ~$3.33 at $3k ETH; tweak via setClaimFee anytime

        // Genesis: airdrop to CDC #1 owner
        ComradeGenesis genesis = new ComradeGenesis(cdcOg, renderer);

        vm.stopBroadcast();

        console2.log("");
        console2.log("== addresses ==");
        console2.log("ComradeSpriteData: ", address(spriteData));
        console2.log("ComradeTaxonomy:   ", address(taxonomy));
        console2.log("ComradeRenderer:   ", address(renderer));
        console2.log("ComradeHook:       ", address(hook));
        console2.log("Comrade404:        ", address(token));
        console2.log("ComradeGenesis:    ", address(genesis));
        console2.log("");
        console2.log("Genesis Comrade #0 minted to:", cdcOg);
        console2.log("Treasury holds", token.totalSupply(), "wei of COMRADE");
        console2.log("");
        console2.log("== Next steps (manual via Uniswap UI or follow-up script) ==");
        console2.log("1. Initialize v4 pool: COMRADE / WETH (or USDC), 0.3% fee, hook=", address(hook));
        console2.log("2. Add single-sided liquidity in your chosen tick range");
        console2.log("3. setSkip on any router contracts you use, so they don't mint Comrades");
    }

    // -------- helpers --------

    function _envAddrOr(string memory key, address dflt) internal view returns (address) {
        try vm.envAddress(key) returns (address v) { return v; } catch { return dflt; }
    }

    function _envUintOr(string memory key, uint256 dflt) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) { return v; } catch { return dflt; }
    }

    function _defaultPoolManager(uint256 chainId) internal pure returns (address) {
        if (chainId == 1)        return 0x000000000004444c5dc75cB358380D2e3dE08A90;
        if (chainId == 8453)     return 0x498581fF718922c3f8e6A244956aF099B2652b2b;
        if (chainId == 42161)    return 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
        if (chainId == 10)       return 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
        if (chainId == 137)      return 0x67366782805870060151383F4BbFF9daB53e5cD6;
        if (chainId == 11155111) return 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        if (chainId == 84532)    return 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
        return address(0);
    }

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
