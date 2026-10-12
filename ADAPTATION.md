# Adaptation and audit delivery

The supplied repository is `17aa38676fce6025a2d18cc705542e8a88c1157f`, not the requested
`security/vrf-recovery` branch. The assignment combines a read-only V3 audit brief with explicit
requirements to fix reproduced imported findings and make the supplied project's constructor
factory-compatible. This delivery keeps those scopes explicit: Candidate V3 was audited without
changing its behavior; the supplied production contract receives only the required launch and
reproduced-finding repairs. The [report](docs/SECURITY-REVIEW.md) concludes **V3 is not Mainnet-ready**.

## Changes and reasons

| File | Change | Rule or reproduced finding |
| --- | --- | --- |
| `src/BMCIlluminatiPass.sol` | Added five static VRF constructor words, validated through the same bounds as the existing setter. Constructor has eight total arguments, is nonpayable, makes no dependency calls, and retains explicit owner assignment. | Constructor-only factory setup; imported `855d25095125`. |
| `src/BMCIlluminatiPass.sol` | Fixed Genesis CID to the supplied verified directory; removed the one-time CID setter and unconfigured mint gates. Retained the existing `genesisImagesCID()` and `genesisCIDLocked()` view signatures as constants. The renderer is now pure. | Static constructor argument restriction and immutable metadata; imported `855d25095125`. |
| `src/BMCIlluminatiPass.sol` | Added `lastRequestAt`, one-day `RETRY_DELAY`, `rerequestRandomness(tokenId)`, and request events. Retries are permissionless, nonreentrant and only allowed while awaiting randomness. Each issued ID remains valid; first delivery wins. Rejected/invalid-ID requests roll back. No extra burn or NFT is created. | Reproduced expiry proof `1885b25c42ea`. |
| `src/BMCIlluminatiPass.sol` | Preserved the owner-only VRF setter for future mints and retries; construction already supplies usable configuration. Coordinator remains immutable. | Existing operational power; enables the imported recommendation's subscription/lane repair without giving owner control of delivered outcomes. |
| `script/Deploy.s.sol` | Expanded the config passed into the constructor. `run()` requires explicit owner, subscription and lane inputs and only simulates; removed broadcast cheatcodes. Retained 500,000 callback gas for production's batched callback. | Constructor signature; audit's no-broadcast constraint. V3 callback optimization does not apply directly to production. |
| `test/BMCIlluminatiPass.t.sol` | Updated constructor calls; replaced tests of required post-deployment CID/VRF initialization with constructor readiness and constant-CID tests. Updated expected Genesis URI and owner surface. Kept all 39 test cases and core economic checks. | Tests follow the two required constructor changes. |
| `test/ChainlinkMockIntegration.t.sol` | Creates the subscription before constructing the pass. Renamed and narrowed the immediate-funding test; explicitly states the official mock does not model expiry. | Constructor change; imported `aa8b03686f57`. |
| `test/VRFRecovery.t.sol` | Added dropped-request model and 11 regression tests: expiry, predecessor blocking, first old/new delivery, zero word, timeout/reset, no second burn, failed requests, invalid IDs, callback failure, configuration repair and reentrancy. | Reproduced `1885b25c42ea` and incomplete expiry coverage. |
| `test/FactoryDeployment.t.sol` | Added CREATE2 deployment with eight encoded static words and codeless dependencies, ownership checks, constructor validation, EIP-170 and forbidden-opcode checks. | Supplied factory reference and protected-test requirements. |
| `test/BMCMainnetFork.t.sol` | Retained real-token Genesis test, adapted construction, added real BMC mystery/retry test with the live coordinator in a local fork. Explicitly skips when not on a Mainnet fork. | Required offline `forge test` plus requested fork checks; previously default tests failed solely for missing fork state. |
| `test/audit/fixtures/BMCIlluminatiPassCandidateV3.sol` | Preserved the remote V3 audit target as a test-only fixture with project import paths adjusted. Its compiled runtime matches the original branch exactly. | Reproducible, offline adversarial audit despite absent V3 files in supplied checkout. This is not a launch application. |
| `test/audit/CandidateV3Audit.t.sol` | Added 18 adversarial tests, including defect demonstrations, 64-seed full-inventory fuzzing, burn/receiver reentrancy, sale boundaries and metadata prediction. | Requested V3 security review. Tests named `Finding` establish the unmodified baseline defect, not its repair. |
| `test/audit/CandidateV3MainnetFork.t.sol` | Added four optional fork checks for actual lane/subscription data, burns before failed seed request, subscription cancellation, and locally registered/funded v2.5 request compatibility. | Requested Mainnet dependency checks. No live state changes. |
| `artwork/tools/verify_genesis_cid.py` | Added a standard-library-only offline UnixFS CID verifier covering the exact 77 filenames and every content byte. Tested expected content, a one-byte mutation and an extra file. | Independently reproduce the supplied final Genesis CID before fixing it as a constant. |
| `README.md`, `website/index.html` | Corrected indefinite-pending and CID-setting claims, described recovery and its limitations, documented factory inputs, updated test commands and marked V3's readiness verdict. | Imported expiry/documentation findings and changed constructor interface. |
| `docs/SECURITY-REVIEW.md` | Replaced obsolete implementer notes with a severity-ranked audit, pinned source locations, reproductions, recommendations, privilege analysis, trust assumptions and readiness verdict. | Requested useful audit deliverable. |
| `docs/TEST-RESULTS.md`, `docs/audit/PROVENANCE.md`, `docs/audit/v3-baseline-tests.txt`, `docs/audit/mainnet-fork-tests.txt` | Recorded independently rerun baseline results, current checks, source hashes, exact fork block, simulation scope and evidence limits. | Requested verification of the claimed 80 passing tests and reproducible evidence. |

## Imported finding disposition

| Imported ID prefix | Result and action |
| --- | --- |
| `1885b25c42ea` | **Reproduced and fixed in supplied production.** The supplied proof failed before changes, then passed after constructor-only test setup adjustment. V3's same root cause independently reproduced in the remote snapshot and remains an open audit finding H-1. |
| `855d25095125` | **Reproduced and fixed in supplied production.** Previously every mint needed CID setup and mystery mints needed VRF setup. Both are now constructor-ready. V3's dynamic-string ABI incompatibility and stale absolute deadline also reproduced; M-1 gives recommendations for that separate candidate. |
| `96d0dabb8a1a` | **V3-specific gas headroom confirmed in the separately fetched target.** Its file does not exist as a deployment script in this checkout. A 150k callback succeeds; the stated funding thresholds are documented estimates, not a reproduced off-chain refusal at 0.3 ETH. Production's callback performs extra reveal work, so its budget was left unchanged. |
| `3d1bf21c1c53` | **Reproduced against the remote V3 target**, now preserved in an audit fixture. The original V3 code already warns that the seed may be public. L-2 explains the residual metadata gap and limits of the suggested callback-batch fix. No V3 behavior was changed. |
| `15eb952710a7` | **Reproduced against V3.** A zero-mint sale can issue a useless seed request. Production has no global seed function and its request helper requires a real mint or eligible token, so this defect does not apply to the supplied launch source. |
| `aa8b03686f57` | **Partially reproduced.** The official mock lacks expiry and old prose overstated recovery. The original test itself funds immediately, so its exact sequence is not a false premise. Kept that legitimate integration check with an accurate name/comment and added real expiry modeling; see L-4. |
| `fca2125e759b` | **Confirmed for remote V3 only.** The owner lacks application powers and several mappings/constants are unused there. In production those powers/mappings drive VRF configuration and per-token reveals; deleting them would break the agreed design. I-1 documents the distinction. |

## Factory handoff for the supplied production application

Application name: **`BMCIlluminatiPass`** (within 32 characters).
Only the application is a launch candidate; internal `StandardArt`, scripts, mocks and audit fixtures
are not deployments. No launch token, pool, proxy, initializer or external linked library was added.

Constructor order:

1. `address initialOwner`: `$owner`, resolving to the launch-specified
   `0x83027AD9d0D5374335086c539dADD1db983441B0`.
2. `address bmcToken`: `0x38224239f2BDae357D47cb864BC533d7f72dF961`.
3. `address vrfCoordinator`: `0xD7f86b4b8Cae7D942340FF628F82735b7a20893a`.
4. `uint256 subscriptionId`: operator's real v2.5 subscription, validated nonzero.
5. `bytes32 keyHash`: registered Mainnet gas lane, validated nonzero.
6. `uint32 callbackGasLimit`: 150,000–2,500,000; production simulation uses 500,000.
7. `uint16 requestConfirmations`: 3–200; simulation uses 3.
8. `bool nativePayment`: `1` for ETH, `0` for LINK; simulation uses `1`.

The task's V3 script nominates subscription
`27852459484169864437638942739291618120641810244677084392617474192083559562985`
and lane `0x3fd2fec10d06ee8f65e7f2e95f5c56511359ece3f33960ad8a866ae24a8ff10b`.
They were verified on the pinned Mainnet fork; the subscription belongs to the specified owner.
It still had no consumers and only 0.02 ETH. These public values are recorded as evidence, not
silently substituted into production configuration. The existing owner-settable VRF setting is
retained as expressly allowed by the imported finding. Registration and funding happen on
Chainlink's coordinator, not through post-deployment application initialization.

No `launch.json` was written. The manifest/deployment stages must use reviewed inputs and must
not select the V3 test fixture. NFT sale minting is retained because it is the expressly requested
application behavior; no ERC-20 inflation or privileged NFT mint capability was introduced.

## Behavior and limits

Prices, maximum burn, 500 supply cap, 40 sequential Genesis mints, 460 mystery slots, 77/423 full-sale
rarity totals, ERC-721 transfer behavior, in-order finalization, artwork generation, coordinator
identity, burn checks and owner role assignment are preserved. Production still has no sale
expiry; V3's different deadline/single-seed design was not transplanted into it.

Retries improve recovery without proving off-chain expiry. Multiple pending proofs increase
reliance on oracle delivery order and may incur additional subscription fees. Permanent coordinator
failure or inaccessible subscription administration can still stall reveals. These assumptions are
explicit in the audit; the repair is not independent approval for Mainnet deployment.

Build configuration and dependencies (`foundry.toml`, locks, remappings, `lib/`, package files),
`.git/`, `.github/`, `.env` files and `node_modules/` were not modified. No new dependency was
installed. All submitted tests run offline using the existing vendored libraries. Optional fork
checks are recorded separately and skip explicitly without a Mainnet fork.
