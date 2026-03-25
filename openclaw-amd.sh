#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="openclaw-amd"
SCRIPT_VERSION="0.3.0"

OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
OPENCLAW_AMD_PROVIDER_ID="${OPENCLAW_AMD_PROVIDER_ID:-lmstudio}"
OPENCLAW_AMD_COMPAT="${OPENCLAW_AMD_COMPAT:-anthropic}"
OPENCLAW_AMD_MODEL_ID="${OPENCLAW_AMD_MODEL_ID:-zai-org/glm-4.7-flash}"
OPENCLAW_AMD_CONTEXT_TOKENS="${OPENCLAW_AMD_CONTEXT_TOKENS:-190000}"
OPENCLAW_AMD_MODEL_MAX_TOKENS="${OPENCLAW_AMD_MODEL_MAX_TOKENS:-64000}"
OPENCLAW_AMD_MAX_AGENTS="${OPENCLAW_AMD_MAX_AGENTS:-2}"
OPENCLAW_AMD_MAX_SUBAGENTS="${OPENCLAW_AMD_MAX_SUBAGENTS:-2}"
OPENCLAW_AMD_GATEWAY_PORT="${OPENCLAW_AMD_GATEWAY_PORT:-18789}"
OPENCLAW_AMD_GATEWAY_BIND="${OPENCLAW_AMD_GATEWAY_BIND:-loopback}"
OPENCLAW_AMD_SKIP_TUNING="${OPENCLAW_AMD_SKIP_TUNING:-0}"
OPENCLAW_AMD_ALLOW_OPENAI_FALLBACK="${OPENCLAW_AMD_ALLOW_OPENAI_FALLBACK:-1}"
LMSTUDIO_API_KEY="${LMSTUDIO_API_KEY:-lmstudio}"
LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"

# ROCm version to install inside WSL2.
# Requires a compatible AMD Adrenalin driver on the Windows host (26.1.1 or newer).
# See: https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/compatibility/compatibilityrad/wsl/wsl_compatibility.html
ROCM_VERSION="${ROCM_VERSION:-latest}"                       # "latest" auto-resolves; or pin e.g. "7.2"
ROCM_AMDGPU_INSTALL_DEB="${ROCM_AMDGPU_INSTALL_DEB:-}"      # override full deb URL if needed

SYSTEMD_READY=0
DAEMON_INSTALLED=0
RAN_ONBOARD=0
LMS_BIN=""
LMSTUDIO_ROOT="http://127.0.0.1:${LMSTUDIO_PORT}"
LMSTUDIO_MODEL_ID_RESOLVED=""
LMSTUDIO_CONTEXT_TOKENS=""
BREW_BIN=""

info() {
  printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    have sudo || die "sudo is required to continue"
    sudo "$@"
  fi
}

is_wsl() {
  grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null || \
    grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "This script is for Linux/WSL only. Run it inside Ubuntu/WSL on Windows."
}

append_line_if_missing() {
  local file="$1"
  local line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -qxF "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

prepare_npm_global_prefix() {
  mkdir -p "$HOME/.config/systemd/user" "$HOME/.npm-global"
  append_line_if_missing "$HOME/.profile" 'export PATH="$HOME/.npm-global/bin:$PATH"'
  append_line_if_missing "$HOME/.bashrc" 'export PATH="$HOME/.npm-global/bin:$PATH"'
  if [[ -f "$HOME/.zshrc" ]]; then
    append_line_if_missing "$HOME/.zshrc" 'export PATH="$HOME/.npm-global/bin:$PATH"'
  fi
  export NPM_CONFIG_PREFIX="$HOME/.npm-global"
  export PATH="$HOME/.npm-global/bin:$PATH"
  if have npm; then
    npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true
  fi
  hash -r 2>/dev/null || true
}

persist_brew_shellenv() {
  [[ -n "$BREW_BIN" ]] || return 0
  local bash_line='eval "$('"$BREW_BIN"' shellenv bash)"'
  append_line_if_missing "$HOME/.profile" "$bash_line"
  append_line_if_missing "$HOME/.bashrc" "$bash_line"
  if [[ -f "$HOME/.zshrc" ]]; then
    local zsh_line='eval "$('"$BREW_BIN"' shellenv)"'
    append_line_if_missing "$HOME/.zshrc" "$zsh_line"
  fi
  eval "$("$BREW_BIN" shellenv bash)"
  hash -r 2>/dev/null || true
}

install_homebrew_if_missing() {
  if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    BREW_BIN="/home/linuxbrew/.linuxbrew/bin/brew"
    persist_brew_shellenv
    info "Homebrew already installed"
    return 0
  fi

  if have brew; then
    BREW_BIN="$(command -v brew)"
    persist_brew_shellenv
    info "Homebrew already installed"
    return 0
  fi

  info "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    BREW_BIN="/home/linuxbrew/.linuxbrew/bin/brew"
  elif have brew; then
    BREW_BIN="$(command -v brew)"
  fi

  [[ -n "$BREW_BIN" ]] || die "Homebrew install finished, but 'brew' was not found."
  persist_brew_shellenv
}

apt_install_if_missing() {
  have apt-get || die "This script currently targets Ubuntu/Debian/WSL environments with apt-get."
  local missing=()
  local pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if (( ${#missing[@]} > 0 )); then
    info "Installing required packages: ${missing[*]}"
    run_root apt-get update
    DEBIAN_FRONTEND=noninteractive run_root apt-get install -y "${missing[@]}"
  fi
}

# ---------------------------------------------------------------------------
# AMD ROCm driver installation for WSL2
# Installs the amdgpu-install script and ROCm with the 'wsl' usecase.
# The Windows host must already have a compatible AMD Adrenalin driver installed.
# IMPORTANT: never pass --dkms inside WSL2; the kernel module lives on the host.
# ---------------------------------------------------------------------------
install_rocm_wsl() {
  if rocminfo >/dev/null 2>&1; then
    info "ROCm already detected (rocminfo succeeded) — skipping driver install"
    return 0
  fi

  info "Installing AMD ROCm ${ROCM_VERSION} for WSL2"

  # Detect Ubuntu codename for the repo URL
  local codename
  codename="$(. /etc/os-release 2>/dev/null && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
  [[ -n "$codename" ]] || die "Cannot determine Ubuntu codename from /etc/os-release"

  # Map codename -> amdgpu-install repo sub-path used by AMD
  # noble = 24.04, jammy = 22.04 — add more as AMD publishes them
  local repo_codename="$codename"

  # If amdgpu-install is already present (e.g. the .deb was installed in a prior
  # partial run), skip the download and apt-install step and go straight to the
  # usecase install so we don't re-download the package unnecessarily.
  if ! have amdgpu-install; then
    # Build the .deb URL unless the caller overrode it.
    # AMD publishes a /latest/ symlink on repo.radeon.com that always points to the
    # newest amdgpu-install release, so we use that by default to stay current.
    # If the caller sets ROCM_VERSION to a specific tag (e.g. "7.2") the script will
    # try to resolve the matching deb filename from that versioned path instead.
    local deb_url="$ROCM_AMDGPU_INSTALL_DEB"
    if [[ -z "$deb_url" ]]; then
      if [[ "$ROCM_VERSION" == "latest" ]]; then
        # Discover the actual deb name from the /latest/ directory listing
        local index_url="https://repo.radeon.com/amdgpu-install/latest/ubuntu/${repo_codename}/"
        local deb_name
        deb_name="$(curl -fsSL --max-time 10 "$index_url" \
          | grep -oP 'amdgpu-install_[0-9][^"]+\.deb' \
          | sort -V | tail -1)"
        [[ -n "$deb_name" ]] || die "Could not discover amdgpu-install deb from ${index_url}"
        deb_url="${index_url}${deb_name}"
      else
        # Versioned path: encode X.Y -> X0Y00, e.g. 7.2 -> 70200
        local deb_name
        deb_name="$(python3 - "$ROCM_VERSION" <<'PY'
import sys
ver = sys.argv[1].strip()
parts = ver.split(".")
major = int(parts[0])
minor = int(parts[1]) if len(parts) > 1 else 0
patch = int(parts[2]) if len(parts) > 2 else 0
encoded = f"{major}{minor:02d}{patch:02d}"
print(f"amdgpu-install_{ver}.{encoded}-1_all.deb")
PY
)"
        deb_url="https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/${repo_codename}/${deb_name}"
      fi
    fi

    local tmp_deb
    tmp_deb="$(mktemp /tmp/amdgpu-install.XXXXXX.deb)"
    trap 'rm -f "$tmp_deb"' RETURN

    info "Downloading amdgpu-install from: ${deb_url}"
    curl -fSL --retry 3 -o "$tmp_deb" "$deb_url" \
      || die "Failed to download amdgpu-install package. Check ROCM_VERSION (${ROCM_VERSION}) and your Adrenalin driver version."

    apt_install_if_missing wget gnupg2 initramfs-tools
    DEBIAN_FRONTEND=noninteractive run_root apt-get install -y "$tmp_deb"
  else
    info "amdgpu-install already present — skipping package download"
  fi

  info "Running amdgpu-install --usecase=wsl,rocm --no-dkms"
  DEBIAN_FRONTEND=noninteractive run_root amdgpu-install --usecase=wsl,rocm --no-dkms -y \
    || die "amdgpu-install failed. Ensure the AMD Adrenalin driver on Windows matches ROCm ${ROCM_VERSION}."

  # Add user to render and video groups so userspace tools can access the GPU
  run_root usermod -a -G render,video "$USER" 2>/dev/null || true

  info "ROCm ${ROCM_VERSION} installed. You may need to run 'wsl --shutdown' and reopen WSL for group membership to take effect."
}

# ---------------------------------------------------------------------------
# llmster / lms installation
# Installs the headless LM Studio core (llmster) via the official installer.
# Binary lands at ~/.lmstudio/bin/lms and is added to PATH.
# ---------------------------------------------------------------------------
install_llmster() {
  refresh_lms_path

  if [[ -n "$LMS_BIN" ]]; then
    info "llmster (lms) already installed at ${LMS_BIN}"
    return 0
  fi

  info "Installing llmster (LM Studio headless core)"
  curl -fsSL https://lmstudio.ai/install.sh | bash

  refresh_lms_path
  [[ -n "$LMS_BIN" ]] || die "llmster installed, but 'lms' was not found on PATH. Open a new shell and rerun."
}

refresh_lms_path() {
  export PATH="$HOME/.lmstudio/bin:$PATH"
  hash -r 2>/dev/null || true
  if have lms; then
    LMS_BIN="$(command -v lms)"
  fi
}

# Persist ~/.lmstudio/bin in shell profiles so future shells pick it up
persist_lms_path() {
  local lms_path_line='export PATH="$HOME/.lmstudio/bin:$PATH"'
  append_line_if_missing "$HOME/.profile" "$lms_path_line"
  append_line_if_missing "$HOME/.bashrc"  "$lms_path_line"
  if [[ -f "$HOME/.zshrc" ]]; then
    append_line_if_missing "$HOME/.zshrc" "$lms_path_line"
  fi
}

# ---------------------------------------------------------------------------
# Start the llmster daemon, load a model, and start the API server.
# Each sub-step checks whether it is already complete before acting, so this
# function is safe to call on a partial or fully-completed previous run.
# ---------------------------------------------------------------------------

# Returns 0 if the model is already loaded in llmster memory.
lms_model_is_loaded() {
  "$LMS_BIN" ps 2>/dev/null | grep -qF "$OPENCLAW_AMD_MODEL_ID"
}

# Returns 0 if the model file is already present on disk (fully downloaded).
lms_model_is_on_disk() {
  "$LMS_BIN" ls 2>/dev/null | grep -qF "$OPENCLAW_AMD_MODEL_ID"
}

# Returns 0 if the API server is already responding on the expected port.
lms_server_is_up() {
  curl -fsS --max-time 2 \
    -H "Authorization: Bearer ${LMSTUDIO_API_KEY}" \
    "http://127.0.0.1:${LMSTUDIO_PORT}/v1/models" >/dev/null 2>&1
}

start_llmster_server() {
  info "Starting llmster daemon"
  "$LMS_BIN" daemon up 2>/dev/null || true

  if [[ -n "$OPENCLAW_AMD_MODEL_ID" ]]; then
    if lms_model_is_loaded; then
      info "Model already loaded in memory: ${OPENCLAW_AMD_MODEL_ID}"
    else
      # Only download if not already on disk; a completed download is not re-fetched.
      if lms_model_is_on_disk; then
        info "Model already on disk — skipping download: ${OPENCLAW_AMD_MODEL_ID}"
      else
        info "Downloading model: ${OPENCLAW_AMD_MODEL_ID}"
        "$LMS_BIN" get "$OPENCLAW_AMD_MODEL_ID" --yes \
          || die "Failed to download model '${OPENCLAW_AMD_MODEL_ID}'. Check the model ID and your internet connection."
      fi

      info "Loading model: ${OPENCLAW_AMD_MODEL_ID}"
      "$LMS_BIN" load "$OPENCLAW_AMD_MODEL_ID" --yes \
        || die "Failed to load model '${OPENCLAW_AMD_MODEL_ID}'."
    fi
  fi

  # Skip server start (and the readiness wait) if it is already listening.
  if lms_server_is_up; then
    info "llmster API server already running on port ${LMSTUDIO_PORT}"
    return 0
  fi

  info "Starting llmster API server on port ${LMSTUDIO_PORT}"
  "$LMS_BIN" server start --port "$LMSTUDIO_PORT" 2>/dev/null || true

  # Wait for the server socket to be ready
  local attempts=0
  while (( attempts < 20 )); do
    if lms_server_is_up; then
      return 0
    fi
    sleep 1
    (( attempts++ )) || true
  done

  die "llmster API server did not become reachable on port ${LMSTUDIO_PORT} after 20 seconds."
}

curl_json() {
  local url="$1"
  curl -fsS --max-time 5 --retry 1 \
    -H "Authorization: Bearer ${LMSTUDIO_API_KEY}" \
    -H "x-api-key: ${LMSTUDIO_API_KEY}" \
    "$url"
}

maybe_enable_wsl_systemd() {
  if ! is_wsl; then
    local init_comm
    init_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$init_comm" == "systemd" ]] && SYSTEMD_READY=1
    return 0
  fi

  info "Detected WSL"
  local init_comm
  init_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$init_comm" == "systemd" ]]; then
    SYSTEMD_READY=1
    return 0
  fi

  info "Ensuring systemd is enabled in /etc/wsl.conf"
  if run_root test -f /etc/wsl.conf; then
    local backup_path="/etc/wsl.conf.bak.${SCRIPT_NAME}.$(date +%s)"
    run_root cp /etc/wsl.conf "$backup_path"
    info "Backed up /etc/wsl.conf to $backup_path"
  fi

  run_root python3 - <<'PY'
from pathlib import Path
import configparser
path = Path('/etc/wsl.conf')
cp = configparser.ConfigParser(strict=False)
if path.exists():
    cp.read(path)
if not cp.has_section('boot'):
    cp.add_section('boot')
cp.set('boot', 'systemd', 'true')
with path.open('w', encoding='utf-8') as f:
    cp.write(f)
PY

  warn "systemd was not active in this WSL session."
  warn "Run 'wsl --shutdown' from PowerShell, reopen Ubuntu/WSL, and rerun the same curl | bash command."
  exit 10
}

install_or_update_openclaw() {
  prepare_npm_global_prefix
  refresh_openclaw_path
  if have openclaw; then
    info "OpenClaw already installed — skipping installer"
  else
    info "Installing OpenClaw"
    curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-prompt --no-onboard
    if have npm; then
      npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true
    fi
  fi
}

refresh_openclaw_path() {
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  if have npm; then
    local npm_prefix
    npm_prefix="$(npm prefix -g 2>/dev/null || true)"
    if [[ -n "$npm_prefix" ]]; then
      export PATH="$npm_prefix/bin:$npm_prefix:$PATH"
    fi
  fi
  hash -r 2>/dev/null || true
}

require_openclaw() {
  refresh_openclaw_path
  have openclaw || die "OpenClaw installed, but the 'openclaw' command is not on PATH yet. Open a new shell and rerun the script."
}

backup_openclaw_config() {
  local cfg="$1"
  if [[ -f "$cfg" ]]; then
    local backup="${cfg}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$cfg" "$backup"
    info "Backed up existing config to $backup"
  fi
}

# Returns 0 if openclaw.json already contains a complete entry for the current
# provider and model, indicating that onboarding ran successfully before.
is_openclaw_configured() {
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 1
  python3 - <<'PY' "$OPENCLAW_CONFIG_FILE" "$OPENCLAW_AMD_PROVIDER_ID" "$LMSTUDIO_MODEL_ID_RESOLVED"
import json, sys
from pathlib import Path
try:
    cfg = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
except Exception:
    sys.exit(1)
provider_id = sys.argv[2]
model_id    = sys.argv[3]
providers = cfg.get('models', {}).get('providers', {})
if provider_id not in providers:
    sys.exit(1)
models = providers[provider_id].get('models', [])
if not any(isinstance(m, dict) and m.get('id') == model_id for m in models):
    sys.exit(1)
# Also require a gateway entry so a half-finished onboard is re-attempted.
if not cfg.get('gateway'):
    sys.exit(1)
sys.exit(0)
PY
}

# ---------------------------------------------------------------------------
# Resolve model ID and context length from the local llmster API server.
# ---------------------------------------------------------------------------
resolve_lmstudio_endpoint() {
  local payload

  # Try the native LM Studio models endpoint first (richer metadata)
  if payload="$(curl_json "http://127.0.0.1:${LMSTUDIO_PORT}/api/v1/models" 2>/dev/null)"; then
    local resolved
    resolved="$(python3 - <<'PY' "$payload" "$OPENCLAW_AMD_MODEL_ID"
import json
import sys
payload = json.loads(sys.argv[1])
forced = sys.argv[2].strip()
models = payload.get('models') or []

selected = None
selected_ctx = None
best_score = -10**9
for model in models:
    mtype = str(model.get('type', '')).lower()
    if mtype != 'llm':
        continue
    key = model.get('key') or model.get('id') or model.get('model') or model.get('name')
    if not key:
        continue
    if forced and key != forced:
        continue
    loaded_instances = model.get('loaded_instances') or []
    loaded = bool(loaded_instances)
    ctx = None
    if loaded_instances:
        inst = loaded_instances[0] or {}
        cfg = inst.get('config') or {}
        ctx = cfg.get('context_length') or cfg.get('max_context_length')
    ctx = ctx or model.get('max_context_length') or model.get('context_length')
    score = 0
    if loaded:
        score += 100
    if isinstance(ctx, int):
        score += min(ctx, 10_000_000)
    if score > best_score:
        best_score = score
        selected = key
        selected_ctx = ctx

if not selected and forced:
    print(f"{forced}\t")
elif selected:
    print(f"{selected}\t{selected_ctx or ''}")
PY
)"
    if [[ -n "$resolved" ]]; then
      LMSTUDIO_MODEL_ID_RESOLVED="${resolved%%$'\t'*}"
      LMSTUDIO_CONTEXT_TOKENS="${resolved#*$'\t'}"
      [[ "$LMSTUDIO_CONTEXT_TOKENS" == "$resolved" ]] && LMSTUDIO_CONTEXT_TOKENS=""
      return 0
    fi
  fi

  # Fall back to the OpenAI-compatible /v1/models endpoint
  if payload="$(curl_json "http://127.0.0.1:${LMSTUDIO_PORT}/v1/models" 2>/dev/null)"; then
    local resolved
    resolved="$(python3 - <<'PY' "$payload" "$OPENCLAW_AMD_MODEL_ID"
import json
import sys
payload = json.loads(sys.argv[1])
forced = sys.argv[2].strip()
items = payload.get('data') or []
selected = None
for item in items:
    mid = item.get('id') or item.get('model') or item.get('name')
    if not mid:
        continue
    if forced and mid != forced:
        continue
    if 'embedding' in str(mid).lower():
        continue
    selected = mid
    break
if not selected and forced:
    print(forced)
elif selected:
    print(selected)
PY
)"
    if [[ -n "$resolved" ]]; then
      LMSTUDIO_MODEL_ID_RESOLVED="$resolved"
      LMSTUDIO_CONTEXT_TOKENS=""
      return 0
    fi
  fi

  return 1
}

provider_base_url_for_compat() {
  local root="$1"
  local compat="$2"
  if [[ "$compat" == "openai" ]]; then
    printf '%s/v1\n' "${root%/}"
  else
    printf '%s\n' "${root%/}"
  fi
}

run_noninteractive_onboard() {
  local compat="$1"
  local base_url
  base_url="$(provider_base_url_for_compat "$LMSTUDIO_ROOT" "$compat")"

  local cmd=(
    openclaw onboard
    --non-interactive
    --mode local
    --auth-choice custom-api-key
    --custom-base-url "$base_url"
    --custom-model-id "$LMSTUDIO_MODEL_ID_RESOLVED"
    --custom-provider-id "$OPENCLAW_AMD_PROVIDER_ID"
    --custom-compatibility "$compat"
    --custom-api-key "$LMSTUDIO_API_KEY"
    --secret-input-mode plaintext
    --gateway-port "$OPENCLAW_AMD_GATEWAY_PORT"
    --gateway-bind "$OPENCLAW_AMD_GATEWAY_BIND"
    --skip-skills
    --accept-risk
  )

  if (( SYSTEMD_READY )); then
    cmd+=(--install-daemon --daemon-runtime node)
  fi

  info "Configuring OpenClaw against llmster (${compat}-compatible API)"
  if "${cmd[@]}"; then
    DAEMON_INSTALLED=$(( SYSTEMD_READY ? 1 : 0 ))
    RAN_ONBOARD=1
    return 0
  fi

  if (( SYSTEMD_READY )); then
    warn "Onboarding with daemon install failed. Retrying without daemon installation."
    local retry_cmd=(
      openclaw onboard
      --non-interactive
      --mode local
      --auth-choice custom-api-key
      --custom-base-url "$base_url"
      --custom-model-id "$LMSTUDIO_MODEL_ID_RESOLVED"
      --custom-provider-id "$OPENCLAW_AMD_PROVIDER_ID"
      --custom-compatibility "$compat"
      --custom-api-key "$LMSTUDIO_API_KEY"
      --secret-input-mode plaintext
      --gateway-port "$OPENCLAW_AMD_GATEWAY_PORT"
      --gateway-bind "$OPENCLAW_AMD_GATEWAY_BIND"
      --skip-skills
      --skip-health
      --accept-risk
    )
    if "${retry_cmd[@]}"; then
      DAEMON_INSTALLED=0
      RAN_ONBOARD=1
      return 0
    fi
  fi

  return 1
}

auto_tune_config() {
  [[ "$OPENCLAW_AMD_SKIP_TUNING" == "1" ]] && return 0
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 0

  local context_tokens="$OPENCLAW_AMD_CONTEXT_TOKENS"

  python3 - <<'PY' \
    "$OPENCLAW_CONFIG_FILE" \
    "$OPENCLAW_AMD_PROVIDER_ID" \
    "$LMSTUDIO_MODEL_ID_RESOLVED" \
    "$context_tokens" \
    "$OPENCLAW_AMD_MODEL_MAX_TOKENS" \
    "$OPENCLAW_AMD_MAX_AGENTS" \
    "$OPENCLAW_AMD_MAX_SUBAGENTS"
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
provider_id = sys.argv[2]
model_id = sys.argv[3]
context_tokens = int(sys.argv[4])
model_max_tokens = int(sys.argv[5])
max_agents = int(sys.argv[6])
max_subagents = int(sys.argv[7])

cfg = json.loads(config_path.read_text(encoding='utf-8'))
agents = cfg.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})

model_ref = f"{provider_id}/{model_id}"

current_model = defaults.get('model')
if isinstance(current_model, str):
    defaults['model'] = {'primary': model_ref}
elif isinstance(current_model, dict):
    current_model['primary'] = model_ref
else:
    defaults['model'] = {'primary': model_ref}

default_models = defaults.setdefault('models', {})
default_models.setdefault(model_ref, {})
default_models[model_ref].setdefault('alias', 'amd-local')

defaults['contextTokens'] = context_tokens
defaults['maxConcurrent'] = max_agents
subagents = defaults.setdefault('subagents', {})
subagents['maxConcurrent'] = max_subagents

models_root = cfg.setdefault('models', {})
providers = models_root.setdefault('providers', {})
provider = providers.setdefault(provider_id, {})
provider_models = provider.setdefault('models', [])

entry = None
for item in provider_models:
    if isinstance(item, dict) and item.get('id') == model_id:
        entry = item
        break
if entry is None:
    entry = {'id': model_id, 'name': model_id}
    provider_models.append(entry)

entry['contextWindow'] = context_tokens
entry['maxTokens'] = model_max_tokens

config_path.write_text(json.dumps(cfg, indent=2, sort_keys=False) + "\n", encoding='utf-8')
PY

  info "Applied RadeonClaw-default OpenClaw tuning to ${OPENCLAW_CONFIG_FILE}"
}

print_next_steps() {
  printf '\n'
  info "${SCRIPT_NAME} ${SCRIPT_VERSION} complete"
  printf '  llmster endpoint  : %s\n' "$LMSTUDIO_ROOT"
  printf '  Model             : %s\n' "$LMSTUDIO_MODEL_ID_RESOLVED"
  printf '  Context tokens    : %s\n' "$OPENCLAW_AMD_CONTEXT_TOKENS"
  printf '  Max tokens        : %s\n' "$OPENCLAW_AMD_MODEL_MAX_TOKENS"
  printf '  Agent concurrency : %s\n' "$OPENCLAW_AMD_MAX_AGENTS"
  printf '  Subagent conc.    : %s\n' "$OPENCLAW_AMD_MAX_SUBAGENTS"
  printf '\n'
  if (( DAEMON_INSTALLED )); then
    printf 'Next commands:\n'
    printf '  openclaw status\n'
    printf '  openclaw dashboard\n'
  else
    printf 'Next commands:\n'
    printf '  openclaw gateway run\n'
    printf '  openclaw dashboard\n'
  fi
  printf '\n'
  printf 'llmster commands:\n'
  printf '  lms status         # check daemon + server status\n'
  printf '  lms server stop    # stop the API server\n'
  printf '  lms daemon down    # stop the daemon\n'
}

main() {
  require_linux
  apt_install_if_missing ca-certificates curl git python3 build-essential wget gnupg2
  prepare_npm_global_prefix
  maybe_enable_wsl_systemd

  # Install AMD ROCm drivers for WSL2 so the GPU is accessible from Linux
  if is_wsl; then
    install_rocm_wsl
  fi

  install_homebrew_if_missing
  install_or_update_openclaw
  prepare_npm_global_prefix
  require_openclaw

  # Install llmster (headless LM Studio core) and start the local API server
  install_llmster
  persist_lms_path
  start_llmster_server

  if ! resolve_lmstudio_endpoint; then
    warn "llmster is running, but no LLM model could be found on the API."
    if [[ -n "$OPENCLAW_AMD_MODEL_ID" ]]; then
      die "Model '${OPENCLAW_AMD_MODEL_ID}' could not be loaded. Make sure it is downloaded: lms get ${OPENCLAW_AMD_MODEL_ID}"
    else
      die "No model is loaded. Download a model with 'lms get <model-id>' then set OPENCLAW_AMD_MODEL_ID=<model-id> and rerun."
    fi
  fi

  [[ -n "$LMSTUDIO_MODEL_ID_RESOLVED" ]] || die "llmster is reachable, but no LLM model could be selected. Load a model with 'lms load <model-id>' and rerun."

  local configured=0
  if is_openclaw_configured; then
    info "OpenClaw already configured for ${OPENCLAW_AMD_PROVIDER_ID}/${LMSTUDIO_MODEL_ID_RESOLVED} — skipping onboard"
    configured=1
    RAN_ONBOARD=1
    # Treat daemon as installed if systemd is ready; we just can't tell for sure
    # without re-running onboard, so assume the previous run set it up correctly.
    DAEMON_INSTALLED=$(( SYSTEMD_READY ? 1 : 0 ))
  else
    backup_openclaw_config "$OPENCLAW_CONFIG_FILE"

    local compat_attempts=("$OPENCLAW_AMD_COMPAT")
    if [[ "$OPENCLAW_AMD_COMPAT" == "anthropic" && "$OPENCLAW_AMD_ALLOW_OPENAI_FALLBACK" == "1" ]]; then
      compat_attempts+=("openai")
    fi

    local compat
    for compat in "${compat_attempts[@]}"; do
      if run_noninteractive_onboard "$compat"; then
        configured=1
        break
      fi
      warn "OpenClaw onboarding failed for compatibility mode '${compat}'."
    done

    (( configured == 1 )) || die "OpenClaw was installed, but non-interactive onboarding against llmster failed. Try setting OPENCLAW_AMD_MODEL_ID explicitly and rerun."
  fi

  auto_tune_config
  print_next_steps
}

main "$@"
