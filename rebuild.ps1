# rebuild.ps1 - refresh the DSLD-Tools distribution from the master LISP
# files, re-zip for email, reinstall locally, and push to GitHub so
# DSLDUPDATE / RPRUPDATE / SCHUPDATE serve the new code.
#
# Run after editing any master:
#   powershell -ExecutionPolicy Bypass -File E:\DSLD-Tools\rebuild.ps1
#
# SchTagNet GUARD: the dev bundle can hold an UNTESTED build (the SCH
# chat holds DLLs until regression passes), so a changed DLL is NOT
# shipped unless you explicitly opt in:
#   ... rebuild.ps1 -ShipSchTagNet
param([switch]$ShipSchTagNet)

$ErrorActionPreference = "Stop"
$root     = "E:\DSLD-Tools"
$contents = Join-Path $root "DSLD-Tools.bundle\Contents"

# 1. masters -> bundle
Copy-Item "E:\Megans RPR lisp\roof-pitch-rafters.lsp" $contents -Force
Copy-Item "E:\Megans lisp routines\SCH.lsp"           $contents -Force
Copy-Item "E:\ADIM lisp\ADIM.lsp"                     $contents -Force

# SchTagNet (.NET schedule-tag add-in) - dev builds ship only on
# explicit request (see guard note above)
$schtag = "E:\Megans lisp routines\SchTagNet.bundle\Contents"
$devDll = Join-Path $schtag "SchTagNet.dll"
$repoDll = Join-Path $contents "SchTagNet.dll"
$dllChanged = (Get-FileHash $devDll -Algorithm MD5).Hash -ne (Get-FileHash $repoDll -Algorithm MD5).Hash
if ($dllChanged -and -not $ShipSchTagNet) {
    Write-Host "NOTE: dev SchTagNet.dll differs from the shipped copy - NOT shipping it." -ForegroundColor Yellow
    Write-Host "      Rerun with -ShipSchTagNet once it has passed regression." -ForegroundColor Yellow
} elseif ($dllChanged) {
    Copy-Item $devDll                                 $contents -Force
    Copy-Item "$schtag\SchTagNet.deps.json"           $contents -Force
    Copy-Item "$schtag\SchTagNet.runtimeconfig.json"  $contents -Force
    Write-Host "Shipping updated SchTagNet build (2027)."
}

# The 2026 build (net8.0) - separate project, same source. Ships under
# the same guard: AutoCAD 2027 hosts .NET 10 and 2026 hosts .NET 8, so
# a seat can only run one of the two and the loader picks by ACADVER.
$schtag26 = "E:\Megans lisp routines\SchTagNet2026\bin\Release"
$dev26    = Join-Path $schtag26 "SchTagNet-2026.dll"
$repo26   = Join-Path $contents "SchTagNet-2026.dll"
if (Test-Path $dev26) {
    $changed26 = -not (Test-Path $repo26) -or
                 (Get-FileHash $dev26 -Algorithm MD5).Hash -ne (Get-FileHash $repo26 -Algorithm MD5).Hash
    if ($changed26 -and -not $ShipSchTagNet) {
        Write-Host "NOTE: dev SchTagNet-2026.dll differs from the shipped copy - NOT shipping it." -ForegroundColor Yellow
        Write-Host "      Rerun with -ShipSchTagNet once it has passed regression." -ForegroundColor Yellow
    } elseif ($changed26) {
        Copy-Item $dev26                                     $contents -Force
        Copy-Item "$schtag26\SchTagNet-2026.deps.json"       $contents -Force
        Copy-Item "$schtag26\SchTagNet-2026.runtimeconfig.json" $contents -Force
        Write-Host "Shipping updated SchTagNet build (2026)."
    }
}

# 2. release stamp - every drafter's loader GETs this tiny file once
#    per session and self-runs DSLDUPDATE when it changes.  Content
#    hash (not a timestamp) so a rebuild that changes nothing does not
#    make every seat re-download.
$stampSrc = @(
    (Join-Path $contents "DSLD-Loader.lsp"),
    (Join-Path $contents "roof-pitch-rafters.lsp"),
    (Join-Path $contents "SCH.lsp"),
    (Join-Path $contents "ADIM.lsp"),
    (Join-Path $contents "SchTagNet.dll"),
    (Join-Path $root "DSLD-Tools.bundle\PackageContents.xml")
)
# the 2026 build joins the stamp only once it exists in the bundle
$dll26 = Join-Path $contents "SchTagNet-2026.dll"
if (Test-Path $dll26) { $stampSrc += $dll26 }
$concat = ($stampSrc | ForEach-Object { (Get-FileHash $_ -Algorithm MD5).Hash }) -join ""
$md5 = [System.Security.Cryptography.MD5]::Create()
$stamp = ([System.BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::ASCII.GetBytes($concat))) -replace '-','')
Set-Content -Path (Join-Path $contents "release.txt") -Value $stamp -Encoding Ascii

# 3. re-zip the EMAIL FALLBACK - LISP-only on purpose. Mail filters
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

# 4. refresh the local install
$dest = Join-Path $env:APPDATA "Autodesk\ApplicationPlugins"
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force $dest | Out-Null }
Copy-Item (Join-Path $root "DSLD-Tools.bundle") $dest -Recurse -Force

# 5. publish to GitHub (only when something actually changed)
git -C $root add -A
git -C $root diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    git -C $root commit -m "Refresh distribution from masters"
    git -C $root push
    Write-Host "DSLD-Tools rebuilt, zipped, reinstalled locally, and pushed."
} else {
    Write-Host "DSLD-Tools rebuilt and reinstalled locally - no source changes to push."
}
