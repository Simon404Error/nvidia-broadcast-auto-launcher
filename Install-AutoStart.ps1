#Requires -Version 5.1
<#
.SYNOPSIS
Registers Windows scheduled tasks for the NVIDIA Broadcast auto launcher.

.DESCRIPTION
The default task runs 5 seconds after system startup. An optional interval
task can be enabled for cases where a discrete GPU may be enabled or plugged in
after boot.

.PARAMETER Trigger
Startup: register the startup task (default).
Interval: register a periodic task.
Both: register both tasks.

.PARAMETER IntervalMinutes
Minutes between interval checks. Defaults to 10.

.PARAMETER TaskNamePrefix
Prefix used for task names.

.PARAMETER ScriptPath
Path to Start-NvidiaBroadcast.ps1. Defaults to the script in this folder.

.PARAMETER BroadcastPath
Optional explicit NVIDIA Broadcast.exe path passed through to the script.

.PARAMETER LogPath
Optional log file path passed through to the script.

.EXAMPLE
.\Install-AutoStart.ps1

.EXAMPLE
.\Install-AutoStart.ps1 -Trigger Both -IntervalMinutes 5

.EXAMPLE
.\Install-AutoStart.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Startup', 'Interval', 'Both')]
    [string]$Trigger = 'Startup',

    [ValidateRange(1, 1440)]
    [int]$IntervalMinutes = 10,

    [string]$TaskNamePrefix = 'NVIDIA Broadcast AutoLauncher',

    [string]$ScriptPath,

    [string]$BroadcastPath,

    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ScriptPath) {
    $ScriptPath = Join-Path $PSScriptRoot 'Start-NvidiaBroadcast.ps1'
}

if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "Start-NvidiaBroadcast.ps1 not found: $ScriptPath"
}

$resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path
$arguments = @(
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-File', ('"{0}"' -f $resolvedScript)
)

if ($BroadcastPath) {
    $arguments += '-BroadcastPath', ('"{0}"' -f $BroadcastPath)
}
if ($LogPath) {
    $arguments += '-LogPath', ('"{0}"' -f $LogPath)
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($arguments -join ' ')
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

$principal = $null
try {
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
}
catch {
    Write-Warning "Could not create an explicit interactive principal; using the default task principal. $($_.Exception.Message)"
}

$startupTrigger = New-ScheduledTaskTrigger -AtStartup
$startupTrigger.Delay = 'PT5S'

$intervalTrigger = $null
if ($Trigger -in @('Interval', 'Both')) {
    $intervalTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
}

function Register-AutoStartTask {
    param(
        [string]$TaskName,
        $TaskTriggers
    )

    $taskParams = @{
        TaskName = $TaskName
        Action   = $action
        Trigger  = $TaskTriggers
        Settings = $settings
        Force    = $true
    }
    if ($principal) {
        $taskParams.Principal = $principal
    }

    if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
        Register-ScheduledTask @taskParams | Out-Null
        Write-Host "Registered: $TaskName"
    }
}

$obsoleteTasks = @("$TaskNamePrefix - Logon")
if ($Trigger -notin @('Interval', 'Both')) {
    $obsoleteTasks += "$TaskNamePrefix - Interval"
}

foreach ($obsoleteName in $obsoleteTasks) {
    $existingTask = Get-ScheduledTask -TaskName $obsoleteName -ErrorAction SilentlyContinue
    if ($existingTask) {
        if ($PSCmdlet.ShouldProcess($obsoleteName, 'Unregister obsolete scheduled task')) {
            Unregister-ScheduledTask -TaskName $obsoleteName -Confirm:$false
            Write-Host "Removed obsolete task: $obsoleteName"
        }
    }
}

if ($Trigger -in @('Startup', 'Both')) {
    try {
        Register-AutoStartTask -TaskName "$TaskNamePrefix - Startup" -TaskTriggers $startupTrigger
    }
    catch {
        Write-Warning 'Startup trigger requires administrator privileges. Falling back to logon trigger with the same 5 second delay.'
        $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $logonTrigger.Delay = 'PT5S'
        Register-AutoStartTask -TaskName "$TaskNamePrefix - Logon" -TaskTriggers $logonTrigger
    }
}

if ($Trigger -in @('Interval', 'Both')) {
    Register-AutoStartTask -TaskName "$TaskNamePrefix - Interval" -TaskTriggers $intervalTrigger
}

Write-Host 'Scheduled task setup completed.'
