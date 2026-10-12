# BMC Illuminati Pass (BMCPASS)

500-piece Ethereum mainnet ERC-721 collection minted by permanently burning BMC
(`0x38224239f2BDae357D47cb864BC533d7f72dF961`) through `burnFrom`. 77 Genesis pieces (IPFS PNG),
423 Standard pieces (fully on-chain SVG). Mystery outcomes are drawn without replacement using
Chainlink VRF v2.5.

**Status: not deployed; Candidate V3 is not Mainnet-ready.** See the [security report](docs/SECURITY-REVIEW.md)
and [adaptation notes](ADAPTATION.md). This checkout is the production per-token design from `17aa386`.
The requested `security/vrf-recovery` Candidate V3 at `bf2a63c` was audited separately; its unchanged
code is preserved under `test/audit/fixtures/` solely for reproducible audit tests, not deployment.
All deployment scripts in this checkout simulate locally and do not broadcast or sign.

## Layout

| Path | What |
| --- | --- |
| `src/BMCIlluminatiPass.sol` | The collection contract (ERC721 + Ownable2Step + ReentrancyGuard, VRF v2.5 consumer). |
| `src/StandardArt.sol` | Internal library rendering the 423 Standard SVGs and their traits. |
| `src/interfaces/IBMCToken.sol` | Minimal BMC interface (`burnFrom`, `decimals`, ...). |
| `script/Deploy.s.sol` | Local deployment simulation; explicit owner and VRF configuration. |
| `test/` | Unit, recovery, factory, V3 audit and optional Mainnet fork tests; see recorded results. |
| `artwork/genesis/` | The 77 Genesis PNGs (1024x1024), `genesis-01.png` .. `genesis-77.png`. |
| `artwork/tools/generate_genesis.py` | Deterministic generator for the Genesis PNGs (Pillow). |
| `website/` | Static mint site "bmc-pass" (no build step, no dependencies). |
| `docs/SECURITY-REVIEW.md` | Security review findings and open items. |
| `docs/TEST-RESULTS.md` | Recorded `forge test` output. |
| `lib/` | Vendored dependencies as plain files: OpenZeppelin 5.1.0, forge-std 1.9.6, Chainlink contracts 1.4.0 (VRF v2.5 subset). |

## Dependency checks (2026-10-12)

| Check | Result |
| --- | --- |
| BMC `decimals()` | 18 (read on mainnet). The contract re-checks on every mint and reverts otherwise. |
| BMC `burnFrom` | Mainnet fork mints confirmed exact reductions in payer balance and total supply for both prices. The pass enforces these same deltas on every mint. |
| BMC owner / pause | No `owner()` or `paused()` function responds. |
| Chainlink VRF v2.5 coordinator | `0xD7f86b4b8Cae7D942340FF628F82735b7a20893a` has code and reports `LINK() == 0x514910771AF9Ca656af840dff83E8264EcF986CA`. |
| Genesis images CID | Fixed constant `bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u`. All 77 files reproduce it with `python3 artwork/tools/verify_genesis_cid.py`. |
| VRF subscription | Constructor-configured. The subscription in the V3 dry-run script has 0 consumers and 0.02 ETH at block 26,176,905. Register the predicted pass address and provide adequate funding before opening sales. |
| Artwork integrity | The 77 committed images reproduce the fixed directory CID; regeneration or replacement would require a different CID. |

Mainnet fork tests exercised both prices against live BMC bytecode using local-only balance adjustments.
They also exercised VRF requests after simulated consumer registration and funding; no real transactions
or oracle proofs were submitted.

## Mint mechanics

- **Phase 1, ids 1-40.** `mintGenesis()` burns 1,000,000 BMC and mints the next id. Id 1 is
  Legendary Genesis; ids N get `genesis-NN.png`. Strictly sequential.
- **Phase 2, ids 41-500.** `mintMystery()` burns 350,000 BMC, mints a pending-reveal NFT and opens
  one VRF request. Price is identical whatever the result.
- **Reveal.** The coordinator calls `rawFulfillRandomWords`; the word is stored, then a gas-aware
  batch of reveals runs. Reveals are finalized **in mint order** (41, 42, ...) by anyone through
  `finalizeReveals(maxCount)`. In-order finalization means nobody can influence an outcome by
  choosing the order in which concurrently pending tokens are drawn.
- **Draw.** Virtual Fisher-Yates over 460 slots (37 Genesis `genesis-41..77`, 423 Standard), O(1)
  per draw. Every outcome is assigned exactly once by full mint-out.
- **Tier storage.** Tier and artwork id are stored per token; nothing is inferred from token id.
- **Totals.** 40 x 1,000,000 + 460 x 350,000 = 201,000,000 BMC maximum burned.

Public views: `ownerOf`, `tierOf`, `artworkIdOf`, `revealStatusOf`, `totalMinted`, `totalSupply`,
`remainingSupply`, `remainingMysteryMints`, `pendingReveals`, `remainingMysteryGenesis`,
`remainingMysteryStandard`, `currentPrice`, `totalBurned`, `tokenURI`, `standardSVG`.

## Unavailable randomness

[Chainlink's subscription documentation](https://docs.chain.link/vrf/v2-5/overview/subscription)
says underfunded requests can expire after 24 hours. Funding later does not revive an expired request.
For an NFT still awaiting randomness, anyone may call `rerequestRandomness(tokenId)` once a full day
has elapsed since its most recent request. This burns no additional BMC and uses the current VRF
configuration. All issued request IDs remain valid, and the first delivered word is permanent.
Tokens with stored or finalized randomness cannot be retried. Pending metadata warns that a stored word may already make an outcome computable before its predecessor finalizes. An expired earlier token can still
block later finalizations until a replacement word arrives.

This recovery requires a functioning coordinator and funded, authorized subscription. The timeout
cannot prove expiry; concurrent requests increase reliance on oracle delivery order and can incur
additional subscription costs. Any caller can create one more request per pending token per day, and every served request can be charged even if its word is ignored. A request accepted with inadequate funding still commits the BMC burn. Register and fund the subscription before sales and monitor its balance and outstanding requests. These tradeoffs are described in the security report. There is no
fallback randomness, refund mint, or coordinator replacement.

## Privileged powers and operational responsibilities

| Power | Who | Effect | Limits |
| --- | --- | --- | --- |
| `setVRFConfig(subId, keyHash, callbackGas, confirmations, nativePayment)` | owner, any time | Parameters for **future** VRF requests. | Bounded (gas 150k-2.5M, confirmations 3-200). Cannot affect stored randomness or revealed tokens. Every mint/retry checks the live registered gas lane; invalid lanes, subscriptions or consumers revert the whole transaction. Funding is a separate operational precondition: an underfunded subscription can still accept a request. Old request IDs remain valid. |
| VRF subscription admin | subscription owner on the Chainlink coordinator | Add/remove the pass as consumer, fund with LINK or ETH. | Removing the consumer blocks new requests. Defunding can delay fulfillment while new requests are still accepted. Anyone can fund. |
| `transferOwnership` / `acceptOwnership` | current owner / proposed owner | OpenZeppelin Ownable2Step handoff. | Current owner retains repair powers until the proposed owner accepts. A zero-address proposal cancels the handoff. `renounceOwnership` reverts. |

There is no owner mint, airdrop, artwork assignment, metadata edit, price change, pause,
withdrawal or upgrade path. The contract is not a proxy. The coordinator address is immutable.

## Constructor and local simulation

The factory calls one nonpayable constructor with eight static arguments:

```solidity
(address initialOwner, address bmcToken, address vrfCoordinator,
 uint256 subscriptionId, bytes32 keyHash, uint32 callbackGasLimit,
 uint16 requestConfirmations, bool nativePayment)
```

Use `$owner` for `initialOwner`; the launch specifies `0x83027AD9d0D5374335086c539dADD1db983441B0`.
Mainnet BMC is `0x38224239f2BDae357D47cb864BC533d7f72dF961`; coordinator is
`0xD7f86b4b8Cae7D942340FF628F82735b7a20893a`. The constructor makes no dependency calls and
requires no subsequent application initialization. Subscription operations happen separately on
Chainlink's coordinator. No launch token or pool is added.

`script/Deploy.s.sol` reads `OWNER`, `SUBSCRIPTION_ID` and `KEY_HASH` for local simulation;
its default request parameters are 500,000 callback gas, 3 confirmations and native payment.
The production per-token callback attempts a reveal batch, so V3's suggested 150,000-gas seed-only
configuration must not be substituted on the assumption that these callbacks do the same work.

Before actual launch, the operator must verify the nominated subscription, gas lane and payment mode;
register the predicted contract as a consumer; fund for up to 460 initial requests plus possible retries;
maintain IPFS pins; and obtain the final independent review. The pass exposes an owner-only
`setVRFConfig` for later subscription/lane repairs, but initial minting does not depend on that call.
Keep the immutable coordinator dependency and loss-of-owner-key risk in mind. Transfers require acceptance and ownership cannot be renounced.

The static site needs the confirmed pass address in `website/config.js`. Do not put a simulation address
there. Monitor `pendingReveals()`; anyone can finalize stored words or retry eligible stalled tokens.

## Website (bmc-pass)

Static files, no build. Connects MetaMask/Rabby over EIP-1193, encodes calls locally (selectors
computed with an inline keccak-256). Shows BMC balance and allowance, phase, price, remaining
supply, total burned, remaining-inventory odds (marked provisional while reveals are pending),
Genesis #1 showcase, preview gallery, reveal lookup, Etherscan links, and explanations of gas,
burning and VRF delays. Two-step approve-then-mint with exact amounts (no infinite approvals).

## Assumptions

- BMC `burnFrom` follows the behavior exercised on the pinned fork; each mint independently
  checks exact supply/balance deltas.
- 18 decimals, prices expressed as `1_000_000e18` and `350_000e18`.
- Chainlink mainnet VRF v2.5 coordinator and key hashes per Chainlink documentation; the owner
  chooses the gas lane.
- Modulo bias of `word % remaining` with a 256-bit word and `remaining <= 460` is negligible (< 2^-247).
- The artwork is original generated vector-style cartoon art; it is not derived from any existing character.

## Testing

```bash
forge build
forge test
python3 artwork/tools/verify_genesis_cid.py
# Optional read-only Mainnet fork checks (network required):
forge test --match-path 'test/*MainnetFork.t.sol' \
  --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26176905
```
