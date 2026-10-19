# Contributing

Thanks for helping. A few ground rules keep this safe to use on real plant projects.

## Never commit
- TIA projects, archives or exports (`*.ap*`, `*.zap*`, `TIA_Exports/`). Real PLC code is usually
  someone's intellectual property, and it can reveal plant details. Use small synthetic projects for tests.
- Siemens DLLs or anything from a TIA installation.
- Usernames, server names, IP addresses or paths from your site.

## Code style
- PowerShell must run on **Windows PowerShell 5.1**. The C# helpers are compiled by `Add-Type`
  with the C# 5 compiler: no `x is T y` patterns, no string interpolation, no `catch ... when`.
- Keep `.ps1` / `.cs` files **ASCII only**, because PS 5.1 misparses UTF-8 without a BOM.
- No hard-coded paths. Use `tools\tia_common.ps1` helpers and environment overrides.
- `tia_common.ps1` exists in both skills (each skill must be self-contained). Keep the two copies identical.

## Safety rails are features
Changes to `tia-writer` must keep these: write only to the local work area, back up before writing,
save only on a clean compile, refuse F-/know-how-protected blocks and protected folders, never
download to a PLC, and publish only on explicit request.

## Testing a change
1. `scripts\doctor.ps1` passes.
2. Export a small V20 test project and a V17-V19 one (upgrade path). Check `export.log` has no unexpected `SKIP`.
3. For writer changes: `-DryRun`, a real write to a checked-out copy, re-export, `compare_exports.py`
   shows only the intended change.
4. Note what you tested in the pull request.
