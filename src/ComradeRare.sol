// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721}         from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IComradeRenderer} from "./IComradeRenderer.sol";

/// @notice Standalone ERC-721 minted when a holder calls Phunk404.claim().
/// Each rare locks in its appearance at claim time — seed and tier are frozen,
/// rendering is independent of the holder's wallet (no champion logic).
/// Trades on any standard NFT marketplace.
contract ComradeRare is ERC721 {
    struct Rare {
        bytes32 seed;
        uint8   lockedTier;
        uint256 origin404Id; // the Phunk-id this was claimed from (informational)
        uint64  claimedAt;   // block.timestamp at claim
    }

    address public immutable comrade404;
    IComradeRenderer public renderer;

    mapping(uint256 => Rare) public rares;
    uint256 public nextId;

    error OnlyPhunk404();
    error NotOwner();

    modifier onlyPhunk404() {
        if (msg.sender != comrade404) revert OnlyPhunk404();
        _;
    }

    constructor(address _comrade404, IComradeRenderer _renderer)
        ERC721("Bytecode Comrades Rare", "BCC-RARE")
    {
        comrade404 = _comrade404;
        renderer = _renderer;
    }

    function setRenderer(IComradeRenderer r) external {
        // Same renderer can be swapped if needed. Phunk404's owner gates this
        // implicitly: only Phunk404 has authority to call into us, but we want
        // the renderer pointer settable independently. For simplicity, allow
        // Phunk404 to update.
        if (msg.sender != comrade404) revert OnlyPhunk404();
        renderer = r;
    }

    /// @notice Mint a new rare. Only callable by Phunk404 during claim().
    function mint(address to, bytes32 seed, uint8 lockedTier, uint256 origin404Id)
        external onlyPhunk404 returns (uint256 id)
    {
        id = nextId++;
        rares[id] = Rare({
            seed:        seed,
            lockedTier:  lockedTier,
            origin404Id: origin404Id,
            claimedAt:   uint64(block.timestamp)
        });
        _mint(to, id);
    }

    /// @notice Burn a rare. Only callable by Phunk404 during unclaim().
    function burn(uint256 id) external onlyPhunk404 {
        if (ownerOf(id) == address(0)) revert NotOwner();
        delete rares[id];
        _burn(id);
    }

    /// @notice Render the locked appearance. Independent of any wallet —
    /// passes a phunkCount that maps to the rare's locked tier.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        Rare memory r = rares[id];
        // ComradeRenderer derives appearance purely from seed — no tier param.
        return renderer.tokenURI(id, r.seed);
    }

    function _countForTier(uint8 tier) internal pure returns (uint256) {
        if (tier == 3) return 10000;
        if (tier == 2) return 1000;
        if (tier == 1) return 100;
        return 1;
    }
}
