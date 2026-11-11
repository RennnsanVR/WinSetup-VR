<#
.SYNOPSIS
    Runs Windows Update.

.DESCRIPTION
    Update the current install to have everything patched before the debloat script gets run

    The module runs in "passes". Each pass installs all available updates (except drivers).
    If a restart is required afterwards, the module saves its progress and exits with code 3010
    (the standard "reboot required" code). start.ps1 picks this up, registers itself to resume
    at the next logon and restarts the computer. After the restart start.ps1 runs again, this
    module recognises that the system was restarted and runs another pass. Once no updates are
    left and no restart is pending, the module cleans up its state and the next module runs.

.NOTES
    Author:  Rennnsan_
    Created: 10/11/2026
    Requires: PSWindowsUpdate
#>

# Call back setup.ps1
param($Config, $ScriptRoot)

# Safety net so a stuck update / sticky reboot flag can't cause an endless restart loop
$MaxPasses = 5
$RebootRequiredExitCode = 3010

$StateDir  = Join-Path $env:ProgramData "WinSetup-VR++"
$StateFile = Join-Path $StateDir "WindowsUpdate.state.json"

function Get-LastBootTime {
    (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToString("o")
}

function Test-PendingReboot {
    # PSWindowsUpdate's own check
    if (Get-WURebootStatus -Silent) { return $true }

    # Fallback registry checks used by Windows Update / Component Based Servicing
    $Keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    foreach ($Key in $Keys) {
        if (Test-Path $Key) { return $true }
    }
    return $false
}

function Save-UpdateState($State) {
    if (-not (Test-Path $StateDir)) { New-Item -Path $StateDir -ItemType Directory -Force | Out-Null }
    $State | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

function Clear-UpdateState {
    if (Test-Path $StateFile) { Remove-Item -Path $StateFile -Force }
}

Write-Host "Step 0 - Updating Windows..."

# Load previous progress (if any) and detect whether the system restarted since the last pass
$CurrentBoot = Get-LastBootTime
$State = $null
if (Test-Path $StateFile) {
    $State = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
}

if ($State) {
    if ($State.LastBootTime -ne $CurrentBoot) {
        Write-Host "System restart detected. Resuming Windows Update (completed passes: $($State.Pass))." -ForegroundColor Cyan
    }
    else {
        Write-Host "Previous Windows Update run found but no restart detected. Continuing (completed passes: $($State.Pass))." -ForegroundColor Yellow
    }
}
else {
    $State = [PSCustomObject]@{ Pass = 0; LastBootTime = $CurrentBoot }
}

$State.Pass = [int]$State.Pass + 1
if ($State.Pass -gt $MaxPasses) {
    Write-Warning "Windows Update has reached the maximum of $MaxPasses passes. Skipping further updates."
    Clear-UpdateState
    exit 0
}

# Check if PSWindowsUpdate is installed
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Write-Host "PSWindowsUpdate is not installed. Installing PSWindowsUpdate..." -ForegroundColor Yellow

    # Ensure TLS 1.2 is enabled for PowerShell Gallery downloads on fresh installs
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Install NuGet provider silently if missing
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }

    # Install PSWindows Update
    Install-Module -Name PSWindowsUpdate -Force -Confirm:$false -Scope AllUsers
}

# Import PSWindowsUpdate for the Windows Update commands to work
Import-Module PSWindowsUpdate

# If a restart is already pending (e.g. from a previous install), restart first so updates apply cleanly
if (Test-PendingReboot) {
    Write-Host "A restart is already pending. Requesting restart before installing more updates..." -ForegroundColor Yellow
    $State.LastBootTime = $CurrentBoot
    Save-UpdateState $State
    exit $RebootRequiredExitCode
}

Write-Host "Windows Update pass $($State.Pass) of max $MaxPasses..." -ForegroundColor Cyan

# Update Windows except for drivers
$Updates = Install-WindowsUpdate -NotCategory "Drivers" -Verbose -AcceptAll -IgnoreReboot
$Updates | Out-Host

if (Test-PendingReboot) {
    Write-Host "Updates installed and a restart is required. The setup will resume after the restart." -ForegroundColor Yellow
    $State.LastBootTime = $CurrentBoot
    Save-UpdateState $State
    exit $RebootRequiredExitCode
}

if ($Updates) {
    # Updates were installed without needing a restart - more may have become available, so do another pass
    Write-Host "Updates installed without a restart. Checking for further updates..." -ForegroundColor Cyan
    $State.LastBootTime = $CurrentBoot
    Save-UpdateState $State
    & $PSCommandPath -Config $Config -ScriptRoot $ScriptRoot
    exit $LASTEXITCODE
}

Write-Host "Windows is fully up to date." -ForegroundColor Green
Clear-UpdateState
exit 0
