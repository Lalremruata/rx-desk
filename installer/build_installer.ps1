# Builds the Windows release and wraps it in an Inno Setup installer.
# Usage (from repo root):  powershell -ExecutionPolicy Bypass -File installer\build_installer.ps1 [-SkipBuild]
param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

# pubspec "version: 1.2.3+4" -> "1.2.3"
$version = ((Select-String pubspec.yaml -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value -split '\+')[0]

if (-not $SkipBuild) {
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }
}

$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
  $iscc = Get-ChildItem "$env:ProgramFiles\Inno Setup*\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup*\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup*\ISCC.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $iscc) { throw 'ISCC.exe not found. Install Inno Setup: winget install JRSoftware.InnoSetup.7' }

# VC++ runtime redistributable (the app imports MSVCP140/VCRUNTIME140). Take the newest
# one shipped with Visual Studio; its version becomes the installer's minimum.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsRoots = @()
if (Test-Path $vswhere) { $vsRoots = & $vswhere -products * -property installationPath }
if (-not $vsRoots) { $vsRoots = Get-ChildItem "$env:ProgramFiles\Microsoft Visual Studio\*\*" -Directory | Select-Object -ExpandProperty FullName }
$redist = $vsRoots | ForEach-Object { Get-ChildItem "$_\VC\Redist\MSVC" -Recurse -Filter vc_redist.x64.exe -ErrorAction SilentlyContinue } |
  Sort-Object { [version]$_.VersionInfo.ProductVersion } -Descending | Select-Object -First 1
if (-not $redist) { throw 'vc_redist.x64.exe not found. Install the "Desktop development with C++" workload in Visual Studio.' }
$rv = [version]$redist.VersionInfo.ProductVersion
Write-Host "Bundling $($redist.FullName) ($rv)"

& $iscc "/DAppVersion=$version" "/DVCRedist=$($redist.FullName)" `
  "/DVCRedistMinMajor=$($rv.Major)" "/DVCRedistMinMinor=$($rv.Minor)" "/DVCRedistMinBld=$($rv.Build)" `
  "$PSScriptRoot\rxdesk.iss"
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compile failed' }
Write-Host "Installer: $root\build\installer\RxDesk-Setup-$version.exe"
