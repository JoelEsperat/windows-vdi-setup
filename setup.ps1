#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configure my Windows VDI
.DESCRIPTION
    Installs apps, configures Git and SSH using a locally managed SSH key.
    Installs Windows features and updates.
    Idempotent -- re-run to update apps or reapply config.
    Run as Administrator.
#>

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
$TargetUser = 'Joel'
$TargetProfilePath = "C:\Users\$TargetUser"
$StaticRoutes = @(
    @{ DestinationPrefix = '10.10.0.0/24'; NextHop = '192.168.0.200' },
    @{ DestinationPrefix = '10.10.10.0/24'; NextHop = '192.168.0.210' }
)

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    WARN: $msg" -ForegroundColor Yellow }

function Ensure-StaticRoute {
    param(
        [Parameter(Mandatory)]
        [string]$DestinationPrefix,

        [Parameter(Mandatory)]
        [string]$NextHop
    )

    # Convert DestinationPrefix CIDR to destination network and mask
    $parts = $DestinationPrefix -split '/'
    $destNetwork = $parts[0]
    $cidr = [int]$parts[1]

    # Convert CIDR prefix length to subnet mask (e.g. 24 -> 255.255.255.0)
    $maskVal = [uint32]::MaxValue
    if ($cidr -lt 32) {
        $maskVal = $maskVal -shl (32 - $cidr)
    }
    $bytes = [System.BitConverter]::GetBytes($maskVal)
    [System.Array]::Reverse($bytes)
    $subnetMask = $bytes -join '.'

    # Check existing routes in the PersistentStore
    $existingRoutes = @(Get-NetRoute -DestinationPrefix $DestinationPrefix -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
    if ($existingRoutes.Count -gt 0) {
        $matchingRoute = $existingRoutes | Where-Object { $_.NextHop -eq $NextHop }
        if ($matchingRoute) {
            Ok "Route $DestinationPrefix via $NextHop already exists in persistent store"
            return
        }

        # Remove existing persistent routes for this destination prefix
        foreach ($route in $existingRoutes) {
            route.exe delete $destNetwork | Out-Null
        }
    }

    # Add the persistent route using route.exe
    route.exe add $destNetwork mask $subnetMask $NextHop -p | Out-Null
    Ok "Route $DestinationPrefix via $NextHop configured"
}

# --- 1. Apps ------------------------------------------------------------------
Step "Installing/updating apps via winget"
winget import --import-file "$RepoRoot\apps\packages.json" --accept-package-agreements --accept-source-agreements --disable-interactivity
Ok "winget packages in sync"

# --- 3. Configuring Git -------------------------------------------------------
Step "Configuring Git"

if (-not (Test-Path $TargetProfilePath)) {
    throw "Target user profile '$TargetUser' was not found. Ensure $TargetProfilePath exists before running setup."
}

$gitDest = "$TargetProfilePath\.gitconfig"
Copy-Item "$RepoRoot\git\gitconfig" $gitDest -Force
Ok "$gitDest"

# --- 4. Configuring OpenSSH Client -------------------------------------------------------
Step "Configuring OpenSSH Client"

$sshDir  = "$TargetProfilePath\.ssh"
$sshCfg  = "$sshDir\config"
$keyFile = "$sshDir\id_ed25519"
$pubKeyFile = "$sshDir\id_ed25519.pub"

New-Item -ItemType Directory -Force $sshDir | Out-Null
Copy-Item "$RepoRoot\ssh\config" $sshCfg -Force
Ok "$sshCfg"

if (Test-Path $keyFile) {
    try {
        # Preserve the existing private key and only ensure it remains accessible to the user.
        icacls "$keyFile" /inheritance:r /grant "${TargetUser}:(R)" /grant "SYSTEM:(F)" /grant "Administrators:(F)" | Out-Null
        Ok "$keyFile (preserved; managed manually)"
    } catch {
        Warn "Unable to update ACLs for ${keyFile}: $_"
    }
} else {
    Warn "No existing private key found at $keyFile. Leave your SSH key in place manually and update the config if needed."
}

if (Test-Path $pubKeyFile) {
    Ok "$pubKeyFile (found)"
} else {
    Warn "No public key found at $pubKeyFile. If you generated a new key pair locally, make sure the public key is present."
}

# --- 5. Remote Desktop --------------------------------------------------------
Step "Enabling Remote Desktop"

$tsRoot = "HKLM:\System\CurrentControlSet\Control\Terminal Server"
Set-ItemProperty -Path $tsRoot -Name "fDenyTSConnections" -Value 0
# Require Network Level Authentication (more secure; standard for modern RDP clients)
Set-ItemProperty -Path "$tsRoot\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 1
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" | Out-Null
Ok "RDP enabled with NLA, firewall opened"

# --- 6. Static routes --------------------------------------------------------
Step "Configuring static routes"
foreach ($route in $StaticRoutes) {
    Ensure-StaticRoute -DestinationPrefix $route.DestinationPrefix -NextHop $route.NextHop
}

# --- 7. Disabling unused features ---------------------------------------------
Step "Configuring Windows features"

# WSL: disable both the WSL subsystem and the VM platform that backs WSL 2.
# Safe on this VDI because no Hyper-V/Containers/Sandbox is in use.
$wslFeatures = @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")
foreach ($f in $wslFeatures) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $f).State
    if ($state -eq "Enabled") {
        Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart | Out-Null
        Ok "$f disabled (reboot required to fully remove)"
    } else {
        Ok "$f already disabled"
    }
}

# SMB Server: stop the file-sharing service and prevent it from restarting.
$smb = Get-Service LanmanServer
if ($smb.StartType -ne "Disabled") {
    Stop-Service LanmanServer -Force -ErrorAction SilentlyContinue
    Set-Service LanmanServer -StartupType Disabled
    Ok "SMB Server (LanmanServer) stopped and disabled"
} else {
    Ok "SMB Server already disabled"
}

# --- 8. Windows Update --------------------------------------------------------
Step "Installing Windows updates"
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Install-Module PSWindowsUpdate -Force -Scope CurrentUser
}
Import-Module PSWindowsUpdate
Get-WindowsUpdate -Install -AcceptAll -IgnoreReboot -MicrosoftUpdate | Out-Host
$rebootPending = Get-WURebootStatus -Silent
if ($rebootPending) {
    Warn "A reboot is required to finish applying updates"
} else {
    Ok "Windows is up to date"
}

Write-Host "`nDone. You may need to restart your shell or VS Code for changes to take effect." -ForegroundColor Green
if ($rebootPending) {
    Write-Host "Reboot pending -- run 'Restart-Computer' when ready." -ForegroundColor Yellow
}
