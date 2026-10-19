# Architecture

## Why it works this way
A TIA Portal project (`.apNN` plus its `System`, `IM`, `XRef`, ... folders) is a proprietary binary
database. The only supported way to get engineering data out is TIA Portal itself, and TIA Portal
Openness is its official automation API. So every export starts by launching TIA headless
(`TiaPortalMode.WithoutUserInterface`) and asking it to export SimaticML XML. Everything after
that is plain text processing.

## Reader pipeline (`skills/tia-reader/tools`)

| Step | Script | Notes |
|---|---|---|
| 1. copy / retrieve | `tia_read.ps1` | `.apNN`: whole folder copied to `<out>\_src` (copied `.lck` files removed). `.zapNN`: `Projects.Retrieve` into `<out>\export\_retrieved` |
| 2. open | `OpennessResolver.cs` | `Projects.Open`; on version mismatch `OpenWithUpgrade` / `RetrieveWithUpgrade` (writes an upgraded *copy*) |
| 3. compile | `OpennessResolver.cs` | `ICompilable.Compile()` on the PLC software, then `Save()` **of the copy**. Upgraded or uncompiled projects are inconsistent, and Openness refuses to export inconsistent blocks |
| 4. export | `OpennessResolver.cs` | blocks (recursive groups), system + user UDTs, technology objects (reflection walk), PLC tag tables, watch tables, alarm text lists, classic HMI targets (generic reflection walker over folders/groups), hardware via `CaxProvider` (AML) + a device/node/address walk |
| 5. render | `extract_scl.ps1`, `render_lad.py`, `stl_dump.py`, `simaticml_flat.py` | SCL token AST -> text; FlgNet -> textual LAD; STL statements -> text; tag/HMI/screen XML -> flat lists |
| 6. compare | `compare_exports.py` | diff two export trees with timestamp/GUID noise removed |

`export_tia.ps1` compiles the C# with `Add-Type` (C# 5, .NET Framework) against the V20
`Siemens.Engineering.dll` found by `tia_common.ps1` (registry first).

## Writer pipeline (`skills/tia-writer/tools`)

| Step | Script | Notes |
|---|---|---|
| check out | `tia_checkout.ps1` | robocopy share -> `TIA_WORK_ROOT`, writes `.tia_checkout.json` with a snapshot (file count, bytes, newest write time) of the source |
| source | `tia_source.ps1` | `ExternalSourceGroup.GenerateSource` from the **reader's copy**, giving full SCL/DB/UDT source to edit |
| write | `tia_write.ps1` + `TiaWriter.cs` | guards -> backup zip -> open -> import (`Blocks/Types/TagTables.Import(..., Override)` into the existing object's group, or `ExternalSources.CreateFromFile` + `GenerateBlocksFromSource`) -> compile -> `Save()` only if 0 errors, else `Close()` unsaved |
| publish | `tia_publish.ps1` | compares the share against the checkout snapshot, zips the share, `robocopy /MIR` local -> share |

## Openness gotchas worth knowing
- Openness is version-locked: the V20 API opens V20 projects; older ones only via upgrade.
- `Export()` refuses relative paths and refuses to overwrite files, so delete first.
- `PlcSoftware.TypeGroup.SystemTypeGroups` holds Siemens types only; user UDTs are in `TypeGroup.Types` + `Groups`.
- Mapped drive letters don't exist in a `runas` logon, so convert to UNC.
- The user must be in the local `Siemens TIA Openness` group, and new membership only applies after a new logon.
- PowerShell 5.1 `Add-Type` uses the C# 5 compiler, and non-ASCII characters in `.ps1` files break parsing.
