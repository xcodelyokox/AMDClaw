# OpenClaw on AMD 

This repo is meant to collapse the long AMD OpenClaw setup into a single WSL command.

## Recommended one-liner

Run this inside your Ubuntu/WSL shell after you have:

1. installed WSL + Ubuntu,
2. opened LM Studio on Windows,
3. loaded your local model, and
4. enabled LM Studio's local server (and **Serve on Local Network**).

```bash
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/openclaw-amd.sh | bash
```

From PowerShell, you can launch the same thing through WSL:

```powershell
wsl -d Ubuntu-24.04 bash -lc 'curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/openclaw-amd.sh | bash'
```

## What the script automates

- installs the Linux packages the AMD guide relies on for the WSL side,
- enables systemd in `/etc/wsl.conf` when needed,
- installs Homebrew for Linux/WSL so brew-dependent skills work out of the box,
- installs or updates OpenClaw via the official installer,
- auto-detects LM Studio from WSL,
- auto-selects an LLM model from LM Studio,
- runs `openclaw onboard` non-interactively against LM Studio,
- applies the tested RadeonClaw default profile for both RadeonClaw and RyzenClaw (`contextTokens=190000`, `maxTokens=190000`, `maxConcurrent=2`, `subagents.maxConcurrent=2`).

## What it intentionally does **not** automate

These are Windows / GUI steps from the AMD guide and still need to be done manually:

- AMD driver updates,
- Ryzen AI Max+ Variable Graphics Memory changes,
- LM Studio installation,
- model download choices in LM Studio,
- Chrome relay / Discord pairing / skill-specific package installs after Homebrew itself is present.

## Useful overrides

```bash
# If autodetect cannot find LM Studio from WSL
OPENCLAW_AMD_LMSTUDIO_URL=http://192.168.1.50:1234 \
OPENCLAW_AMD_MODEL_ID=lmstudio-community/Qwen3.5-35B-A3B-GGUF \
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/openclaw-amd.sh | bash

# If you want OpenAI-compatible LM Studio endpoints instead of Anthropic-compatible
OPENCLAW_AMD_COMPAT=openai \
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/openclaw-amd.sh | bash

# Tune concurrency / context explicitly (default is the tested RadeonClaw profile)
OPENCLAW_AMD_CONTEXT_TOKENS=190000 \
OPENCLAW_AMD_MODEL_MAX_TOKENS=190000 \
OPENCLAW_AMD_MAX_AGENTS=2 \
OPENCLAW_AMD_MAX_SUBAGENTS=2 \
curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/openclaw-amd.sh | bash
```

## Exit behavior

- If systemd was not active yet, the script writes `/etc/wsl.conf`, asks you to run `wsl --shutdown`, and exits. Re-run the same one-liner after reopening Ubuntu.
- If LM Studio is not reachable yet, the script still installs Homebrew and OpenClaw, then exits with instructions to start the LM Studio server and rerun.

## Default tuning

The script hardcodes the tested RadeonClaw profile as the default for both RadeonClaw and RyzenClaw:

- `contextTokens=190000`
- `maxTokens=190000`
- `maxConcurrent=2`
- `subagents.maxConcurrent=2`

You can still override these with environment variables if you want, but you no longer need a separate RyzenClaw default profile.
