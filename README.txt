DSLD Tools - RPR / SCH / ADIM for AutoCAD Architecture
=======================================================

WHAT YOU GET (loaded automatically in every drawing):
  RPR    - roof pitch + rafter layout with H/R/V chart   (help: RPRHELP)
  SCH    - door/window Schedule of Openings auto-fill    (help: SCHHELP)
  ADIM   - automatic plan dimensioning                   (help: ADIMHELP)
  SCHTAG - schedule-tag placer add-in used by the SCH workflow
  DSLDUPDATE - downloads the newest version of everything from GitHub
  DSLDRELOAD - reloads the LISP tools without restarting CAD

INSTALL (one time, about a minute - no admin rights needed)
  1. Right-click the zip -> Extract All... -> anywhere (Desktop is fine).
  2. Press the Windows key, type
         %appdata%\Autodesk\ApplicationPlugins
     and press Enter.  (If the folder doesn't exist, create it.)
  3. Copy the folder  DSLD-Tools.bundle  from the extracted files into
     that ApplicationPlugins folder.
  4. Restart AutoCAD Architecture.

CHECK IT WORKED
  Open any drawing - the command line shows
      [DSLD] Tools bundle v1.0.0 - RPR / SCH / ADIM loaded.
  Type RPRHELP, SCHHELP or ADIMHELP any time.

UPDATES
  Type DSLDUPDATE in any drawing - it downloads the latest versions
  from GitHub and reloads them.  (RPR also checks GitHub by itself
  when a drawing opens.)

UNINSTALL
  Delete the DSLD-Tools.bundle folder from ApplicationPlugins.

NOTES
  - If you previously set up SCH with SCHINSTALL, type SCHUNINSTALL
    once to remove the old acaddoc.lsp entry (the bundle replaces it).
  - If you previously ran SCHTAGINSTALL, type SCHTAGUNINSTALL once -
    the tag placer is included in this bundle now.
  - Source + downloads: https://github.com/ssche13/dsld-lisp-tools
