# Local verification record — 2026-10-12

Tools: Foundry **1.8.5**, commit `51a52c59cffd940f76eddd0b4bb1791aa4b5ac7f`, Solidity **0.8.26**.
The project's own configuration was used: Cancun, optimizer 200 runs, no via-IR,
`bytecode_hash = "none"`, 64 fuzz runs. Build configuration and vendored dependencies were unchanged.
Results are observations from this contributor's run, not independent certification.

## Independently checked baseline

| Target / command | Result |
| --- | --- |
| Supplied checkout `17aa386`: `forge build` | Passed |
| Supplied checkout, untouched: `forge test` | **43 passed, 1 failed**; fork test requires Ethereum Mainnet state |
| Requested branch `bf2a63c`, untouched: `forge test` | **80 passed, 1 failed**; same fork requirement |
| Requested branch: `forge test --no-match-path test/BMCMainnetFork.t.sol` | **80 passed, 0 failed** across 11 suites, including 9 V3 tests |
| Requested branch's real BMC Genesis test on the pinned fork | Passed |
| Original V3 deployment dry-run on the pinned fork | Passed, local simulation only |

The claimed **80 passed, 0 failed** is verified for the branch's **non-fork** suite; it is not the
result of unqualified `forge test` in an empty environment. Original branch test output is preserved
in [audit/v3-baseline-tests.txt](audit/v3-baseline-tests.txt).

Running the *entire original branch suite* on Mainnet state produced **36 passes and 28 failures**
(counting failing `setUp` routines as Foundry does). The common cause was
`ERC721InvalidReceiver(0x328809Bc894f92807417D2dAD6b7C998c1aFdac6)`: the deterministic unit-test
`makeAddr("alice")` address has code in this fork. Those mocked unit tests are designed for an empty
chain; this run does not demonstrate a collection reentrancy defect. Dedicated fork tests use
isolated buyers and real dependency bytecode. We do not claim the whole branch passes on a fork.

## Submitted project

```bash
forge build
forge test
python3 artwork/tools/verify_genesis_cid.py
```

Result excluding disposable scratch scaffolding (which is removed before submission):

```text
Compiler run successful!
75 tests passed, 0 failed, 3 skipped (78 reported cases)
Verified all 77 Genesis files: bafybeihfihwwpev4gkqjuqawgtptsv3ynzsokclo6odsolvoa65aqaac2u
```

The three reported skips are two production fork tests and the V3 fork suite's `setUp` skip;
that suite contains four tests. All six integration tests ran successfully in the separate fork run.
The default suite performs no network calls and requires no environment variables.

| Delivered suite | Offline result |
| --- | --- |
| Production unit/economic/metadata suite | 39 passed |
| Official Chainlink mock integration | 4 passed |
| Expiry/retry adversarial regression suite | 11 passed |
| Factory/constructor/bytecode checks | 3 passed |
| Preserved V3 adversarial audit suite | 18 passed |

Passing V3 `Finding` tests means the documented baseline defect was reproduced, **not** repaired.
Its full-inventory fuzz test runs 64 seeds/batch sizes, independently checks each of 460 draws,
unique artwork, 37 mystery Genesis/423 Standard totals and 201,000,000 BMC full-sale burn.
Production fuzz tests cover single-word inventory bounds and the first original/retry delivery
winning permanently. No larger fuzz-run count is claimed.

The original supplied expiry proof failed before the production repair with:

```text
[FAIL: no recovery path: token 41 is pending forever]
```

It passed after updating only its setup for the new constructor. A stronger delivered regression
also verifies that recovery unblocks an already-stored successor without changing BMC balance,
allowance, supply, NFT count or total burn.

## Explicit Mainnet fork checks

```bash
forge test --match-path 'test/*MainnetFork.t.sol' \
  --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26176905 -vv
```

**6 passed, 0 failed, 0 skipped.** Full output:
[audit/mainnet-fork-tests.txt](audit/mainnet-fork-tests.txt).

The public endpoint later rejected additional historical calls with an archive-access error.
Replaying this pinned block may require an archive-capable RPC URL; the default offline suite
does not require RPC access.

Block hash: `0xe144c5336ac2a4fb005c803b0ef0b6f97d86696defb8cb4c33b9dc6a1c1e07cb`.
Timestamp: 2026-10-12 14:11:11 UTC.

Checks execute real BMC code for Genesis and mystery burns, confirm exact supply/balance deltas,
exercise a production retry against the actual coordinator, read the registered lane and nominated
subscription, demonstrate V3's missing-consumer/cancelled-subscription failures, and obtain an
accepted V3 request after local-only registration/funding. No VRF proof was obtained from an oracle;
no actual coordinator fulfillment or off-chain service expiry is claimed by these fork checks.

The original V3 simulation command ran in the separate pinned branch snapshot:

```bash
OWNER=0x83027ad9d0d5374335086c539dadd1db983441b0 \
forge script script/DeployBMCIlluminatiPassV3DryRun.s.sol:DeployBMCIlluminatiPassV3DryRun \
  --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26176905
```

It reported `Script ran successfully`. No broadcast flag or signing key was used. This checks local
construction, owner/deadline/CID assertions, not readiness of the subscription or seed lifecycle.
No simulation address is a deployed Mainnet address.

## Additional checks

- Production runtime: **22,986 bytes**; V3 fixture/original runtime: **23,592 bytes**.
  Both are below EIP-170; no external library link references. Instruction-aware opcode inspection
  found no DELEGATECALL, CALLCODE or SELFDESTRUCT. The production factory test scans actual deployed
  runtime and verifies the owner argument is retained rather than assigned to the factory.
- Constructor factory test uses CREATE2, zero ETH, exactly eight static words and dependency addresses
  with no code. Missing owner/dependencies and every invalid VRF parameter class are rejected.
- V3's 150k-gas callback test succeeded. A detailed trace measured 31,188 gas inside the callback
  with that test's access warmth, and 66,842 gas including the coordinator helper/measurement.
  These measurements are not a formal maximum or a live billing measurement.
- Offline Genesis CID reconstruction covers all content and the exact 77 directory names. Independent
  negative checks rejected a one-byte image mutation and an extra directory file. Gateway observations
  and source hashes are documented in [audit/PROVENANCE.md](audit/PROVENANCE.md).
- The adapted `script/Deploy.s.sol` also completed an empty-chain local simulation with the
  task's explicit owner and nominated subscription/lane, with no RPC or broadcast.
- `git diff --check` passed. The website change is explanatory copy only; no wallet interaction or
  transaction was initiated. No build/dependency or prohibited path changed.

Slither/Mythril were not run. The final external launch checker, signed manifest/deployment simulation,
real oracle delivery, long-term pinning and independent audit remain separate from these local checks.
