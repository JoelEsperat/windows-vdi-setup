# windows-config

Personal Windows VDI configuration as code. Installs apps, configures Git and SSH, and retrieves credentials from Azure Key Vault.

## What it does

- **`setup.ps1`** — entry point; idempotent, re-run any time to update apps or reapply config
	- Configures only the `Joel` profile
- **`apps/packages.json`** — winget package list
- **`git/gitconfig`** — global Git configuration (`~/.gitconfig`)
- **`ssh/config`** — SSH host aliases (`~/.ssh/config`)

SSH private key is pulled from Azure Key Vault (`kv-lab-f7d470`) and written to `~/.ssh/id_ed25519`.

This script is intentionally hardcoded for a single-user VDI (`Joel`).

## Usage

```powershell
git clone https://github.com/JoelEsperat/windows-config.git C:\Projects\windows-config
Set-ExecutionPolicy Bypass -Scope Process -Force
C:\Projects\windows-config\setup.ps1
```

> Run as Administrator. Requires an active Azure login — the script will prompt `az login` if needed.
>
> The script expects `C:\Users\Joel` to exist. To target a different user, edit `$TargetUser` in `setup.ps1`.

## Apps installed

| Type | Apps |
|------|------|
| Apps | PowerShell, VS Code, Antigravity |
| CLI | Azure CLI, Git, GitHub CLI |
| Runtimes | Python |

## Updating this repo

| Config | Command |
|--------|---------|
| winget packages | `winget export -o apps\packages.json` |
| Everything else | Copy the file from its install location (see `setup.ps1` for paths) |
