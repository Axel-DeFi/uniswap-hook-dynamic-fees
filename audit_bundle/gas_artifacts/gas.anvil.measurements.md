# Anvil Engineering Gas Measurements

Source: `ops/local/out/reports/gas.anvil.measurements.json`
Date: 2026-03-10 (UTC)

| Operation | txHash | gasUsed | effectiveGasPrice (gwei) | Estimated Cost (ETH) |
|---|---|---:|---:|---:|
| Deploy hook | `0xc6d1f80a7a663ff6d68555d5955fded3cc69cca140a19ef08b21daeed6785de7` | 4866228 | 0.882977951 | 0.004296772029 |
| Create/init pool path | `0x5c90ce085105fe1dd6379686a6b4ebd682940148ec47bc37a4ddc92e1e1f0219` | 130715 | 0.882977951 | 0.000115418463 |
| Normal swap without rollover | `0xfbcf4ee98b7e4e2f816fb0d6765394f1652a8c2f1e1db21e9204bf73d8c4805d` | 167695 | 0.882977951 | 0.000148070987 |
| Swap with period close | `0xa12ec72bf7874be3105db42247f9d14cc14626d0f8266887b72ec65770ef510d` | 69716 | 0.712486380 | 0.000049671700 |
| Swap with lull reset | `0x33ca2f31fbe5703004ca9baec2dcde10c0fa81e841e65ce94cde1c5289c77604` | 121122 | 0.545859575 | 0.000066115603 |
| pause() | `0xb96f8f562775399330e5549cd8dc90f1264c1e4d479c938553e37a854698a085` | 35721 | 0.882977951 | 0.000031540855 |
| unpause() | `0x2fc4dade183b65bbeec9fd6d332c3f5ae054b9dd76f93aaa5e4d5f0e8a49f190` | 35219 | 0.882977951 | 0.000031097600 |
| emergencyResetToFloor() | `0x4f40b9e972416d5277e85339cb1d18633a2caab1260413e1fe01bd585da12848` | 31840 | 0.882977951 | 0.000028114018 |
| claimAllHookFees() | `0xf73477fc7710443d1d5238ffcc924338166493b482d1083340bc50f9d7c01e12` | 112998 | 0.882977951 | 0.000099774743 |
