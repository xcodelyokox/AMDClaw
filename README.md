# OpenClaw on AMD / WSL bootstrap

This repo collapses AMD's longer WSL2 + LM Studio + OpenClaw setup into a single command for the Linux/WSL side.

## Recommended one-liner

Run this inside your Ubuntu/WSL shell after you have:

1. installed WSL + Ubuntu,
2. opened LM Studio on Windows,
3. loaded your local model, and
4. enabled LM Studio's local server and **Serve on Local Network**.

```bash
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/openclaw-amd.sh | bash
```

From PowerShell, you can launch the same thing through WSL:

```powershell
wsl -d Ubuntu-24.04 bash -lc 'curl -fsSL https://raw.githubusercontent.com/xcodelyokox/amdclaw/main/openclaw-amd.sh | bash'
```

## What the script automates

- installs the Linux packages the AMD guide relies on for the WSL side,
- creates `~/.config/systemd/user` and `~/.npm-global`,
- persists `~/.npm-global/bin` into your shell PATH,
- enables systemd in `/etc/wsl.conf` when needed,
- installs Homebrew and persists `brew shellenv`,
- installs or updates OpenClaw via the official installer,
- auto-detects LM Studio from WSL,
- auto-selects an LLM model from LM Studio,
- runs `openclaw onboard` non-interactively against LM Studio, including explicit non-interactive risk acknowledgement,
- applies the tested RadeonClaw profile by default.

## Default profile

The script hardcodes the RadeonClaw-style defaults unless you override them:

- `OPENCLAW_AMD_CONTEXT_TOKENS=190000`
- `OPENCLAW_AMD_MODEL_MAX_TOKENS=190000`
- `OPENCLAW_AMD_MAX_AGENTS=2`
- `OPENCLAW_AMD_MAX_SUBAGENTS=2`

These defaults are used for both RadeonClaw and RyzenClaw in this bootstrap.

## What it intentionally does **not** automate

These are still Windows / GUI steps from the AMD guide and still need to be done manually:

- AMD driver updates,
- Ryzen AI Max+ Variable Graphics Memory changes,
- LM Studio installation,
- model download and load choices in LM Studio,
- Discord/channel pairing,
- optional browser relay setup.

## Useful overrides

```bash
# If autodetect cannot find LM Studio from WSL
OPENCLAW_AMD_LMSTUDIO_URL=http://192.168.1.50:1234 \
OPENCLAW_AMD_MODEL_ID=lmstudio-community/Qwen3.5-35B-A3B-GGUF \
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/openclaw-amd.sh | bash

# If you want OpenAI-compatible LM Studio endpoints instead of Anthropic-compatible
OPENCLAW_AMD_COMPAT=openai \
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/openclaw-amd.sh | bash

# Override the hardcoded RadeonClaw defaults explicitly
OPENCLAW_AMD_CONTEXT_TOKENS=190000 \
OPENCLAW_AMD_MODEL_MAX_TOKENS=190000 \
OPENCLAW_AMD_MAX_AGENTS=2 \
OPENCLAW_AMD_MAX_SUBAGENTS=2 \
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/openclaw-amd.sh | bash
```

## Exit behavior

- If systemd was not active yet, the script writes `/etc/wsl.conf`, tells you to run `wsl --shutdown`, and exits. Re-run the same one-liner after reopening Ubuntu.
- If LM Studio is not reachable yet, the script still installs Homebrew and OpenClaw, then exits with instructions to start the LM Studio server and rerun.
