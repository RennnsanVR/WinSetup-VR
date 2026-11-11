<#
.SYNOPSIS
    Updates Windows and its apps.

.DESCRIPTION
    This module runs in passes. The first few passes will involve Windows Update updating the system (except drivers).
    When a restart is triggered, This module will save its current state and exit with code 3010.
    When rebooted, start.ps1 starts again through Schedule Task and this module will continue from before.
    It start a new scan for Windows Updates then begins updating apps from the Microsoft Store and winget packages
    before continuing to the next module. This is to make sure that the system is fully updated before debloating.

.NOTES
    Author:  Rennnsan_
    Created: 10/11/2026
    Requires: PSWindowsUpdate
#>

# Call back start.ps1
param($Config, $ScriptRoot)

# Safety net so a stuck update / sticky reboot flag can't cause an endless restart loop
$MaxPasses = 5
$RebootRequiredExitCode = 3010

$StateDir  = Join-Path $env:ProgramData "WinSetup-VR"
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

# ---- Microsoft Store apps (same method Topgrade uses) ----
# Asks the Store's MDM agent to scan for and install app updates. The scan runs in the background.
Write-Host "Triggering Microsoft Store app updates..." -ForegroundColor Cyan
try {
    Get-CimInstance -Namespace "Root\cimv2\mdm\dmmap" -ClassName "MDM_EnterpriseModernAppManagement_AppManagement01" -ErrorAction Stop |
        Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop | Out-Null
    Write-Host "Microsoft Store update scan started (updates install in the background)." -ForegroundColor Green
}
catch {
    Write-Warning "Could not trigger Microsoft Store updates: $($_.Exception.Message)"
}

# ---- winget packages ----
$Winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($Winget) {
    Write-Host "Updating packages with winget..." -ForegroundColor Cyan
    try {
        # Refresh sources first so a fresh install doesn't act on stale/empty data
        & winget.exe source update | Out-Host
        & winget.exe upgrade --all --silent --include-unknown --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "winget exited with code $LASTEXITCODE (some packages may not have updated)."
        }
    }
    catch {
        Write-Warning "winget upgrade failed: $($_.Exception.Message)"
    }
}
else {
    Write-Warning "winget was not found. Skipping winget upgrades."
}

Clear-UpdateState
exit 0
