# Source Of Truth Hierarchy

This repository uses an explicit documentation hierarchy.

## 1) Contract NatSpec (primary)

- `src/VolumeDynamicFeeHook.sol`

NatSpec in the live contract is authoritative for runtime behavior and admin semantics.

## 2) Specification (normative mirror)

- `docs/SPEC.md`

`docs/SPEC.md` must match contract NatSpec and is treated as normative operational documentation.

## 3) Repository operational docs (guidance)

- `README.md`
- `docs/FAQ.md`
- `ops/local/RUNBOOK.md`
- `ops/sepolia/RUNBOOK.md`
- `scripts/README.md`

These documents are operational guidance and must remain consistent with (1) and (2).
If there is any mismatch, contract NatSpec and `docs/SPEC.md` take precedence.

## 4) Release metadata

- `VERSION`
- `CHANGELOG.md`
- git tag `vX.Y.Z`

Release versioning is authoritative only for version identity and release state, not behavior semantics.

## Archival / non-normative documents

- Legacy concept PDFs and third-party audit PDFs are archival references only.
- They are not normative for current runtime behavior.
- External dependency PDFs under `lib/` are out of scope for this repository’s behavior source-of-truth rules.
