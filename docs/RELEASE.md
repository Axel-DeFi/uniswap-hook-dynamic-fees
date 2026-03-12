# Release Process

This repository uses SemVer (`X.Y.Z`) with git tags (`vX.Y.Z`) as the release source of truth.

## Canonical release artifacts

- `VERSION` file: plain SemVer value, for example `2.0.2`
- git tag: `v2.0.2` (annotated tag)
- `CHANGELOG.md`: heading `## v2.0.2 - YYYY-MM-DD`

All three must always match.

## Rules

1. Do not edit version manually across random files.
2. Cut releases only with `scripts/release/cut.sh`.
3. Validate state with `scripts/release/check.sh`.
4. Push release commit and tag together.

## Cut a new release

Patch release:

```bash
scripts/release/cut.sh --bump patch --push
```

Minor release:

```bash
scripts/release/cut.sh --bump minor --push
```

Major release:

```bash
scripts/release/cut.sh --bump major --push
```

Dry-run preview:

```bash
scripts/release/cut.sh --bump patch --dry-run
```

## CI / automation check

Run locally (or in CI):

```bash
scripts/release/check.sh
```

The check fails if:
- `VERSION` is invalid or missing,
- tag `v<VERSION>` does not exist,
- latest SemVer tag is different from `VERSION`,
- changelog heading for `VERSION` is missing.
