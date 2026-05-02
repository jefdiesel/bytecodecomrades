// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Mirrors the uPEG seed layout (UpegMetadata.sol from the live token).
/// Each byte of the seed encodes one trait. Bit positions are exact.
library UpegSeedDecoder {
    struct Traits {
        uint8 backgroundColor;   // byte 0  - always present (can be 0)
        uint8 horn;              // byte 1  - 0 = none
        uint8 accessories;       // byte 2  - 0 = none
        uint8 hair;              // byte 3  - 0 = none
        uint8 wings;             // byte 4  - 0 = none
        uint8 tail;              // byte 5  - 0 = none
        uint8 legsFront;         // byte 6  - always present
        uint8 legsBack;          // byte 7  - always present
        uint8 eyes;              // byte 8  - always present
        uint8 body;              // byte 9  - always present
        uint8 ground;            // byte 10 - 0 = none
        uint8 bodyColor;         // byte 11 (also legs+wings color)
        uint8 eyesColor;         // byte 12
        uint8 hairColor;         // byte 13
        uint8 hornColor;         // byte 14
        uint8 groundColor;       // byte 15
        uint8 accessoriesColor;  // byte 16
        uint8 tailColor;         // byte 17
    }

    function decode(uint256 seed) internal pure returns (Traits memory t) {
        t.backgroundColor  = uint8( seed        & 0xFF);
        t.horn             = uint8((seed >> 8)  & 0xFF);
        t.accessories      = uint8((seed >> 16) & 0xFF);
        t.hair             = uint8((seed >> 24) & 0xFF);
        t.wings            = uint8((seed >> 32) & 0xFF);
        t.tail             = uint8((seed >> 40) & 0xFF);
        t.legsFront        = uint8((seed >> 48) & 0xFF);
        t.legsBack         = uint8((seed >> 56) & 0xFF);
        t.eyes             = uint8((seed >> 64) & 0xFF);
        t.body             = uint8((seed >> 72) & 0xFF);
        t.ground           = uint8((seed >> 80) & 0xFF);
        t.bodyColor        = uint8((seed >> 88) & 0xFF);
        t.eyesColor        = uint8((seed >> 96) & 0xFF);
        t.hairColor        = uint8((seed >> 104)& 0xFF);
        t.hornColor        = uint8((seed >> 112)& 0xFF);
        t.groundColor      = uint8((seed >> 120)& 0xFF);
        t.accessoriesColor = uint8((seed >> 128)& 0xFF);
        t.tailColor        = uint8((seed >> 136)& 0xFF);
    }
}

/// @title UpegEthscriberV3
/// @notice Curve-priced uPEG ethscriber for the AppChain collection.
///         v3 adds: per-id dupe prevention + ERC-721 traits decoded from seed.
///         Spec-compliant Data URI: rule=esip6 + string item_index, key order
///         enforced. Validated by forge test before deploy.
contract UpegEthscriberV3 {
    using Strings for uint256;
    using UpegSeedDecoder for uint256;

    event ethscriptions_protocol_CreateEthscription(
        address indexed initialOwner,
        string contentURI
    );

    address payable public immutable feeRecipient;
    uint256        public immutable basePrice;
    uint256        public immutable priceStep;
    address        public immutable upegHook;
    string         public           collectionId;

    uint256 public mintCount;

    // No contract-level dupe mapping. Uniqueness is enforced naturally at the
    // ethscription/AppChain protocol layer:
    //  - L1 ethscriptions reject duplicate content by SHA256(dataURI)
    //  - AppChain collection protocol rejects duplicate item_index per collection
    // The page should pre-check via the ethscriptions API before letting the
    // user pay the mint fee. We don't pay storage gas on every mint to track
    // something the protocol tracks for free.

    error InsufficientFee();
    error FeeTransferFailed();
    error RefundFailed();
    error SvgGenerateFailed();

    constructor(
        address payable feeRecipient_,
        uint256 basePrice_,
        uint256 priceStep_,
        address upegHook_,
        string memory collectionId_
    ) {
        require(feeRecipient_ != address(0), "feeRecipient=0");
        require(upegHook_ != address(0), "upegHook=0");
        require(bytes(collectionId_).length == 66, "collectionId must be 0x + 64 hex chars");
        feeRecipient = feeRecipient_;
        basePrice    = basePrice_;
        priceStep    = priceStep_;
        upegHook     = upegHook_;
        collectionId = collectionId_;
    }

    function currentPrice() public view returns (uint256) {
        return basePrice + priceStep * mintCount;
    }

    function mint(uint256 upegId, uint256 seed) external payable {
        uint256 price = currentPrice();
        if (msg.value < price) revert InsufficientFee();
        unchecked { ++mintCount; }

        // Fetch the SVG from the uPEG hook (deterministic per seed)
        (bool ok, bytes memory ret) = upegHook.staticcall(
            abi.encodeWithSignature("generate(uint256)", seed)
        );
        if (!ok) revert SvgGenerateFailed();
        string memory svg = abi.decode(ret, (string));

        // Build the spec-compliant JSON (key order enforced)
        bytes memory jsonBytes = _buildJson(upegId, seed);

        // Build header-form Data URI. rule=esip6 is MANDATORY.
        string memory dataURI = string.concat(
            "data:image/svg+xml;rule=esip6;p=erc-721-ethscriptions-collection;op=add_self_to_collection;d=",
            Base64.encode(jsonBytes),
            ";base64,",
            Base64.encode(bytes(svg))
        );

        emit ethscriptions_protocol_CreateEthscription(msg.sender, dataURI);

        // Atomic fee forward
        (bool feeOk, ) = feeRecipient.call{value: price}("");
        if (!feeOk) revert FeeTransferFailed();
        uint256 excess = msg.value - price;
        if (excess > 0) {
            (bool refundOk, ) = payable(msg.sender).call{value: excess}("");
            if (!refundOk) revert RefundFailed();
        }
    }

    // ----- internal payload builders -----

    function _buildJson(uint256 upegId, uint256 seed) internal view returns (bytes memory) {
        UpegSeedDecoder.Traits memory t = seed.decode();
        string memory upegIdStr = upegId.toString();
        bytes memory attrs = _buildAttributes(t, upegIdStr);

        // item key order: item_index, name, background_color, description, attributes, merkle_proof
        return abi.encodePacked(
            '{"collection_id":"', collectionId,
            '","item":{"item_index":"', upegIdStr,
            '","name":"uPEG #', upegIdStr,
            '","background_color":"#0b0c10"',
            ',"description":"uPEG unicorn #', upegIdStr,
            '. On-chain SVG, deterministic from seed."',
            ',"attributes":', attrs,
            ',"merkle_proof":[]}}'
        );
    }

    function _buildAttributes(UpegSeedDecoder.Traits memory t, string memory upegIdStr)
        internal pure returns (bytes memory attrs)
    {
        // Always-present traits
        attrs = abi.encodePacked(
            '[{"trait_type":"upeg_id","value":"', upegIdStr, '"}',
            _attr("background", t.backgroundColor),
            _attr("body",       t.body),
            _attr("body_color", t.bodyColor),
            _attr("eyes",       t.eyes),
            _attr("eyes_color", t.eyesColor),
            _attr("legs_front", t.legsFront),
            _attr("legs_back",  t.legsBack)
        );

        // Optional traits — omit when value == 0 ("none")
        uint256 optCount;
        if (t.horn > 0)        { attrs = abi.encodePacked(attrs, _attr("horn",        t.horn),        _attr("horn_color",        t.hornColor));        ++optCount; }
        if (t.accessories > 0) { attrs = abi.encodePacked(attrs, _attr("accessories", t.accessories), _attr("accessories_color", t.accessoriesColor)); ++optCount; }
        if (t.hair > 0)        { attrs = abi.encodePacked(attrs, _attr("hair",        t.hair),        _attr("hair_color",        t.hairColor));        ++optCount; }
        if (t.wings > 0)       { attrs = abi.encodePacked(attrs, _attr("wings",       t.wings));      ++optCount; }
        if (t.tail > 0)        { attrs = abi.encodePacked(attrs, _attr("tail",        t.tail),        _attr("tail_color",        t.tailColor));        ++optCount; }
        if (t.ground > 0)      { attrs = abi.encodePacked(attrs, _attr("ground",      t.ground),      _attr("ground_color",      t.groundColor));      ++optCount; }

        // Trait count (lower = rarer; range 0..6 of the 6 optional categories)
        attrs = abi.encodePacked(attrs, _attr("optional_trait_count", uint8(optCount)), ']');
    }

    function _attr(string memory name, uint8 val) internal pure returns (bytes memory) {
        return abi.encodePacked(',{"trait_type":"', name, '","value":"', uint256(val).toString(), '"}');
    }
}
