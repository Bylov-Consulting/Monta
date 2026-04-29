# Dependencies

This folder contains pre-built Continia Software `.app` artifacts redistributed in this private repository for use by the AL-Go CI pipeline.

## Contents

The full Continia Document Capture 27.3 dependency chain (BC 2025 Wave 2 CU3, target BC 27.0):

| File | Component |
|---|---|
| `Continia System Application 27.3.0.330477 - 27.3.app` | Continia System Application |
| `Core 27.3.0.330522 - 27.3 (BC 2025 Wave 2 CU3).app` | Continia Core |
| `Continia Connector App 27.3.0.330477 - 27.3.app` | Continia Connector App |
| `CDN 27.3.0.330582 - 27.3 (BC 2025 Wave 2 CU3).app` | Continia Delivery Network |
| `Continia Business Foundation 27.3.0.330477 - 27.3.app` | Continia Business Foundation |
| `Continia Approvals 27.3.0.330477 - 27.3.app` | Continia Approvals |
| `Continia Online Connector 27.3.0.330477 - 27.3.app` | Continia Online Connector |
| `DC 27.3.0.330595 - 27.3 (BC 2025 Wave 2 CU3).app` | Continia Document Capture |

These are referenced by `.AL-Go/settings.json` `installApps` so AL-Go's CI/CD pipeline can compile `Monta Document Capture Utility` against DC's symbols.

## License notice

Continia `.app` artifacts are the property of Continia Software A/S. They are redistributed in this private repository under Continia's confirmed permission for internal AL-Go pipeline use only. Do **not** redistribute outside this repository.

## Updating

When DC is upgraded:
1. Replace the `.app` files in this folder with the new versions.
2. Update the version floor in `Monta Document Capture Utility/app.json` `dependencies` if the new build introduces an incompatible signature.
3. Re-verify the dependency chain (run `Get-AppJsonFromAppFile` from BcContainerHelper to inspect each `.app`'s `dependencies` array) and reorder `installApps` if the chain shape changed.
