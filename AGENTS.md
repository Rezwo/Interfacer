# Repository instructions

- Preserve Flux attribution and the MIT notice, including the standalone model's FluxLicense value.
- Preserve scoped ownership and the documented Flux-derived execution contract.
- Do not import private archives, credentials, machine-local receipts or raw third-party art.
- Keep source edits in strict Luau with descriptive PascalCase names. Do not weaken types to hide analyzer errors.
- Run `python verify_distribution.py --luau PATH_TO_COMPATIBLE_LUAU`; use SolverV2 for compatible static analysis.
- Update source identities only after reviewing the actual source changes. CLI-skipped native tests are not passes.
