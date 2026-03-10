# Contract Tests (Ops Profile)

Contract tests were migrated from `test/VolumeDynamicFeeHook` to `ops/tests`.

## Structure

- `mocks/MockPoolManager.sol`
- `utils/VolumeDynamicFeeHookV2DeployHelper.sol`
- `unit/VolumeDynamicFeeHook.Admin.t.sol`
- `unit/VolumeDynamicFeeHook.ConfigAndEdges.t.sol`
- `fuzz/VolumeDynamicFeeHook.Fuzz.t.sol`
- `invariant/VolumeDynamicFeeHook.Invariant.t.sol`

## Run

Preferred profile invocation:

```bash
FOUNDRY_PROFILE=ops NO_PROXY='*' forge test
```

Compatibility note:

- On Foundry `1.5.1-stable`, `forge test --profile ops` is not available (CLI returns `unexpected argument '--profile'`).
- Use `FOUNDRY_PROFILE=ops` instead.
