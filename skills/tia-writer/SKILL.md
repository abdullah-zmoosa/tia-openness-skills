---
name: tia-writer
description: Use ONLY when the user explicitly asks to change, edit, add, fix or write code/data INTO a Siemens TIA Portal project (blocks, SCL, ladder constants, DB start values, tags, UDTs) - e.g. "change the upper limit in FC_Tension to 50", "add this FB to the project" - or to check out / publish a TIA project between a shared drive and the local work area. Works on a local copy, compiles, saves only if clean, with backup. For reading/reviewing/comparing use tia-reader instead.
---

# TIA Writer

Writes changes into a TIA Portal **V20** project: SCL blocks, LAD/FBD blocks (via XML), DBs, UDTs,
PLC tag tables. Always on a **local copy**; the shared drive is updated only by an explicit publish.
Reading is `tia-reader` (load it too - this skill uses its exports).

`<skill>` = this skill's base directory (shown when the skill loads). Paths auto-detected
(`tools\tia_common.ps1`); overrides: `TIA_WORK_ROOT` (local work area, default `C:\TIA_Work`),
`TIA_EXPORT_ROOT` (default `%USERPROFILE%\TIA_Exports`), `TIA_OPENNESS_DLL`, and folder rules
`TIA_REQUIRE_SEGMENT` (e.g. `Working`: only paths containing `\Working\`), `TIA_PROTECTED_SEGMENTS`
(default `Master;Archive`: never written), `TIA_MIRROR_ANCHOR` (checkout mirrors below this folder).

## Hard rules (the scripts enforce most of them - do not work around them)
- **Explicit request only.** Never write because it "would help". Restate the exact change, get a yes.
- **Local first:** writes go only into the local work area (`TIA_WORK_ROOT`); shared-drive paths are
  refused. The share is updated only by `tia_publish.ps1`, only when the user says to publish.
- **Folder rules:** paths under protected folders (`TIA_PROTECTED_SEGMENTS`, default Master/Archive)
  are refused; if `TIA_REQUIRE_SEGMENT` is set, only paths containing it are accepted.
- **`.ap20` only** - older projects: the user upgrades in TIA first (no silent upgrade on write).
- **No safety (F_) or know-how-protected blocks.** Refused.
- **Never download to a PLC.** The user reviews in TIA and downloads.
- **Project closed in TIA** during a write or publish.
- Backup: the project folder is zipped to `<TIA_EXPORT_ROOT>\_backups\` before every write and
  before every publish.
- Saved **only** if every import succeeds AND compile has 0 errors; otherwise closed unsaved.
- If the user/team has version-control rules (version numbers, changelog, block header comments),
  follow them - check memory. Sign entries with the user's initials (ask once if unknown).

## Workflow
1. **Confirm** the project, the change, and the version it belongs to. Openness group check:
   `(whoami /groups) -match 'Siemens TIA Openness'` - if missing, the user must sign out/in (or use
   runas as in tia-reader) before writes can run.
2. **Check out** if there is no local copy yet:
   ```
   powershell -ExecutionPolicy Bypass -File "<skill>\tools\tia_checkout.ps1" -Source "<share>\...\<project folder>"
   ```
   Mirrors into `TIA_WORK_ROOT` (path below the drive/share root, or below `TIA_MIRROR_ANCHOR`).
   If a local copy exists, keep using it (may hold unpublished work); never `-Force` without asking.
3. **Fresh export** of the LOCAL project with tia-reader (the "before" picture).
4. **Prepare the edit** in `<export>\edit\` (never edit files in `export\` itself):
   - **SCL block / DB / UDT** -> generate full source from the reader copy, then edit it:
     ```
     powershell -ExecutionPolicy Bypass -File "<skill>\tools\tia_source.ps1" -Export "<reader export folder>" -Blocks "FB_Name","DB_Name"
     ```
     Do NOT import the reader's body-only `.scl`.
   - **LAD/FBD block** -> copy `export\blocks\<Block>.xml` to `edit\`, make the minimal change
     (e.g. a `<ConstantValue>`), keep IDs/structure. Big ladder rewrites: faster in TIA - say so.
   - **Tag table** -> copy `export\tags\<Table>.xml`, edit.
   - **New block** -> full SCL source (`FUNCTION_BLOCK "Name" ... END_FUNCTION_BLOCK`) + `-Group "A/B"`.
5. **Dry run** (imports + compile, never saves):
   ```
   powershell -ExecutionPolicy Bypass -File "<skill>\tools\tia_write.ps1" -Project "<local project folder>" -Files "<edit\a.scl>","<edit\b.xml>" -DryRun
   ```
   Fix compile errors, repeat until clean.
6. **Real run:** same without `-DryRun`, after the user's go-ahead. Exit 0 = saved.
   Log: `<TIA_EXPORT_ROOT>\_write_<stamp>.log`.
7. **Verify:** re-export the local project with tia-reader, diff against step 3. Report exactly
   which blocks changed and that nothing else did.
8. **Hand over:** changelog / header text if they use one; remind: review in TIA, compile, test.
9. **Publish** only when the user says so (TIA closed on both copies):
   ```
   powershell -ExecutionPolicy Bypass -File "<skill>\tools\tia_publish.ps1" -Local "<local project folder>" -Check
   ```
   `-Check` only reports. Then without `-Check`: refuses if the share changed since checkout
   (someone else saved - show the user; `-Force` only with their OK), zips the share copy to
   `_backups`, mirrors local -> share.

## Exit codes (tia_write.ps1)
0 saved | 1 not saved (compile errors or dry run) | 2 an import failed (nothing saved) | 3 refused/error before import

## Gotchas
- Block import goes into the existing block's group (replace), or `-Group "A/B"` (created if missing) for new ones.
- Generating from an SCL source replaces the existing block of the same name.
- Instance DBs follow their FB: if the FB interface changes, compile re-generates/flags them.
- Renamed tags/blocks break references - check compile output.
- Restore = unzip the `_backups` zip over the project folder (TIA closed).
