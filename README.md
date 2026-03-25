# OpenClaw on AMD / WSL bootstrap

This repo collapses AMD's WSL2 + llmster + OpenClaw setup into a single command. Two entry points are provided depending on your starting point.

---

## Option A — Full Windows bootstrap (recommended)

Run this from a **PowerShell** window on your Windows machine. It handles everything from scratch:

1. Self-elevates to Administrator if needed
2. Enables WSL2 (reboots and resumes automatically if required)
3. Installs Ubuntu 24.04 and prompts you to create a Unix username and password
4. Installs llmster and starts the API server
5. Selects the Vulkan GPU backend for AMD GPU acceleration
6. Downloads and loads `nvidia/nemotron-3-nano-4b`
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
- installs the required Linux packages,
- creates `~/.config/systemd/user` and `~/.npm-global`,
- persists `~/.npm-global/bin` into your shell PATH,
- enables systemd in `/etc/wsl.conf` when needed,
- installs Homebrew and persists `brew shellenv`,
- **installs Google Chrome** (required for `openclaw dashboard` to open a browser tab from WSL2),
- installs or updates OpenClaw via the official installer,
- **installs llmster** (the headless LM Studio core) via the official installer,
- **selects the Vulkan llama.cpp runtime** for GPU acceleration,
- **starts the llmster daemon and API server** on `127.0.0.1:1234`,
- **downloads and loads `nvidia/nemotron-3-nano-4b`** by default (with `gpu_offload=max`, `context=190000`, `mmap=on`),
- auto-detects the loaded model and its context length from the local llmster API,
- runs `openclaw onboard` non-interactively against llmster,
- applies the tested RadeonClaw profile by default,
- **starts the OpenClaw gateway**, opens the dashboard in Chrome, then **hatches in TUI** automatically.

---

## Default model

**`nvidia/nemotron-3-nano-4b`** — Nemotron 3 Nano 4B.

Override with `OPENCLAW_AMD_MODEL_ID=<model-id>` (see Useful overrides below).

## Default profile

The script hardcodes the RadeonClaw-style defaults unless you override them:

- `OPENCLAW_AMD_CONTEXT_TOKENS=190000`
- `OPENCLAW_AMD_MODEL_MAX_TOKENS=64000`
- `OPENCLAW_AMD_MAX_AGENTS=2`
- `OPENCLAW_AMD_MAX_SUBAGENTS=2`

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

# Use the default model explicitly
OPENCLAW_AMD_MODEL_ID=nvidia/nemotron-3-nano-4b \
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash

# Use Anthropic-compatible llmster endpoints instead of OpenAI-compatible (default)
OPENCLAW_AMD_COMPAT=anthropic \
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash

# Override the hardcoded RadeonClaw defaults explicitly
OPENCLAW_AMD_CONTEXT_TOKENS=190000 \
OPENCLAW_AMD_MODEL_MAX_TOKENS=64000 \
OPENCLAW_AMD_MAX_AGENTS=2 \
OPENCLAW_AMD_MAX_SUBAGENTS=2 \
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash
```

## Exit behavior

- If systemd was not active yet, the bash script writes `/etc/wsl.conf` and exits with code 10. The PowerShell bootstrap handles this automatically (runs `wsl --shutdown` and resumes). If using Option B, run `wsl --shutdown` from PowerShell, reopen Ubuntu, and rerun the curl command.
- If no model is loaded after llmster starts, the script exits with instructions to download a model with `lms get <model-id>` and rerun.

## Finish line

When everything succeeds the script automatically:

1. Starts the OpenClaw gateway (background process, or via systemd daemon if available)
2. Opens the OpenClaw dashboard in Google Chrome
3. Hatches in TUI — drops you into the live terminal dashboard

Press `Q` to quit the TUI at any time. The gateway keeps running in the background.

## llmster quick-reference

```bash
lms status                            # check daemon + server status
lms server stop                       # stop the API server
lms daemon down                       # stop the daemon
lms runtime ls                        # list runtimes and see which is selected
lms get nvidia/nemotron-3-nano-4b     # download the default model
lms load nvidia/nemotron-3-nano-4b    # load it into memory
```
