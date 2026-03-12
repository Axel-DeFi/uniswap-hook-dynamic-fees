# Agent Rules (Repository-local)

## Release and versioning

- Source of truth for release version:
  - `VERSION` file (`X.Y.Z`)
  - git tag (`vX.Y.Z`)
  - changelog heading (`## vX.Y.Z - YYYY-MM-DD`)
- Never bump version manually in ad-hoc edits.
- Always fetch tags before release operations.
- Release flow is mandatory:
  1. `scripts/release/cut.sh --bump <patch|minor|major> --push`
  2. verify with `scripts/release/check.sh`
- If tag race happens (another chat/release already pushed), fetch tags and rerun release cut to compute the next valid version.
