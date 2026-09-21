[CmdletBinding()]
param([ValidateSet('x64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$windowsRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $windowsRoot -Parent
$version = (Get-Content -Raw (Join-Path $repoRoot 'VERSION')).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') { throw 'Invalid VERSION.' }
$artifacts = Join-Path $windowsRoot 'artifacts'
New-Item -ItemType Directory -Force $artifacts | Out-Null
$output = Join-Path $artifacts ('publish-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $windowsRoot 'QuotaLens.Windows/QuotaLens.Windows.csproj'
try {
    & dotnet publish $project -c Release -r "win-$Architecture" --self-contained true -p:Platform=x64 -p:ContinuousIntegrationBuild=true -o $output
    if ($LASTEXITCODE -ne 0) { throw 'Windows native build failed.' }
    Copy-Item (Join-Path $repoRoot 'LICENSE') $output
    Copy-Item (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') $output
    $zip = Join-Path $artifacts "QuotaLens-Windows-$Architecture-v$version.zip"
    Compress-Archive -Path (Join-Path $output '*') -DestinationPath $zip -Force
    $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($zip + '.sha256', "$hash  $([IO.Path]::GetFileName($zip))`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Created $zip"
} finally {
    if (Test-Path $output) { Remove-Item -Recurse -Force $output }
}
