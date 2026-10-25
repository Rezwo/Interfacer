# Public package verification

This is a clean package export with a new Git history. It does not include the private development archive or its machine-local receipts.

## Initial export checks

- All **27 runtime Luau files** match the current practical package byte-for-byte. `SOURCE_IDENTITIES.json` records their SHA-256 values.
- A fresh headless run recorded **253 passed, 0 failed, 78 skipped**. See `HEADLESS.json`. The skipped Roblox-specific checks are not counted as passes.
- Exact calculation/callback/write assertions passed at **3, 500 and 5,000** independent bindings. See `COUNTS.json` and `CoreCounts.luau`.
- The standalone model is built from these sources with Rojo, not copied from a Studio place. It contains the runtime ModuleScripts and the upstream MIT notice, not players, game data, third-party icons or plugins.
- Public files are selected by an explicit allowlist and scanned before publication. The public repository starts with a new root commit, not a filtered copy of the private history.

## Not claimed

This export does not run a new native Immediate/Deferred campaign, a competitive performance campaign, a full security proof or a bug-free certification. Previous local native testing is not relabeled as a new clean-clone run.

The source uses modern Luau syntax, including read-only fields and type functions. Older/default analyzer modes can reject it and produce cascading diagnostics. Use a compatible SolverV2 configuration; this release does not claim that every analyzer mode is clean.

The CLI identity used for the portable tests is recorded in each receipt. No executable tool binaries are distributed.

## Reproduce

```sh
python verify_distribution.py --luau PATH_TO_COMPATIBLE_LUAU
```

`--hashes-only` checks identity only and explicitly does not pass runtime acceptance. The distribution manifest excludes itself; review source changes before regenerating it.

## Verbose naming and multiline blocks

The working sources now include a mechanical style cleanup after the initial export. They no longer match the initial export byte-for-byte. Current hashes are in `SOURCE_IDENTITIES.json`; the change record is in `STYLE_CLEANUP.json`. All 27 optimized instruction disassemblies match the initial export. Headless tests and exact counts were rerun; no new native or timing run is claimed.

Run `python verification/CheckStyle.py` to check the specific abbreviated bindings and compact return blocks corrected in this pass. This is a targeted guard, not a complete naming linter.
