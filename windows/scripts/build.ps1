[CmdletBinding()]
param([ValidateSet('x64')][string]$Architecture = 'x64', [switch]$SkipSmoke)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$windowsRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $windowsRoot -Parent
$version = (Get-Content -Raw (Join-Path $repoRoot 'VERSION')).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)?$') { throw 'Invalid VERSION.' }
$artifacts = Join-Path $windowsRoot 'artifacts'
$validation = Join-Path $windowsRoot 'validation'
New-Item -ItemType Directory -Force $artifacts, $validation | Out-Null
$output = Join-Path $artifacts ('publish-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $windowsRoot 'QuotaLens.Windows/QuotaLens.Windows.csproj'
try {
    & dotnet publish $project -c Release -r "win-$Architecture" --self-contained true -p:Platform=x64 -p:ContinuousIntegrationBuild=true -o $output
    if ($LASTEXITCODE -ne 0) { throw 'Windows native build failed.' }
    $executable = Join-Path $output 'QuotaLens.exe'
    if (!(Test-Path $executable) -or (Get-Item $executable).Length -lt 1024) { throw 'Native executable was not published.' }
    if (!$SkipSmoke) {
        Get-ChildItem $validation -File | Remove-Item -Force
        $process = Start-Process -FilePath $executable -ArgumentList @('--smoke-test', ('"' + $validation + '"')) -PassThru
        if (!$process.WaitForExit(120000)) { Stop-Process -Id $process.Id -Force; throw 'Native UI smoke test timed out.' }
        $process.Refresh()
        if (Test-Path (Join-Path $validation 'failure.txt')) { Get-Content (Join-Path $validation 'failure.txt'); throw 'Native UI smoke test reported a failure.' }
        if ($process.ExitCode -ne 0 -or !(Test-Path (Join-Path $validation 'smoke.json'))) { throw "Native UI launch failed: $($process.ExitCode)" }
        $result = Get-Content -Raw (Join-Path $validation 'smoke.json') | ConvertFrom-Json
        if ($result.passed -lt 60 -or $result.liveNetwork) { throw 'Native UI smoke coverage is incomplete.' }
        Write-Host "Native UI checks passed: $($result.passed)"
    }
    Copy-Item (Join-Path $repoRoot 'LICENSE') $output
    Copy-Item (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') $output
    $zip = Join-Path $artifacts "QuotaLens-Windows-$Architecture-v$version.zip"
    Compress-Archive -Path (Join-Path $output '*') -DestinationPath $zip -Force
    $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($zip + '.sha256', "$hash  $([IO.Path]::GetFileName($zip))`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Created $zip"
} finally { if (Test-Path $output) { Remove-Item -Recurse -Force $output } }
