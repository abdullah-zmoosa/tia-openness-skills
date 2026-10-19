# Changelog

## 1.0.0 - 2026-10-19
First public release.

**tia-reader**
- Headless export of V17-V20 projects (`.apNN`) and archives (`.zapNN`) via TIA Openness V20, always on a copy
- Compile-before-export (upgraded or uncompiled projects are otherwise inconsistent and skipped)
- Blocks (SCL, LAD/FBD, STL rendered to text), DBs, user + system UDTs, technology objects
- PLC tag tables with a flat address list; watch tables; PLC alarm text lists
- Classic WinCC HMI: screens, templates, pop-ups, tags (HMI-to-PLC map), connections, text/graphic lists
- Hardware: AutomationML (CAx) export and a readable device / module / IP / I/O-range list
- `compare_exports.py`: noise-free diff of two exports
- `tia_pending.ps1` / `run_pending.ps1`: run via `runas` when the Openness group isn't active in the current logon

**tia-writer**
- Import SCL / DB / UDT sources and SimaticML blocks, UDTs and tag tables into a local V20 copy
- `tia_source.ps1`: generate full block source from an export copy for editing
- Dry run, backup zip, save only on clean compile, refuse F-/know-how-protected blocks
- `tia_checkout.ps1` / `tia_publish.ps1`: local work area with change detection on publish
- Configurable folder rules (`TIA_REQUIRE_SEGMENT`, `TIA_PROTECTED_SEGMENTS`, `TIA_MIRROR_ANCHOR`)
