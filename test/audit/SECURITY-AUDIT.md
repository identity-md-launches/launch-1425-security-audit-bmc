# BMC Illuminati Pass Candidate V3 — adversarial audit follow-up

**Mainnet verdict: NOT READY.** V3 has two reproduced high-severity liveness risks: loss of its sole seed request permanently prevents mystery reveals, and canceled immutable VRF configuration cannot be repaired after buyers have burned BMC. Its constructor also cannot be encoded by the static-word launch factory and takes an absolute deadline that can expire or shrink the sale before deployment lands (M-1). Passing tests and a successful deployment simulation do not resolve any of these. This contributor review is **not independent certification**.

**Revision note (2026-10-12).** An independent reviewer confirmed H-1, H-2 and L-1 with their own proofs, which reproduce on this tree, and raised the constructor issue now recorded as M-1. The merge of another contributor's accepted work had made this suite fail to compile (`s_provingKeys` became `virtual` in `test/mocks/MockVRFCoordinator.sol`, so `SequenceCoordinator` in `helpers/V3SecurityMocks.sol` needed `override`); that one word is the only change to existing test code. Nothing in the audited fixture changed: V3 is the read-only subject of this audit, so the H-1/H-2 proofs still fail by design and the defects remain open for the V3 author.

This assignment changes tests and audit evidence only. No application, deployment script, dependency, configuration, wallet, subscription or live contract was changed. No transaction was broadcast and no message was signed.

## Scope and identity of the audited code

The accepted checkout starts at `fba0ebd`. Its `src/BMCIlluminatiPass.sol` is an earlier contributor's **different, per-token recovery implementation**. The brief's `src/experimental/BMCIlluminatiPassCandidateV3.sol` and dry-run script are absent from their original paths. V3 is preserved in [the existing fixture](fixtures/BMCIlluminatiPassCandidateV3.sol), which this assignment leaves unchanged.

I independently downloaded the three named files at upstream commit `bf2a63c04d0e73a1a1b9c65a785d921526ec39b0`, reviewed the differences, and rebuilt the original branch in scratch space. The fixture differs only in its two project import paths and formatting. Its **23,592-byte compiled runtime template is identical** to the original branch's output with the existing compiler settings. Original file hashes and fork identity are recorded in [provenance.json](evidence/provenance.json). No scratch sources or dependencies are required by the submitted suite.

Locations below use the **current fixture's line numbers**, with original-branch links where useful. Existing `docs/SECURITY-REVIEW.md` remains historical evidence; its test names and counts are superseded by this follow-up. Production recovery tests remain in the suite, but their success does not establish V3 recovery.

## Findings

| ID | Severity | Finding | Reproduction |
| --- | --- | --- | --- |
| H-1 | High | One abandoned seed request permanently strands mystery reveals | [Failing proof](evidence/V3LostSeedProof.t.sol.txt), [observed failure](evidence/H-1-failing-proof.txt) |
| H-2 | High | Canceled subscription cannot be replaced after irreversible burns | [Failing proof](evidence/V3CancelledSubscriptionProof.t.sol.txt), [observed failure](evidence/H-2-failing-proof.txt) |
| M-1 | Medium | Constructor cannot be encoded by the static-word factory; absolute deadline can expire or shrink the sale before deployment lands | Passing documentation tests `CandidateV3DeploymentEncodingTest` in [CandidateV3FailurePaths.t.sol](CandidateV3FailurePaths.t.sol) |
| L-1 | Low | An empty sale can spend subscription funds on unusable randomness | [Failing proof](evidence/V3EmptySaleFeeProof.t.sol.txt), [observed failure](evidence/L-1-failing-proof.txt) |

These are also submitted in `.imd-findings.json`, including the complete standalone proof sources. Each proof was run individually and **failed at the stated assertion**, without a fork, FFI, another test harness or skipped tests. The imports target the preserved application fixture because the requested original source path does not exist in this checkout. The proof dependencies are already vendored libraries. The low-severity issue corresponds to L-3 in the earlier report; IDs in the table above are local to this follow-up.

### H-1 — Lost seed request has no recovery

**Locations:** fixture `requestSeed`, lines 254–277, especially line 257; callback lines 303–310; finalization line 315. [Original request guard, line 255](https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/bf2a63c04d0e73a1a1b9c65a785d921526ec39b0/src/experimental/BMCIlluminatiPassCandidateV3.sol#L255).

**Sequence:** Mint the 40 Genesis NFTs and mystery token 41. Close at the deadline, request seed ID 1, advance eight days and model the service abandoning that request. The coordinator remains usable for fresh requests. Attempt recovery through `requestSeed`, then finalization.

**Expected:** A reviewed recovery or compensation mechanism prevents a single lost request from leaving a paid mystery NFT permanently pending. The supplied regression specifies a timed fresh request, no additional burn, and finalization after delivery.

**Actual:** `requestSeed` forever reverts `seed already requested`; `finalizeReveals` cannot proceed without a seed. The initial transactions burned 40,350,000 BMC, of which **350,000 BMC paid for the affected mystery token**. At full sellout, all **460 mystery NFTs / 161,000,000 BMC of mystery payments** are exposed. Genesis NFTs already have their artwork and are not themselves reveal-stalled.

**External behavior:** Chainlink documents expiry of underfunded requests after up to 24 hours and no automatic retry of a failed callback. The proof's expiry is an **off-chain service model**, not an invented expiry check in the Mainnet coordinator. [Subscription lifecycle](https://docs.chain.link/vrf/v2-5/overview/subscription), [callback guidance](https://docs.chain.link/vrf/v2-5/security).

**Recommendation:** Resolve the liveness/economic design before accepting irreversible burns. If adopting timed retries, preserve valid earlier IDs, accept only the first delivered seed, forbid replacement after seed receipt and review oracle withholding/delivery-order incentives. Chainlink warns that retries can enable discarding unfavorable randomness; elapsed time does not prove a previous result is unavailable. An alternative compensation design must account for the fact that V3 has already destroyed the payment tokens. Merely funding an abandoned request or changing the UI is not a fix.

### H-2 — Immutable subscription can become permanently unusable

**Locations:** fixture constructor lines 178–205, particularly stored configuration at line 204; proving-key validation and request dispatch at lines 258–273. [Original constructor](https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass/blob/bf2a63c04d0e73a1a1b9c65a785d921526ec39b0/src/experimental/BMCIlluminatiPassCandidateV3.sol#L178).

**Sequence:** Mint 40 Genesis and one mystery NFT against subscription 1. Before any seed request, cancel that subscription and make subscription 2 available on the same coordinator. At the deadline, request the seed, then attempt owner-authorized repair of the future request parameters.

**Expected:** A narrowly controlled operational repair can restore the reveal lifecycle without another burn or replacing delivered randomness. The proof specifies `setVRFConfig` using the replacement subscription on the same coordinator.

**Actual:** The seed request fails with an invalid subscription, and V3 has no configuration repair function. A retired proving key produces the analogous permanent failure unless that same key is restored externally. Cancellation before the first request was also reproduced against the actual coordinator on the local Mainnet fork. The actor with cancellation power is the **subscription administrator**; this is an operational trust/liveness risk, not an unauthorized cancellation exploit. Missing consumer registration alone is recoverable by registration and is tested as such.

**Recommendation:** Validate intended dependencies, subscription ownership, registration, funding and lane before opening minting. Validation at one point in time does not prevent subsequent cancellation. Design a constrained replacement path for future request parameters before seed receipt, keeping the trusted coordinator fixed and preserving accepted randomness. Such repair authority changes V3's current owner trust model and needs explicit design acceptance. Review subscription administration and monitoring as explicit buyer-facing trust assumptions.

### M-1 — Constructor cannot be factory-encoded and its absolute deadline is deployment-sensitive

**Locations:** fixture constructor lines 178–205: dynamic `string memory initialGenesisCID` parameter at line 188, `closingTime > block.timestamp` at line 191, `saleDeadline = closingTime` at line 202. Compare the production constructor, which hard-codes the CID and takes eight static words (`test/FactoryDeployment.t.sol`).

**Encoding.** The launch factory appends one static 32-byte word per constructor parameter. V3's ABI-encoded argument block is **13 words** (ten head words plus a length word and two data words for the 59-byte CID), and the tenth head word is a tail offset, not the CID. `test_ConstructorABIHasDynamicArgumentStaticWordsCannotEncode` appends ten static words (the CID packed into a `bytes32`) to `type(V3).creationCode` and shows `CREATE` returns `address(0)`, while the full dynamic encoding deploys. No valid manifest entry can instantiate V3; the accepted `launch.json` lists only the production contract.

**Deadline.** `closingTime` is chosen before the deployment transaction is submitted. `test_PrecomputedDeadlineLandingLateLeavesNoSaleWindow` deploys with `closingTime = now + 1`: construction succeeds, and one second later `currentPrice()` is `0`, `mintGenesis` reverts `GenesisPhaseOver`, `mintMystery` reverts `GenesisPhaseNotOver`, `closeSale()` succeeds with nothing sold and `remainingSupply() == 500`, and no owner call reopens or extends the sale. The identical words one second later revert `deadline must be future`. A landing delay therefore either blocks deployment or silently shortens the sale window.

**Expected:** a constructor the factory can encode, with the sale window measured from deployment.

**Actual:** a `string` parameter and an absolute timestamp. These tests pass because they document V3's real behaviour; the defect is the design and is reported rather than tested around.

**Recommendation:** hard-code the verified CID as a constant (as `src/BMCIlluminatiPass.sol` does) and take a bounded sale duration that the constructor converts to a deadline. Until V3's constructor changes, it cannot be deployed through the launch factory at all.

### L-1 — Empty sale spends a request fee

**Location:** fixture `requestSeed`, lines 254–277; no check requires `totalMinted > GENESIS_PHASE_SUPPLY`.

**Sequence:** Create and fund a mock subscription with 1 ETH, register V3, mint zero NFTs, advance to the deadline and request a seed from an unrelated caller. Fulfill through Chainlink's vendored v2.5 mock.

**Expected:** No subscription expense when no mystery NFT can use the randomness.

**Actual:** The subscription is charged. In the proof, its native balance decreases from `1000000000000000000` to `998932833000000000` wei. This is **mock billing evidence, not a Mainnet price estimate**. The same unnecessary request is possible with only 1–40 Genesis NFTs. Exposure is one request, not an unbounded drain.

**Recommendation:** Require at least one sold mystery position before requesting the seed. Keep `closeSale` independently callable so an empty sale can still end normally.

## Review of the requested security areas

| Area | Evidence and conclusion |
| --- | --- |
| VRF v2.5 ABI, coordinator and lane | Local official-mock integration checks every request event field, one word, extra-argument tag, both billing currencies and the 150,000-gas callback. Mainnet fork verifies live coordinator code, LINK reference and the registered 500-gwei lane. V3's explicit caller check rejects forged callbacks, unknown IDs and empty words; zero randomness is valid and duplicate delivery cannot change the first seed. The custom `s_provingKeys` getter is an implementation-specific dependency, so a different coordinator cannot be assumed compatible. |
| One global request | H-1/H-2 are open. A reverted request submission is distinct from an accepted request later abandoned: the former rolls back the automatic close and request ID and can be resubmitted after registration/funding is repaired. New tests check that distinction. |
| Burns and reentrancy | Both payer balance and total supply must decrease by the price. Tests independently attack each delta using no-op, short, excessive, balance-only and supply-only burns, increasing supply and explicit burn reverts. Insufficient balance restores the allowance already spent inside `burnFrom`; receiver rejection restores all accounting in both phases. Existing burn and receiver reentrancy tests remain. Real BMC `burnFrom` executes on the fork. All of this assumes the configured BMC is the verified token; arbitrary malicious getters can lie consistently. |
| Rarity and uniqueness | Full sellout is 1 Legendary Genesis + 39 fixed Genesis + 37 random Genesis + 423 Standard. Random sequence invariants enumerate actual owners and artwork, reject duplicates, and reconcile every inventory counter. A new metamorphic fuzz property restores the same seed snapshot and varies caller, holder, time and batch partition; outcomes and metadata must match without copying the shuffle. Full-sale and one-token boundaries are pinned. Existing StandardArt tests check its 423 distinct trait combinations. No duplicate or accounting defect was reproduced. |
| Deadline, closure and unsold NFTs | Mints fail at exactly the deadline. An unsold sale cannot close early, including through its owner. Sellout permits earlier closure. Closed sales cannot mint more. Unassigned artwork stays in unused inventory; partial sales do not guarantee all 77 Genesis NFTs will be issued. `remainingSupply` is unissued capacity after closure, not a promise that those NFTs can still be bought. |
| Genesis metadata | I reran the offline UnixFS verifier over all 77 local PNG files; the resulting CID is `bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u`, matching the script. Tests verify locked metadata survives transfers and ownership renunciation. The constructor validates only nonemptiness, not CID syntax/content; a bad deployment argument cannot later be repaired. Content integrity does not demonstrate sustained IPFS availability or pinning. |
| Constructor and permissions | Owner and dependency zero values, empty CID, every VRF bound, and present/past deadlines are tested. Construction succeeds with codeless dependencies and assigns the explicit owner, not the caller. Original runtime is 984 bytes below EIP-170. V3's owner only has inherited ownership transfer/renunciation powers; no privileged mint, outcome assignment, withdrawal, configuration or upgrade surface was found. That lack of repair authority is material to H-2. |

Additional deployment observations:

- The V3 dry-run derives a fresh 30-day deadline, requires chain ID 1, a nonzero explicit owner and dependency code, then checks the resulting owner/CID/deadline. It does **not** verify consumer registration, sufficient VRF funding, successful oracle fulfillment or service liveness. Its successful simulation is evidence of constructor compatibility only.
- V3's dynamic `string` constructor argument and absolute deadline are now finding M-1. Direct deployment with a full ABI encoding simulates successfully; the static-word factory cannot produce that encoding. The existing production adaptation is a different constructor and must not be substituted silently for the audited candidate.
- A 500,000-gas budget is conservative for V3's storage-only callback; 150,000 succeeds in the existing callback test and official-mock integration. This does not justify reducing the different production contract's callback budget. Recalculate the service funding buffer using actual final deployment parameters. No fixed Mainnet fee or guaranteed fulfillment time is claimed.
- After seed delivery and before finalization, outcomes can be calculated from the public seed while NFT metadata remains pending. The original pending description already discloses this. It remains a secondary-market information risk: show seed availability, provide a preview and arrange prompt bounded finalization. A small callback reveal batch would not eliminate the gap for the remaining tokens. Public seed availability is not proof that a buyer could choose rarity before the sale closes.
- Three confirmations meet the configured minimum; this review does not establish that three confirmations make a reorganization economically unattractive at the collection's eventual market value.

## Reproducible evidence and tests

The original branch's **80 passed, 0 failed** claim was independently reproduced, including **nine Candidate V3 tests**, excluding its Mainnet-only test path. [Original run](evidence/original-80-tests.txt). The accepted checkout, before this task's edits, independently yielded **75 passed, 0 failed and three fork skips**. Those are different trees and must not be combined into one baseline.

The new passing suite adds failure-path/property tests, offline Chainlink integration and stateful invariants. The handler starts from **0**, **41** and **499** sold NFTs; four actors mint batches, transfer directly or through approvals, attempt unauthorized transfers/callbacks, transfer/donate BMC, advance time, close/request, deliver/redeliver and finalize. Ghost ledgers track payments, BMC balances, NFT ownership and immutable outcomes. Full inventory and accounting checks run after every handler call. Inline configuration sets two campaigns to **256 sequences × 32 calls** and the near-sellout campaign to **64 × 32**, with unexpected reverts treated as failures. A deterministic handler exercise proves the branches execute. End-of-sequence settlement explicitly assumes a functioning delivered oracle request; it does not assert recovery for H-1.

The two allowance/balance properties each run **1,000 examples**, malformed burn behavior runs **256**, batch independence runs **128**, and native/LINK mock billing runs **64**. Existing tests retain their established run counts. Every submitted Solidity dependency is already present; default tests require no network or RPC environment. No test calls `vm.setEnv`.

Final delivered-tree verification (this revision, after the merge of the other contributor's VRF-configuration tests): **`forge build` passed; `forge test --offline` passed with 116 passed, 0 failed, 4 fork skips** (the skips are the three production and one V3 chain-id-1 fork tests). The previous round's own tree reported 102 passed and 3 skips; the upstream branch's "80 passed" is `docs/TEST-RESULTS.md`'s record of `bf2a63c`, not this tree. The separately invoked V3 Mainnet fork suite passed **3/3** at the pinned block in the previous round. The combined run includes **18,432 random handler calls** with zero unexpected reverts. [Build output](evidence/final-forge-build.txt), [complete test output](evidence/final-forge-test.txt), [targeted invariant output](evidence/invariant-tests.txt). The independent reviewer's two proofs for H-1 and H-2 were copied under `test/scratch/` and run on this tree: both fail at the stated assertions, as do the three evidence proofs.

Commands for the delivered tree:

```sh
forge build
forge test
forge test --match-path 'test/audit/CandidateV3Invariants.t.sol' -vv
forge test --match-path 'test/audit/CandidateV3MainnetFork.t.sol' \
  --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26177090 -vv
python3 artwork/tools/verify_genesis_cid.py
```

The public endpoint prunes historical state, so the pinned block may already answer `historical state is not available`; the fork tests key only on `block.chainid == 1` and do not require the pin. Drop `--fork-block-number` to run at the latest block (the reviewer's rerun passed there), or use an archive provider to reproduce the pinned observations exactly.

For this worker run, `FOUNDRY_OUT=test/scratch/out` and `FOUNDRY_CACHE_PATH=test/scratch/cache` redirected generated artifacts to the permitted scratch space. They are not needed by the verifier and do not change the tested logic or run counts. Original-branch build scaffolding and deliberately failing `.t.sol` files were removed from test discovery after their individual runs. Full proof text remains in the findings and `.sol.txt` evidence, not as skipped or inverted passing assertions.

To reproduce a finding, copy its `.t.sol.txt` source from `evidence/` into `test/scratch/` with the `.t.sol` extension, then run `forge test --match-path` on that file. A failure is expected on this V3. The H-1/H-2 proofs express the proposed recovery interfaces; an alternative reviewed economic fix needs an equivalent regression criterion.

Mainnet fork identity: **block 26,177,090**, hash `0xcd99ba7251bb8dc2086d6c7b1d2f7ff5d91a053d362660ed6de6b5eb5dc11cc1`, timestamp **2026-10-12 14:48:35 UTC**. Endpoint: `https://ethereum-rpc.publicnode.com`. At that block the nominated subscription belongs to `0x83027AD9d0D5374335086c539dADD1db983441B0`, has **0 LINK / 0.02 ETH / zero consumers**, and the specified key is registered at **500 gwei**. A local request succeeds after local registration/funding. [Fork results](evidence/mainnet-fork-tests.txt), [dry-run output](evidence/v3-dry-run.txt). All mutations were inside the local fork. Reproduction may require an archive provider if the public endpoint prunes the block.

No real oracle proof was delivered, no service was observed over an actual 24-hour wait, and no availability certification, market-value/reorganization model or full static-analysis campaign is claimed. The protected deployment probe covers runtime/constructor constraints, not these application liveness guarantees. Resolve H-1/H-2, review the final artifact and operational configuration, then repeat these checks before considering Mainnet deployment.
