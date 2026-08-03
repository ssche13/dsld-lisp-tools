# DSLD Tools

Distribution package for the DSLD office AutoLISP tools for AutoCAD
Architecture:

| Command family | File | What it does |
|---|---|---|
| `RPR...` | `roof-pitch-rafters.lsp` | Roof pitch + rafter layout with H/R/V chart, live grip-edit mode (`RPRHELP`) |
| `SCH...` | `SCH.lsp` | Door/window Schedule of Openings auto-fill from ACA objects (`SCHHELP`) |
| `ADIM...` | `ADIM.lsp` | Automatic plan dimensioning (`ADIMHELP`) |

## Install (drafter machine)

1. Download `DSLD-Tools.zip` (emailed) **or** Code → Download ZIP here.
2. Extract, then copy the `DSLD-Tools.bundle` folder into
   `%APPDATA%\Autodesk\ApplicationPlugins` (create the folder if missing).
3. Restart AutoCAD Architecture. The tools now load in every drawing —
   the command line shows `[DSLD] Tools bundle ... loaded.`

No admin rights, no support-path setup, no APPLOAD.

## Updates

- `DSLDUPDATE` in any drawing pulls the latest copy of all three
  routines from this repo and reloads them (old copies kept as `.bak`).
- RPR also auto-checks this repo each time a drawing opens.

## Layout

```
DSLD-Tools.bundle/
  PackageContents.xml        AutoCAD plug-in AutoLoader manifest
  Contents/
    DSLD-Loader.lsp          loads the three routines per drawing,
                             defines DSLDUPDATE / DSLDRELOAD
    roof-pitch-rafters.lsp
    SCH.lsp
    ADIM.lsp
```

## Maintainer notes (dev machine)

The master sources live outside this repo:

- `E:\Megans RPR lisp\roof-pitch-rafters.lsp`
- `E:\Megans lisp routines\SCH.lsp`
- `E:\ADIM lisp\ADIM.lsp`

After editing a master, run `rebuild.ps1` — it copies the masters into
the bundle, re-zips `DSLD-Tools.zip` for email, refreshes the local
install in ApplicationPlugins, and commits + pushes here so
`DSLDUPDATE` / `RPRUPDATE` / `SCHUPDATE` serve the new code.

**Push promptly after editing a master**: RPR's load-time auto-update
compares against this repo, so a stale repo means drafters keep old
code (and the bundle's own copy can be rolled back on next load).
