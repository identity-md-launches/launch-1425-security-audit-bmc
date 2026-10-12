# Security audit — BMC Illuminati Pass Candidate V3

**Verdict: NOT READY for Ethereum Mainnet.** Candidate V3 can permanently strand every mystery
reveal after one lost VRF request. Its immutable subscription/lane can also make the first request
impossible after buyers have burned BMC. It cannot be encoded by this launch factory because its
constructor accepts a dynamic string. The dry-run subscription needs consumer registration and
additional funding. Passing tests and a successful deployment simulation do not resolve these issues.

This is a contributor's adversarial review and local verification, **not independent certification**.
No live deployment, broadcast, signature, paid job or key access occurred.

## Scope and versions

The supplied checkout is `17aa38676fce6025a2d18cc705542e8a88c1157f`, containing the production
per-token `src/BMCIlluminatiPass.sol`. The requested V3 files were absent. The requested branch
`security/vrf-recovery` was therefore inspected separately at
`bf2a63c04d0e73a1a1b9c65a785d921526ec39b0`.

The V3 audit covers its contract, named tests and dry-run script, inherited vendored OpenZeppelin
and Chainlink interfaces, BMC burn integration, and `StandardArt`. A preserved V3 fixture and new
adversarial tests are in `test/audit/`. Its compiled runtime matches the original branch byte-for-byte.
V3's behavior has not been modified. The assignment separately required reproduced findings and
factory compatibility to be fixed in the supplied project: those narrow production changes are
listed in [ADAPTATION.md](../ADAPTATION.md). They do not resolve V3's findings or turn the production
per-token design into V3.

All V3 source line numbers below refer to the **pinned original branch**, so formatting of the audit
fixture cannot change the cited locations. [Evidence provenance](audit/PROVENANCE.md) records source
hashes, the exact fork block and limitations. [Test results](TEST-RESULTS.md) records commands and counts.

## Reopened production review — revision

**Production verdict: fixes verified locally; release remains conditional on subscription setup,
adequate ongoing funding and accessible administration. The nominated subscription is not ready
for sales. Candidate V3's NOT READY verdict above is unchanged.** The original Candidate fixture
was not rewritten to satisfy production findings. All twelve reviewer IDs are answered in
[`.imd-responses.json`](../.imd-responses.json).

| Revision ID | Severity | Production finding | Disposition |
| --- | --- | --- | --- |
| P-M1 / `93c8c9763cf5` | Medium | Unregistered gas lane accepts irreversible buyer burns but cannot deliver randomness | Reproduced on Mainnet fork; request-time lane guard added. |
| P-L1 / `3753c03fb830` | Low | Underfunded subscription accepts burns and requests it cannot presently serve | Reproduced locally and on fork; retained operational precondition, documented. |
| P-L2 / `1a044c26a8ab` | Low | Permissionless retries can charge the subscription for ignored deliveries | Reproduced with official mock billing; retained recovery trade-off, documented. |
| P-L3 / `3a69bc2e9e57` | Low | Mistaken single-step transfer or renunciation removes the sole configuration repair role | Reproduced locally; two-step transfer and disabled renunciation added. |
| P-L4 / `2781c3b45e92` | Low | Stored successor outcome is often computable while pending metadata claims otherwise | Reproduced locally; inaccurate description corrected. Outcome visibility gap still exists. |

### P-M1 — Unregistered lane request commits the burn

**Locations:** `src/BMCIlluminatiPass.sol`, `mintMystery` lines 255–265,
`_requestRandomness` lines 280–305, `_setVRFConfig` lines 211–232. Before this revision the helper
had no lane query. The constructor/setter only checked that the key was nonzero.

**Before-fix reproduction:** At Mainnet block **26,177,335**, create a local-fork subscription,
register the locally constructed pass and fund 1 ETH. Construct/configure with
`keccak256("not a registered mainnet lane")`, for which `s_provingKeys` returns `(false, 0)`.
Mint 40 Genesis using real BMC bytecode, then mint token 41. It succeeds: buyer loses 350,000 BMC,
BMC total supply decreases by the same amount, a nonzero coordinator request commitment appears,
and the NFT remains AwaitingRandomness. Advance one day: a retry commits another bad-lane request.
As a control, a nonexistent subscription with the real lane reverts and restores all buyer BMC.
The scratch before-fix test passed, confirming the reported behavior rather than testing the fix.

**Impact:** A typo or retired lane strands reveals until the owner repairs the lane. A stalled
predecessor blocks later finalizations. Subscription funding cannot make an unknown proving key
serviceable. Losing configuration administration can make the stall permanent.

**Resolution:** The shared helper now staticcalls the immutable coordinator's `s_provingKeys`
before `requestRandomWords`, requires at least two ABI words, and decodes a registered boolean
and `uint64` lane limit. Missing/reverting/short/malformed results fail closed. The check runs on
every mint/retry, not just configuration; no external call was added to construction. Although
`_burnExact` executes first, the guard's revert atomically restores the entire mint transaction,
including the token's balance, allowance and total supply. No burn remains committed on rejection.
The owner can still set valid static configuration words on an empty chain and repair them later.

**Delivered reproduction/regressions:** `test/VRFConfigMainnetFork.t.sol` demonstrates that the real
coordinator still accepts unknown lanes via a deliberately unchecked test probe, while repaired
production rejects them and restores real BMC. `test/VRFConfigSafety.t.sol` additionally covers
constructor/setter mistakes, lane retirement, malformed lookup responses, unchanged original request
and retry timestamp on failure, and successful repair. No oracle proof/fulfillment was produced
on the fork; requests and commitment state were verified.

### P-L1 / P-L2 — Funding and duplicate billing remain recovery trade-offs

**Locations:** `mintMystery` lines 255–265, `rerequestRandomness` lines 271–277,
`rawFulfillRandomWords` lines 329–350 in `src/BMCIlluminatiPass.sol`.

**Reproduction:** A fresh zero-funded subscription with a registered consumer accepts a mystery
request and commits 350,000 BMC burned. The official mock then rejects delivery with
`InsufficientBalance`. After one simulated day an unrelated caller can open a retry. Funding the
subscription and delivering the original and retry reduces its balance twice, but the NFT reveals
only once. Before-fix mock charges were 25,041,686,000,000,000,000 and
25,010,241,250,000,000,000 juels; these are mock pricing, not Mainnet costs. A new fork regression
confirms a zero-native/zero-LINK live coordinator subscription accepts the request and burn.

**Evidence:** `test_UnfundedMintAndPermissionlessRetryCanChargeForIgnoredDelivery` in
`test/ChainlinkMockIntegration.t.sol`; `test_ZeroNativeFundingStillAcceptsRequestAndCommitsBurn` in
`test/VRFConfigMainnetFork.t.sol`. The official mock's request/subscription/billing code is unchanged;
a small test subclass supplies the lane getter missing from that mock. It does not model service
expiry. Expiry is separately tested with the existing dropped-request coordinator.

**Disposition/recommendation:** These low-severity behaviors are real and retained explicitly.
Do not begin sales until consumer registration and adequate funding are established; budget for
up to 460 initial requests plus retries, monitor both balances and outstanding requests, and
maintain administration. The 0.434 ETH estimate for one 500k callback on the 500-gwei lane is a
buffer estimate, not a guaranteed charge, an exact aggregate requirement or reserved balance.
The existing [funding formula][cl-sub] and [re-request security caveat][cl-security] apply.
A balance query alone cannot guarantee fulfillment or reserve fees against other pending requests
or consumers. Restricting sponsors or imposing a finite retry count would weaken the accepted
permissionless expiry-recovery design; a node's timeout must not be guessed. No on-chain minimum,
retry restriction or financial guarantee was added. The README no longer implies every bad
configuration fails immediately: insufficient funding can still accept a request.

### P-L3 — Keep configuration repair accessible through ownership handoffs

**Locations:** `src/BMCIlluminatiPass.sol`, inheritance line 41, `renounceOwnership` lines 194–197;
vendored OpenZeppelin `Ownable2Step.transferOwnership` and `acceptOwnership`.

**Before-fix reproduction:** The current owner transfers to an unintended address: ownership
changes immediately and the previous owner's `setVRFConfig` reverts. Separately, renunciation
sets owner to zero and every caller loses that setter. Both behaviors were independently reproduced.

**Resolution/evidence:** Use the existing vendored `Ownable2Step`. The old owner retains its powers
until the nominated recipient accepts. A proposal can be cancelled with a zero-address proposal or
replaced without surrendering ownership. Renunciation now reverts. The three ownership regressions
in `test/VRFConfigSafety.t.sol` exercise authorized acceptance, unauthorized acceptance/configuration,
proposal cancellation/replacement, and retained repair after blocked renunciation. Constructor owner
and arguments stay unchanged. These changes do not prevent lost signing keys, a malicious current
owner or acceptance by an unintended recipient able to sign; those remain administration risks.

### P-L4 — Pending does not mean unpredictable

**Locations:** `src/BMCIlluminatiPass.sol`, `finalizeReveals` lines 356–367 and `_pendingJson`
lines 540–550 (description line 546).

**Reproduction:** Mint 41 and 42. Deliver `0xBEEF` for 42 while 41 lacks a word. Finalization
returns zero and token 42 remains Pending/RandomnessStored. Its slot is
`keccak256(abi.encode(uint256(0xBEEF), uint256(42))) % 459 == 331`.
Deliver word 1 to token 41: its slot is 169, and token 42 becomes Standard artwork 295, as predicted.
Before the revision its pending description incorrectly said the outcome was not determined.

**Resolution/evidence:** Description now discloses public randomness and computable outcomes
before in-order finalization, including the waiting-for-predecessor state. Regression
`test_PendingMetadataDisclosesPredictableStoredOutcome` verifies the disclosure and the concrete
prediction. This is an accurate disclosure fix, not an algorithmic solution to information
asymmetry: final tier/artwork still require predecessor finalization. No provisional prediction
is rendered as an authoritative outcome.

Revision validation uses unchanged compiler/build/dependencies: **87 offline passes, no failures,
four reported skips**, and **10 dedicated Mainnet fork passes**. Fork block hash:
`0x57935951c91171a2e955f162df55f65474e516347408d5aa6fb804d3b8cbacfe`.
The nominated subscription again read 0 LINK, 0.02 ETH and no consumers. The registered nominated
lane still returns `true, 500 gwei`. Full logs/commands are in [TEST-RESULTS.md](TEST-RESULTS.md).
These are local contributor observations, not independent certification or authorization to deploy.

## Severity-ranked findings — unchanged V3 baseline

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| H-1 | High | A lost sole seed request permanently stalls all V3 mystery reveals | Reproduced; open in V3. Per-token equivalent fixed in production. |
| H-2 | High | Immutable subscription/lane can prevent any seed request after irreversible burns | Reproduced; open in V3. |
| M-1 | Medium | Factory cannot encode V3's CID; baseline production needs post-deployment initialization | Reproduced. Production constructor adapted; V3 remains incompatible. |
| L-1 | Low | V3 callback budget is unnecessarily high and raises the funding buffer | Gas headroom reproduced; off-chain minimum is a documentation-based estimate. |
| L-2 | Low | Public seed fixes outcomes while metadata still says Pending Reveal | Reproduced; open in V3. |
| L-3 | Low | A seed request can spend subscription funds without any mystery tokens | Reproduced; open in V3. |
| L-4 | Low | Mock coverage does not establish recovery after service expiry | Confirmed coverage gap; production tests and claims corrected. |
| I-1 | Informational | Vestigial owner role, mappings and constants complicate V3 review | Confirmed; no privilege bypass demonstrated. |

No critical-severity exploit was demonstrated within this scope.

### H-1 — Sole request is a permanent liveness dependency

**Locations:** V3 [`requestSeed`, lines 252–275][v3-request], especially the `seedRequestId == 0`
guard at line 255; [`rawFulfillRandomWords`, lines 302–310][v3-callback]. Baseline production
[`mintMystery`, lines 239–272][main-mint] had the equivalent per-token issue.

**Reproduction:** Complete 40 Genesis mints, mint token 41, close at the deadline and request the
seed. Model the oracle dropping the underfunded request after 24 hours, advance eight days and try
requesting again. V3 reverts `seed already requested`; finalization reverts `seed pending`.
40,350,000 BMC remains burned, including the 350,000 BMC mystery price. With 460 mystery mints,
up to **161,000,000 BMC** paid for mystery NFTs is exposed. In the production baseline, a missing
predecessor also prevents later tokens with stored words from finalizing.

**Evidence:** `test_FindingExpiredSingleRequestPermanentlyStalls` and
`test_FindingFailedCallbackHasNoRecovery` in `test/audit/CandidateV3Audit.t.sol`. The supplied
production proof failed before repair with `no recovery path: token 41 is pending forever` and
passed after repair. The delivered regression is
`test_ExpiredRequestRecoveryUnblocksSuccessorsWithoutAnotherBurn` in `test/VRFRecovery.t.sol`.

Chainlink documents a 24-hour expiry window for underfunded requests; this is oracle-service
behavior, not an on-chain expiry check in the mock or coordinator. A callback failure also does not
cause automatic redelivery. [Subscription lifecycle][cl-sub], [callback security guidance][cl-security].

**Recommendation:** Resolve the liveness/fairness tradeoff before deploying V3. A timed recovery
path can retain all issued IDs, accept only the first delivered seed, reject retries after receipt,
and never burn again. It must also repair H-2. Chainlink warns against re-request designs because
of selective withholding and ordering risks; a timeout is not proof that an earlier result is
unavailable. Treat such recovery as an explicit additional trust assumption, not a free safety fix.
The production adaptation implements the imported timed-recovery recommendation, with these
limitations documented below. [Chainlink security guidance][cl-security].

### H-2 — Configuration failure can become permanent after burns

**Locations:** V3 [`constructor`, lines 178–205][v3-constructor], immutable operational configuration
stored at line 204; [`requestSeed`, lines 256–271][v3-request]; dry-run
[subscription, lane and payment configuration, lines 10–40][v3-script].

**Reproduction:** Mint 40 Genesis plus one mystery token, cancel the nominated subscription locally
on a Mainnet fork, advance to the deadline and request the seed. The live coordinator reverts
`InvalidSubscription`; V3 has no setter or alternative subscription input. Separately deregister
its key in the adversarial coordinator: the proving-key check permanently rejects requests unless
that same lane returns. Buyer burns happened in earlier calls and remain in effect.

**Evidence:** `test_CancelledSubscriptionCannotBeReplacedInV3` and
`test_BurnsPersistWhenUnregisteredConsumerCannotRequestSeed` in
`test/audit/CandidateV3MainnetFork.t.sol`; `test_FindingRemovedLaneCannotBeReconfigured` in the
local audit suite. Consumer absence alone is recoverable by the subscription admin adding the
consumer; it is not described here as intrinsically permanent.

At block **26,176,905**, the script's subscription
`27852459484169864437638942739291618120641810244677084392617474192083559562985`
reports owner `0x83027AD9d0D5374335086c539dADD1db983441B0`, **0 LINK, 0.02 ETH, and no consumers**.
A local fork request succeeds after simulated registration and funding. These operations were
performed only in the fork's local state; no live subscription was changed.

**Recommendation:** Validate the intended subscription and consumer before accepting burns.
Provide a controlled way to choose a valid replacement subscription/lane while no seed has arrived,
without replacing the coordinator or discarding delivered randomness. Keep registration/funding
responsibilities explicit. A permanent coordinator outage still needs to be accepted as a trust
dependency; pointing fulfillment at an arbitrary replacement would introduce a stronger attack path.

### M-1 — Constructor does not meet factory requirements

**Locations:** V3 [`constructor`, line 188][v3-constructor] (`string memory initialGenesisCID`)
and line 191 (`closingTime > block.timestamp`). Baseline production
[`constructor` and configuration setters, lines 172–218][main-constructor].

**Reproduction:** V3's ABI contains a dynamic string, which the supplied static-word manifest format
cannot represent. Separately, deploying with `closingTime == block.timestamp` reverts; the same
precomputed timestamp can become stale while deployment waits. Baseline production's three-address
constructor leaves every mint gated on setting the CID, with mystery minting also gated on VRF
configuration. A factory making no initialization calls cannot complete that setup.

**Evidence:** Constructor ABI inspection; `test_FindingAbsoluteDeadlineCanExpireBeforeDeployment`;
original production setup paths. The repaired production is tested by
`test_MintingIsConfiguredByConstructor` and `test_FactoryDeploysWithEightStaticArgumentsAndNoDependencyCalls`.

**Recommendation/resolution:** Production now fixes the verified CID as a constant and accepts
all VRF words in its nonpayable eight-argument constructor. The owner stays an explicit argument,
not the factory or transaction origin. No external call or code-presence check occurs in construction.
For V3, use the verified constant CID and consider a bounded sale duration converted to a deadline
at construction. The absolute-deadline concern is deployment fragility, not a demonstrated ability
for an outsider to close the sale early.

### L-1 — V3 callback funding buffer exceeds its workload

**Locations:** [dry-run script line 37][v3-script]; [V3 callback lines 302–310][v3-callback].

**Reproduction/evidence:** `test_CallbackFits150kWithStorageMargin` successfully invokes the
unchanged callback with 150,000 gas. The traced callback used **31,188 gas** in this test's access
context; the coordinator helper plus measurement overhead used **66,842 gas**. This is a measured
scenario, not a formal worst-case gas bound. The callback only stores the seed and emits an event;
it does not run the production contract's reveal batch.

Using the published estimation formula and Ethereum parameters, the approximate funding buffer is
`500 gwei × (200,000 + callbackGasLimit) × 1.24`: **0.434 ETH** at 500,000 callback gas and
**0.217 ETH** at 150,000. These are estimates, not actual charges or a locally demonstrated oracle
refusal at 0.3 ETH. The coordinator can accept a request before the off-chain service has enough
funding to serve it. [Minimum balance calculation][cl-sub], [Ethereum lane and premium][cl-networks].

**Recommendation:** Use a measured callback budget with margin for V3, such as its existing 150,000
minimum, and fund above the service's current required buffer. Do not blindly apply this reduction
to production's callback, which also attempts finalization. Its existing budget is retained.

### L-2 — Pending metadata hides an already-computable outcome

**Locations:** [V3 seed storage, line 308][v3-callback]; [`_finalize`, lines 323–349][v3-draw];
[`tokenURI` and pending metadata, lines 424–436 and 495–505][v3-metadata].

**Reproduction:** Deliver a seed chosen so `keccak256(abi.encode(seed, uint256(41))) % 460 < 37`.
Before finalization, calculate token 41's Genesis artwork as `41 + result`. `tierOf` remains Pending,
`artworkIdOf` returns zero, and `tokenURI` is byte-identical to its pre-seed value. Finalization then
produces the predicted Genesis result. Later outcomes can be computed by simulating the same
without-replacement shuffle in mint order.

**Evidence:** `test_FindingOutcomePublicWhileMetadataRemainsPending`.

**Impact/recommendation:** An informed buyer can value pending NFTs before a holder relying on
metadata does. V3 already warns in its description that randomness may be public, reducing the
surprise but not eliminating the information gap. Provide an accurate preview/metadata path for
fixed outcomes and arrange prompt, gas-bounded finalization. Merely finalizing a few tokens inside
the callback does not eliminate the gap for the remaining collection. Do not make a large reveal
loop a prerequisite for successful VRF receipt.

### L-3 — Seed request without any mystery inventory

**Location:** [V3 `requestSeed`, lines 252–275][v3-request].

**Reproduction:** With zero mints (also possible with only Genesis mints), advance to the deadline
and call `requestSeed`. It consumes a coordinator request. On fulfillment, `finalizeReveals(500)`
returns zero: no token can use the seed. `test_FindingUselessRequestWithNoMysteryTokens` demonstrates
this. The local mock records the request; actual Mainnet billing was not incurred.

**Recommendation:** Require `totalMinted > GENESIS_PHASE_SUPPLY` before requesting, without
preventing the sale from closing independently. Exposure is one unnecessary request in current V3.
The production per-token architecture cannot request without a minted mystery token.

### L-4 — Mock tests do not establish indefinite recoverability

**Locations:** original [`test/ChainlinkMockIntegration.t.sol`, lines 57–75][main-mock]; original
[V3 `test_OnlyOneSeedRequestEvenAfterSevenDays`, lines 89–103][v3-tests]; original README
“Unavailable randomness”.

**Reproduction/evidence:** The official mock accepts funding and later delivery without modeling
the service expiry window. The original immediate-funding test is valid for its actual no-time-lapse
sequence; the imported finding overstates matters if read as saying that test itself is always
unreachable on Mainnet. What it cannot establish is delivery after an underfunded request expires.
The production README's blanket guarantee was incorrect. The added expiry coordinator deliberately
models dropped delivery, and the V3 finding test shows the permanent stall.

**Resolution:** Renamed the production test to `test_ImmediateFundingAllowsMockFulfillment`, narrowed
its comments, corrected public documentation, and added expiry, callback-failure, configuration
repair and first-delivery regressions. V3's original test remains baseline evidence, not assurance
that its liveness risk is solved.

### I-1 — Vestigial V3 state and role

**Locations:** [V3 inheritance at line 35 and constants at lines 87–94][v3-top]; mappings at
lines 117–119; no-op `_randomWord` deletion at line 335; mystery event's zero request ID at line 237.

V3 has no `onlyOwner` application function: inherited ownership transfer and renunciation are its
only owner operations. The per-token request mappings remain zero; `RandomnessStored` is never
used; callback reveal constants are unused. `test_CIDHasNoSetterAndOwnerCannotChangeSeed` confirms
the observable mapping/permission behavior. No access-control bypass follows from these leftovers.

**Recommendation:** Remove dead state/ABI surface in a separately reviewed V3 revision or document
compatibility reasons. Original V3 runtime is **23,592 bytes**, leaving **984 bytes** below EIP-170;
headroom matters when adding recovery or previews. Production still uses its owner role and these
per-token mappings, so removing them there would be a behavior change without this justification.

## Other reviewed properties

- **Burn accounting and reentrancy:** Both mint entry points use `nonReentrant`. Every burn checks
  18 decimals and exact payer-balance and total-supply decreases. Fork tests execute real BMC
  `burnFrom` for both prices. Fake transfer-to-sink burns and wrong decimals revert. Adversarial
  `burnFrom` and ERC-721 receiver reentry are blocked; receiver rejection restores balance,
  allowance, total supply, mint count and burn accounting. Irreversibility applies to completed
  burns, not a reverted mint transaction. No refund path exists by design.
- **Rarity and uniqueness:** Full sellout yields token 1 Legendary Genesis, 39 additional fixed
  Genesis, 37 mystery Genesis, and 423 Standard NFTs. A 64-run fuzz test compares every one of
  460 V3 outcomes with an independent array-based shuffle and varies finalization batch sizes.
  No duplicates or missing inventory were observed. StandardArt's coprime stride maps 423 distinct
  IDs to distinct trait combinations. Modulo bias is negligible for a 256-bit word over at most
  460 slots; the seed must still be unpredictable before sale closure.
- **Sale deadlines:** Neither owner nor another caller can close early unless all 500 NFTs sell.
  Minting is rejected at `timestamp == saleDeadline`. Unsold tokens never mint later, and unassigned
  artwork stays unassigned. Partial sellout does not promise exactly 77 minted Genesis NFTs.
  `remainingSupply()` describes unused capacity after closure, not purchasable availability;
  `currentPrice()` correctly returns zero.
- **Metadata:** The original V3 constructor locks its nonempty CID but does not validate its content.
  The supplied final CID was independently recomputed from all 77 local files using the delivered
  offline verifier. Metadata/Genesis URI cannot be changed after deployment. IPFS content addressing
  proves integrity, not availability; sustained pinning remains an operator responsibility.
- **VRF integration:** The Mainnet coordinator address, its LINK address, registered 500-gwei key,
  subscription ownership and v2.5 request ABI were checked on the pinned fork. The tuple returned by
  `s_provingKeys` decodes correctly. The script uses native payment, three confirmations and one word.
  These meet published bounds, but minimum confirmations are not a quantified reorg-security proof
  for the collection's value. Only the fixed coordinator can call the callback; unknown IDs are
  rejected; a zero seed is valid; subsequent deliveries cannot change the first stored seed.
- **Constructor and bytecode:** V3's constructor makes no external call and gives ownership to its
  argument. Both analyzed runtimes have no DELEGATECALL, CALLCODE or SELFDESTRUCT opcodes after PUSH
  data is skipped, and no external library link references. Production's repaired constructor
  was actually called through a CREATE2 factory on an empty local chain with codeless dependency
  addresses. Its revised runtime is **23,757 bytes**, 819 bytes below EIP-170 (accepted pre-revision runtime: 22,986 bytes).

## Production repair limits and release conditions

The production fix allows one retry per token per day while it awaits a word, recognizes old and new
request IDs, and preserves the first delivered word. It does not reset outcomes, change rarity,
change prices or supply, or burn twice. Failed retries roll back their timestamp and mapping changes.
The existing owner may update future request parameters, including those used by retries.

Recovery is conditional on a functioning immutable coordinator and a serviceable subscription.
Timed retries can create multiple legitimate proofs for one token; oracle/validator withholding or
ordering can influence which is delivered first. They can also spend additional subscription funds
if several delayed requests are eventually served. The contract cannot prove off-chain expiry.
Two-step transfer and disabled renunciation now protect the configuration role against accidental
handoff/renunciation; losing access to the owner or subscription-admin key still strands repairs.
These are material residual assumptions to review before accepting production for release.

Before deploying **V3**, resolve H-1/H-2/M-1 in a reviewed candidate, retest the exact resulting
artifact, choose and verify the operational VRF configuration, register its consumer address,
fund adequately, and maintain Genesis pins. A dry-run deployment alone does not exercise the
request/fulfillment lifecycle. The current V3 baseline remains **not ready**, regardless of the
production adaptation's passing checks. Explorer verification and the final independent review
belong to the eventual deployment process.

Slither/Mythril, real oracle proof fulfillment, service expiry over real elapsed time, multi-provider
RPC consensus, long-term IPFS availability, and a production gas/reorg economic model were not
established in this bounded review. Time-dependent local tests use `vm.warp`; no clock waiting was
required. See the test record for the full-suite-on-fork fixture collision that limits that command.

[v3-top]: https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/bf2a63c04d0e73a1a1b9c65a785d921526ec39b0/src/experimental/BMCIlluminatiPassCandidateV3.sol#L35
[v3-constructor]: https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/bf2a63c04d0e73a1a1b9c65a785d921526ec39b0/src/experimental/BMCIlluminatiPassCandidateV3.sol#L178
[v3-request]: https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/bf2a63c04d0e73a1a1b9c65a785d921526ec39b0/src/experimental/BMCIlluminatiPassCandidateV3.sol#L252
[v3-callback]: https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/bf2a63c04d0e73a1a1b9c65a785d921526ec39b0/src/experimental/BMCIlluminatiPassCandidateV3.sol#L302
[v3-draw]: https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/bf2a63c04d0e73a1a1b9c65a785d921526ec39b0/src/experimental/BMCIlluminatiPassCandidateV3.sol#L323
[v3-metadata]: https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/bf2a63c04d0e73a1a1b9c65a785d921526ec39b0/src/experimental/BMCIlluminatiPassCandidateV3.sol#L424
[v3-script]: https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/bf2a63c04d0e73a1a1b9c65a785d921526ec39b0/script/DeployBMCIlluminatiPassV3DryRun.s.sol#L10
[v3-tests]: https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/bf2a63c04d0e73a1a1b9c65a785d921526ec39b0/test/BMCIlluminatiPassCandidateV3.t.sol#L89
[main-mint]: https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/17aa38676fce6025a2d18cc705542e8a88c1157f/src/BMCIlluminatiPass.sol#L239
[main-constructor]: https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/17aa38676fce6025a2d18cc705542e8a88c1157f/src/BMCIlluminatiPass.sol#L172
[main-mock]: https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/17aa38676fce6025a2d18cc705542e8a88c1157f/test/ChainlinkMockIntegration.t.sol#L57
[cl-sub]: https://docs.chain.link/vrf/v2-5/overview/subscription
[cl-security]: https://docs.chain.link/vrf/v2-5/security
[cl-networks]: https://docs.chain.link/vrf/v2-5/supported-networks#ethereum-mainnet
