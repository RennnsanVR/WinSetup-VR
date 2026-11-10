<#
.SYNOPSIS
    The initiator for WinSetup-VR++

.DESCRIPTION
    It is just a wrapper for WinSetup-VR++ to execute from \modules and apply its settings.
    It also loads config.json to be stored in memory so that the rest of the modules can references the needed configs to be setup.
    This script will require Administrative access in order to function correctly.

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

Write-Host "=== Starting Automated System Provisioning ===" -ForegroundColor Cyan

# Load central configuration
$ConfigPath = Join-Path $ScriptRoot "config.json"
if (-not (Test-Path $ConfigPath)) {
    Throw "Missing config.json at $ConfigPath"
}
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# Execute numbered modules in order
$Modules = Get-ChildItem -Path (Join-Path $ScriptRoot "modules") -Filter "*.ps1" | Sort-Object Name
foreach ($Module in $Modules) {
    Write-Host "`n---> Executing Module: $($Module.Name)" -ForegroundColor Yellow
    & $Module.FullName -Config $Config -ScriptRoot $ScriptRoot
}

Write-Host "`n=== System Provisioning Complete! Reboot recommended. ===" -ForegroundColor Green
Stop-Transcript