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
    & (Join-Path $PSScriptRoot 'export-icon.ps1')
    & dotnet publish $project -c Release -r "win-$Architecture" --self-contained true -p:Platform=x64 -p:ContinuousIntegrationBuild=true -o $output
    if ($LASTEXITCODE -ne 0) { throw 'Windows native build failed.' }
    $executable = Join-Path $output 'QuotaLens.exe'
    if (!(Test-Path $executable) -or (Get-Item $executable).Length -lt 1024) { throw 'Native executable was not published.' }
    if (!(Test-Path (Join-Path $output 'Assets/AppIcon.ico'))) { throw 'Application artwork was not published.' }
    if (!$SkipSmoke) {
        Get-ChildItem $validation -File | Remove-Item -Force
        $started = Get-Date
        $process = Start-Process -FilePath $executable -ArgumentList @('--smoke-test', ('"' + $validation + '"')) -PassThru
        if (!$process.WaitForExit(120000)) { Stop-Process -Id $process.Id -Force; throw 'Native UI smoke test timed out.' }
        $process.Refresh()
        if (Test-Path (Join-Path $validation 'startup.log')) { Get-Content (Join-Path $validation 'startup.log') }
        if ($process.ExitCode -ne 0) {
            Get-ChildItem (Join-Path $windowsRoot 'QuotaLens.Windows/obj') -Recurse -Filter 'App.g*.cs' | ForEach-Object { Get-Content $_.FullName } | Out-File (Join-Path $validation 'generated-app.txt')
            Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$started; Id=1000,1026} -ErrorAction SilentlyContinue |
                Where-Object { $_.Message -match 'QuotaLens' } | Format-List TimeCreated,Id,Message | Out-File (Join-Path $validation 'native-launch-events.txt')
            Get-Content (Join-Path $validation 'native-launch-events.txt') -ErrorAction SilentlyContinue
        }
        if (Test-Path (Join-Path $validation 'failure.txt')) { Get-Content (Join-Path $validation 'failure.txt'); throw 'Native UI smoke test reported a failure.' }
        if ($process.ExitCode -ne 0 -or !(Test-Path (Join-Path $validation 'smoke.json'))) { throw "Native UI launch failed: $($process.ExitCode)" }
        $result = Get-Content -Raw (Join-Path $validation 'smoke.json') | ConvertFrom-Json
        if ($result.passed -lt 60 -or $result.liveNetwork) { throw 'Native UI smoke coverage is incomplete.' }
        Write-Host "Native UI checks passed: $($result.passed)"
    }
    Copy-Item (Join-Path $repoRoot 'LICENSE') $output
    Copy-Item (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') $output
    Copy-Item (Join-Path $repoRoot 'docs/windows.md') (Join-Path $output 'WINDOWS-GUIDE.md')
    Copy-Item (Join-Path $repoRoot 'docs/windows.zh-CN.md') (Join-Path $output 'WINDOWS-GUIDE.zh-CN.md')
    & (Join-Path $PSScriptRoot 'collect-notices.ps1') -PublishDirectory $output
    $sourceCommit = (& git -C $repoRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $sourceCommit = 'unknown-source-archive' }
    $checks = if ($SkipSmoke) { 0 } else { $result.passed }
    [ordered]@{version=$version; architecture=$Architecture; sourceCommit=$sourceCommit;
        builtAtUtc=[DateTimeOffset]::UtcNow.ToString('O'); signed=$false;
        isolatedUiChecks=$checks; liveProviderValidation=$false} | ConvertTo-Json |
        Set-Content -Encoding utf8 (Join-Path $output 'BUILD-INFO.json')
    $zip = Join-Path $artifacts "QuotaLens-Windows-$Architecture-v$version.zip"
    Compress-Archive -Path (Join-Path $output '*') -DestinationPath $zip -Force
    $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($zip + '.sha256', "$hash  $([IO.Path]::GetFileName($zip))`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Created $zip"
} finally { if (Test-Path $output) { Remove-Item -Recurse -Force $output } }
