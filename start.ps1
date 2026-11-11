<#
.SYNOPSIS
    The initiator for WinSetup-VR++

.DESCRIPTION
    It is just a wrapper for WinSetup-VR++ to execute from \modules and apply its settings.
    It also loads config.json to be stored in memory so that the rest of the modules can references the needed configs to be setup.
    This script will require Administrative access in order to function correctly.

    Restart handling:
    Any module can request a restart by exiting with code 3010. When that happens this script
    registers a scheduled task that re-launches start.ps1 (elevated) at the next logon, then
    restarts the computer. Modules that already completed are skipped on resume. Once every
    module has completed, the scheduled task and resume state are removed.

.NOTES
    Author:  Rennnsan_
    Created: 10/11/2026
    Requires: RunAsAdministrator
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$ScriptRoot = $PSScriptRoot
$LogFile = Join-Path $ScriptRoot "deploy_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $LogFile

# Restart / resume settings
$RebootRequiredExitCode = 3010
$ResumeTaskName = "WinSetup-VR++ Resume"
$StateDir       = Join-Path $env:ProgramData "WinSetup-VR++"
$ResumeFile     = Join-Path $StateDir "resume.state.json"

function Register-ResumeTask {
    $ScriptPath = Join-Path $ScriptRoot "start.ps1"
    $Action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" `
                    -WorkingDirectory $ScriptRoot
    $Trigger   = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $Trigger.Delay = "PT30S"   # Give the desktop / OneDrive / network a moment to come up
    $Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $Settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $ResumeTaskName -Action $Action -Trigger $Trigger `
        -Principal $Principal -Settings $Settings -Force | Out-Null
}

function Unregister-ResumeTask {
    if (Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false
    }
}

Write-Host "=== Starting Automated System Provisioning ===" -ForegroundColor Cyan

# Load central configuration
$ConfigPath = Join-Path $ScriptRoot "config.json"
if (-not (Test-Path $ConfigPath)) {
    Throw "Missing config.json at $ConfigPath"
}
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# Load resume state (list of modules already completed before a restart)
$CompletedModules = @()
if (Test-Path $ResumeFile) {
    $CompletedModules = @((Get-Content -Raw -Path $ResumeFile | ConvertFrom-Json).CompletedModules)
    Write-Host "Resuming provisioning after restart. Completed modules: $($CompletedModules -join ', ')" -ForegroundColor Cyan
}

# Execute numbered modules in order
$Modules = Get-ChildItem -Path (Join-Path $ScriptRoot "modules") -Filter "*.ps1" | Sort-Object Name
foreach ($Module in $Modules) {
    if ($CompletedModules -contains $Module.Name) {
        Write-Host "`n---> Skipping Module (already completed): $($Module.Name)" -ForegroundColor DarkGray
        continue
    }

    Write-Host "`n---> Executing Module: $($Module.Name)" -ForegroundColor Yellow
    $global:LASTEXITCODE = 0
    & $Module.FullName -Config $Config -ScriptRoot $ScriptRoot

    if ($LASTEXITCODE -eq $RebootRequiredExitCode) {
        Write-Host "`n=== $($Module.Name) requested a restart. Provisioning will resume after logon. ===" -ForegroundColor Magenta

        if (-not (Test-Path $StateDir)) { New-Item -Path $StateDir -ItemType Directory -Force | Out-Null }
        [PSCustomObject]@{ CompletedModules = $CompletedModules } | ConvertTo-Json | Set-Content -Path $ResumeFile -Encoding UTF8
        Register-ResumeTask

        Write-Host "Restarting in 15 seconds..." -ForegroundColor Magenta
        Stop-Transcript
        Start-Sleep -Seconds 15
        Restart-Computer -Force
        exit
    }

    $CompletedModules += $Module.Name
}

# All modules finished - clean up the resume mechanism
Unregister-ResumeTask
if (Test-Path $ResumeFile) { Remove-Item -Path $ResumeFile -Force }

Write-Host "`n=== System Provisioning Complete! Reboot recommended. ===" -ForegroundColor Green
Stop-Transcript
