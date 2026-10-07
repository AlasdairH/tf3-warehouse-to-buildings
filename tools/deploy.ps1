# Copies the mod into the TF3 staging area (where the game loads local mods and the in-game
# Mod Manager lists them under "My Mods" for uploading to mod.io) of every Steam user on this
# machine. Use -Target mods to install it as a plain local mod instead. The copy in the other
# folder is removed, so the mod ID never exists twice.
# Adapted from Paid Warehouse Deliveries by GlcrTE (MIT).
param(
    [ValidateSet('staging_area', 'mods')]
    [string]$Target = 'staging_area',
    [string]$Userdata = 'C:\Program Files (x86)\Steam\userdata'
)
$ErrorActionPreference = 'Stop'

$modName = 'warehouse_distribution_1'
$source = Join-Path $PSScriptRoot "..\mod\$modName"
$other = if ($Target -eq 'mods') { 'staging_area' } else { 'mods' }

$locals = Get-ChildItem $Userdata -Directory | ForEach-Object { Join-Path $_.FullName '3493540\local' } | Where-Object { Test-Path $_ }
if (-not $locals) { throw "No TF3 local folder found under $Userdata" }

foreach ($local in $locals) {
    $stale = Join-Path $local "$other\$modName"
    if (Test-Path $stale) {
        Remove-Item $stale -Recurse -Force
        Write-Host "Removed $stale"
    }

    $targetDir = Join-Path $local $Target
    New-Item -ItemType Directory -Force $targetDir | Out-Null
    $dest = Join-Path $targetDir $modName
    # keep the mod.io link the game writes on the first upload
    $fileId = Join-Path $dest '_metadata\mod.io_fileid.txt'
    $sourceFileId = Join-Path $source '_metadata\mod.io_fileid.txt'
    if ((Test-Path $fileId) -and -not (Test-Path $sourceFileId)) {
        Copy-Item $fileId $sourceFileId
        Write-Host "Adopted $sourceFileId from the game; commit it"
    }
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Copy-Item $source $dest -Recurse
    Write-Host "Deployed to $dest"
}
