# rebuild.ps1 - refresh the DSLD-Tools distribution from the master LISP
# files, re-zip for email, reinstall locally, and push to GitHub so
# DSLDUPDATE / RPRUPDATE / SCHUPDATE serve the new code.
#
# Run after editing any master:
#   powershell -ExecutionPolicy Bypass -File E:\DSLD-Tools\rebuild.ps1

$ErrorActionPreference = "Stop"
$root     = "E:\DSLD-Tools"
$contents = Join-Path $root "DSLD-Tools.bundle\Contents"

# 1. masters -> bundle
Copy-Item "E:\Megans RPR lisp\roof-pitch-rafters.lsp" $contents -Force
Copy-Item "E:\Megans lisp routines\SCH.lsp"           $contents -Force
Copy-Item "E:\ADIM lisp\ADIM.lsp"                     $contents -Force

# SchTagNet (.NET schedule-tag add-in) - released builds live in the
# dev bundle next to SCH.lsp
$schtag = "E:\Megans lisp routines\SchTagNet.bundle\Contents"
Copy-Item "$schtag\SchTagNet.dll"                     $contents -Force
Copy-Item "$schtag\SchTagNet.deps.json"               $contents -Force
Copy-Item "$schtag\SchTagNet.runtimeconfig.json"      $contents -Force

# 2. re-zip the EMAIL FALLBACK - LISP-only on purpose. Mail filters
#    (Gmail and most corporate gateways) block .dll even inside
#    archives, so SchTagNet is deliberately excluded here; it reaches
#    zip-installed machines via their first DSLDUPDATE instead.
#    GitHub is the only channel that carries the binaries.
$zip = Join-Path $root "DSLD-Tools.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
$stage = Join-Path $env:TEMP "DSLD-Tools-zipstage"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory "$stage\DSLD-Tools.bundle\Contents" -Force | Out-Null
Copy-Item (Join-Path $root "DSLD-Tools.bundle\PackageContents.xml") "$stage\DSLD-Tools.bundle\"
Copy-Item (Join-Path $root "DSLD-Tools.bundle\Contents\*.lsp") "$stage\DSLD-Tools.bundle\Contents\"
Copy-Item (Join-Path $root "README.txt") $stage
Compress-Archive -Path "$stage\DSLD-Tools.bundle", "$stage\README.txt" -DestinationPath $zip
Remove-Item $stage -Recurse -Force

# 3. refresh the local install
$dest = Join-Path $env:APPDATA "Autodesk\ApplicationPlugins"
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force $dest | Out-Null }
Copy-Item (Join-Path $root "DSLD-Tools.bundle") $dest -Recurse -Force

# 4. publish to GitHub (only when something actually changed)
git -C $root add -A
git -C $root diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    git -C $root commit -m "Refresh distribution from masters"
    git -C $root push
    Write-Host "DSLD-Tools rebuilt, zipped, reinstalled locally, and pushed."
} else {
    Write-Host "DSLD-Tools rebuilt and reinstalled locally - no source changes to push."
}
