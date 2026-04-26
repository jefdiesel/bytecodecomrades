// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISeedSource}    from "./ISeedSource.sol";
import {IPhunkRenderer} from "./IPhunkRenderer.sol";
import {IPhunkRare}     from "./IPhunkRare.sol";

/// @notice Hybrid ERC-20 + Phunk NFT (horizontally-flipped Punks).
/// Holding N whole tokens means owning N Phunks. Crossing an integer balance
/// threshold mints (or burns) a Phunk. Each minted Phunk is stamped with the
/// hook's current seed at the moment of mint and is immutable thereafter.
/// The seed determines traits; the renderer mirrors the 24x24 sprite L-R.
contract Phunk404 {
    string  public constant name      = "CryptoPhunks v4";
    string  public constant symbol    = "PHUNK";
    uint8   public constant decimals  = 18;

    /// @dev Max number of Phunks that can ever simultaneously exist.
    uint256 public immutable maxPhunks;
    /// @dev Wei of PHUNK required to earn one Phunk. e.g. 1e18 = 1 PHUNK per Phunk;
    /// 1e24 = 1,000,000 PHUNK per Phunk (memecoin ratio).
    uint256 public immutable tokensPerPhunk;
    uint256 public immutable totalSupply;

    /// @dev Renderer must mirror the 24x24 sprite left-to-right. Set false to render unflipped (Punks).
    bool public constant FLIPPED_HORIZONTAL = true;

    /// @dev Background color for the SVG renderer (lime / chartreuse).
    bytes3 public constant BACKGROUND_COLOR = 0xc3ff00;

    struct Phunk {
        bytes32 seed;
        address originalMinter;
        uint64  mintedAtSwap;
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    mapping(uint256 => Phunk)     public phunks;
    mapping(uint256 => address)   public phunkOwner;
    mapping(address => uint256[]) internal _inventory;
    mapping(address => bool)      public skipPhunks;

    uint256 public nextPhunkId;
    address public owner;
    ISeedSource public seed;
    IPhunkRenderer public renderer;
    IPhunkRare public rare;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event PhunkMinted(uint256 indexed id, address indexed to, bytes32 seed);
    event PhunkBurned(uint256 indexed id, address indexed from);
    event SeedSourceSet(address indexed seed);
    event SkipSet(address indexed account, bool skipped);
    event RendererSet(address indexed renderer);
    event RareSet(address indexed rare);
    event PhunkClaimed(address indexed holder, uint256 indexed phunkId, uint256 indexed rareId, uint8 lockedTier);
    event PhunkUnclaimed(address indexed holder, uint256 indexed rareId, uint256 indexed newPhunkId);

    error NotOwner();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroTokensPerPhunk();
    error NotPhunkHolder();
    error NotRareHolder();
    error RareNotConfigured();
    error PhunkNotFound();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        ISeedSource _seed,
        address treasury,
        uint256 _maxPhunks,
        uint256 _tokensPerPhunk
    ) {
        if (_tokensPerPhunk == 0) revert ZeroTokensPerPhunk();
        owner          = msg.sender;
        seed           = _seed;
        maxPhunks      = _maxPhunks;
        tokensPerPhunk = _tokensPerPhunk;
        totalSupply    = _maxPhunks * _tokensPerPhunk;
        skipPhunks[treasury] = true;
        balanceOf[treasury]  = totalSupply;
        emit Transfer(address(0), treasury, totalSupply);
    }

    function setSeedSource(ISeedSource s) external onlyOwner {
        seed = s;
        emit SeedSourceSet(address(s));
    }

    function setSkip(address a, bool v) external onlyOwner {
        skipPhunks[a] = v;
        emit SkipSet(a, v);
    }

    function setRenderer(IPhunkRenderer r) external onlyOwner {
        renderer = r;
        emit RendererSet(address(r));
    }

    function setRare(IPhunkRare r) external onlyOwner {
        rare = r;
        emit RareSet(address(r));
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        Phunk memory p = phunks[id];
        address holder = phunkOwner[id];
        // Effective tier-count: wallet's full count IFF this Phunk is the holder's champion
        // (= the oldest Phunk they still hold = inventory[0] under LIFO burn). Otherwise force
        // tier 0 by passing 0. This ensures only one Phunk per wallet renders at the wallet's tier.
        uint256[] storage inv = _inventory[holder];
        uint256 effectiveCount = (inv.length > 0 && inv[0] == id) ? inv.length : 0;
        return renderer.tokenURI(id, p.seed, effectiveCount);
    }

    /// @notice The holder's champion Phunk id (their oldest still-held Phunk).
    /// Returns 0 if the holder has no Phunks. Note: id 0 is a valid Phunk id; check
    /// _inventory length first if you need to distinguish "no champion" from "champion is #0".
    function championOf(address holder) external view returns (uint256) {
        uint256[] storage inv = _inventory[holder];
        return inv.length > 0 ? inv[0] : 0;
    }

    function hasChampion(address holder) external view returns (bool) {
        return _inventory[holder].length > 0;
    }

    // -------- claim / unclaim (rare ERC-721 wrapping) --------

    /// @notice Compute the effective tier of a Phunk in its current holder's wallet.
    /// Returns 0 unless the Phunk is the holder's champion.
    function effectiveTierOf(uint256 id) public view returns (uint8) {
        address holder = phunkOwner[id];
        if (holder == address(0)) return 0;
        uint256[] storage inv = _inventory[holder];
        if (inv.length == 0 || inv[0] != id) return 0;
        return _tierFor(inv.length);
    }

    /// @notice Convert a 404-Phunk into a standalone ERC-721 PhunkRare token.
    /// Locks in the current effective tier. Burns the 404-Phunk; the caller's
    /// PHUNK ERC-20 balance drops by tokensPerPhunk (the wrapped value moves
    /// into the rare). Caller must own the Phunk and have at least tokensPerPhunk
    /// of PHUNK held. The rare is minted to msg.sender.
    function claim(uint256 id) external returns (uint256 rareId) {
        if (address(rare) == address(0)) revert RareNotConfigured();
        if (phunkOwner[id] != msg.sender) revert NotPhunkHolder();
        if (balanceOf[msg.sender] < tokensPerPhunk) revert InsufficientBalance();

        uint8 lockedTier = effectiveTierOf(id);
        Phunk memory p = phunks[id];

        // Remove from 404 inventory + storage
        _removeFromInventory(msg.sender, id);
        delete phunks[id];
        delete phunkOwner[id];

        // Lock the wrapped PHUNK by sending to address(this)
        unchecked {
            balanceOf[msg.sender] -= tokensPerPhunk;
            balanceOf[address(this)] += tokensPerPhunk;
        }
        emit Transfer(msg.sender, address(this), tokensPerPhunk);
        emit PhunkBurned(id, msg.sender);

        // Mint the rare
        rareId = rare.mint(msg.sender, p.seed, lockedTier, id);
        emit PhunkClaimed(msg.sender, id, rareId, lockedTier);
    }

    /// @notice Burn a PhunkRare ERC-721 and re-enter the 404 system. The caller
    /// receives back tokensPerPhunk of PHUNK and a freshly-minted Phunk-ID
    /// stamped with the rare's original seed (preserving art continuity).
    function unclaim(uint256 rareId) external returns (uint256 newPhunkId) {
        if (address(rare) == address(0)) revert RareNotConfigured();
        if (rare.ownerOf(rareId) != msg.sender) revert NotRareHolder();

        (bytes32 oldSeed,,,) = rare.rares(rareId);

        // Burn the rare first to prevent reentrancy weirdness
        rare.burn(rareId);

        // Return the wrapped PHUNK
        unchecked {
            balanceOf[address(this)] -= tokensPerPhunk;
            balanceOf[msg.sender]   += tokensPerPhunk;
        }
        emit Transfer(address(this), msg.sender, tokensPerPhunk);

        // Re-mint a 404 Phunk with the original seed (so the art ancestry persists)
        newPhunkId = nextPhunkId++;
        phunks[newPhunkId] = Phunk({
            seed:           oldSeed,
            originalMinter: msg.sender,
            mintedAtSwap:   seed.swapCount()
        });
        phunkOwner[newPhunkId] = msg.sender;
        _inventory[msg.sender].push(newPhunkId);
        emit PhunkMinted(newPhunkId, msg.sender, oldSeed);
        emit PhunkUnclaimed(msg.sender, rareId, newPhunkId);
    }

    /// @dev Linear-scan removal. Used by claim() — N is small per holder.
    function _removeFromInventory(address holder, uint256 id) internal {
        uint256[] storage inv = _inventory[holder];
        uint256 n = inv.length;
        for (uint256 i = 0; i < n; i++) {
            if (inv[i] == id) {
                inv[i] = inv[n - 1];
                inv.pop();
                return;
            }
        }
        revert PhunkNotFound();
    }

    /// @dev Tier from Phunk count — duplicated from renderer for in-contract use.
    function _tierFor(uint256 count) internal pure returns (uint8) {
        if (count >= 10000) return 3;
        if (count >= 1000)  return 2;
        if (count >= 100)   return 1;
        return 0;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = a - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 fb = balanceOf[from];
        if (fb < amount) revert InsufficientBalance();

        uint256 fromWholeBefore = fb / tokensPerPhunk;
        uint256 toWholeBefore   = balanceOf[to] / tokensPerPhunk;

        unchecked {
            balanceOf[from] = fb - amount;
            balanceOf[to]  += amount;
        }

        uint256 fromWholeAfter = balanceOf[from] / tokensPerPhunk;
        uint256 toWholeAfter   = balanceOf[to]   / tokensPerPhunk;

        if (!skipPhunks[from] && fromWholeAfter < fromWholeBefore) {
            uint256 lose = fromWholeBefore - fromWholeAfter;
            for (uint256 i; i < lose; ++i) {
                uint256 last = _inventory[from].length - 1;
                uint256 id   = _inventory[from][last];
                _inventory[from].pop();
                delete phunks[id];
                delete phunkOwner[id];
                emit PhunkBurned(id, from);
            }
        }

        if (!skipPhunks[to] && toWholeAfter > toWholeBefore) {
            uint256 gain     = toWholeAfter - toWholeBefore;
            bytes32 hookSeed = seed.currentSeed();
            uint64  swapNo   = seed.swapCount();
            for (uint256 i; i < gain; ++i) {
                uint256 id = nextPhunkId++;
                bytes32 s  = keccak256(abi.encode(hookSeed, id, to));
                phunks[id]    = Phunk({ seed: s, originalMinter: to, mintedAtSwap: swapNo });
                phunkOwner[id] = to;
                _inventory[to].push(id);
                emit PhunkMinted(id, to, s);
            }
        }

        emit Transfer(from, to, amount);
    }

    function inventoryOf(address a) external view returns (uint256[] memory) {
        return _inventory[a];
    }

    function phunksOwned(address a) external view returns (uint256) {
        return _inventory[a].length;
    }
}
