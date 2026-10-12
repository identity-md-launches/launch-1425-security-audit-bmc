# Audit evidence provenance

The supplied checkout was detached at `17aa38676fce6025a2d18cc705542e8a88c1157f`.
It did not contain Candidate V3. The requested branch was fetched read-only into a separate
local snapshot at `bf2a63c04d0e73a1a1b9c65a785d921526ec39b0` from
<https://github.com/0xSt3w/launch-1356-project-bmc-illuminati-pass>.
No branch switch, merge or remote write was performed.

SHA-256 of the original downloaded files, before import-path adjustment:

| File on the requested branch | SHA-256 |
| --- | --- |
| `src/experimental/BMCIlluminatiPassCandidateV3.sol` | `262af67283b7cf171fe2d46d5e13384b331953c12f6876a9852f73264262cf26` |
| `test/BMCIlluminatiPassCandidateV3.t.sol` | `2894b386a382f56c2109ccaff9f8d228248707691c9a312a75d272bfe4294c83` |
| `script/DeployBMCIlluminatiPassV3DryRun.s.sol` | `79ee940ac1e6a6154286793310a3c50d19e9e5f0a095d40b488e0b8eaecbff8a` |

`test/audit/fixtures/BMCIlluminatiPassCandidateV3.sol` preserves the audited candidate behavior.
Only its two project-relative import paths and formatting may differ. Its compiled runtime
was compared byte-for-byte with the separate original-branch build: identical, 23,592 bytes,
using the project's unchanged compiler configuration. The fixture is a test input, not a launch
application. Do not put it in a deployment manifest.

`v3-baseline-tests.txt` records the original branch's 80 non-fork tests, including 9 V3 tests.
`mainnet-fork-tests.txt` records six explicit fork tests on the submitted production adaptation
and the preserved V3 fixture. These are local observations, not independent certification.

Fork source: `https://ethereum-rpc.publicnode.com`, Ethereum chain id 1.
Block: **26,176,905**, hash
`0xe144c5336ac2a4fb005c803b0ef0b6f97d86696defb8cb4c33b9dc6a1c1e07cb`.
Block timestamp: **2026-10-12 14:11:11 UTC** (`1791814271`).
Later historical reads were rejected by this public endpoint as requiring archive access;
reproduction may need an archive-capable provider. The successful fork runs preceded that restriction.

Genesis integrity was verified by recomputing the entire UnixFS directory CID from the 77 files,
using `artwork/tools/verify_genesis_cid.py`. The recomputed root also matched the independently
retrieved 4,641-byte directory DAG block. The first file's reconstructed DAG matched its
559-byte retrieved block. Direct downloads of 21 images also matched local SHA-256 hashes;
other gateway requests encountered HTTP 403/429. Full content integrity does not depend on
those downloads: the offline verifier covers all 77 files. Availability on two gateways and
ongoing pinning were not established.

No external dependency was installed. Vendored libraries, Foundry configuration and compiler
settings were not changed. No transaction was broadcast, no message signed, no key read, and
no paid service or additional contributor job was initiated.
