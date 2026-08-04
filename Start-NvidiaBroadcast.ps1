#Requires -Version 5.1
<#
.SYNOPSIS
Checks whether a discrete NVIDIA GPU is present and active, then starts NVIDIA
Broadcast minimized when both conditions are met.

.DESCRIPTION
At startup this script waits for the scheduled task delay, checks the GPU
state, and then:
  - Starts NVIDIA Broadcast minimized if the GPU exists and is active.
  - Shows a popup if the discrete GPU is not present.
  - Shows a popup if the discrete GPU is present but not running.

.PARAMETER BroadcastPath
Optional explicit path to NVIDIA Broadcast.exe.

.PARAMETER NvidiaSmiPath
Optional explicit path to nvidia-smi.exe.

.PARAMETER ConfigPath
Optional JSON config file. If omitted, config.json in the script folder is used
when it exists.

.PARAMETER DryRun
Print the detected state and intended action without launching or showing
popups.

.PARAMETER LogPath
Optional log file path.

.EXAMPLE
.\Start-NvidiaBroadcast.ps1

.EXAMPLE
.\Start-NvidiaBroadcast.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$BroadcastPath,

    [string]$NvidiaSmiPath,

    [string]$ConfigPath,

    [switch]$DryRun,

    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PopupTitle = '独立显卡检测'
$script:GpuMissingMessage = '独显不存在' + [Environment]::NewLine + '目前可能是集显模式'
$script:GpuInactiveMessage = '独显已连接' + [Environment]::NewLine + '但未运行' + [Environment]::NewLine + '请检查独显状态'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')]
        [string]$Level = 'Info'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line

    if ($LogPath) {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
}

function Resolve-Config {
    if (-not $ConfigPath) {
        $defaultConfig = Join-Path $PSScriptRoot 'config.json'
        if (Test-Path -LiteralPath $defaultConfig) {
            $script:ConfigPath = $defaultConfig
        }
        else {
            return
        }
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    if (-not $PSBoundParameters.ContainsKey('BroadcastPath') -and $config.broadcastPath) {
        $script:BroadcastPath = [string]$config.broadcastPath
    }
    if (-not $PSBoundParameters.ContainsKey('NvidiaSmiPath') -and $config.nvidiaSmiPath) {
        $script:NvidiaSmiPath = [string]$config.nvidiaSmiPath
    }
    if (-not $PSBoundParameters.ContainsKey('LogPath') -and $config.logPath) {
        $script:LogPath = [string]$config.logPath
    }
    if (-not $PSBoundParameters.ContainsKey('DryRun') -and $config.dryRun -eq $true) {
        $script:DryRun = $true
    }
}

function Get-NvidiaSmiPath {
    param([string]$ConfiguredPath)

    if ($ConfiguredPath) {
        if (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $ConfiguredPath).Path
        }
        throw "nvidia-smi not found at configured path: $ConfiguredPath"
    }

    $command = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe')
        (Join-Path ${env:ProgramFiles} 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Get-NvidiaSmiSummary {
    param([string]$SmiPath)

    if (-not $SmiPath) {
        return [PSCustomObject]@{
            Available = $false
            Count     = 0
            Names     = @()
        }
    }

    try {
        $output = & $SmiPath --query-gpu=name --format=csv,noheader 2>$null
        $names = @(
            $output | Where-Object {
                $_ -and $_ -notmatch 'NVIDIA-SMI has failed|Unable to determine|No devices were found'
            }
        )

        return [PSCustomObject]@{
            Available = $true
            Count     = $names.Count
            Names     = $names
        }
    }
    catch {
        Write-Log "nvidia-smi query failed: $($_.Exception.Message)" -Level Warn
        return [PSCustomObject]@{
            Available = $true
            Count     = 0
            Names     = @()
        }
    }
}

function Get-DiscreteGpuState {
    $state = [PSCustomObject]@{
        PnpNvidiaPresent = $false
        CimNvidiaPresent = $false
        GpuActive        = $false
        GpuNames         = @()
    }

    $pnpDevices = @(
        Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -match 'VEN_10DE' }
    )

    if ($pnpDevices.Count -gt 0) {
        $presentPnp = @($pnpDevices | Where-Object { $_.Present -eq $true })
        if ($presentPnp.Count -gt 0) {
            $state.PnpNvidiaPresent = $true
            $state.GpuNames += @($presentPnp | ForEach-Object { $_.FriendlyName })
            $state.GpuActive = @($presentPnp | Where-Object { $_.Status -eq 'OK' }).Count -gt 0
        }
    }

    $cimCards = @(
        Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue |
            Where-Object { $_.PNPDeviceID -match 'VEN_10DE' }
    )

    if ($cimCards.Count -gt 0) {
        $state.CimNvidiaPresent = $true
        $state.GpuNames += @($cimCards | ForEach-Object { $_.Name })
        if (-not $state.GpuActive) {
            $state.GpuActive = @(
                $cimCards | Where-Object {
                    $_.Status -eq 'OK' -or $_.ConfigManagerErrorCode -eq 0
                }
            ).Count -gt 0
        }
    }

    $state.GpuNames = @($state.GpuNames | Select-Object -Unique)
    return $state
}

function Get-BroadcastProcess {
    param([string]$ExecutablePath)

    $processMatches = @()
    $broadcastNames = @('NVIDIA Broadcast', 'NVIDIA_Broadcast', 'NVIDIABroadcast')
    foreach ($name in $broadcastNames) {
        $processMatches += @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    }

    if ($ExecutablePath) {
        $targetPath = $ExecutablePath.TrimEnd('\')
        $byPath = @(
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.ExecutablePath -and
                    $_.ExecutablePath.TrimEnd('\') -ieq $targetPath
                }
        )
        foreach ($processInfo in $byPath) {
            $processMatches += @(Get-Process -Id $processInfo.ProcessId -ErrorAction SilentlyContinue)
        }
    }

    return @($processMatches | Sort-Object -Property Id -Unique)
}

function Find-BroadcastExecutable {
    param([string]$ConfiguredPath)

    if ($ConfiguredPath) {
        if (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $ConfiguredPath).Path
        }
        throw "NVIDIA Broadcast executable not found at configured path: $ConfiguredPath"
    }

    $candidates = @()

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($root in $uninstallRoots) {
        try {
            $uninstallItems = @(
                Get-ItemProperty -Path $root -ErrorAction Stop |
                    Where-Object { $_.DisplayName -like '*NVIDIA Broadcast*' }
            )

            foreach ($item in $uninstallItems) {
                if ($item.InstallLocation) {
                    $candidates += (Join-Path ([string]$item.InstallLocation) 'NVIDIA Broadcast.exe')
                }
                if ($item.DisplayIcon) {
                    $icon = ([string]$item.DisplayIcon).Trim('"')
                    if ($icon -match '\.exe') {
                        $candidates += $icon.Split(',')[0].Trim('"')
                    }
                }
            }
        }
        catch {
            # Registry hive may be absent or unreadable; continue searching.
        }
    }

    $candidates += @(
        'C:\Program Files\NVIDIA Corporation\NVIDIA Broadcast\NVIDIA Broadcast.exe'
        (Join-Path ${env:ProgramFiles} 'NVIDIA Corporation\NVIDIA Broadcast\NVIDIA Broadcast.exe')
        (Join-Path ${env:ProgramFiles} 'NVIDIA\NVIDIA Broadcast\NVIDIA Broadcast.exe')
        (Join-Path ${env:LOCALAPPDATA} 'Programs\NVIDIA Broadcast\NVIDIA Broadcast.exe')
    )

    $startMenuRoots = @(
        (Join-Path ${env:ProgramData} 'Microsoft\Windows\Start Menu\Programs')
        (Join-Path ${env:APPDATA} 'Microsoft\Windows\Start Menu\Programs')
    )

    $shell = New-Object -ComObject WScript.Shell
    foreach ($root in $startMenuRoots) {
        try {
            $shortcuts = @(
                Get-ChildItem -LiteralPath $root -Recurse -Filter '*NVIDIA Broadcast*.lnk' -ErrorAction SilentlyContinue
            )

            foreach ($shortcut in $shortcuts) {
                try {
                    $target = $shell.CreateShortcut($shortcut.FullName).TargetPath
                    if ($target) {
                        $candidates += $target
                    }
                }
                catch {
                    # Ignore shortcuts that cannot be resolved.
                }
            }
        }
        catch {
            # Start menu folder may not exist; continue searching.
        }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Show-StatusPopup {
    param(
        [string]$Title,
        [string]$Message,
        [switch]$DryRun
    )

    if ($DryRun) {
        $flatMessage = $Message -replace "`r?`n", ' | '
        Write-Log "Dry run popup [$Title]: $flatMessage"
        return
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shell.Popup($Message, 0, $Title, 0x40) | Out-Null
    }
    catch {
        Write-Log "Failed to show popup: $($_.Exception.Message)" -Level Warn
    }
}

function Start-NvidiaBroadcastApp {
    param([string]$ExecutablePath)

    $exeDir = Split-Path -Parent $ExecutablePath
    $process = Start-Process -FilePath $ExecutablePath -WorkingDirectory $exeDir -WindowStyle Minimized -PassThru
    Start-Sleep -Seconds 2

    $process.Refresh()
    if ($process.HasExited) {
        throw "NVIDIA Broadcast exited early with code $($process.ExitCode)."
    }

    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WindowMinimizeHelper {
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
'@ -ErrorAction Stop
    }
    catch {
        Write-Log "Minimize helper unavailable; process was started minimized." -Level Warn
    }

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) {
            throw "NVIDIA Broadcast exited early with code $($process.ExitCode)."
        }

        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            $minimizeType = 'WindowMinimizeHelper' -as [type]
            if ($minimizeType) {
                [WindowMinimizeHelper]::ShowWindowAsync($process.MainWindowHandle, 6) | Out-Null
                Write-Log 'NVIDIA Broadcast main window minimized.'
            }
            break
        }

        Start-Sleep -Milliseconds 500
    }

    return $process
}

Resolve-Config

$smiPath = Get-NvidiaSmiPath -ConfiguredPath $NvidiaSmiPath
$smi = Get-NvidiaSmiSummary -SmiPath $smiPath

if ($smi.Count -gt 0) {
    $gpu = [PSCustomObject]@{
        PnpNvidiaPresent = $true
        CimNvidiaPresent = $true
        GpuActive        = $true
        GpuNames         = @($smi.Names)
    }
    Write-Log 'GPU confirmed by nvidia-smi; skipped slower PnP/CIM enumeration.'
}
else {
    $gpu = Get-DiscreteGpuState
}

$discreteGpuPresent = $gpu.PnpNvidiaPresent -or $gpu.CimNvidiaPresent
$gpuActive = $gpu.GpuActive -or $smi.Count -gt 0

Write-Log 'NVIDIA Broadcast launcher status:'
Write-Log ("  nvidia-smi path     : {0}" -f $(if ($smiPath) { $smiPath } else { 'not found' }))
Write-Log ("  nvidia-smi GPUs     : {0}" -f $smi.Count)
if ($smi.Count -gt 0) {
    Write-Log ("  nvidia-smi names    : {0}" -f ($smi.Names -join '; '))
}
Write-Log ("  PnP NVIDIA present  : {0}" -f $gpu.PnpNvidiaPresent)
Write-Log ("  CIM NVIDIA present  : {0}" -f $gpu.CimNvidiaPresent)
if ($gpu.GpuNames.Count -gt 0) {
    Write-Log ("  detected GPU names  : {0}" -f ($gpu.GpuNames -join '; '))
}
Write-Log ("  Discrete GPU present: {0}" -f $discreteGpuPresent)
Write-Log ("  GPU active          : {0}" -f $gpuActive)

if (-not $discreteGpuPresent) {
    Write-Log 'Discrete GPU not found; showing popup.' -Level Warn
    Show-StatusPopup -Title $script:PopupTitle -Message $script:GpuMissingMessage -DryRun:$DryRun
    exit 1
}

if (-not $gpuActive) {
    Write-Log 'Discrete GPU present but not running; showing popup.' -Level Warn
    Show-StatusPopup -Title $script:PopupTitle -Message $script:GpuInactiveMessage -DryRun:$DryRun
    exit 2
}

$broadcastExe = Find-BroadcastExecutable -ConfiguredPath $BroadcastPath
Write-Log ("  Broadcast path      : {0}" -f $(if ($broadcastExe) { $broadcastExe } else { 'not found' }))

if (-not $broadcastExe) {
    Write-Log 'NVIDIA Broadcast was not found. Install it or set -BroadcastPath.' -Level Error
    exit 4
}

$broadcastProcess = @(Get-BroadcastProcess -ExecutablePath $broadcastExe)
Write-Log ("  Broadcast running   : {0}" -f ($broadcastProcess.Count -gt 0))
if ($broadcastProcess.Count -gt 0) {
    Write-Log 'NVIDIA Broadcast is already running; no action needed.'
    exit 0
}

if ($DryRun) {
    Write-Log 'Dry run: GPU is active and NVIDIA Broadcast is not running; it would be started minimized.'
    exit 0
}

try {
    $process = Start-NvidiaBroadcastApp -ExecutablePath $broadcastExe
    Write-Log "NVIDIA Broadcast started minimized (PID $($process.Id))."
    exit 0
}
catch {
    Write-Log "Failed to start NVIDIA Broadcast: $($_.Exception.Message)" -Level Error
    exit 5
}
