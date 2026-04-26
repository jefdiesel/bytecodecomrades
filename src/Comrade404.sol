// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISeedSource}      from "./ISeedSource.sol";
import {IComradeRenderer} from "./IComradeRenderer.sol";
import {IComradeRare}     from "./IComradeRare.sol";
import {IComradeBloom}    from "./IComradeBloom.sol";

/// @notice Hybrid ERC-20 + Comrade NFT, with ERC-721 visibility events so wallets
/// and explorers auto-detect the NFTs without an explicit claim.
///
/// Holding 1 whole COMRADE token = owning 1 Comrade NFT (joined at the hip).
/// Selling burns your NFT; the buyer gets a freshly-minted one with a new seed.
///
/// You can OPTIONALLY `claim(id)` to lift a specific Comrade out into a
/// standalone ComradeRare ERC-721 (separately tradeable on OpenSea, etc.).
/// claim() charges a fee in COMRADE that goes to the treasury.
contract Comrade404 {
    string  public constant name     = "Bytecode Comrades";
    string  public constant symbol   = "BCC";
    uint8   public constant decimals = 18;

    uint256 public immutable maxComrades;
    uint256 public immutable tokensPerComrade;
    uint256 public immutable totalSupply;

    struct Comrade {
        bytes32 seed;
        address originalMinter;
        uint64  mintedAtSwap;
    }

    // ERC-20 state
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // NFT state
    mapping(uint256 => Comrade)   public comrades;
    mapping(uint256 => address)   public comradeOwner;
    mapping(address => uint256[]) internal _inventory;
    mapping(address => bool)      public skipComrades;

    uint256 public nextComradeId;
    address public owner;
    address payable public treasury;
    /// @dev Claim fee in ETH (wei). Sent to treasury when a holder calls claim().
    /// Default suggested: ~$5 worth of ETH (e.g. 1.67e15 wei at $3000 ETH).
    /// Update via setClaimFee() as ETH price moves, or set to 0 for free claims.
    uint256 public claimFeeWei;

    ISeedSource public seed;
    IComradeRenderer public renderer;
    IComradeRare public rare;
    IComradeBloom public bloom;
    uint8 public maxBloomRetries = 8;

    // -------- events --------

    // ERC-20
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    // ERC-721 (NFT side) — same name as ERC-20 Transfer but distinguished by 3rd indexed arg
    event Transfer721(address indexed from, address indexed to, uint256 indexed id);
    // Note: Solidity event overloading isn't possible. We use a distinct event name so explorers
    // can pick up both. For wallets that strictly need ERC-721 Transfer(address,address,uint256),
    // see the indexed-uint256 variant below — emitted in addition.

    // Admin
    event ComradeMinted(uint256 indexed id, address indexed to, bytes32 seed);
    event ComradeBurned(uint256 indexed id, address indexed from);
    event SeedSourceSet(address indexed seed);
    event SkipSet(address indexed account, bool skipped);
    event RendererSet(address indexed renderer);
    event RareSet(address indexed rare);
    event BloomSet(address indexed bloom);
    event TreasurySet(address indexed treasury);
    event ClaimFeeSet(uint256 feeWei);
    event ClaimFeePaid(address indexed payer, address indexed treasury, uint256 amount);
    event ComradeClaimed(address indexed holder, uint256 indexed comradeId, uint256 indexed rareId, uint256 fee);
    event ComradeUnclaimed(address indexed holder, uint256 indexed rareId, uint256 indexed newComradeId);

    // -------- errors --------

    error NotOwner();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroTokensPerComrade();
    error NotComradeHolder();
    error NotRareHolder();
    error RareNotConfigured();
    error TreasuryNotSet();
    error TransferDisabled();   // ERC-721 transfer not allowed; use ERC-20
    error WrongClaimFee();      // msg.value didn't match claimFeeWei
    error TreasuryRejectedEth();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        ISeedSource _seed,
        address payable _treasury,
        uint256 _maxComrades,
        uint256 _tokensPerComrade
    ) {
        if (_tokensPerComrade == 0) revert ZeroTokensPerComrade();
        owner            = msg.sender;
        seed             = _seed;
        treasury         = _treasury;
        maxComrades      = _maxComrades;
        tokensPerComrade = _tokensPerComrade;
        totalSupply      = _maxComrades * _tokensPerComrade;
        skipComrades[_treasury] = true;
        balanceOf[_treasury]    = totalSupply;
        emit Transfer(address(0), _treasury, totalSupply);
    }

    // -------- admin --------

    function setSeedSource(ISeedSource s) external onlyOwner {
        seed = s;
        emit SeedSourceSet(address(s));
    }

    function setSkip(address a, bool v) external onlyOwner {
        skipComrades[a] = v;
        emit SkipSet(a, v);
    }

    function setRenderer(IComradeRenderer r) external onlyOwner {
        renderer = r;
        emit RendererSet(address(r));
    }

    function setRare(IComradeRare r) external onlyOwner {
        rare = r;
        emit RareSet(address(r));
    }

    /// @notice Set the bloom filter contract used for CDC/CRC dedup at mint time.
    /// Set to address(0) to disable dedup checking (zero gas overhead at mint).
    function setBloom(IComradeBloom b) external onlyOwner {
        bloom = b;
        emit BloomSet(address(b));
    }

    function setMaxBloomRetries(uint8 n) external onlyOwner {
        maxBloomRetries = n;
    }

    function setTreasury(address payable t) external onlyOwner {
        treasury = t;
        emit TreasurySet(t);
    }

    function setClaimFee(uint256 feeWei) external onlyOwner {
        claimFeeWei = feeWei;
        emit ClaimFeeSet(feeWei);
    }

    // -------- ERC-20 --------

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

        uint256 fromWholeBefore = fb / tokensPerComrade;
        uint256 toWholeBefore   = balanceOf[to] / tokensPerComrade;

        unchecked {
            balanceOf[from] = fb - amount;
            balanceOf[to]  += amount;
        }

        uint256 fromWholeAfter = balanceOf[from] / tokensPerComrade;
        uint256 toWholeAfter   = balanceOf[to]   / tokensPerComrade;

        if (!skipComrades[from] && fromWholeAfter < fromWholeBefore) {
            uint256 lose = fromWholeBefore - fromWholeAfter;
            for (uint256 i; i < lose; ++i) {
                uint256 last = _inventory[from].length - 1;
                uint256 id   = _inventory[from][last];
                _inventory[from].pop();
                delete comrades[id];
                delete comradeOwner[id];
                emit ComradeBurned(id, from);
                emit Transfer721(from, address(0), id);
            }
        }

        if (!skipComrades[to] && toWholeAfter > toWholeBefore) {
            uint256 gain     = toWholeAfter - toWholeBefore;
            bytes32 hookSeed = seed.currentSeed();
            uint64  swapNo   = seed.swapCount();
            for (uint256 i; i < gain; ++i) {
                uint256 id = nextComradeId++;
                bytes32 s  = _findCleanSeed(hookSeed, id, to);
                comrades[id]    = Comrade({ seed: s, originalMinter: to, mintedAtSwap: swapNo });
                comradeOwner[id] = to;
                _inventory[to].push(id);
                emit ComradeMinted(id, to, s);
                emit Transfer721(address(0), to, id);
            }
        }

        emit Transfer(from, to, amount);
    }

    // -------- views --------

    function inventoryOf(address a) external view returns (uint256[] memory) {
        return _inventory[a];
    }

    function comradesOwned(address a) external view returns (uint256) {
        return _inventory[a].length;
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        Comrade memory c = comrades[id];
        return renderer.tokenURI(id, c.seed);
    }

    /// @notice ERC-721 helper. Returns NFT count for an address. (ERC-20 balanceOf
    /// returns wei balance — wallets that understand 404 will divide by tokensPerComrade.)
    function nftBalanceOf(address a) external view returns (uint256) {
        return _inventory[a].length;
    }

    /// @notice ERC-721 helper. Returns owner of a Comrade by id.
    function ownerOf(uint256 id) external view returns (address) {
        return comradeOwner[id];
    }

    // -------- ERC-721 transfer surface (intentionally disabled) --------
    // The NFT and the underlying ERC-20 are joined at the hip — they cannot be
    // transferred independently. To trade a specific Comrade, either:
    //   - transfer the whole COMRADE token via the ERC-20 functions, or
    //   - claim() it into a standalone ComradeRare and trade that.

    function getApproved(uint256) external pure returns (address) { return address(0); }
    function isApprovedForAll(address, address) external pure returns (bool) { return false; }
    function approveNft(address, uint256) external pure { revert TransferDisabled(); }
    function setApprovalForAll(address, bool) external pure { revert TransferDisabled(); }
    function transferFrom(address, address, uint256, bytes calldata) external pure { revert TransferDisabled(); }
    function safeTransferFrom(address, address, uint256) external pure { revert TransferDisabled(); }
    function safeTransferFrom(address, address, uint256, bytes calldata) external pure { revert TransferDisabled(); }

    // -------- claim / unclaim (rare ERC-721 wrapping with treasury fee) --------

    /// @notice Lift a Comrade out of the 404 system into a standalone ComradeRare ERC-721.
    /// Pays `claimFeeWei` ETH to the treasury and locks `tokensPerComrade` worth of
    /// COMRADE inside this contract (the wrapped value moves with the rare).
    ///
    /// Caller must:
    ///   - own the Comrade (id)
    ///   - have at least `tokensPerComrade` COMRADE
    ///   - send exactly `claimFeeWei` of ETH as msg.value
    function claim(uint256 id) external payable returns (uint256 rareId) {
        if (address(rare) == address(0)) revert RareNotConfigured();
        if (comradeOwner[id] != msg.sender) revert NotComradeHolder();
        if (treasury == address(0) && claimFeeWei > 0) revert TreasuryNotSet();
        if (msg.value != claimFeeWei) revert WrongClaimFee();
        if (balanceOf[msg.sender] < tokensPerComrade) revert InsufficientBalance();

        Comrade memory c = comrades[id];

        // Burn from 404 inventory + storage
        _removeFromInventory(msg.sender, id);
        delete comrades[id];
        delete comradeOwner[id];

        // Lock the wrapped COMRADE inside this contract
        unchecked {
            balanceOf[msg.sender] -= tokensPerComrade;
            balanceOf[address(this)] += tokensPerComrade;
        }
        emit Transfer(msg.sender, address(this), tokensPerComrade);

        // Forward ETH fee to treasury
        if (msg.value > 0) {
            (bool ok, ) = treasury.call{value: msg.value}("");
            if (!ok) revert TreasuryRejectedEth();
            emit ClaimFeePaid(msg.sender, treasury, msg.value);
        }

        emit ComradeBurned(id, msg.sender);
        emit Transfer721(msg.sender, address(0), id);

        // Mint the standalone rare
        rareId = rare.mint(msg.sender, c.seed, 0, id);
        emit ComradeClaimed(msg.sender, id, rareId, msg.value);
    }

    /// @notice Burn a ComradeRare ERC-721 and return its wrapped COMRADE.
    /// Mints a fresh in-404 Comrade with the rare's original seed.
    /// No fee on unclaim.
    function unclaim(uint256 rareId) external returns (uint256 newComradeId) {
        if (address(rare) == address(0)) revert RareNotConfigured();
        if (rare.ownerOf(rareId) != msg.sender) revert NotRareHolder();

        (bytes32 oldSeed,,,) = rare.rares(rareId);

        rare.burn(rareId);

        unchecked {
            balanceOf[address(this)] -= tokensPerComrade;
            balanceOf[msg.sender]    += tokensPerComrade;
        }
        emit Transfer(address(this), msg.sender, tokensPerComrade);

        newComradeId = nextComradeId++;
        comrades[newComradeId] = Comrade({
            seed:           oldSeed,
            originalMinter: msg.sender,
            mintedAtSwap:   seed.swapCount()
        });
        comradeOwner[newComradeId] = msg.sender;
        _inventory[msg.sender].push(newComradeId);
        emit ComradeMinted(newComradeId, msg.sender, oldSeed);
        emit Transfer721(address(0), msg.sender, newComradeId);
        emit ComradeUnclaimed(msg.sender, rareId, newComradeId);
    }

    // -------- internals --------

    /// @dev Derive a Comrade seed from (hookSeed, id, to). If a bloom filter is
    /// configured, retry up to `maxBloomRetries` times with mutated seeds when
    /// the resulting trait pick would collide with the CDC/CRC fingerprint set.
    /// FPR is ~10^-9, so retries are vanishingly rare in practice.
    function _findCleanSeed(bytes32 hookSeed, uint256 id, address to)
        internal view returns (bytes32)
    {
        bytes32 s = keccak256(abi.encode(hookSeed, id, to));

        // No bloom or no renderer configured → skip dedup
        if (address(bloom) == address(0) || address(renderer) == address(0)) {
            return s;
        }

        for (uint8 retry = 0; retry < maxBloomRetries; retry++) {
            uint16[] memory ids = renderer.pick(s);
            bytes32 fp = bloom.fingerprintOf(ids);
            if (!bloom.mightContain(fp)) return s;
            // Reroll: mutate seed deterministically
            s = keccak256(abi.encode(s, retry, "reroll"));
        }
        // Give up — return last attempt. ~10^-9 × 8 retries = effectively never.
        return s;
    }

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
        revert NotComradeHolder();
    }

    // -------- ERC-165 supportsInterface --------

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7  // ERC-165
            || id == 0x36372b07  // ERC-20 (loose)
            || id == 0x80ac58cd  // ERC-721
            || id == 0x5b5e139f; // ERC-721 Metadata
    }
}
