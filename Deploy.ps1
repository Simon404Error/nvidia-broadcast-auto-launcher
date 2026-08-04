#Requires -Version 5.1
<#
.SYNOPSIS
One-click deployment for the NVIDIA Broadcast auto launcher.

.DESCRIPTION
Double-click deploy.bat or run this script. On a normal user PowerShell it
re-launches itself as administrator, detects or asks for NVIDIA Broadcast.exe,
writes config.json, and registers the AtStartup scheduled task with a 5 second
delay.

.PARAMETER Elevated
Internal switch used when the script re-launches itself elevated.

.PARAMETER BroadcastPath
Optional explicit path to NVIDIA Broadcast.exe. If omitted, common install
locations are searched and the user is prompted when necessary.

.EXAMPLE
.\deploy.bat

.EXAMPLE
.\Deploy.ps1 -BroadcastPath "C:\Program Files\NVIDIA Corporation\NVIDIA Broadcast\NVIDIA Broadcast.exe"
#>
[CmdletBinding()]
param(
    [switch]$Elevated,

    [string]$BroadcastPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = $PSScriptRoot
$script:LogPath = Join-Path $PSScriptRoot 'deploy.log'
$script:TaskLogPath = Join-Path $PSScriptRoot 'task.log'

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-DeployLog {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')]
        [string]$Level = 'Info'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Show-DeployPopup {
    param(
        [string]$Message,
        [string]$Title = 'NVIDIA Broadcast 自动部署',
        [int]$Seconds = 0
    )

    $shell = New-Object -ComObject WScript.Shell
    $shell.Popup($Message, $Seconds, $Title, 0x40) | Out-Null
}

function Find-BroadcastExecutable {
    $candidates = @(
        'C:\Program Files\NVIDIA Corporation\NVIDIA Broadcast\NVIDIA Broadcast.exe'
        (Join-Path ${env:ProgramFiles} 'NVIDIA Corporation\NVIDIA Broadcast\NVIDIA Broadcast.exe')
        (Join-Path ${env:ProgramFiles} 'NVIDIA\NVIDIA Broadcast\NVIDIA Broadcast.exe')
        (Join-Path ${env:LOCALAPPDATA} 'Programs\NVIDIA Broadcast\NVIDIA Broadcast.exe')
    )

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($root in $uninstallRoots) {
        try {
            $items = @(
                Get-ItemProperty -Path $root -ErrorAction Stop |
                    Where-Object { $_.DisplayName -like '*NVIDIA Broadcast*' }
            )
            foreach ($item in $items) {
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

function Write-ProjectConfig {
    param([string]$ExecutablePath)

    $config = @{
        broadcastPath  = $ExecutablePath
        nvidiaSmiPath  = ''
        dryRun         = $false
        logPath        = $script:TaskLogPath
    } | ConvertTo-Json

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'config.json'), $config, $utf8Bom)
}

if (-not $Elevated -and -not (Test-Admin)) {
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumentString = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated' -f $PSCommandPath
    if ($BroadcastPath) {
        $argumentString += ' -BroadcastPath "{0}"' -f $BroadcastPath
    }

    try {
        $process = Start-Process -FilePath $powerShellPath -ArgumentList $argumentString -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        if (Test-Path -LiteralPath $script:LogPath) {
            Get-Content -LiteralPath $script:LogPath -Encoding UTF8
        }
        exit $process.ExitCode
    }
    catch {
        Write-Host "Deployment was cancelled or could not be elevated: $($_.Exception.Message)"
        exit 1
    }
}

if (-not (Test-Admin)) {
    Write-Host 'Administrator privileges are required for AtStartup registration.'
    exit 1
}

Write-DeployLog 'Deployment started.'

$resolvedBroadcastPath = $null
if ($BroadcastPath -and (Test-Path -LiteralPath $BroadcastPath -PathType Leaf)) {
    $resolvedBroadcastPath = (Resolve-Path -LiteralPath $BroadcastPath).Path
}
else {
    $resolvedBroadcastPath = Find-BroadcastExecutable
}

if (-not $resolvedBroadcastPath) {
    Write-DeployLog 'NVIDIA Broadcast.exe was not found automatically.' -Level Warn
    Add-Type -AssemblyName Microsoft.VisualBasic
    $userPath = [Microsoft.VisualBasic.Interaction]::InputBox(
        "未检测到 NVIDIA Broadcast.exe。`r`n请输入完整 exe 路径，或先安装 NVIDIA Broadcast 后重试。",
        'NVIDIA Broadcast 自动部署',
        'C:\Program Files\NVIDIA Corporation\NVIDIA Broadcast\NVIDIA Broadcast.exe'
    )
    if ($userPath -and (Test-Path -LiteralPath $userPath.Trim('"') -PathType Leaf)) {
        $resolvedBroadcastPath = (Resolve-Path -LiteralPath $userPath.Trim('"')).Path
    }
}

if (-not $resolvedBroadcastPath) {
    Write-DeployLog 'NVIDIA Broadcast.exe was not found; deployment aborted.' -Level Error
    Show-DeployPopup "未找到 NVIDIA Broadcast.exe。`r`n请先安装 NVIDIA Broadcast，或手动提供正确路径。"
    exit 1
}

Write-ProjectConfig -ExecutablePath $resolvedBroadcastPath
Write-DeployLog "Config updated: $resolvedBroadcastPath"

$installScript = Join-Path $PSScriptRoot 'Install-AutoStart.ps1'
try {
    & $installScript -Trigger Startup -LogPath $script:TaskLogPath
    Write-DeployLog 'Install-AutoStart.ps1 completed.'
}
catch {
    Write-DeployLog "Install-AutoStart.ps1 failed: $($_.Exception.Message)" -Level Error
}

$task = Get-ScheduledTask -TaskName 'NVIDIA Broadcast AutoLauncher - Startup' -ErrorAction SilentlyContinue
if (-not $task) {
    Write-DeployLog 'AtStartup task was not found after installation.' -Level Error
    Show-DeployPopup "开机计划任务注册失败。`r`n请查看 deploy.log。"
    exit 1
}

$delay = $task.Triggers | Select-Object -First 1 -ExpandProperty Delay
Write-DeployLog "Startup task registered. State=$($task.State), Delay=$delay"
Show-DeployPopup -Message "部署完成。`r`n开机 5 秒后将自动检查独显并处理 NVIDIA Broadcast。" -Title '部署完成' -Seconds 5
Write-Host 'Deployment completed.'
exit 0
