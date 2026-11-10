<#
.SYNOPSIS
    Runs Windows Update.

.DESCRIPTION
    Update the current install to have everything patched before the debloat script gets run

.NOTES
    Author:  Rennnsan_
    Created: 10/11/2026
    Requires: PSWindowsUpdate
#>

# Call back setup.ps1
param($ScriptRoot)


Write-Host "Step 0 - Updating Windows..."

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

# Update Windows except for drivers
Install-WindowsUpdate -NotCategory "Drivers" -Verbose -AcceptAll -IgnoreReboot
