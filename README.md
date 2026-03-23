# OpenClaw on AMD / WSL bootstrap

This repo collapses AMD's WSL2 + llmster + OpenClaw setup into a single command. Two entry points are provided depending on your starting point.

---

## Option A — Full Windows bootstrap (recommended)

Run this from a **PowerShell** window on your Windows machine. It handles everything from scratch:

1. Self-elevates to Administrator if needed
2. Enables WSL2 (reboots and resumes automatically if required)
3. Installs Ubuntu 24.04 and prompts you to create a Unix username and password
4. Installs AMD ROCm drivers inside WSL2
5. Installs llmster and starts the API server
6. Loads `qwen/qwen3-coder-next`
7. Installs and configures OpenClaw

```powershell
irm https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd-bootstrap.ps1 | iex
```

> **Requires:** AMD Adrenalin Edition 26.1.1 or newer installed on the Windows host before running.

---

## Option B — WSL-only (WSL2 + Ubuntu already installed)

Run this inside an existing Ubuntu/WSL shell:

```bash
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash
```

---

## What the scripts automate

**PowerShell (`openclaw-amd-bootstrap.ps1`):**
- self-elevates to Administrator,
- enables `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform` Windows features,
- reboots and resumes automatically via a scheduled task if required,
- installs Ubuntu 24.04 and opens a terminal window so you can set your Unix username and password,
- waits for you to confirm setup is complete before continuing,
- invokes `openclaw-amd.sh` inside WSL as your user — `sudo` will prompt for your password wherever needed,
- handles the systemd-restart step (`exit 10`) transparently.

**Bash (`openclaw-amd.sh`):**
- installs the Linux packages the AMD/ROCm guide relies on,
- creates `~/.config/systemd/user` and `~/.npm-global`,
- persists `~/.npm-global/bin` into your shell PATH,
- enables systemd in `/etc/wsl.conf` when needed,
- **installs AMD ROCm drivers inside WSL2** (`amdgpu-install --usecase=wsl,rocm --no-dkms`),
- installs Homebrew and persists `brew shellenv`,
- installs or updates OpenClaw via the official installer,
- **installs llmster** (the headless LM Studio core) via the official installer,
- **starts the llmster daemon and API server** on `127.0.0.1:1234`,
- **loads `qwen/qwen3-coder-next` (Qwen3-Coder-Next 80B)** by default,
- auto-detects the loaded model and its context length from the local llmster API,
- runs `openclaw onboard` non-interactively against llmster,
- applies the tested RadeonClaw profile by default.

---

## Default model

**`qwen/qwen3-coder-next`** — Qwen3-Coder-Next 80B MoE (3B active parameters, 256K context).

Hardware requirements: >45 GB VRAM/combined RAM for a 4-bit quant, >30 GB for a 2-bit quant.

Override with `OPENCLAW_AMD_MODEL_ID=<model-id>` (see Useful overrides below).

## Default profile

The script hardcodes the RadeonClaw-style defaults unless you override them:

- `OPENCLAW_AMD_CONTEXT_TOKENS=190000`
- `OPENCLAW_AMD_MODEL_MAX_TOKENS=190000`
- `OPENCLAW_AMD_MAX_AGENTS=2`
- `OPENCLAW_AMD_MAX_SUBAGENTS=2`

## ROCm version

By default the script uses `ROCM_VERSION=latest`, which auto-resolves the newest `amdgpu-install` package from AMD's `/latest/` repo symlink — so it will always pull the current release without requiring script edits. As of early 2026 that resolves to **ROCm 7.2**.

Requires **AMD Adrenalin Edition 26.1.1 or newer** on your Windows host. Consult AMD's [WSL2 compatibility matrix](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/compatibility/compatibilityrad/wsl/wsl_compatibility.html) if you need to pin to a specific version.

After ROCm is installed the script adds your user to the `render` and `video` groups. If this is the first install, run `wsl --shutdown` from PowerShell and reopen Ubuntu to pick up the group membership, then rerun the one-liner.

## What it intentionally does **not** automate

- AMD Adrenalin driver installation on the Windows host,
- Ryzen AI Max+ Variable Graphics Memory changes,
- model downloads (use `lms get <model-id>` if a model is not already present),
- Discord/channel pairing,
- optional browser relay setup.

## Useful overrides

```bash
# Use a different model
OPENCLAW_AMD_MODEL_ID=lmstudio-community/Qwen3-Coder-480B-A35B-GGUF \
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash

# Pin to a specific ROCm version instead of auto-resolving latest
ROCM_VERSION=7.2 \
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash

# Use a custom amdgpu-install .deb (e.g. for an unsupported Ubuntu codename)
ROCM_AMDGPU_INSTALL_DEB=https://your-mirror/amdgpu-install_7.2.70200-1_all.deb \
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash

# Use OpenAI-compatible llmster endpoints instead of Anthropic-compatible
OPENCLAW_AMD_COMPAT=openai \
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash

# Override the hardcoded RadeonClaw defaults explicitly
OPENCLAW_AMD_CONTEXT_TOKENS=190000 \
OPENCLAW_AMD_MODEL_MAX_TOKENS=190000 \
OPENCLAW_AMD_MAX_AGENTS=2 \
OPENCLAW_AMD_MAX_SUBAGENTS=2 \
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash
```

## Exit behavior

- If systemd was not active yet, the bash script writes `/etc/wsl.conf` and exits with code 10. The PowerShell bootstrap handles this automatically (runs `wsl --shutdown` and resumes). If using Option B, run `wsl --shutdown` from PowerShell, reopen Ubuntu, and rerun the curl command.
- If no model is loaded after llmster starts, the script exits with instructions to download a model with `lms get <model-id>` and rerun.

## llmster quick-reference

```bash
lms status                       # check daemon + server status
lms server stop                  # stop the API server
lms daemon down                  # stop the daemon
lms get qwen/qwen3-coder-next    # download the default model
lms load qwen/qwen3-coder-next   # load it into memory
```
