# windows-config

Personal Windows VDI configuration as code. Installs apps, configures Git and SSH, and uses a locally managed SSH key.

## What it does

- **`setup.ps1`** — entry point; idempotent, re-run any time to update apps or reapply config
	- Configures only the `Joel` profile
	- Applies persistent static routes for `10.10.10.0/24` via `192.168.0.210` and `10.10.20.0/24` via `192.168.0.220`
- **`apps/packages.json`** — winget package list
- **`git/gitconfig`** — Git configuration (`~/.gitconfig`)
- **`ssh/config`** — SSH host aliases (`~/.ssh/config`)

SSH private key is managed manually and left in place at `~/.ssh/id_ed25519`.

This script is intentionally hardcoded for a single-user VDI (`Joel`).

## Usage

```powershell
git clone https://github.com/JoelEsperat/windows-config.git C:\Projects\windows-config
Set-ExecutionPolicy Bypass -Scope Process -Force
C:\Projects\windows-config\setup.ps1
```

> Run as Administrator.
>
> The script expects `C:\Users\Joel` to exist. To target a different user, edit `$TargetUser` in `setup.ps1`.
>
> Keep your private key in `C:\Users\Joel\.ssh\id_ed25519` and your public key in `C:\Users\Joel\.ssh\id_ed25519.pub`; the script will preserve them.

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
