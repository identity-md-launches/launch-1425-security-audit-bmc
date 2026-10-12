// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IBMCToken} from "./interfaces/IBMCToken.sol";
import {StandardArt} from "./StandardArt.sol";

/// @title BMC Illuminati Pass
/// @notice 500-piece ERC-721 collection minted by permanently burning BMC through `burnFrom`.
///
///  Phase 1 (token ids 1-40): sequential Genesis mints at 1,000,000 BMC each. Token #1 is the
///  Legendary Genesis. Token id N receives artwork genesis-NN.png for N in 1..40.
///
///  Phase 2 (token ids 41-500): 460 mystery mints at 350,000 BMC each. Each mystery mint burns BMC,
///  immediately mints a pending-reveal NFT and requests one Chainlink VRF v2.5 random word. When the
///  coordinator delivers the word it is stored; reveals are then finalized permissionlessly, in
///  strict mint order, drawing without replacement from a fixed pool of 37 Genesis (genesis-41 ..
///  genesis-77) and 423 Standard outcomes (fully on-chain SVG).
///
///  Trust model / privileged powers (see README "Operational responsibilities"):
///   - The verified Genesis images CID is a constant; metadata cannot be reconfigured.
///   - Owner can update the Chainlink VRF request configuration (subscription id, key hash, callback
///     gas, confirmations, payment mode). This can only affect *future* requests, never a stored or
///     finalized outcome. Retries use the current configuration. The coordinator is immutable.
///     The owner cannot mint, overwrite delivered randomness, assign
///     artwork, change prices or metadata, withdraw anything, or upgrade the contract.
///   - The VRF subscription itself is administered on the Chainlink coordinator by its subscription
///     owner (adding this contract as a consumer, funding it). Anyone can fund a subscription.
///
///  Unavailable randomness: underfunded requests can expire. Anyone can request another word after
///  the retry delay while no word has arrived. All issued ids stay valid and the first delivered
///  word wins. No caller can discard a stored word. This recovery still trusts the coordinator's
///  delivery order; see the security report for the additional trust and subscription cost risks.
contract BMCIlluminatiPass is ERC721, Ownable2Step, ReentrancyGuard {
    using Strings for uint256;

    // ------------------------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------------------------

    enum Tier {
        Pending, // 0: mystery mint awaiting reveal
        LegendaryGenesis, // 1: token #1
        Genesis, // 2
        Standard // 3
    }

    enum RevealStatus {
        None, // not a mystery token / not minted
        AwaitingRandomness, // VRF request open
        RandomnessStored, // word delivered, waiting for in-order finalization
        Revealed // tier and artwork assigned
    }

    struct VRFConfig {
        uint256 subscriptionId;
        bytes32 keyHash;
        uint32 callbackGasLimit;
        uint16 requestConfirmations;
        bool nativePayment;
        bool configured;
    }

    // ------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------

    uint256 public constant MAX_SUPPLY = 500;
    uint256 public constant GENESIS_PHASE_SUPPLY = 40;
    uint256 public constant MYSTERY_SUPPLY = 460;
    uint256 public constant TOTAL_GENESIS = 77;
    uint256 public constant MYSTERY_GENESIS = 37;
    uint256 public constant TOTAL_STANDARD = 423;

    /// @dev BMC has 18 decimals (verified on mainnet; also re-checked on every mint).
    uint8 public constant BMC_DECIMALS = 18;
    uint256 public constant GENESIS_PRICE = 1_000_000 * 1e18;
    uint256 public constant MYSTERY_PRICE = 350_000 * 1e18;
    /// @dev 40 * 1,000,000 + 460 * 350,000 = 201,000,000 BMC.
    uint256 public constant MAX_TOTAL_BURN = 201_000_000 * 1e18;

    uint32 public constant MIN_CALLBACK_GAS_LIMIT = 150_000;
    uint32 public constant MAX_CALLBACK_GAS_LIMIT = 2_500_000;
    uint16 public constant MIN_REQUEST_CONFIRMATIONS = 3;
    uint16 public constant MAX_REQUEST_CONFIRMATIONS = 200;
    /// @dev Maximum reveals processed from inside one VRF callback (bounded gas).
    uint256 public constant CALLBACK_REVEAL_BATCH = 4;
    /// @dev Conservative gas budget per reveal (measured ~85k worst case) and reserve for the return path.
    uint256 public constant GAS_PER_REVEAL = 110_000;
    uint256 public constant CALLBACK_GAS_RESERVE = 30_000;
    uint256 public constant RETRY_DELAY = 1 days;

    string public constant genesisImagesCID = "bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u";
    /// @notice Retained for integrations: the constant CID is locked from construction.
    bool public constant genesisCIDLocked = true;

    IBMCToken public immutable BMC;
    IVRFCoordinatorV2Plus public immutable VRF_COORDINATOR;

    // ------------------------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------------------------

    /// @notice Number of NFTs minted so far (also the last token id).
    uint256 public totalMinted;
    /// @notice Total BMC (18-decimal units) burned through this contract.
    uint256 public totalBurned;
    /// @notice Number of mystery tokens whose outcome has been finalized.
    uint256 public revealedCount;
    /// @notice Number of Genesis outcomes drawn from the mystery pool so far.
    uint256 public mysteryGenesisRevealed;

    VRFConfig public vrfConfig;

    mapping(uint256 tokenId => Tier) private _tier;
    mapping(uint256 tokenId => uint16) private _artworkId;
    mapping(uint256 tokenId => RevealStatus) private _revealStatus;
    mapping(uint256 tokenId => uint256 requestId) public requestIdOf;
    mapping(uint256 requestId => uint256 tokenId) public tokenIdOfRequest;
    mapping(uint256 tokenId => uint256 timestamp) public lastRequestAt;
    mapping(uint256 tokenId => uint256) private _randomWord;

    /// @dev Virtual Fisher-Yates over 460 slots. slot(i) = i unless swapped; stores value + 1.
    mapping(uint256 => uint256) private _slotSwap;

    // ------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------

    event VRFConfigSet(
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment
    );
    event GenesisMinted(address indexed minter, uint256 indexed tokenId, uint16 artworkId, uint256 bmcBurned);
    event MysteryMinted(address indexed minter, uint256 indexed tokenId, uint256 indexed requestId, uint256 bmcBurned);
    event RandomnessStored(uint256 indexed tokenId, uint256 indexed requestId, uint256 randomWord);
    event RandomnessRequested(uint256 indexed tokenId, uint256 indexed requestId);
    event Revealed(uint256 indexed tokenId, Tier tier, uint16 artworkId);

    // ------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------

    error InvalidVRFConfig();
    error OwnershipRenunciationDisabled();
    error RetryUnavailable();
    error GenesisPhaseOver();
    error GenesisPhaseNotOver();
    error SoldOut();
    error UnexpectedTokenDecimals(uint8 actual);
    error BurnMismatch(uint256 expected, uint256 actual);
    error OnlyCoordinator();
    error UnknownRequest(uint256 requestId);
    error NoRandomWords();
    error NonexistentToken(uint256 tokenId);

    // ------------------------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------------------------

    /// @param initialOwner Owner able to update future VRF request configuration.
    /// @param bmcToken The BMC token (mainnet 0x38224239f2BDae357D47cb864BC533d7f72dF961).
    /// @param vrfCoordinator Chainlink VRF v2.5 coordinator (mainnet 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a).
    constructor(
        address initialOwner,
        address bmcToken,
        address vrfCoordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment
    ) ERC721("BMC Illuminati Pass", "BMCPASS") Ownable(initialOwner) {
        require(bmcToken != address(0) && vrfCoordinator != address(0), "zero address");
        BMC = IBMCToken(bmcToken);
        VRF_COORDINATOR = IVRFCoordinatorV2Plus(vrfCoordinator);
        _setVRFConfig(subscriptionId, keyHash, callbackGasLimit, requestConfirmations, nativePayment);
    }

    // ------------------------------------------------------------------------------------------
    // Owner configuration (disclosed operational permissions)
    // ------------------------------------------------------------------------------------------

    /// @notice Keep the owner role available to repair future requests and stalled reveals.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenunciationDisabled();
    }

    /// @notice Set the Chainlink VRF v2.5 request parameters used for future mints and retries.
    /// @dev Only affects requests made after this call. Cannot touch stored randomness or reveals.
    function setVRFConfig(
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment
    ) external onlyOwner {
        _setVRFConfig(subscriptionId, keyHash, callbackGasLimit, requestConfirmations, nativePayment);
    }

    function _setVRFConfig(
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment
    ) private {
        if (
            subscriptionId == 0 || keyHash == bytes32(0) || callbackGasLimit < MIN_CALLBACK_GAS_LIMIT
                || callbackGasLimit > MAX_CALLBACK_GAS_LIMIT || requestConfirmations < MIN_REQUEST_CONFIRMATIONS
                || requestConfirmations > MAX_REQUEST_CONFIRMATIONS
        ) revert InvalidVRFConfig();
        vrfConfig = VRFConfig({
            subscriptionId: subscriptionId,
            keyHash: keyHash,
            callbackGasLimit: callbackGasLimit,
            requestConfirmations: requestConfirmations,
            nativePayment: nativePayment,
            configured: true
        });
        emit VRFConfigSet(subscriptionId, keyHash, callbackGasLimit, requestConfirmations, nativePayment);
    }

    // ------------------------------------------------------------------------------------------
    // Minting
    // ------------------------------------------------------------------------------------------

    /// @notice Phase 1: mint the next sequential Genesis NFT (ids 1-40) for 1,000,000 BMC.
    function mintGenesis() external nonReentrant returns (uint256 tokenId) {
        if (totalMinted >= GENESIS_PHASE_SUPPLY) revert GenesisPhaseOver();

        _burnExact(msg.sender, GENESIS_PRICE);

        tokenId = ++totalMinted;
        Tier tier = tokenId == 1 ? Tier.LegendaryGenesis : Tier.Genesis;
        _tier[tokenId] = tier;
        _artworkId[tokenId] = uint16(tokenId);
        emit GenesisMinted(msg.sender, tokenId, uint16(tokenId), GENESIS_PRICE);
        emit Revealed(tokenId, tier, uint16(tokenId));

        _safeMint(msg.sender, tokenId);
    }

    /// @notice Phase 2: burn 350,000 BMC, receive a pending-reveal NFT and open a VRF request.
    function mintMystery() external nonReentrant returns (uint256 tokenId, uint256 requestId) {
        if (totalMinted < GENESIS_PHASE_SUPPLY) revert GenesisPhaseNotOver();
        if (totalMinted >= MAX_SUPPLY) revert SoldOut();
        _burnExact(msg.sender, MYSTERY_PRICE);

        tokenId = ++totalMinted;
        _revealStatus[tokenId] = RevealStatus.AwaitingRandomness;

        requestId = _requestRandomness(tokenId);
        emit MysteryMinted(msg.sender, tokenId, requestId, MYSTERY_PRICE);
        _safeMint(msg.sender, tokenId);
    }

    /// @notice Retry a stalled token without burning BMC again. Anyone may pay the transaction gas.
    /// @dev Old requests remain eligible; the first delivered word is permanent. A delay is not
    ///      proof of oracle expiry. Subscription administrators must monitor the cost of retries.
    function rerequestRandomness(uint256 tokenId) external nonReentrant returns (uint256 requestId) {
        _requireMinted(tokenId);
        if (
            _revealStatus[tokenId] != RevealStatus.AwaitingRandomness
                || block.timestamp < lastRequestAt[tokenId] + RETRY_DELAY
        ) revert RetryUnavailable();
        requestId = _requestRandomness(tokenId);
    }

    function _requestRandomness(uint256 tokenId) private returns (uint256 requestId) {
        VRFConfig memory cfg = vrfConfig;
        // The coordinator accepts unknown keys, but the oracle never serves them. Check on
        // every mint/retry, including lane retirement; a failure rolls back the entire mint.
        // Deliberately avoid dependency calls in the empty-chain factory constructor.
        (bool ok, bytes memory data) =
            address(VRF_COORDINATOR).staticcall(abi.encodeWithSignature("s_provingKeys(bytes32)", cfg.keyHash));
        require(ok && data.length >= 64, "unregistered gas lane");
        (bool exists,) = abi.decode(data, (bool, uint64));
        require(exists, "unregistered gas lane");
        lastRequestAt[tokenId] = block.timestamp;

        requestId = VRF_COORDINATOR.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: cfg.keyHash,
                subId: cfg.subscriptionId,
                requestConfirmations: cfg.requestConfirmations,
                callbackGasLimit: cfg.callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: cfg.nativePayment}))
            })
        );
        require(requestId != 0 && tokenIdOfRequest[requestId] == 0, "invalid request id");
        requestIdOf[tokenId] = requestId;
        tokenIdOfRequest[requestId] = tokenId;
        emit RandomnessRequested(tokenId, requestId);
    }

    /// @dev Burns exactly `amount` BMC from `payer` via burnFrom and verifies the burn happened.
    function _burnExact(address payer, uint256 amount) private {
        uint8 dec = BMC.decimals();
        if (dec != BMC_DECIMALS) revert UnexpectedTokenDecimals(dec);
        uint256 supplyBefore = BMC.totalSupply();
        uint256 balanceBefore = BMC.balanceOf(payer);
        BMC.burnFrom(payer, amount);
        uint256 supplyDelta = supplyBefore - BMC.totalSupply();
        uint256 balanceDelta = balanceBefore - BMC.balanceOf(payer);
        if (supplyDelta != amount || balanceDelta != amount) revert BurnMismatch(amount, supplyDelta);
        totalBurned += amount;
        assert(totalBurned <= MAX_TOTAL_BURN);
    }

    // ------------------------------------------------------------------------------------------
    // Chainlink VRF v2.5 fulfillment
    // ------------------------------------------------------------------------------------------

    /// @notice Called by the VRF coordinator. Stores the random word for the mapped token and then
    ///         attempts a bounded, best-effort batch of in-order reveals.
    /// @dev Same signature as Chainlink's VRFConsumerBaseV2Plus so the coordinator can call it.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(VRF_COORDINATOR)) revert OnlyCoordinator();
        uint256 tokenId = tokenIdOfRequest[requestId];
        if (tokenId == 0) revert UnknownRequest(requestId);
        if (randomWords.length == 0) revert NoRandomWords();
        // Idempotent: a repeated delivery for an already-stored request is ignored.
        if (_revealStatus[tokenId] != RevealStatus.AwaitingRandomness) return;

        _randomWord[tokenId] = randomWords[0];
        _revealStatus[tokenId] = RevealStatus.RandomnessStored;
        emit RandomnessStored(tokenId, requestId, randomWords[0]);

        // Best effort, gas-aware: only attempt as many in-order reveals as the remaining callback gas
        // can pay for, so the coordinator never records a failed callback. If the attempt still fails
        // the stored word stays intact for permissionless finalization via finalizeReveals().
        uint256 gasAvailable = gasleft();
        if (gasAvailable <= CALLBACK_GAS_RESERVE) return;
        uint256 batch = (gasAvailable - CALLBACK_GAS_RESERVE) / GAS_PER_REVEAL;
        if (batch == 0) return;
        if (batch > CALLBACK_REVEAL_BATCH) batch = CALLBACK_REVEAL_BATCH;
        try this.finalizeReveals(batch) {} catch {}
    }

    /// @notice Permissionless: finalize up to `maxCount` pending tokens whose randomness is stored,
    ///         in strict mint order (token 41, 42, ...). Returns how many were revealed.
    /// @dev Processing in mint order means nobody (minter, keeper, owner) can influence an outcome by
    ///      choosing the finalization order of concurrently pending tokens.
    function finalizeReveals(uint256 maxCount) external returns (uint256 done) {
        uint256 tokenId = GENESIS_PHASE_SUPPLY + revealedCount + 1;
        while (done < maxCount && tokenId <= totalMinted && _revealStatus[tokenId] == RevealStatus.RandomnessStored) {
            _finalize(tokenId);
            unchecked {
                ++tokenId;
                ++done;
            }
        }
    }

    /// @dev Draw one outcome without replacement using a virtual Fisher-Yates shuffle (O(1) gas).
    function _finalize(uint256 tokenId) private {
        uint256 remaining = MYSTERY_SUPPLY - revealedCount;
        uint256 word = _randomWord[tokenId];
        uint256 r = uint256(keccak256(abi.encode(word, tokenId))) % remaining;

        uint256 picked = _slotValue(r);
        uint256 last = _slotValue(remaining - 1);
        _slotSwap[r] = last + 1;
        delete _slotSwap[remaining - 1];

        revealedCount += 1;
        _revealStatus[tokenId] = RevealStatus.Revealed;
        delete _randomWord[tokenId];

        Tier tier;
        uint16 artwork;
        if (picked < MYSTERY_GENESIS) {
            tier = Tier.Genesis;
            artwork = uint16(GENESIS_PHASE_SUPPLY + 1 + picked); // genesis-41 .. genesis-77
            mysteryGenesisRevealed += 1;
        } else {
            tier = Tier.Standard;
            artwork = uint16(picked - MYSTERY_GENESIS + 1); // standard 1 .. 423
        }
        _tier[tokenId] = tier;
        _artworkId[tokenId] = artwork;
        emit Revealed(tokenId, tier, artwork);
    }

    function _slotValue(uint256 i) private view returns (uint256) {
        uint256 s = _slotSwap[i];
        return s == 0 ? i : s - 1;
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function tierOf(uint256 tokenId) external view returns (Tier) {
        _requireMinted(tokenId);
        return _tier[tokenId];
    }

    /// @notice Artwork identifier: for Genesis tiers the genesis-NN number (1..77); for Standard the
    ///         on-chain artwork index (1..423); 0 while pending.
    function artworkIdOf(uint256 tokenId) external view returns (uint16) {
        _requireMinted(tokenId);
        return _artworkId[tokenId];
    }

    function revealStatusOf(uint256 tokenId) external view returns (RevealStatus) {
        _requireMinted(tokenId);
        if (tokenId <= GENESIS_PHASE_SUPPLY) return RevealStatus.Revealed;
        return _revealStatus[tokenId];
    }

    function totalSupply() external view returns (uint256) {
        return totalMinted;
    }

    function remainingSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalMinted;
    }

    function genesisPhaseActive() external view returns (bool) {
        return totalMinted < GENESIS_PHASE_SUPPLY;
    }

    /// @notice Mystery mint positions not yet sold.
    function remainingMysteryMints() external view returns (uint256) {
        return totalMinted < GENESIS_PHASE_SUPPLY ? MYSTERY_SUPPLY : MAX_SUPPLY - totalMinted;
    }

    /// @notice Mystery mints sold but not yet revealed.
    function pendingReveals() external view returns (uint256) {
        return totalMinted < GENESIS_PHASE_SUPPLY ? 0 : (totalMinted - GENESIS_PHASE_SUPPLY) - revealedCount;
    }

    /// @notice Outcomes still inside the random pool (includes outcomes owed to pending tokens).
    function remainingMysteryGenesis() external view returns (uint256) {
        return MYSTERY_GENESIS - mysteryGenesisRevealed;
    }

    function remainingMysteryStandard() external view returns (uint256) {
        return TOTAL_STANDARD - (revealedCount - mysteryGenesisRevealed);
    }

    /// @notice Current price of the next mint in BMC units, 0 when sold out.
    function currentPrice() external view returns (uint256) {
        if (totalMinted >= MAX_SUPPLY) return 0;
        return totalMinted < GENESIS_PHASE_SUPPLY ? GENESIS_PRICE : MYSTERY_PRICE;
    }

    function _requireMinted(uint256 tokenId) private view {
        if (tokenId == 0 || tokenId > totalMinted) revert NonexistentToken(tokenId);
    }

    // ------------------------------------------------------------------------------------------
    // Metadata (fully on-chain JSON)
    // ------------------------------------------------------------------------------------------

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireMinted(tokenId);
        Tier tier = _tier[tokenId];
        string memory json;
        if (tier == Tier.Pending) {
            json = _pendingJson(tokenId);
        } else if (tier == Tier.Standard) {
            json = _standardJson(tokenId, _artworkId[tokenId]);
        } else {
            json = _genesisJson(tokenId, tier, _artworkId[tokenId]);
        }
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice Raw SVG of a Standard token (reverts for other tiers).
    function standardSVG(uint256 tokenId) external view returns (string memory) {
        _requireMinted(tokenId);
        require(_tier[tokenId] == Tier.Standard, "not standard");
        return StandardArt.render(_artworkId[tokenId]);
    }

    function _genesisFile(uint16 artwork) private pure returns (string memory) {
        return string.concat("genesis-", artwork < 10 ? "0" : "", uint256(artwork).toString(), ".png");
    }

    function _genesisJson(uint256 tokenId, Tier tier, uint16 artwork) private pure returns (string memory) {
        bool legendary = tier == Tier.LegendaryGenesis;
        string memory file = _genesisFile(artwork);
        string memory head = string.concat(
            '{"name":"BMC Illuminati Pass #',
            tokenId.toString(),
            legendary ? " - Legendary Genesis" : " - Genesis",
            '","description":"',
            legendary
                ? "The one. The first BMC Illuminati Pass ever minted: the Legendary Genesis, the rarest piece of the 500-piece collection. A mysterious hooded frog with a glowing golden third eye, crowned and veiled, beneath the floating golden eye-in-triangle. Minted by permanently burning 1,000,000 BMC."
                : "A Genesis BMC Illuminati Pass. A mysterious cartoon frog in a black hooded cloak with premium gold-and-black styling, a glowing golden third eye and a floating golden eye-in-triangle. One of 77 Genesis pieces in a 500-piece collection minted by permanently burning BMC.",
            '","image":"ipfs://',
            genesisImagesCID,
            "/",
            file
        );
        string memory attrs = string.concat(
            '","attributes":[{"trait_type":"Tier","value":"',
            legendary ? "Legendary Genesis" : "Genesis",
            '"},{"trait_type":"Artwork","value":"',
            file,
            '"},{"trait_type":"Cloak","value":"Black Hooded, Gold Trim"},{"trait_type":"Third Eye","value":"Glowing Gold"},{"trait_type":"Sigil","value":"Floating Golden Eye-in-Triangle"}',
            legendary
                ? ',{"trait_type":"Crown","value":"Legendary Golden Crown"},{"trait_type":"Aura","value":"Radiant Gold Halo"},{"trait_type":"Rank","value":"First Minter"}'
                : "",
            ',{"trait_type":"Genesis Number","display_type":"number","value":',
            uint256(artwork).toString(),
            "}]}"
        );
        return string.concat(head, attrs);
    }

    function _standardJson(uint256 tokenId, uint16 artwork) private pure returns (string memory) {
        return string.concat(
            '{"name":"BMC Illuminati Pass #',
            tokenId.toString(),
            ' - Standard","description":"A Standard BMC Illuminati Pass. An original cartoon frog in a dark hooded cloak, rendered fully on-chain as SVG. One of 423 Standard pieces in a 500-piece collection minted by permanently burning BMC.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(StandardArt.render(artwork))),
            '","attributes":[{"trait_type":"Tier","value":"Standard"},{"trait_type":"Artwork","value":"standard-',
            uint256(artwork).toString(),
            '"},',
            StandardArt.attributesJson(artwork),
            "]}"
        );
    }

    function _pendingJson(uint256 tokenId) private pure returns (string memory) {
        string memory svg =
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 400' width='400' height='400'><rect width='400' height='400' fill='#0b0b14'/><circle cx='200' cy='190' r='90' fill='none' stroke='#555' stroke-width='6' stroke-dasharray='12 10'/><text x='200' y='200' font-family='monospace' font-size='48' fill='#888' text-anchor='middle'>?</text><text x='200' y='330' font-family='monospace' font-size='16' fill='#888' text-anchor='middle'>BMC ILLUMINATI PASS</text><text x='200' y='355' font-family='monospace' font-size='14' fill='#666' text-anchor='middle'>REVEAL PENDING (Chainlink VRF)</text></svg>";
        return string.concat(
            '{"name":"BMC Illuminati Pass #',
            tokenId.toString(),
            ' - Pending Reveal","description":"A BMC Illuminati Pass mystery mint awaiting finalization in mint order. Randomness may already be public and the outcome may be computable before finalization. Pending Reveal does not mean the outcome is unknown. Metadata becomes permanent once revealed.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[{"trait_type":"Tier","value":"Pending Reveal"}]}'
        );
    }
}
