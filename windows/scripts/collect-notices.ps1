[CmdletBinding()]
param([Parameter(Mandatory)][string]$PublishDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$windowsRoot = Split-Path $PSScriptRoot -Parent
$assets = Get-Content -Raw (Join-Path $windowsRoot 'QuotaLens.Windows/obj/project.assets.json') | ConvertFrom-Json
$destination = Join-Path $PublishDirectory 'ThirdParty'
New-Item -ItemType Directory -Force $destination | Out-Null
$inventory = [Collections.Generic.List[object]]::new()
foreach ($property in $assets.libraries.PSObject.Properties) {
    $library = $property.Value
    if ($library.type -ne 'package') { continue }
    $packageRoot = $null
    foreach ($folder in $assets.packageFolders.PSObject.Properties.Name) {
        $candidate = Join-Path $folder $library.path
        if (Test-Path $candidate -PathType Container) { $packageRoot = $candidate; break }
    }
    if ($null -eq $packageRoot) { throw "Restored package not found: $($property.Name)" }
    $target = Join-Path $destination ($property.Name -replace '/', '-')
    New-Item -ItemType Directory -Force $target | Out-Null
    $documents = @(Get-ChildItem $packageRoot -Recurse -File | Where-Object {
        $_.Extension -eq '.nuspec' -or ($_.Name -match '(?i)(licen[cs]e|notice|copyright)' -and $_.Extension -in @('', '.txt', '.md', '.rtf', '.html'))
    })
    foreach ($document in $documents) {
        $relative = [IO.Path]::GetRelativePath($packageRoot, $document.FullName)
        $output = Join-Path $target $relative
        New-Item -ItemType Directory -Force (Split-Path $output -Parent) | Out-Null
        Copy-Item -LiteralPath $document.FullName -Destination $output
    }
    $inventory.Add([ordered]@{package=$property.Name; packageSha512=$library.sha512; noticeFiles=@($documents | ForEach-Object { [IO.Path]::GetRelativePath($packageRoot, $_.FullName) })})
}
if ($inventory.Count -eq 0) { throw 'The dependency inventory is empty.' }
$inventory | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $destination 'packages.json')
Write-Host "Collected package metadata and available upstream notices for $($inventory.Count) dependencies."
