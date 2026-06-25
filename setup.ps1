#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configure my Windows VDI
.DESCRIPTION
    Installs apps, configures Git and SSH, retrieves secrets from Azure Key Vault.
    Installs Windows features and updates.
    Idempotent -- re-run to update apps or reapply config.
    Run as Administrator.
#>

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
$TargetUser = 'Joel'
$TargetProfilePath = "C:\Users\$TargetUser"

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    WARN: $msg" -ForegroundColor Yellow }

# --- 1. Azure CLI -------------------------------------------------------------
Step "Installing Azure CLI"
winget install Microsoft.AzureCLI --accept-package-agreements --accept-source-agreements --disable-interactivity
# Refresh PATH so az is available in this session without reopening the shell
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH", "User")
Ok "Azure CLI ready"

Step "Ensuring Azure login"
az account show --only-show-errors *> $null
if ($LASTEXITCODE -ne 0) {
    az login --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "az login failed -- aborting" }
    Ok "Logged in"
} else {
    Ok "Already logged in"
}

# --- 2. Apps ------------------------------------------------------------------
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

# Pull the private key from Key Vault once, avoiding multiple API calls
$b64 = az keyvault secret show --vault-name kv-lab-f7d470 --name ssh-id-ed25519 --query value -o tsv --only-show-errors
$vaultBytes = $null
if ($LASTEXITCODE -ne 0) {
    Warn "Key Vault fetch failed -- check your subscription and Secrets User role assignment"
} else {
    try {
        $vaultBytes = [Convert]::FromBase64String($b64)
    } catch {
        Warn "Key Vault secret ssh-id-ed25519 is not valid base64. Skipping private key update."
        $vaultBytes = $null
    }
}

$sshDir  = "$TargetProfilePath\.ssh"
$sshCfg  = "$sshDir\config"
$keyFile = "$sshDir\id_ed25519"

New-Item -ItemType Directory -Force $sshDir | Out-Null
Copy-Item "$RepoRoot\ssh\config" $sshCfg -Force
Ok "$sshCfg"

if ($vaultBytes) {
    $needsWrite = $true
    if (Test-Path $keyFile) {
        try {
            $localBytes = [System.IO.File]::ReadAllBytes($keyFile)
            if (($localBytes.Length -eq $vaultBytes.Length) -and
                (-not (Compare-Object $localBytes $vaultBytes -SyncWindow 0))) {
                $needsWrite = $false
            }
        } catch {
            # If we cannot read the file due to current ACL restrictions, overwrite it
            $needsWrite = $true
        }
    }

    if ($needsWrite) {
        try {
            [System.IO.File]::WriteAllBytes($keyFile, $vaultBytes)
            Ok "$keyFile (updated from Key Vault)"
        } catch {
            Warn "Failed to write $keyFile for ${TargetUser}: $_"
        }
    } else {
        Ok "$keyFile (already in sync)"
    }

    # Always reassert ACL -- OpenSSH refuses keys readable by anyone but the owner
    # We grant the target user Read-only access, and full control to SYSTEM and Administrators
    if (Test-Path $keyFile) {
        icacls "$keyFile" /inheritance:r /grant:r "$TargetUser:R" /grant:r "SYSTEM:F" /grant:r "Administrators:F" | Out-Null
    }
}

# --- 5. OpenSSH Server --------------------------------------------------------
Step "Configuring OpenSSH Server"

$sshdCap = Get-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0"
if ($sshdCap.State -ne "Installed") {
    Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null
    Ok "OpenSSH Server capability installed"
} else {
    Ok "OpenSSH Server capability already installed"
}

Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne "Running") {
    Start-Service sshd
    Ok "sshd started"
} else {
    Ok "sshd already running"
}

# Firewall rule — profile must be Any so the rule applies regardless of how Windows
# classifies the active network (Private/Public/Domain).
if (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -Profile Any
    Ok "Firewall rule for TCP 22 updated (Profile: Any)"
} else {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any | Out-Null
    Ok "Firewall rule for TCP 22 created (Profile: Any)"
}

# Default shell: Windows PowerShell
$defaultShell = (Get-Command powershell).Source
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value $defaultShell -PropertyType String -Force | Out-Null
Ok "Default SSH shell: $defaultShell"

# Authorize GitHub public keys. Admin users use administrators_authorized_keys
# (Windows OpenSSH ignores ~/.ssh/authorized_keys for accounts in the Administrators group)
$ghUser = "JoelEsperat"
$ghKeys = (Invoke-RestMethod "https://github.com/$ghUser.keys") -split "`n" |
          ForEach-Object { $_.Trim() } |
          Where-Object { $_ -match '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521))\s+' }
$adminKeysFile = "C:\ProgramData\ssh\administrators_authorized_keys"
if ($ghKeys.Count -eq 0) {
    Warn "No valid SSH keys returned from github.com/$ghUser. Leaving $adminKeysFile unchanged."
} else {
    $tmpKeysFile = "$adminKeysFile.new"
    Set-Content -Path $tmpKeysFile -Value $ghKeys -Encoding ASCII
    Move-Item -Path $tmpKeysFile -Destination $adminKeysFile -Force
    icacls $adminKeysFile /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null
    Ok "$adminKeysFile ($($ghKeys.Count) keys from github.com/$ghUser)"
}

# --- 6. Remote Desktop --------------------------------------------------------
Step "Enabling Remote Desktop"

$tsRoot = "HKLM:\System\CurrentControlSet\Control\Terminal Server"
Set-ItemProperty -Path $tsRoot -Name "fDenyTSConnections" -Value 0
# Require Network Level Authentication (more secure; standard for modern RDP clients)
Set-ItemProperty -Path "$tsRoot\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 1
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" | Out-Null
Ok "RDP enabled with NLA, firewall opened"

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
