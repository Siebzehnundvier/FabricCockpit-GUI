# Build-Release.ps1 - packs exactly the files an end user needs into a zip.
# Excludes: .git, docs/ (internal specification), tools/, local settings.
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Release.ps1
param([string]$OutDir = (Join-Path $PSScriptRoot '..\release'))

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$ver  = (Select-String -Path (Join-Path $root 'Fabric-Cockpit.ps1') -Pattern "^\`$CockpitVersion = '([^']+)'").Matches[0].Groups[1].Value
$name = "FabricCockpit-GUI-$ver"
$stage = Join-Path $env:TEMP $name
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $stage 'lib') | Out-Null

$files = @('Fabric-Cockpit.ps1', 'Start-Cockpit.cmd', 'Start-Cockpit.vbs', 'README.md', 'CHANGELOG.md', 'LICENSE',
           'lib\Fabric-Common.ps1', 'lib\Fabric-Cost.ps1')
foreach ($f in $files) { Copy-Item (Join-Path $root $f) (Join-Path $stage $f) }

# refuse to ship anything that looks like a tenant/subscription id or a local path
$leak = Get-ChildItem $stage -Recurse -File | Select-String -Pattern '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[A-Z]:\\Users\\' -CaseSensitive:$false
if ($leak) { $leak | ForEach-Object { Write-Warning ("possible personal data: {0}:{1}" -f $_.Path, $_.LineNumber) }; throw 'Release aborted.' }

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$zip = Join-Path (Resolve-Path $OutDir) "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item $stage -Recurse -Force
Write-Host "Release written: $zip" -ForegroundColor Green
Get-ChildItem $zip | Select-Object Name, Length
