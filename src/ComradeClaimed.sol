// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721}             from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IComradeRenderer}   from "./IComradeRenderer.sol";

/// @notice Standalone ERC-721 minted when a holder calls Comrade404.claim().
/// Each token locks in its appearance at claim time — seed is frozen, rendering
/// is independent of the holder's wallet. Trades on any standard NFT marketplace
/// (OpenSea, Blur, etc.) — the whole reason this contract exists separate from
/// the 404 hybrid is that NFT marketplaces don't index 404 NFTs as tradeable
/// because they don't emit canonical ERC-721 Transfer events.
contract ComradeClaimed is ERC721 {
    struct Claimed {
        bytes32 seed;
        uint256 origin404Id; // the 404 id this was claimed from (informational)
        uint64  claimedAt;   // block.timestamp at claim
    }

    address public immutable comrade404;
    IComradeRenderer public renderer;

    mapping(uint256 => Claimed) public claimed;
    uint256 public nextId;

    error OnlyComrade404();
    error NotOwner();

    modifier onlyComrade404() {
        if (msg.sender != comrade404) revert OnlyComrade404();
        _;
    }

    constructor(address _comrade404, IComradeRenderer _renderer)
        ERC721("Bytecode Comrades", "BCC")
    {
        comrade404 = _comrade404;
        renderer = _renderer;
    }

    /// @notice Swap the renderer contract. Gated to onlyComrade404 so the parent
    /// token's owner controls upgrades via Comrade404.setClaimedRenderer().
    function setRenderer(IComradeRenderer r) external onlyComrade404 {
        renderer = r;
    }

    /// @notice Mint a new claimed NFT. Only callable by Comrade404 during claim().
    function mint(address to, bytes32 seed, uint256 origin404Id)
        external onlyComrade404 returns (uint256 id)
    {
        id = nextId++;
        claimed[id] = Claimed({
            seed:        seed,
            origin404Id: origin404Id,
            claimedAt:   uint64(block.timestamp)
        });
        _mint(to, id);
    }

    /// @notice Burn a claimed NFT. Only callable by Comrade404 during unclaim().
    function burn(uint256 id) external onlyComrade404 {
        if (ownerOf(id) == address(0)) revert NotOwner();
        delete claimed[id];
        _burn(id);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        Claimed memory c = claimed[id];
        return renderer.tokenURI(id, c.seed);
    }
}
