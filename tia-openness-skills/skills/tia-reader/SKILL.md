---
name: tia-reader
description: ALWAYS use whenever the user gives, mentions or points at a Siemens TIA Portal project or archive (any path or file ending .ap14-.ap21 or .zap14-.zap21, a TIA project folder, or a folder containing one), or asks to read, review, explain, compare or search a PLC program's OBs, FBs, FCs, DBs, UDTs, tags, I/O addresses, HMI screens/tags or hardware/IP config. Exports the project headless via TIA V20 Openness (on a copy, read-only) and reads the resulting text.
---

# TIA Reader

Turns a binary TIA Portal project (any machine, any program) into text Claude can read: every block
(SCL / LAD / FBD / STL), DBs, UDTs (user + system), technology objects, PLC tags with addresses,
HMI screens + tags (WinCC Comfort/Advanced), hardware + IP addresses.

`<skill>` below = this skill's base directory (shown when the skill loads). All paths are
auto-detected (`tools\tia_common.ps1`); overrides: `TIA_OPENNESS_DLL`, `TIA_EXPORT_ROOT`
(default `%USERPROFILE%\TIA_Exports`), `TIA_PYTHON`.

## Requirements (once per PC)
- TIA Portal **V20** with Openness installed (reads V17-V20 projects; older ones via an upgraded copy).
- Windows user in the local group **"Siemens TIA Openness"** (admin adds it; then sign out/in).
- Python 3 and Windows PowerShell 5.1.

## Rules (do not break)
- **Read-only, copy-only.** The script copies `.apNN` projects (or retrieves `.zapNN`) into the
  export folder and works on that copy. Never point Openness at an original project.
- **Never import, write back or download** with this skill (that is `tia-writer`, on request only).

## Step 1 - reuse an existing export if it is current
Exports live in `<TIA_EXPORT_ROOT>\<ProjectName>_<yyyyMMdd_HHmm>\`; newest path in `LATEST.txt`.
If an export of the same project exists and is newer than the project's LastWriteTime (check the
newest file in the project folder, not just the `.apNN`), read it and skip to Step 3.

## Step 2 - run the export
Check this shell's logon: `(whoami /groups) -match 'Siemens TIA Openness'`

- **Group present** -> run it yourself (PowerShell tool, `run_in_background: true`, 2-6 min):
  ```
  powershell -ExecutionPolicy Bypass -File "<skill>\tools\tia_read.ps1" -Project "<path to .apNN / .zapNN / project folder>"
  ```
- **Group missing** (added but user hasn't signed out/in) -> queue it and relay the printed command:
  ```
  powershell -ExecutionPolicy Bypass -File "<skill>\tools\tia_pending.ps1" -Project "<path1>","<path2>"
  ```
  It converts mapped drives to UNC (runas sessions have no mapped drives) and prints a fixed
  `runas /user:<DOMAIN>\<user> "powershell ... run_pending.ps1"` line for the user to run
  (Win+R or terminal; asks for their Windows password). Never build a runas line with the project
  path inside it - nested quotes break in PowerShell. Wait for "done", then read `LATEST.txt`.

The project may stay open in the TIA UI - the script works on a copy (copied `.lck` files are deleted).
First Openness use on a PC can pop a one-time "allow access" dialog - the user must click Yes.

## Step 3 - read the export (`<out>\export\`)
| Path | Contents | Start here for |
|---|---|---|
| `blocks/Main.lad.txt` | OB1 call tree | program structure |
| `blocks/*.lad.txt` | LAD/FBD networks as text | ladder logic |
| `blocks/*.scl` | SCL source (body) | SCL blocks / networks |
| `blocks/*.stl` | STL source | STL blocks |
| `blocks/*.xml` | SimaticML (DBs, interfaces, everything) | DB members/start values, interfaces |
| `manifest.json` | every block: type, language, know-how-protected, safety | inventory |
| `tags/_PLC_TAGS.txt` | all PLC tags: name, %address, type, table, comment | I/O addresses |
| `udt/` | user + system UDTs | data types |
| `hmi/<HMI>/_HMI_TAGS.txt` | HMI tag -> PLC tag / connection | what the HMI reads/writes |
| `hmi/<HMI>/ScreenFolder/**/*.xml.txt` | screen object tree with tag links | screens |
| `hw/devices.txt` | devices, order numbers, firmware, IPs, PN names, I/O ranges | hardware / network |
| `hw/project.aml` | full AutomationML hardware export | detail |
| `to/*.params.txt` | technology objects (PID_Temp, PID_Compact, counters, axes) | TO settings |
| `watch/` | watch tables | |
| `../export.log` | compile result, every SKIP | check before claiming completeness |

Always check `export.log` for `SKIP` lines and the compile result before saying "everything".

## Comparing two projects / versions
Export both (use `-Out` to name them), then:
```
python -I "<skill>\tools\compare_exports.py" "<exportA>" "<exportB>"
```
It drops the noise (`<Created>` timestamps; in `hw/project.aml` GUIDs, `<LastWritingDateTime>`,
project name) and prints blocks/files only on one side plus each real difference.
Report those to the user; "0 differ" = identical.

## Known limits - tell the user when relevant
- `render_lad.py` is approximate for series/parallel contacts (shows last contact traced). Call
  parameter bindings and coils are exact. For tricky rung logic, say to confirm in TIA.
- `[empty network]` = genuinely empty network, not missing code.
- Know-how-protected blocks (e.g. Siemens library blocks) export interface only - nobody can read them.
- Older projects are read from a V20-upgraded copy; logic is identical, but old HMI devices may report
  "device is not supported" in V20 (needs Change device/version in TIA). Screens/tags still export.
- WinCC **Unified** HMIs are detected but not exported (only classic Comfort/Advanced).
- Compile errors in the project -> broken blocks are skipped ("inconsistent"); list them.
- Only the first PLC in a multi-PLC project is exported (blocks/tags); HMI/HW cover all devices.
- V21+ projects are not supported (V20 Openness).
