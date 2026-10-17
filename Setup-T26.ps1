[CmdletBinding()]
param(
    [switch]$PreflightOnly,
    [switch]$InstallMissing,
    [string]$MockRuntimesPath
)

$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manualDotnetUrl = 'https://dotnet.microsoft.com/download/dotnet/9.0/runtime'
$manualAspNetUrl = 'https://dotnet.microsoft.com/download/dotnet/9.0'
$script:MockRuntimesPath = $MockRuntimesPath
if ($script:MockRuntimesPath -and -not (Test-Path -LiteralPath $script:MockRuntimesPath -PathType Leaf)) { throw "Mock runtime fixture missing: $script:MockRuntimesPath" }

function Read-RequiredFrameworks {
    $paths = @(
        (Join-Path $packageRoot 'Launcher\publish\Terminator.Launcher.runtimeconfig.json'),
        (Join-Path $packageRoot 'releases\standard\Terminator.App.runtimeconfig.json'),
        (Join-Path $packageRoot 'releases\standard\Terminator.Communication.runtimeconfig.json'),
        (Join-Path $packageRoot 'releases\developer\Terminator.App.runtimeconfig.json'),
        (Join-Path $packageRoot 'releases\developer\Terminator.Communication.runtimeconfig.json')
    )
    $requirements = @()
    foreach ($path in ($paths | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing runtime configuration: $path" }
        $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $options = $config.runtimeOptions
        $rollForward = if ($options.rollForward) { [string]$options.rollForward } else { 'Minor' }
        $frameworks = @()
        if ($options.framework) { $frameworks += $options.framework }
        if ($options.frameworks) { $frameworks += @($options.frameworks) }
        foreach ($framework in $frameworks) {
            $requirements += [pscustomobject]@{
                Name = [string]$framework.name
                Version = [version][string]$framework.version
                RollForward = $rollForward
                ApplyPatches = if ($null -eq $options.applyPatches) { $true } else { [bool]$options.applyPatches }
                Source = $path.Substring($packageRoot.Length).TrimStart('\')
            }
        }
    }
    return @($requirements | Group-Object Name, Version, RollForward, ApplyPatches | ForEach-Object { $_.Group[0] })
}

function Get-X64Dotnet {
    if ($script:MockRuntimesPath) { return '__MOCK_X64_DOTNET__' }
    $candidates = @()
    if ($env:DOTNET_ROOT_X64) { $candidates += (Join-Path $env:DOTNET_ROOT_X64 'dotnet.exe') }
    if ($env:ProgramW6432) { $candidates += (Join-Path $env:ProgramW6432 'dotnet\dotnet.exe') }
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $info = (& $candidate --info 2>$null | Out-String)
            $match = [regex]::Match($info, '(?im)^\s*Architecture:\s*(\S+)')
            if ($match.Success -and $match.Groups[1].Value -eq 'x64') { return $candidate }
        } catch { }
    }
    return $null
}

function Get-X64Runtimes([string]$dotnet) {
    if ($script:MockRuntimesPath) {
        $parsed = ConvertFrom-Json (Get-Content -LiteralPath $script:MockRuntimesPath -Raw)
        $raw = @($parsed)
        return @($raw | ForEach-Object { [pscustomobject]@{ Name=[string]$_.Name; Version=[version][string]$_.Version; Path=[string]$_.Path } })
    }
    $rows = @(& $dotnet --list-runtimes 2>$null)
    $result = @()
    foreach ($row in $rows) {
        $match = [regex]::Match([string]$row, '^\s*(\S+)\s+(\S+)\s+\[(.+)\]\s*$')
        if (-not $match.Success) { continue }
        $path = $match.Groups[3].Value
        if ($path -match '(?i)Program Files \(x86\)') { continue }
        $result += [pscustomobject]@{ Name=$match.Groups[1].Value; Version=[version]$match.Groups[2].Value; Path=$path }
    }
    return $result
}

function Test-Compatible($installed, $required) {
    $i = [version][string]$installed.Version
    $r = [version][string]$required.Version
    if ($required.RollForward -eq 'Disable') { return $i -eq $r }
    if ($required.RollForward -in @('LatestMajor','Major')) { return $i -ge $r }
    if ($required.RollForward -in @('LatestMinor','Minor')) { return $i.Major -eq $r.Major -and $i -ge $r }
    if ($i.Major -ne $r.Major -or $i.Minor -ne $r.Minor) { return $false }
    if ($required.ApplyPatches) { return $i -ge $r }
    return $i -eq $r
}

function Get-MissingFrameworks([object[]]$requirements, [object[]]$installed) {
    $missing = @()
    foreach ($required in $requirements) {
        $matches = @($installed | Where-Object { $_.Name -eq $required.Name -and (Test-Compatible $_ $required) })
        if ($matches.Count -eq 0) { $missing += $required }
    }
    return @($missing | Group-Object Name | ForEach-Object { $_.Group[0] })
}

function Show-Requirements($requirements, $installed, $missing) {
    Write-Host 'Required x64 .NET frameworks from packaged runtimeconfig.json files:'
    foreach ($required in $requirements) { Write-Host ("  $($required.Name) $($required.Version) (rollForward=$($required.RollForward))") }
    if ($installed.Count -gt 0) { Write-Host 'Detected compatible x64 runtimes:'; $installed | Sort-Object Name,Version | ForEach-Object { Write-Host "  $($_.Name) $($_.Version)" } }
    if ($missing.Count -gt 0) { Write-Host 'Missing:'; $missing | ForEach-Object { Write-Host "  $($_.Name) $($_.Version)" } }
}

function Install-ApprovedFrameworks($missing) {
    $packages = @()
    if ($missing.Name -contains 'Microsoft.WindowsDesktop.App') { $packages += [pscustomobject]@{ Id='Microsoft.DotNet.DesktopRuntime.9'; Name='x64 .NET 9 Desktop Runtime' } }
    if ($missing.Name -contains 'Microsoft.AspNetCore.App') { $packages += [pscustomobject]@{ Id='Microsoft.DotNet.AspNetCore.9'; Name='x64 ASP.NET Core 9 Runtime' } }
    if (($missing.Name -contains 'Microsoft.NETCore.App') -and -not ($packages.Id -contains 'Microsoft.DotNet.DesktopRuntime.9')) { $packages += [pscustomobject]@{ Id='Microsoft.DotNet.Runtime.9'; Name='x64 .NET 9 Runtime' } }
    $packages = @($packages | Sort-Object Id -Unique)
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Host "Install manually from: $manualDotnetUrl"
        Write-Host "ASP.NET Core downloads: $manualAspNetUrl"
        return $false
    }
    Write-Host 'The following official winget packages may be installed only after explicit approval:'
    $packages | ForEach-Object { Write-Host "  $($_.Name) [$($_.Id)]" }
    $approval = (Read-Host 'Type YES to request these x64 runtime installs').Trim()
    if ($approval -cne 'YES') { Write-Host 'Installation declined.'; return $false }
    foreach ($package in $packages) {
        & $winget.Source install --id $package.Id --exact --architecture x64 --source winget --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { Write-Host "winget failed for $($package.Id) with exit code $LASTEXITCODE"; return $false }
    }
    return $true
}

try {
    $requirements = @(Read-RequiredFrameworks)
    $dotnet = Get-X64Dotnet
    if (-not $dotnet) {
        Write-Host 'No x64 dotnet host was detected. An x86 host is not accepted for this package.'
        $missing = $requirements
        Show-Requirements $requirements @() $missing
        if (-not $PreflightOnly) { [void](Install-ApprovedFrameworks $missing) }
        exit 10
    }
    $installed = @(Get-X64Runtimes $dotnet)
    $missing = @(Get-MissingFrameworks -requirements $requirements -installed $installed)
    Show-Requirements $requirements $installed $missing
    if ($missing.Count -eq 0) { Write-Host 'DOTNET PREFLIGHT: READY'; exit 0 }
    if ($PreflightOnly) { exit 10 }
    if (-not (Install-ApprovedFrameworks $missing)) { exit 10 }
    $dotnet = Get-X64Dotnet
    $installed = if ($dotnet) { @(Get-X64Runtimes $dotnet) } else { @() }
    $missing = @(Get-MissingFrameworks -requirements $requirements -installed $installed)
    if ($missing.Count -eq 0) { Write-Host 'DOTNET PREFLIGHT: READY AFTER INSTALL'; exit 0 }
    Show-Requirements $requirements $installed $missing
    exit 10
} catch {
    Write-Host ('DOTNET PREFLIGHT ERROR: ' + $_.Exception.Message)
    exit 20
}
