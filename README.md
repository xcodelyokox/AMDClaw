# OpenClaw on AMD — LM Studio + WSL2 Bootstrap

This repo collapses AMD's WSL2 + LM Studio + OpenClaw setup into a single command. LM Studio runs natively on Windows with GPU offload; OpenClaw runs inside WSL2 and connects to LM Studio over the LAN.

> **Architecture:** LM Studio on Windows host &rarr; WSL2 connects via `http://<host-ip>:1234`
>
> **No API key needed.** Models are served locally by LM Studio (Anthropic-compatible API).
>
> **Model selection:** The script auto-detects loaded models from LM Studio and presents an interactive arrow-key picker.

---

## Prerequisites

1. **LM Studio** installed and running on Windows with at least one model loaded
2. A Windows machine with WSL2 support (Windows 10 build 19041+ or Windows 11)
3. For AMD Ryzen AI Max+ systems: Variable Graphics Memory set to 96GB (see [AMD article](https://www.amd.com/en/resources/articles/run-openclaw-locally-on-amd-ryzen-ai-max-and-radeon-gpus.html))

---

## Option A — Full Windows bootstrap (recommended)

Run this from a **PowerShell** window. It handles everything from scratch:

1. Self-elevates to Administrator if needed
2. Enables WSL2 (reboots and resumes automatically if required)
3. Installs Ubuntu 24.04 and prompts you to create a Unix username and password
4. Detects LM Studio on the Windows host and resolves the endpoint for WSL2
5. Adds a firewall rule if needed so WSL2 can reach LM Studio
6. Runs the bash script inside WSL2 (see below)

```powershell
irm https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd-bootstrap.ps1 | iex
```

---

## Option B — WSL-only (WSL2 + Ubuntu already installed)

Run this inside an existing Ubuntu/WSL shell. The script auto-detects the Windows host IP:

```bash
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash
```

Or pass the LM Studio URL explicitly:

```bash
LMSTUDIO_BASE_URL=http://172.20.0.1:1234 \
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash
```

---

## What the scripts automate

**PowerShell (`openclaw-amd-bootstrap.ps1`):**
- Self-elevates to Administrator
- Enables `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform` Windows features
- Reboots and resumes automatically via a scheduled task if required
- Installs Ubuntu 24.04
- Probes the LM Studio API on `localhost:1234` to verify it's running with models loaded
- Determines the Windows host IP for WSL2 (`vEthernet (WSL)` adapter)
- Tests connectivity from WSL2 and offers to add a firewall rule if blocked
- Invokes `openclaw-amd.sh` inside WSL with `LMSTUDIO_BASE_URL` forwarded
- Handles the systemd-restart step (`exit 10`) transparently

**Bash (`openclaw-amd.sh`):**
- Shows a risk disclaimer and requires user acceptance before proceeding
- Installs required Linux packages (`ca-certificates`, `curl`, `git`, `python3`, `build-essential`)
- Configures `~/.npm-global` for non-root npm installs and persists `openclaw` to PATH
- Enables systemd in `/etc/wsl.conf` when needed
- Auto-detects the LM Studio endpoint (probes default gateway, all host IPs, resolv.conf nameserver)
- Probes the LM Studio API with retries and clear error messaging
- **Interactive model picker** — queries `GET /v1/models`, presents an arrow-key menu (auto-selects if only one model)
- Installs Google Chrome in WSL2 for browser control via CDP (port 9222)
- Installs OpenClaw via the official installer and persists it to PATH
- Runs `openclaw onboard --non-interactive` (Anthropic-compatible, pointing at LM Studio)
- Applies profile tuning (context tokens, max tokens, agent concurrency, embeddings, browser CDP)
- Persists `DISPLAY=:0` for WSLg so the agent can launch Chrome
- Runs interactive onboard for gateway, hooks, skills, and channels
- Writes `TOOLS.md` with Chrome browser usage instructions for the agent
- Builds the memory search index (`openclaw memory index`)
- Launches the hatching experience (final interactive onboard pass)

---

## Default profile

| Setting | Default | Override env var |
|---|---|---|
| Context tokens | 190,000 | `OPENCLAW_AMD_CONTEXT_TOKENS` |
| Max output tokens | 64,000 | `OPENCLAW_AMD_MODEL_MAX_TOKENS` |
| Max agents | 2 | `OPENCLAW_AMD_MAX_AGENTS` |
| Max subagents | 2 | `OPENCLAW_AMD_MAX_SUBAGENTS` |
| Gateway port | 18789 | `OPENCLAW_AMD_GATEWAY_PORT` |

---

## Useful overrides

```bash
# Pre-select a specific model (skips the model picker)
OPENCLAW_AMD_MODEL_ID=nvidia/nemotron-3-nano-4b \
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash

# Custom LM Studio URL (e.g. LM Studio on a different machine)
LMSTUDIO_BASE_URL=http://192.168.1.50:1234 \
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash

# Override the default profile
OPENCLAW_AMD_CONTEXT_TOKENS=260000 \
OPENCLAW_AMD_MAX_AGENTS=6 \
OPENCLAW_AMD_MAX_SUBAGENTS=2 \
curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash
```

---

## What it intentionally does **not** automate

- LM Studio installation on Windows (install from [lmstudio.ai](https://lmstudio.ai))
- Model downloading in LM Studio (use LM Studio's UI to search and download models)
- AMD driver installation / Variable Graphics Memory changes

---

## LM Studio configuration tips

Based on the [AMD article](https://www.amd.com/en/resources/articles/run-openclaw-locally-on-amd-ryzen-ai-max-and-radeon-gpus.html):

1. Enable **Developer Mode** in LM Studio settings
2. Set context length to **190,000** (or your preferred value)
3. Set **GPU Offload to MAX**
4. Enable **Flash Attention**
5. Set **Max Concurrent Predictions** to `max_agents + (max_agents * max_subagents)` (default: 6)
6. Keep **Unified KV Cache** enabled to save memory

---

## Three-pass onboard

The bash script runs `openclaw onboard` three times for a seamless experience:

1. **Non-interactive** — configures the LM Studio provider, model, API key, and gateway settings silently
2. **Interactive (no hatch)** — lets you configure gateway, hooks, skills, and channels interactively
3. **Hatch only** — skips all config steps and launches the hatching UI

---

## Exit behavior

- If systemd was not active yet, the bash script writes `/etc/wsl.conf` and exits with code 10. The PowerShell bootstrap handles this automatically. If using Option B, run `wsl --shutdown` from PowerShell, reopen Ubuntu, and rerun.
- If LM Studio is not reachable, the script installs everything it can, then exits with instructions to start the LM Studio server and rerun.
