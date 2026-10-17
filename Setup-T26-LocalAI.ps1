param(
    [string]$OllamaEndpoint = 'http://127.0.0.1:11434'
)

$ErrorActionPreference = 'Stop'
$catalogSource = 'https://ollama.com/library/qwen3'

# These are the Qwen3 tags already supported by T26's local model catalog.
# Sizes are the current Ollama catalog listings, not guaranteed download byte counts.
$catalog = @(
    [pscustomobject]@{ Tier='LIGHT'; Tag='qwen3:1.7b'; Name='Qwen 3 1.7B'; Size='1.4 GB'; SizeGb=1.4; MinRamMb=4096; RecommendedRamMb=6144; MinVramMb=$null; CpuOnly=$true; Vendors=@(); Purpose='General conversation and lightweight planning' },
    [pscustomobject]@{ Tier='BALANCED'; Tag='qwen3:4b'; Name='Qwen 3 4B'; Size='2.5 GB'; SizeGb=2.5; MinRamMb=8192; RecommendedRamMb=12288; MinVramMb=$null; CpuOnly=$true; Vendors=@(); Purpose='General conversation and practical coding assistance' },
    [pscustomobject]@{ Tier='BALANCED'; Tag='qwen3:8b'; Name='Qwen 3 8B'; Size='5.2 GB'; SizeGb=5.2; MinRamMb=12288; RecommendedRamMb=16384; MinVramMb=6144; CpuOnly=$true; Vendors=@('NVIDIA','AMD','Intel'); Purpose='Best practical general-use and coding balance' },
    [pscustomobject]@{ Tier='ADVANCED'; Tag='qwen3:14b'; Name='Qwen 3 14B'; Size='9.3 GB'; SizeGb=9.3; MinRamMb=16384; RecommendedRamMb=32768; MinVramMb=8192; CpuOnly=$true; Vendors=@('NVIDIA','AMD','Intel'); Purpose='More capable reasoning and programming' },
    [pscustomobject]@{ Tier='ADVANCED'; Tag='qwen3:32b'; Name='Qwen 3 32B'; Size='20 GB'; SizeGb=20; MinRamMb=32768; RecommendedRamMb=65536; MinVramMb=16384; CpuOnly=$false; Vendors=@('NVIDIA','AMD'); Purpose='Highest supported local reasoning tier in this catalog' }
)

function Get-NvidiaAdapters {
    $command = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($null -eq $command) { return @() }
    try {
        $rows = @(& $command.Source '--query-gpu=name,memory.total' '--format=csv,noheader,nounits' 2>$null)
        $result = @()
        foreach ($row in $rows) {
            $parts = $row -split ',', 2
            if ($parts.Count -ne 2) { continue }
            $memory = 0L
            if ([long]::TryParse($parts[1].Trim(), [ref]$memory)) {
                $result += [pscustomobject]@{ Vendor='NVIDIA'; Model=$parts[0].Trim(); VramMb=$memory; VramSource='nvidia-smi'; Backend='CUDA' }
            }
        }
        return $result
    } catch { return @() }
}

function Get-HardwareProfile {
    $processor = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
    $ramMb = if ($null -ne $computer -and $computer.TotalPhysicalMemory) { [math]::Floor([double]$computer.TotalPhysicalMemory / 1MB) } else { $null }
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } elseif ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE } else { 'UNKNOWN' }
    $nvidia = @(Get-NvidiaAdapters)
    $video = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    $gpus = @()
    foreach ($item in $video) {
        $name = [string]$item.Name
        $compat = [string]$item.AdapterCompatibility
        $vendor = if ($name -match 'NVIDIA' -or $compat -match 'NVIDIA') { 'NVIDIA' } elseif ($name -match 'AMD|Radeon' -or $compat -match 'AMD|ATI') { 'AMD' } elseif ($name -match 'Intel' -or $compat -match 'Intel') { 'Intel' } else { 'UNKNOWN' }
        $nvidiaMatch = $nvidia | Where-Object { $_.Model -and $name -and ($name -like "*$($_.Model)*" -or $_.Model -like "*$name*") } | Select-Object -First 1
        $gpus += [pscustomobject]@{
            Vendor=$vendor
            Model=if ($name) { $name } else { 'UNKNOWN' }
            VramMb=if ($null -ne $nvidiaMatch) { $nvidiaMatch.VramMb } else { $null }
            VramSource=if ($null -ne $nvidiaMatch) { 'nvidia-smi' } else { 'UNKNOWN' }
            Backend=if ($vendor -eq 'NVIDIA') { 'CUDA if available' } elseif ($vendor -eq 'AMD') { 'Ollama-supported GPU/offload depends on local runtime' } elseif ($vendor -eq 'Intel') { 'Ollama-supported GPU/offload depends on local runtime' } else { 'UNKNOWN' }
        }
    }
    $root = [IO.Path]::GetPathRoot($PSScriptRoot)
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($root.TrimEnd('\'))'" -ErrorAction SilentlyContinue | Select-Object -First 1
    [pscustomobject]@{
        CpuModel=if ($null -ne $processor) { [string]$processor.Name } else { 'UNKNOWN' }
        CpuArchitecture=$arch
        RamMb=$ramMb
        Gpus=$gpus
        FreeDiskMb=if ($null -ne $disk) { [math]::Floor([double]$disk.FreeSpace / 1MB) } else { $null }
        DiskRoot=$root
    }
}

function Get-OllamaState([string]$endpoint) {
    $command = Get-Command ollama -ErrorAction SilentlyContinue
    $reachable = $false
    $models = @()
    $errorText = $null
    try {
        $reply = Invoke-RestMethod -Uri ($endpoint.TrimEnd('/') + '/api/tags') -Method Get -TimeoutSec 3
        $reachable = $true
        if ($reply.models) { $models = @($reply.models | ForEach-Object { [string]$_.name } | Where-Object { $_ }) }
    } catch { $errorText = $_.Exception.GetType().Name }
    [pscustomobject]@{ Installed=($null -ne $command); Command=if ($null -ne $command) { $command.Source } else { $null }; Reachable=$reachable; Models=$models; Error=$errorText }
}

function Get-Fit($hardware, $profile) {
    if ($null -eq $hardware.RamMb -or $hardware.RamMb -lt $profile.MinRamMb) { return [pscustomobject]@{ Fits=$false; Backend='UNAVAILABLE'; Reason="Requires at least $($profile.MinRamMb) MB system RAM." } }
    $matchingGpu = $hardware.Gpus | Where-Object { $_.Vendor -in $profile.Vendors } | Sort-Object VramMb -Descending | Select-Object -First 1
    if ($null -ne $profile.MinVramMb) {
        if ($null -ne $matchingGpu -and $null -ne $matchingGpu.VramMb -and $matchingGpu.VramMb -ge $profile.MinVramMb) {
            return [pscustomobject]@{ Fits=$true; Backend=$matchingGpu.Backend; Reason="Compatible GPU memory is confirmed by $($matchingGpu.VramSource)." }
        }
        if ($profile.CpuOnly -and $hardware.RamMb -ge ($profile.RecommendedRamMb + 4096)) {
            return [pscustomobject]@{ Fits=$true; Backend='CPU/OFFLOAD'; Reason='CPU fallback is supported; expect slower generation without confirmed dedicated VRAM.' }
        }
        if ($null -ne $matchingGpu -and $null -eq $matchingGpu.VramMb) { return [pscustomobject]@{ Fits=$false; Backend='UNKNOWN'; Reason='Dedicated VRAM is UNKNOWN; no safe GPU recommendation was made.' } }
        return [pscustomobject]@{ Fits=$false; Backend='UNAVAILABLE'; Reason="Requires at least $($profile.MinVramMb) MB compatible VRAM or a supported CPU fallback." }
    }
    $backend = if ($null -ne $matchingGpu) { $matchingGpu.Backend } else { 'CPU' }
    [pscustomobject]@{ Fits=$true; Backend=$backend; Reason='CPU-compatible profile; GPU offload is optional.' }
}

function Select-Recommendations($hardware) {
    $fit = @{}
    foreach ($profile in $catalog) { $fit[$profile.Tag] = Get-Fit $hardware $profile }
    $light = $catalog | Where-Object Tier -eq 'LIGHT' | Where-Object { $fit[$_.Tag].Fits } | Select-Object -First 1
    $balanced = @('qwen3:8b','qwen3:4b','qwen3:1.7b') | ForEach-Object { $catalog | Where-Object Tag -eq $_ } | Where-Object { $fit[$_.Tag].Fits } | Select-Object -First 1
    $advanced = @('qwen3:32b','qwen3:14b') | ForEach-Object { $catalog | Where-Object Tag -eq $_ } | Where-Object { $fit[$_.Tag].Fits } | Select-Object -First 1
    @($light,$balanced,$advanced) | Where-Object { $null -ne $_ } | Sort-Object Tier,Tag -Unique | ForEach-Object { [pscustomobject]@{ Profile=$_; Fit=$fit[$_.Tag] } }
}

function Show-Hardware($hardware) {
    Write-Host "CPU: $($hardware.CpuModel)"
    Write-Host "Architecture: $($hardware.CpuArchitecture)"
    Write-Host ("System RAM: " + $(if ($null -ne $hardware.RamMb) { "$($hardware.RamMb) MB" } else { 'UNKNOWN' }))
    Write-Host ("Free disk ($($hardware.DiskRoot)): " + $(if ($null -ne $hardware.FreeDiskMb) { "$($hardware.FreeDiskMb) MB" } else { 'UNKNOWN' }))
    if ($hardware.Gpus.Count -eq 0) { Write-Host 'GPU: CPU-only or no GPU discovered' }
    foreach ($gpu in $hardware.Gpus) { Write-Host ("GPU: $($gpu.Vendor) $($gpu.Model); VRAM=" + $(if ($null -ne $gpu.VramMb) { "$($gpu.VramMb) MB ($($gpu.VramSource))" } else { 'UNKNOWN' })) }
}

Write-Host 'T26 optional local-AI setup assistant'
Write-Host "Model catalog source: $catalogSource"
$hardware = Get-HardwareProfile
Show-Hardware $hardware
$runtime = Get-OllamaState $OllamaEndpoint
Write-Host ("Ollama installed: $($runtime.Installed); server: " + $(if ($runtime.Reachable) { 'HEALTHY' } else { 'UNAVAILABLE' }))
if ($runtime.Models.Count -gt 0) { Write-Host ('Installed models: ' + ($runtime.Models -join ', ')) }

if (-not $runtime.Installed) {
    Write-Host 'Ollama is not installed. Install it from https://ollama.com/download/windows, then rerun this assistant.'
    Write-Host 'No software or model was installed by this run.'
    exit 0
}

$recommendations = @(Select-Recommendations $hardware)
if ($recommendations.Count -eq 0) {
    Write-Host 'No conservative compatible recommendation could be established from the detected hardware.'
    Write-Host 'RESULT: UNAVAILABLE'
    exit 0
}
Write-Host ''
Write-Host 'Recommendations (choose a number, or S to skip):'
for ($i = 0; $i -lt $recommendations.Count; $i++) {
    $r = $recommendations[$i]; $installed = $runtime.Models -contains $r.Profile.Tag
    Write-Host ("[$($i + 1)] $($r.Profile.Tier) - $($r.Profile.Name) [$($r.Profile.Tag)]$($(if($installed){' [INSTALLED]'}else{''}))")
    Write-Host ("    Purpose: $($r.Profile.Purpose); listed size: $($r.Profile.Size); backend: $($r.Fit.Backend)")
    Write-Host ("    $($r.Fit.Reason)")
}
$choice = (Read-Host 'Select a model or S to skip').Trim()
if ($choice -match '^[Ss]$') { Write-Host 'RESULT: SKIPPED'; exit 0 }
if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $recommendations.Count) { Write-Host 'RESULT: UNAVAILABLE (invalid selection)'; exit 0 }
$selected = $recommendations[$index - 1].Profile
$alreadyInstalled = $runtime.Models -contains $selected.Tag
if (-not $alreadyInstalled) {
    $freeGb = if ($null -ne $hardware.FreeDiskMb) { $hardware.FreeDiskMb / 1024 } else { $null }
    $requiredGb = [math]::Ceiling($selected.SizeGb * 1.2 + 2)
    if ($null -eq $freeGb -or $freeGb -lt $requiredGb) { Write-Host "RESULT: BLOCKED (need approximately $requiredGb GB free including safety headroom)"; exit 0 }
    $approve = (Read-Host "Pull $($selected.Tag) ($($selected.Size) listed size) now? Type YES to approve").Trim()
    if ($approve -cne 'YES') { Write-Host 'RESULT: SKIPPED'; exit 0 }
    if (-not $runtime.Reachable) { Write-Host 'Ollama server is unavailable; start it and rerun. RESULT: UNAVAILABLE'; exit 0 }
    if (-not $runtime.Command) { Write-Host "Ollama API is reachable, but the ollama CLI was not discovered. Run 'ollama pull $($selected.Tag)' in the supported Ollama installation, then rerun. RESULT: UNAVAILABLE"; exit 0 }
    & $runtime.Command pull $selected.Tag
}

$after = Get-OllamaState $OllamaEndpoint
if (-not $after.Reachable -or $after.Models -notcontains $selected.Tag) { Write-Host 'RESULT: PARTIAL (model installation could not be confirmed)'; exit 0 }
$probe = (Read-Host 'Run one minimal local inference probe? Type YES to approve, or press Enter to skip').Trim()
if ($probe -cne 'YES') { Write-Host "Model $($selected.Tag) is installed and Ollama is reachable. RESULT: PARTIAL (inference not tested)"; exit 0 }
try {
    $body = @{ model=$selected.Tag; prompt='Reply with OK.'; stream=$false; think=$false; options=@{ num_predict=8 } } | ConvertTo-Json -Depth 4
    $result = Invoke-RestMethod -Uri ($OllamaEndpoint.TrimEnd('/') + '/api/generate') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 45
    if ([string]::IsNullOrWhiteSpace([string]$result.response)) { Write-Host 'RESULT: PARTIAL (Ollama reachable but inference returned no text)' } else { Write-Host "RESULT: READY ($($selected.Tag), local inference verified)" }
} catch { Write-Host "RESULT: PARTIAL (inference unavailable: $($_.Exception.GetType().Name))" }
