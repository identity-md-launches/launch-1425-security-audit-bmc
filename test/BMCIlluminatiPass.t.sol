// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BMCIlluminatiPass} from "../src/BMCIlluminatiPass.sol";
import {StandardArt} from "../src/StandardArt.sol";
import {MockBMC, FakeBurnBMC, SixDecimalBMC} from "./mocks/MockBMC.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";
import {DeployBMCIlluminatiPass} from "../script/Deploy.s.sol";

contract Reenterer is IERC721Receiver {
    BMCIlluminatiPass public pass;
    bool public attackGenesis;
    uint256 public attempts;
    bytes public lastRevert;

    constructor(BMCIlluminatiPass p) {
        pass = p;
    }

    function setAttackGenesis(bool v) external {
        attackGenesis = v;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external override returns (bytes4) {
        attempts++;
        if (attackGenesis) {
            try pass.mintGenesis() {}
            catch (bytes memory reason) {
                lastRevert = reason;
                revert("reentered");
            }
        } else {
            try pass.mintMystery() {}
            catch (bytes memory reason) {
                lastRevert = reason;
                revert("reentered");
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract BMCIlluminatiPassTest is Test {
    MockBMC bmc;
    MockVRFCoordinator vrf;
    BMCIlluminatiPass pass;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant GENESIS_PRICE = 1_000_000e18;
    uint256 constant MYSTERY_PRICE = 350_000e18;
    bytes32 constant KEY_HASH = keccak256("500 gwei lane");

    function setUp() public {
        bmc = new MockBMC();
        vrf = new MockVRFCoordinator();
        pass = new BMCIlluminatiPass(owner, address(bmc), address(vrf), 42, KEY_HASH, 300_000, 3, false);
    }

    // ------------------------------------------------------------------ helpers

    function _fund(address who, uint256 amount) internal {
        bmc.mint(who, amount);
    }

    function _mintGenesisAs(address who) internal returns (uint256 id) {
        _fund(who, GENESIS_PRICE);
        vm.startPrank(who);
        bmc.approve(address(pass), GENESIS_PRICE);
        id = pass.mintGenesis();
        vm.stopPrank();
    }

    function _mintMysteryAs(address who) internal returns (uint256 id, uint256 req) {
        _fund(who, MYSTERY_PRICE);
        vm.startPrank(who);
        bmc.approve(address(pass), MYSTERY_PRICE);
        (id, req) = pass.mintMystery();
        vm.stopPrank();
    }

    function _finishPhase1() internal {
        for (uint256 i = 0; i < 40; i++) {
            _mintGenesisAs(address(uint160(0x1000 + i)));
        }
        assertEq(pass.totalMinted(), 40);
    }

    function _decodeTokenURI(uint256 id) internal view returns (string memory) {
        string memory uri = pass.tokenURI(id);
        bytes memory b = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory payload = new bytes(b.length - prefix.length);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = b[i + prefix.length];
        }
        return string(_b64decode(payload));
    }

    function _b64decode(bytes memory data) internal pure returns (bytes memory out) {
        bytes memory table = bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");
        uint8[256] memory rev;
        for (uint8 i = 0; i < 64; i++) {
            rev[uint8(table[i])] = i;
        }
        uint256 len = data.length;
        uint256 pad;
        if (len > 0 && data[len - 1] == "=") pad++;
        if (len > 1 && data[len - 2] == "=") pad++;
        out = new bytes((len / 4) * 3 - pad);
        uint256 o;
        for (uint256 i = 0; i < len; i += 4) {
            uint256 n = (uint256(rev[uint8(data[i])]) << 18) | (uint256(rev[uint8(data[i + 1])]) << 12)
                | (uint256(rev[uint8(data[i + 2])]) << 6) | uint256(rev[uint8(data[i + 3])]);
            if (o < out.length) out[o++] = bytes1(uint8(n >> 16));
            if (o < out.length) out[o++] = bytes1(uint8(n >> 8));
            if (o < out.length) out[o++] = bytes1(uint8(n));
        }
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ deployment / config

    function test_DeployScriptConfig() public {
        DeployBMCIlluminatiPass d = new DeployBMCIlluminatiPass();
        DeployBMCIlluminatiPass.Config memory cfg = d.mainnetConfig(owner, 42, KEY_HASH);
        assertEq(cfg.bmc, 0x38224239f2BDae357D47cb864BC533d7f72dF961);
        assertEq(cfg.vrfCoordinator, 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a);
        BMCIlluminatiPass p = d.deploy(cfg);
        assertEq(p.owner(), owner);
        assertEq(address(p.BMC()), cfg.bmc);
        assertEq(address(p.VRF_COORDINATOR()), cfg.vrfCoordinator);
        assertEq(p.name(), "BMC Illuminati Pass");
        assertEq(p.symbol(), "BMCPASS");
        assertTrue(p.genesisCIDLocked());
        (uint256 sub, bytes32 key, uint32 gasLimit, uint16 confirmations, bool nativePayment, bool configured) =
            p.vrfConfig();
        assertEq(sub, 42);
        assertEq(key, KEY_HASH);
        assertEq(gasLimit, 500_000);
        assertEq(confirmations, 3);
        assertTrue(nativePayment);
        assertTrue(configured);
    }

    function test_DeployScriptRequiresOwner() public {
        DeployBMCIlluminatiPass d = new DeployBMCIlluminatiPass();
        DeployBMCIlluminatiPass.Config memory cfg = d.mainnetConfig(address(0), 42, KEY_HASH);
        vm.expectRevert(bytes("owner required"));
        d.deploy(cfg);
    }

    function test_Constants() public view {
        assertEq(pass.MAX_SUPPLY(), 500);
        assertEq(pass.GENESIS_PHASE_SUPPLY(), 40);
        assertEq(pass.MYSTERY_SUPPLY(), 460);
        assertEq(pass.TOTAL_GENESIS(), 77);
        assertEq(pass.MYSTERY_GENESIS(), 37);
        assertEq(pass.TOTAL_STANDARD(), 423);
        assertEq(pass.GENESIS_PRICE(), GENESIS_PRICE);
        assertEq(pass.MYSTERY_PRICE(), MYSTERY_PRICE);
        assertEq(pass.MAX_TOTAL_BURN(), 201_000_000e18);
        assertEq(40 * GENESIS_PRICE + 460 * MYSTERY_PRICE, pass.MAX_TOTAL_BURN());
    }

    function test_CIDConstantAndHasNoSetter() public {
        assertTrue(pass.genesisCIDLocked());
        assertEq(pass.genesisImagesCID(), "bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u");
        vm.prank(owner);
        (bool ok,) = address(pass).call(abi.encodeWithSignature("setGenesisImagesCID(string)", "replacement"));
        assertFalse(ok);
    }

    function test_VRFConfigValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(BMCIlluminatiPass.InvalidVRFConfig.selector);
        pass.setVRFConfig(0, KEY_HASH, 300_000, 3, false);
        vm.expectRevert(BMCIlluminatiPass.InvalidVRFConfig.selector);
        pass.setVRFConfig(1, bytes32(0), 300_000, 3, false);
        vm.expectRevert(BMCIlluminatiPass.InvalidVRFConfig.selector);
        pass.setVRFConfig(1, KEY_HASH, 100_000, 3, false);
        vm.expectRevert(BMCIlluminatiPass.InvalidVRFConfig.selector);
        pass.setVRFConfig(1, KEY_HASH, 3_000_000, 3, false);
        vm.expectRevert(BMCIlluminatiPass.InvalidVRFConfig.selector);
        pass.setVRFConfig(1, KEY_HASH, 300_000, 2, false);
        vm.expectRevert(BMCIlluminatiPass.InvalidVRFConfig.selector);
        pass.setVRFConfig(1, KEY_HASH, 300_000, 201, false);
        pass.setVRFConfig(7, KEY_HASH, 250_000, 5, true);
        vm.stopPrank();
        (uint256 sub, bytes32 kh, uint32 cb, uint16 conf, bool native, bool configured) = pass.vrfConfig();
        assertEq(sub, 7);
        assertEq(kh, KEY_HASH);
        assertEq(cb, 250_000);
        assertEq(conf, 5);
        assertTrue(native);
        assertTrue(configured);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pass.setVRFConfig(7, KEY_HASH, 250_000, 5, true);
    }

    function test_MintingIsConfiguredByConstructor() public {
        _finishPhase1();
        (uint256 id, uint256 req) = _mintMysteryAs(alice);
        assertEq(id, 41);
        assertTrue(vrf.fulfill(req, 123));
        assertEq(uint256(pass.revealStatusOf(id)), uint256(BMCIlluminatiPass.RevealStatus.Revealed));
    }

    // ------------------------------------------------------------------ phase 1

    function test_FirstMinterGetsLegendaryGenesis1() public {
        uint256 id = _mintGenesisAs(alice);
        assertEq(id, 1);
        assertEq(pass.ownerOf(1), alice);
        assertEq(uint8(pass.tierOf(1)), uint8(BMCIlluminatiPass.Tier.LegendaryGenesis));
        assertEq(pass.artworkIdOf(1), 1);
        string memory json = _decodeTokenURI(1);
        assertTrue(_contains(json, '"Legendary Genesis"'));
        assertTrue(_contains(json, "ipfs://bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u/genesis-01.png"));
        assertTrue(_contains(json, "Legendary Golden Crown"));
    }

    function test_Mints2To40AreSequentialGenesis() public {
        _mintGenesisAs(alice);
        for (uint256 i = 2; i <= 40; i++) {
            address who = address(uint160(0x3000 + i));
            uint256 id = _mintGenesisAs(who);
            assertEq(id, i);
            assertEq(pass.ownerOf(i), who);
            assertEq(uint8(pass.tierOf(i)), uint8(BMCIlluminatiPass.Tier.Genesis));
            assertEq(pass.artworkIdOf(i), uint16(i));
        }
        string memory json = _decodeTokenURI(7);
        assertTrue(_contains(json, "/genesis-07.png"));
        assertTrue(_contains(json, '{"trait_type":"Tier","value":"Genesis"}'));
        assertFalse(_contains(json, "Legendary"));
        json = _decodeTokenURI(40);
        assertTrue(_contains(json, "/genesis-40.png"));
        assertEq(pass.totalMinted(), 40);
        assertFalse(pass.genesisPhaseActive());
        assertEq(pass.totalBurned(), 40 * GENESIS_PRICE);
    }

    function test_Phase1CostsExactlyOneMillion() public {
        _fund(alice, 5_000_000e18);
        uint256 supplyBefore = bmc.totalSupply();
        vm.startPrank(alice);
        bmc.approve(address(pass), GENESIS_PRICE);
        pass.mintGenesis();
        vm.stopPrank();
        assertEq(bmc.balanceOf(alice), 4_000_000e18);
        assertEq(bmc.totalSupply(), supplyBefore - GENESIS_PRICE, "tokens destroyed, not moved");
        assertEq(bmc.balanceOf(address(pass)), 0);
        assertEq(bmc.allowance(alice, address(pass)), 0);
        assertEq(pass.totalBurned(), GENESIS_PRICE);
        assertEq(pass.currentPrice(), GENESIS_PRICE);
    }

    function test_GenesisRevertsAfterPhase1() public {
        _finishPhase1();
        _fund(alice, GENESIS_PRICE);
        vm.startPrank(alice);
        bmc.approve(address(pass), GENESIS_PRICE);
        vm.expectRevert(BMCIlluminatiPass.GenesisPhaseOver.selector);
        pass.mintGenesis();
        vm.stopPrank();
    }

    function test_MysteryRevertsDuringPhase1() public {
        _mintGenesisAs(alice);
        _fund(bob, MYSTERY_PRICE);
        vm.startPrank(bob);
        bmc.approve(address(pass), MYSTERY_PRICE);
        vm.expectRevert(BMCIlluminatiPass.GenesisPhaseNotOver.selector);
        pass.mintMystery();
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ burn / allowance failures

    function test_RevertNoAllowance() public {
        _fund(alice, GENESIS_PRICE);
        vm.prank(alice);
        vm.expectRevert();
        pass.mintGenesis();
        assertEq(pass.totalMinted(), 0);
        assertEq(bmc.balanceOf(alice), GENESIS_PRICE);
    }

    function test_RevertInsufficientAllowance() public {
        _fund(alice, GENESIS_PRICE);
        vm.startPrank(alice);
        bmc.approve(address(pass), GENESIS_PRICE - 1);
        vm.expectRevert();
        pass.mintGenesis();
        vm.stopPrank();
        assertEq(pass.totalMinted(), 0);
    }

    function test_RevertInsufficientBalance() public {
        _fund(alice, GENESIS_PRICE - 1);
        vm.startPrank(alice);
        bmc.approve(address(pass), GENESIS_PRICE);
        vm.expectRevert();
        pass.mintGenesis();
        vm.stopPrank();
        assertEq(pass.totalMinted(), 0);
        assertEq(pass.totalBurned(), 0);
    }

    function test_ExcessAllowanceOnlyBurnsPrice() public {
        _fund(alice, 10_000_000e18);
        vm.startPrank(alice);
        bmc.approve(address(pass), 10_000_000e18);
        pass.mintGenesis();
        vm.stopPrank();
        assertEq(bmc.balanceOf(alice), 9_000_000e18);
        assertEq(bmc.allowance(alice, address(pass)), 9_000_000e18);
    }

    function test_RevertWhenTokenDoesNotActuallyBurn() public {
        FakeBurnBMC fake = new FakeBurnBMC();
        BMCIlluminatiPass p = new BMCIlluminatiPass(owner, address(fake), address(vrf), 42, KEY_HASH, 300_000, 3, false);
        fake.mint(alice, GENESIS_PRICE);
        vm.startPrank(alice);
        fake.approve(address(p), GENESIS_PRICE);
        vm.expectRevert(abi.encodeWithSelector(BMCIlluminatiPass.BurnMismatch.selector, GENESIS_PRICE, 0));
        p.mintGenesis();
        vm.stopPrank();
    }

    function test_RevertWhenTokenDecimalsUnexpected() public {
        SixDecimalBMC six = new SixDecimalBMC();
        BMCIlluminatiPass p = new BMCIlluminatiPass(owner, address(six), address(vrf), 42, KEY_HASH, 300_000, 3, false);
        six.mint(alice, GENESIS_PRICE);
        vm.startPrank(alice);
        six.approve(address(p), GENESIS_PRICE);
        vm.expectRevert(abi.encodeWithSelector(BMCIlluminatiPass.UnexpectedTokenDecimals.selector, uint8(6)));
        p.mintGenesis();
        vm.stopPrank();
    }

    function test_MysteryBurnRevertsIfVRFRequestFails() public {
        _finishPhase1();
        vrf.setRejectRequests(true);
        _fund(alice, MYSTERY_PRICE);
        vm.startPrank(alice);
        bmc.approve(address(pass), MYSTERY_PRICE);
        vm.expectRevert(bytes("mock: subscription not funded"));
        pass.mintMystery();
        vm.stopPrank();
        assertEq(bmc.balanceOf(alice), MYSTERY_PRICE, "burn rolled back with the failed request");
        assertEq(pass.totalMinted(), 40);
    }

    // ------------------------------------------------------------------ reentrancy

    function test_ReentrancyGenesisBlocked() public {
        Reenterer r = new Reenterer(pass);
        r.setAttackGenesis(true);
        _fund(address(r), 2 * GENESIS_PRICE);
        vm.prank(address(r));
        bmc.approve(address(pass), 2 * GENESIS_PRICE);
        vm.prank(address(r));
        vm.expectRevert(bytes("reentered"));
        pass.mintGenesis();
        assertEq(pass.totalMinted(), 0);
        assertEq(pass.totalBurned(), 0);
        assertEq(bmc.balanceOf(address(r)), 2 * GENESIS_PRICE);
    }

    function test_ReentrancyMysteryBlocked() public {
        _finishPhase1();
        Reenterer r = new Reenterer(pass);
        r.setAttackGenesis(false);
        _fund(address(r), 2 * MYSTERY_PRICE);
        vm.prank(address(r));
        bmc.approve(address(pass), 2 * MYSTERY_PRICE);
        vm.prank(address(r));
        vm.expectRevert(bytes("reentered"));
        pass.mintMystery();
        assertEq(pass.totalMinted(), 40);
        assertEq(bmc.balanceOf(address(r)), 2 * MYSTERY_PRICE);
        // The receiver only reverts with "reentered" when its inner mint call failed; a successful
        // reentrant mint would have let the outer mint succeed and the expectRevert above fail.
        assertEq(r.attempts(), 0, "outer revert rolled back the receiver state too");
    }

    // ------------------------------------------------------------------ phase 2

    function test_Phase2CostsExactly350k() public {
        _finishPhase1();
        _fund(alice, 1_000_000e18);
        uint256 supplyBefore = bmc.totalSupply();
        vm.startPrank(alice);
        bmc.approve(address(pass), MYSTERY_PRICE);
        (uint256 id, uint256 req) = pass.mintMystery();
        vm.stopPrank();
        assertEq(id, 41);
        assertEq(pass.ownerOf(41), alice);
        assertEq(bmc.balanceOf(alice), 650_000e18);
        assertEq(bmc.totalSupply(), supplyBefore - MYSTERY_PRICE);
        assertEq(pass.totalBurned(), 40 * GENESIS_PRICE + MYSTERY_PRICE);
        assertEq(pass.requestIdOf(41), req);
        assertEq(pass.tokenIdOfRequest(req), 41);
        assertEq(uint8(pass.tierOf(41)), uint8(BMCIlluminatiPass.Tier.Pending));
        assertEq(uint8(pass.revealStatusOf(41)), uint8(BMCIlluminatiPass.RevealStatus.AwaitingRandomness));
        assertEq(pass.pendingReveals(), 1);
        assertEq(pass.remainingMysteryMints(), 459);
        assertEq(pass.currentPrice(), MYSTERY_PRICE);
        (,,, bytes32 kh, uint256 sub,,) = vrf.requests(req);
        assertEq(kh, KEY_HASH);
        assertEq(sub, 42);
    }

    function test_PendingMetadataIsNeutral() public {
        _finishPhase1();
        (uint256 id,) = _mintMysteryAs(alice);
        string memory json = _decodeTokenURI(id);
        assertTrue(_contains(json, "Pending Reveal"));
        assertFalse(_contains(json, "genesis-"));
        assertFalse(_contains(json, '"Standard"'));
        assertFalse(_contains(json, '"Genesis"'));
        assertEq(pass.artworkIdOf(id), 0);
    }

    function test_PendingMetadataDisclosesPredictableStoredOutcome() public {
        _finishPhase1();
        (, uint256 first) = _mintMysteryAs(alice);
        (uint256 id, uint256 second) = _mintMysteryAs(alice);
        string memory json = _decodeTokenURI(id);
        assertTrue(_contains(json, "Randomness may already be public"));
        assertTrue(_contains(json, "outcome may be computable before finalization"));
        assertFalse(_contains(json, "not yet determined on-chain"));
        assertTrue(vrf.fulfill(second, 0xBEEF));
        assertEq(pass.finalizeReveals(10), 0, "predecessor blocks finalization");
        assertEq(uint256(pass.revealStatusOf(id)), uint256(BMCIlluminatiPass.RevealStatus.RandomnessStored));
        assertEq(uint256(pass.tierOf(id)), uint256(BMCIlluminatiPass.Tier.Pending));
        assertEq(_decodeTokenURI(id), json, "disclosure applies while waiting and while stored");
        uint256 slot = uint256(keccak256(abi.encode(uint256(0xBEEF), id))) % 459;
        assertEq(slot, 331);
        assertTrue(vrf.fulfill(first, 1));
        assertEq(pass.artworkIdOf(id), slot - 37 + 1);
        assertEq(pass.artworkIdOf(id), 295, "stored successor outcome was predictable");
    }

    function test_FulfillRevealsAndLocksMetadata() public {
        _finishPhase1();
        (uint256 id, uint256 req) = _mintMysteryAs(alice);
        assertTrue(vrf.fulfill(req, 123456789));
        assertEq(uint8(pass.revealStatusOf(id)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
        BMCIlluminatiPass.Tier t = pass.tierOf(id);
        assertTrue(t == BMCIlluminatiPass.Tier.Genesis || t == BMCIlluminatiPass.Tier.Standard);
        uint16 art = pass.artworkIdOf(id);
        string memory json = _decodeTokenURI(id);
        if (t == BMCIlluminatiPass.Tier.Genesis) {
            assertTrue(art >= 41 && art <= 77);
            assertTrue(_contains(json, '"Genesis"'));
        } else {
            assertTrue(art >= 1 && art <= 423);
            assertTrue(_contains(json, '"Standard"'));
            assertTrue(_contains(json, "data:image/svg+xml;base64,"));
        }
        // Re-delivery of the same request changes nothing (no reroll).
        assertTrue(vrf.redeliver(req, 987654321));
        assertEq(uint8(pass.tierOf(id)), uint8(t));
        assertEq(pass.artworkIdOf(id), art);
        assertEq(keccak256(bytes(_decodeTokenURI(id))), keccak256(bytes(json)));
        assertEq(pass.revealedCount(), 1);
    }

    function test_OnlyCoordinatorCanFulfill() public {
        _finishPhase1();
        (, uint256 req) = _mintMysteryAs(alice);
        uint256[] memory words = new uint256[](1);
        words[0] = 1;
        vm.prank(alice);
        vm.expectRevert(BMCIlluminatiPass.OnlyCoordinator.selector);
        pass.rawFulfillRandomWords(req, words);
        vm.prank(owner);
        vm.expectRevert(BMCIlluminatiPass.OnlyCoordinator.selector);
        pass.rawFulfillRandomWords(req, words);
        vm.prank(address(vrf));
        vm.expectRevert(abi.encodeWithSelector(BMCIlluminatiPass.UnknownRequest.selector, 999_999));
        pass.rawFulfillRandomWords(999_999, words);
        vm.prank(address(vrf));
        vm.expectRevert(BMCIlluminatiPass.NoRandomWords.selector);
        pass.rawFulfillRandomWords(req, new uint256[](0));
    }

    function test_OutOfOrderFulfillmentFinalizesInMintOrder() public {
        _finishPhase1();
        (uint256 a, uint256 ra) = _mintMysteryAs(alice); // 41
        (uint256 b, uint256 rb) = _mintMysteryAs(bob); // 42
        (uint256 c, uint256 rc) = _mintMysteryAs(alice); // 43
        assertEq(a, 41);
        assertEq(b, 42);
        assertEq(c, 43);

        // 43 arrives first: stored, cannot be finalized ahead of 41 and 42.
        assertTrue(vrf.fulfill(rc, 777));
        assertEq(uint8(pass.revealStatusOf(c)), uint8(BMCIlluminatiPass.RevealStatus.RandomnessStored));
        assertEq(uint8(pass.tierOf(c)), uint8(BMCIlluminatiPass.Tier.Pending));
        assertEq(pass.finalizeReveals(10), 0);
        assertEq(pass.revealedCount(), 0);

        // 41 arrives: 41 reveals, 42 still waiting, 43 blocked behind 42.
        assertTrue(vrf.fulfill(ra, 888));
        assertEq(uint8(pass.revealStatusOf(a)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
        assertEq(uint8(pass.revealStatusOf(b)), uint8(BMCIlluminatiPass.RevealStatus.AwaitingRandomness));
        assertEq(uint8(pass.revealStatusOf(c)), uint8(BMCIlluminatiPass.RevealStatus.RandomnessStored));
        assertEq(pass.revealedCount(), 1);
        assertEq(pass.pendingReveals(), 2);

        // 42 arrives: callback batch reveals 42 and the already-stored 43.
        assertTrue(vrf.fulfill(rb, 999));
        assertEq(uint8(pass.revealStatusOf(b)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
        assertEq(uint8(pass.revealStatusOf(c)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
        assertEq(pass.revealedCount(), 3);
        assertEq(pass.pendingReveals(), 0);
    }

    function test_CallbackBatchIsGasAware() public {
        // With a 300k callback and three stored words, the callback reveals what fits (2) and leaves
        // the rest for permissionless finalization instead of failing the whole callback.
        _finishPhase1();
        (uint256 a, uint256 ra) = _mintMysteryAs(alice);
        (uint256 b, uint256 rb) = _mintMysteryAs(bob);
        (uint256 c, uint256 rc) = _mintMysteryAs(alice);
        assertTrue(vrf.fulfill(rc, 1));
        assertTrue(vrf.fulfill(rb, 2));
        assertTrue(vrf.fulfill(ra, 3));
        assertEq(uint8(pass.revealStatusOf(a)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
        assertEq(uint8(pass.revealStatusOf(b)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
        assertEq(uint8(pass.revealStatusOf(c)), uint8(BMCIlluminatiPass.RevealStatus.RandomnessStored));
        assertEq(pass.finalizeReveals(10), 1);
        assertEq(uint8(pass.revealStatusOf(c)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
    }

    function test_PermissionlessFinalizationWhenCallbackGasTooLow() public {
        _finishPhase1();
        (uint256 id, uint256 req) = _mintMysteryAs(alice);
        // Enough gas to store the word, not enough to finalize inline.
        assertTrue(vrf.fulfillWithGas(req, 4242, 95_000));
        assertEq(uint8(pass.revealStatusOf(id)), uint8(BMCIlluminatiPass.RevealStatus.RandomnessStored));
        assertEq(uint8(pass.tierOf(id)), uint8(BMCIlluminatiPass.Tier.Pending));
        // Anyone finalizes; the stored word is the only randomness ever used.
        vm.prank(bob);
        assertEq(pass.finalizeReveals(1), 1);
        assertEq(uint8(pass.revealStatusOf(id)), uint8(BMCIlluminatiPass.RevealStatus.Revealed));
        assertTrue(pass.tierOf(id) != BMCIlluminatiPass.Tier.Pending);
        assertEq(pass.finalizeReveals(5), 0, "nothing left");
    }

    function test_FinalizationOrderCannotBeChosen() public {
        // Two tokens with stored randomness: whoever calls finalize, the result is the same.
        _finishPhase1();
        (uint256 a, uint256 ra) = _mintMysteryAs(alice);
        (uint256 b, uint256 rb) = _mintMysteryAs(bob);
        uint256 snap = vm.snapshotState();
        assertTrue(vrf.fulfillWithGas(ra, 11, 95_000));
        assertTrue(vrf.fulfillWithGas(rb, 22, 95_000));
        vm.prank(bob);
        pass.finalizeReveals(2);
        bytes32 h1 = keccak256(abi.encode(pass.tierOf(a), pass.artworkIdOf(a), pass.tierOf(b), pass.artworkIdOf(b)));
        vm.revertToState(snap);
        assertTrue(vrf.fulfillWithGas(rb, 22, 95_000));
        assertTrue(vrf.fulfillWithGas(ra, 11, 95_000));
        vm.prank(alice);
        pass.finalizeReveals(1);
        vm.prank(alice);
        pass.finalizeReveals(1);
        bytes32 h2 = keccak256(abi.encode(pass.tierOf(a), pass.artworkIdOf(a), pass.tierOf(b), pass.artworkIdOf(b)));
        assertEq(h1, h2);
    }

    function test_PendingTokenRemainsTransferableAfterConfigChange() public {
        _finishPhase1();
        (uint256 id,) = _mintMysteryAs(alice);
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 2_000_000);
        assertEq(pass.finalizeReveals(10), 0);
        assertEq(uint8(pass.tierOf(id)), uint8(BMCIlluminatiPass.Tier.Pending));
        // Owner changing the VRF config does not touch the pending token.
        vm.prank(owner);
        pass.setVRFConfig(99, keccak256("other"), 400_000, 3, true);
        assertEq(uint8(pass.revealStatusOf(id)), uint8(BMCIlluminatiPass.RevealStatus.AwaitingRandomness));
        assertEq(pass.finalizeReveals(10), 0);
        // Pending token is still a normal, transferable ERC-721.
        vm.prank(alice);
        pass.transferFrom(alice, bob, id);
        assertEq(pass.ownerOf(id), bob);
    }

    function test_TransfersAreStandard() public {
        _mintGenesisAs(alice);
        vm.prank(alice);
        pass.transferFrom(alice, bob, 1);
        assertEq(pass.ownerOf(1), bob);
        assertEq(bmc.totalSupply(), 0, "no BMC burned on transfer");
        assertEq(pass.totalBurned(), GENESIS_PRICE);
        vm.prank(bob);
        pass.safeTransferFrom(bob, alice, 1);
        assertEq(pass.ownerOf(1), alice);
    }

    function test_ViewsRevertForNonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(BMCIlluminatiPass.NonexistentToken.selector, 0));
        pass.tierOf(0);
        vm.expectRevert(abi.encodeWithSelector(BMCIlluminatiPass.NonexistentToken.selector, 1));
        pass.tokenURI(1);
        vm.expectRevert(abi.encodeWithSelector(BMCIlluminatiPass.NonexistentToken.selector, 501));
        pass.artworkIdOf(501);
    }

    // ------------------------------------------------------------------ full mint-out

    function test_Full500MintSimulation() public {
        _finishPhase1();
        uint256[] memory reqs = new uint256[](460);
        for (uint256 i = 0; i < 460; i++) {
            address who = address(uint160(0x5000 + (i % 97)));
            (uint256 id, uint256 req) = _mintMysteryAs(who);
            assertEq(id, 41 + i);
            assertEq(uint8(pass.tierOf(id)), uint8(BMCIlluminatiPass.Tier.Pending));
            reqs[i] = req;
        }
        assertEq(pass.totalMinted(), 500);
        assertEq(pass.remainingSupply(), 0);
        assertEq(pass.pendingReveals(), 460);
        assertEq(pass.currentPrice(), 0);

        // Sold out: no further mints of either kind.
        _fund(alice, GENESIS_PRICE);
        vm.startPrank(alice);
        bmc.approve(address(pass), GENESIS_PRICE);
        vm.expectRevert(BMCIlluminatiPass.SoldOut.selector);
        pass.mintMystery();
        vm.expectRevert(BMCIlluminatiPass.GenesisPhaseOver.selector);
        pass.mintGenesis();
        vm.stopPrank();

        // Fulfil in a shuffled order so stored randomness piles up out of order.
        uint256 seed = uint256(keccak256("shuffle"));
        for (uint256 i = 459; i > 0; i--) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 j = seed % (i + 1);
            (reqs[i], reqs[j]) = (reqs[j], reqs[i]);
        }
        for (uint256 i = 0; i < 460; i++) {
            assertTrue(vrf.fulfill(reqs[i], uint256(keccak256(abi.encode("vrf", reqs[i])))));
        }
        // Drain whatever the bounded callback batches left behind.
        while (pass.finalizeReveals(50) != 0) {}
        assertEq(pass.revealedCount(), 460);
        assertEq(pass.pendingReveals(), 0);
        assertEq(pass.remainingMysteryGenesis(), 0);
        assertEq(pass.remainingMysteryStandard(), 0);

        // Tally: 77 Genesis, 423 Standard, no duplicate artwork, no tier inferable from id.
        uint256 genesis;
        uint256 standard;
        bool[78] memory genesisSeen;
        bool[424] memory standardSeen;
        for (uint256 id = 1; id <= 500; id++) {
            BMCIlluminatiPass.Tier t = pass.tierOf(id);
            uint16 art = pass.artworkIdOf(id);
            if (t == BMCIlluminatiPass.Tier.LegendaryGenesis) {
                assertEq(id, 1);
                assertEq(art, 1);
                genesis++;
                genesisSeen[1] = true;
            } else if (t == BMCIlluminatiPass.Tier.Genesis) {
                assertTrue(art >= 2 && art <= 77, "genesis art range");
                assertFalse(genesisSeen[art], "duplicate genesis artwork");
                genesisSeen[art] = true;
                genesis++;
                if (id <= 40) assertEq(art, id);
                else assertTrue(art >= 41);
            } else if (t == BMCIlluminatiPass.Tier.Standard) {
                assertTrue(id > 40);
                assertTrue(art >= 1 && art <= 423, "standard art range");
                assertFalse(standardSeen[art], "duplicate standard artwork");
                standardSeen[art] = true;
                standard++;
            } else {
                revert("pending token after full reveal");
            }
        }
        assertEq(genesis, 77);
        assertEq(standard, 423);
        for (uint256 g = 1; g <= 77; g++) {
            assertTrue(genesisSeen[g], "genesis artwork never assigned");
        }
        for (uint256 s = 1; s <= 423; s++) {
            assertTrue(standardSeen[s], "standard artwork never assigned");
        }
        assertEq(pass.mysteryGenesisRevealed(), 37);
        assertEq(pass.totalBurned(), 201_000_000e18);
        assertEq(pass.totalBurned(), pass.MAX_TOTAL_BURN());
        // Only the unspent sold-out probe balance remains: every BMC paid for a mint was destroyed.
        assertEq(bmc.totalSupply(), GENESIS_PRICE, "every BMC paid was destroyed");
    }

    function test_FullMintOutWithInOrderFulfillment() public {
        _finishPhase1();
        for (uint256 i = 0; i < 460; i++) {
            (, uint256 req) = _mintMysteryAs(alice);
            assertTrue(vrf.fulfill(req, uint256(keccak256(abi.encode("w", i)))));
        }
        assertEq(pass.revealedCount(), 460);
        assertEq(pass.mysteryGenesisRevealed(), 37);
        assertEq(pass.remainingMysteryStandard(), 0);
        assertEq(pass.totalBurned(), 201_000_000e18);
    }

    // ------------------------------------------------------------------ standard art

    function test_StandardArtCombinationsUnique() public pure {
        bool[5400] memory seen;
        for (uint256 i = 1; i <= 423; i++) {
            uint256 c = StandardArt.comboIndex(i);
            assertFalse(seen[c], "duplicate combination");
            seen[c] = true;
            StandardArt.Traits memory t = StandardArt.traitsOf(i);
            assertTrue(t.background < 6 && t.cloak < 5 && t.eyes < 6 && t.symbol < 5 && t.accessory < 6);
        }
    }

    function test_StandardArtCoversEveryTrait() public pure {
        bool[6] memory bg;
        bool[5] memory cl;
        bool[6] memory ey;
        bool[5] memory sy;
        bool[6] memory ac;
        for (uint256 i = 1; i <= 423; i++) {
            StandardArt.Traits memory t = StandardArt.traitsOf(i);
            bg[t.background] = true;
            cl[t.cloak] = true;
            ey[t.eyes] = true;
            sy[t.symbol] = true;
            ac[t.accessory] = true;
        }
        for (uint256 i = 0; i < 6; i++) {
            assertTrue(bg[i]);
            assertTrue(ey[i]);
            assertTrue(ac[i]);
        }
        for (uint256 i = 0; i < 5; i++) {
            assertTrue(cl[i]);
            assertTrue(sy[i]);
        }
    }

    function test_StandardArtRendersWithoutGenesisTraits() public pure {
        for (uint256 i = 1; i <= 423; i += 47) {
            string memory svg = StandardArt.render(i);
            assertTrue(_contains(svg, "<svg"));
            assertTrue(_contains(svg, "</svg>"));
            assertFalse(_contains(svg, "#ffd700"));
            assertFalse(_contains(svg, "#d4af37"));
            assertFalse(_contains(svg, "gold"));
            assertFalse(_contains(svg, "triangle"));
        }
        string memory attrs = StandardArt.attributesJson(1);
        assertTrue(_contains(attrs, '"trait_type":"Background"'));
        assertFalse(_contains(attrs, "Third Eye"));
    }

    function test_StandardMetadataAfterReveal() public {
        _finishPhase1();
        // Fulfil until we hit a Standard outcome (37/460 are Genesis, so this is quick).
        for (uint256 i = 0; i < 20; i++) {
            (uint256 id, uint256 req) = _mintMysteryAs(alice);
            vrf.fulfill(req, uint256(keccak256(abi.encode("s", i))));
            if (pass.tierOf(id) == BMCIlluminatiPass.Tier.Standard) {
                string memory json = _decodeTokenURI(id);
                uint16 art = pass.artworkIdOf(id);
                assertTrue(_contains(json, '{"trait_type":"Tier","value":"Standard"}'));
                assertTrue(_contains(json, string.concat('"value":"standard-', vm.toString(uint256(art)), '"')));
                assertTrue(_contains(json, '"trait_type":"Background"'));
                assertTrue(_contains(json, '"trait_type":"Accessory"'));
                assertFalse(_contains(json, "ipfs://"));
                string memory svg = pass.standardSVG(id);
                assertTrue(_contains(svg, "</svg>"));
                return;
            }
        }
        revert("no standard outcome in 20 draws (astronomically unlikely)");
    }

    function test_NoOwnerMintOrWithdrawSurface() public {
        // The owner's only application power is future VRF configuration.
        vm.startPrank(owner);
        (bool ok,) = address(pass).call(abi.encodeWithSignature("setGenesisImagesCID(string)", "again"));
        assertFalse(ok);
        vm.expectRevert();
        pass.mintGenesis(); // no allowance / balance: owner pays like anyone else
        vm.stopPrank();
        assertEq(pass.totalMinted(), 0);
    }

    function testFuzz_SingleRevealAlwaysInInventory(uint256 word) public {
        _finishPhase1();
        (uint256 id, uint256 req) = _mintMysteryAs(alice);
        assertTrue(vrf.fulfill(req, word));
        BMCIlluminatiPass.Tier t = pass.tierOf(id);
        uint16 art = pass.artworkIdOf(id);
        if (t == BMCIlluminatiPass.Tier.Genesis) {
            assertTrue(art >= 41 && art <= 77);
            assertEq(pass.remainingMysteryGenesis(), 36);
            assertEq(pass.remainingMysteryStandard(), 423);
        } else {
            assertEq(uint8(t), uint8(BMCIlluminatiPass.Tier.Standard));
            assertTrue(art >= 1 && art <= 423);
            assertEq(pass.remainingMysteryGenesis(), 37);
            assertEq(pass.remainingMysteryStandard(), 422);
        }
    }
}
