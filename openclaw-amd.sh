#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="openclaw-amd"
SCRIPT_VERSION="0.5.0"

OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
LMSTUDIO_BASE_URL="${LMSTUDIO_BASE_URL:-}"
OPENCLAW_AMD_MODEL_ID="${OPENCLAW_AMD_MODEL_ID:-}"
OPENCLAW_AMD_CONTEXT_TOKENS="${OPENCLAW_AMD_CONTEXT_TOKENS:-190000}"
OPENCLAW_AMD_MODEL_MAX_TOKENS="${OPENCLAW_AMD_MODEL_MAX_TOKENS:-64000}"
OPENCLAW_AMD_MAX_AGENTS="${OPENCLAW_AMD_MAX_AGENTS:-2}"
OPENCLAW_AMD_MAX_SUBAGENTS="${OPENCLAW_AMD_MAX_SUBAGENTS:-2}"
OPENCLAW_AMD_GATEWAY_PORT="${OPENCLAW_AMD_GATEWAY_PORT:-18789}"
OPENCLAW_AMD_GATEWAY_BIND="${OPENCLAW_AMD_GATEWAY_BIND:-loopback}"
OPENCLAW_AMD_SKIP_TUNING="${OPENCLAW_AMD_SKIP_TUNING:-0}"

SYSTEMD_READY=0
DAEMON_INSTALLED=0
RAN_ONBOARD=0

print_banner() {
  printf '\033[1;31m░████░█░░░░░█████░█░░░█░███░░████░░████░░▀█▀\033[0m\n'
  printf '\033[1;31m█░░░░░█░░░░░█░░░█░█░█░█░█░░█░█░░░█░█░░░█░░█░\033[0m\n'
  printf '\033[1;31m█░░░░░█░░░░░█████░█░█░█░█░░█░████░░█░░░█░░█░\033[0m\n'
  printf '\033[1;31m█░░░░░█░░░░░█░░░█░█░█░█░█░░█░█░░█░░█░░░█░░█░\033[0m\n'
  printf '\033[1;31m░████░█████░█░░░█░░█░█░░███░░████░░░███░░░█░\033[0m\n'
  printf '\033[1;33m  🦞  AMD Quick Start (LM Studio + OpenClaw)  🦞\033[0m\n'
  printf '\n'
}

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
  mkdir -p "$HOME/.config/systemd/user" "$HOME/.npm-global" "$HOME/.local/bin"

  # Persist both ~/.npm-global/bin and ~/.local/bin (where openclaw may install)
  local path_line='export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"'
  append_line_if_missing "$HOME/.profile" "$path_line"
  append_line_if_missing "$HOME/.bashrc" "$path_line"
  if [[ -f "$HOME/.zshrc" ]]; then
    append_line_if_missing "$HOME/.zshrc" "$path_line"
  fi

  export NPM_CONFIG_PREFIX="$HOME/.npm-global"
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  if have npm; then
    npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true
    # Also add the npm global prefix bin to profiles
    local npm_prefix
    npm_prefix="$(npm prefix -g 2>/dev/null || true)"
    if [[ -n "$npm_prefix" && "$npm_prefix" != "$HOME/.npm-global" ]]; then
      local npm_path_line="export PATH=\"${npm_prefix}/bin:\$PATH\""
      append_line_if_missing "$HOME/.profile" "$npm_path_line"
      append_line_if_missing "$HOME/.bashrc" "$npm_path_line"
      export PATH="${npm_prefix}/bin:$PATH"
    fi
  fi
  hash -r 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# LM Studio detection — resolve Windows host IP from inside WSL2
# ---------------------------------------------------------------------------

LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"

# Probe a candidate IP for a reachable LM Studio API.
# Tries the native /api/v1 endpoint first, then the OpenAI-compat /v1 endpoint.
probe_lmstudio() {
  local ip="$1"
  curl -fsS --max-time 2 "http://${ip}:${LMSTUDIO_PORT}/v1/models" >/dev/null 2>&1 \
    || curl -fsS --max-time 2 "http://${ip}:${LMSTUDIO_PORT}/api/v1/models" >/dev/null 2>&1
}

resolve_lmstudio_url() {
  # Already set via environment (e.g. forwarded from PowerShell)
  if [[ -n "$LMSTUDIO_BASE_URL" ]]; then
    info "LM Studio base URL from environment: $LMSTUDIO_BASE_URL"
    return 0
  fi

  info "Detecting LM Studio on Windows host..."

  # Collect unique candidate IPs to try, in priority order
  local -a candidates=()

  # 1. Mirrored networking (newer Windows 11) — localhost works directly
  candidates+=("127.0.0.1")

  # 2. Default gateway — usually the Windows host in WSL2 NAT mode
  local gw_ip
  gw_ip="$(ip route show default 2>/dev/null | awk '{print $3}' | head -1 || true)"
  if [[ -n "$gw_ip" ]] && [[ "$gw_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    candidates+=("$gw_ip")
  fi

  # 3. /etc/resolv.conf nameserver
  local dns_ip
  if [[ -f /etc/resolv.conf ]]; then
    dns_ip="$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}' || true)"
    if [[ -n "$dns_ip" ]] && [[ "$dns_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      candidates+=("$dns_ip")
    fi
  fi

  # 4. Ask PowerShell for ALL host IPv4 addresses (WSL adapter, LAN, Wi-Fi, etc.)
  #    This catches the real LAN IP (e.g. 192.168.0.218) that LM Studio binds to
  #    when "Serve on Local Network" is enabled.
  local ps_ips
  ps_ips="$(powershell.exe -NoProfile -Command \
    'Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } | ForEach-Object { $_.IPAddress }' \
    2>/dev/null | tr -d '\r' || true)"
  local ps_ip
  while IFS= read -r ps_ip; do
    ps_ip="${ps_ip// /}"
    if [[ -n "$ps_ip" ]] && [[ "$ps_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      candidates+=("$ps_ip")
    fi
  done <<< "$ps_ips"

  # De-duplicate while preserving order
  local -a unique=()
  local -A seen=()
  local c
  for c in "${candidates[@]}"; do
    if [[ -z "${seen[$c]+x}" ]]; then
      seen[$c]=1
      unique+=("$c")
    fi
  done

  # Probe each candidate
  for c in "${unique[@]}"; do
    info "  Trying ${c}:${LMSTUDIO_PORT} ..."
    if probe_lmstudio "$c"; then
      LMSTUDIO_BASE_URL="http://${c}:${LMSTUDIO_PORT}/v1"
      info "LM Studio found at: $LMSTUDIO_BASE_URL"
      return 0
    fi
  done

  # None worked — ask the user
  warn "Could not auto-detect LM Studio. Tried: ${unique[*]}"
  warn "Ensure LM Studio is running on Windows with a model loaded."
  warn "Ensure 'Serve on Local Network' is enabled in LM Studio settings."
  warn "Ensure Windows Firewall allows inbound connections on port ${LMSTUDIO_PORT}."
  printf '\n'
  read -r -p "Enter the LM Studio host IP (e.g. 192.168.0.218): " user_ip < /dev/tty
  user_ip="${user_ip// /}"
  if [[ -z "$user_ip" ]]; then
    die "No IP provided. Set LMSTUDIO_BASE_URL manually (e.g. LMSTUDIO_BASE_URL=http://192.168.0.218:${LMSTUDIO_PORT}/v1)."
  fi
  LMSTUDIO_BASE_URL="http://${user_ip}:${LMSTUDIO_PORT}/v1"
  info "Using user-provided LM Studio URL: $LMSTUDIO_BASE_URL"
}

wait_for_lmstudio() {
  local url="${LMSTUDIO_BASE_URL}/models"
  local attempts=0
  local max_attempts=10

  info "Checking LM Studio API at ${url}"
  while (( attempts < max_attempts )); do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      info "LM Studio API is reachable"
      return 0
    fi
    (( attempts++ )) || true
    if (( attempts == 1 )); then
      warn "LM Studio not reachable yet."
      warn "Ensure LM Studio is running on Windows with a model loaded."
      warn "Ensure Windows Firewall allows inbound connections on port 1234."
    fi
    sleep 2
  done

  die "LM Studio API at ${url} is not reachable after ${max_attempts} attempts. Start LM Studio, load a model, check firewall, and rerun."
}

# ---------------------------------------------------------------------------
# Dynamic model selection from LM Studio
# ---------------------------------------------------------------------------

# Interactive arrow-key menu.  Reads from /dev/tty so it works even when
# the script itself is piped in via  curl … | bash.
#
# Usage:  pick_from_menu RESULT_VAR "Prompt text" item1 item2 …
pick_from_menu() {
  local _result_var="$1"; shift
  local _prompt="$1"; shift
  local -a _items=("$@")
  local _count=${#_items[@]}
  local _cur=0

  # Save terminal state and switch to raw mode on /dev/tty
  local _old_stty
  _old_stty="$(stty -g < /dev/tty 2>/dev/null)"
  stty -echo -icanon min 1 time 0 < /dev/tty 2>/dev/null

  # Hide cursor
  printf '\033[?25l' > /dev/tty

  _draw_menu() {
    # Move cursor to start of menu area and redraw
    local i
    for i in "${!_items[@]}"; do
      printf '\r\033[2K' > /dev/tty
      if (( i == _cur )); then
        printf '  \033[1;7;36m > %s \033[0m\n' "${_items[$i]}" > /dev/tty
      else
        printf '  \033[0;90m   %s\033[0m\n' "${_items[$i]}" > /dev/tty
      fi
    done
    printf '\r\033[2K\033[0;33m  ↑↓ move  ⏎ select\033[0m' > /dev/tty
    # Move cursor back up to top of menu + hint line
    printf '\033[%dA' "$(( _count ))" > /dev/tty
  }

  printf '\n' > /dev/tty
  printf '\033[1;34m[INFO]\033[0m %s\n\n' "$_prompt" > /dev/tty
  _draw_menu

  local _key
  while true; do
    # Read one byte from /dev/tty
    IFS= read -r -n1 _key < /dev/tty 2>/dev/null || true

    if [[ "$_key" == $'\x1b' ]]; then
      # Escape sequence — read two more bytes for arrow keys
      local _seq1 _seq2
      IFS= read -r -n1 -t 0.1 _seq1 < /dev/tty 2>/dev/null || true
      IFS= read -r -n1 -t 0.1 _seq2 < /dev/tty 2>/dev/null || true
      if [[ "$_seq1" == "[" ]]; then
        case "$_seq2" in
          A) # Up arrow
            (( _cur > 0 )) && (( _cur-- ))
            _draw_menu
            ;;
          B) # Down arrow
            (( _cur < _count - 1 )) && (( _cur++ )) || true
            _draw_menu
            ;;
        esac
      fi
    elif [[ "$_key" == "" || "$_key" == $'\n' ]]; then
      # Enter pressed — accept selection
      break
    elif [[ "$_key" == "k" ]]; then
      (( _cur > 0 )) && (( _cur-- ))
      _draw_menu
    elif [[ "$_key" == "j" ]]; then
      (( _cur < _count - 1 )) && (( _cur++ )) || true
      _draw_menu
    fi
  done

  # Move past the menu and hint line, show cursor, restore terminal
  printf '\033[%dB' "$(( _count ))" > /dev/tty
  printf '\r\033[2K\n' > /dev/tty
  printf '\033[?25h' > /dev/tty
  stty "$_old_stty" < /dev/tty 2>/dev/null || true

  eval "$_result_var=\${_items[\$_cur]}"
}

select_lmstudio_model() {
  # If model already set by env var, skip selection
  if [[ -n "$OPENCLAW_AMD_MODEL_ID" ]]; then
    info "Using model from environment: $OPENCLAW_AMD_MODEL_ID"
    return 0
  fi

  local models_url="${LMSTUDIO_BASE_URL}/models"
  local response
  response="$(curl -fsS --max-time 5 "$models_url")" \
    || die "Failed to query models from LM Studio at ${models_url}"

  # Parse model IDs, filter out embedding models
  local model_list
  model_list="$(printf '%s' "$response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
models = data.get('data', [])
if not models:
    sys.exit(1)
for m in models:
    mid = m.get('id', '')
    if 'embed' in mid.lower():
        continue
    print(mid)
" 2>/dev/null)" || die "No models loaded in LM Studio. Load a model in LM Studio and rerun."

  # Read into array
  local -a models=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && models+=("$line")
  done <<< "$model_list"

  if (( ${#models[@]} == 0 )); then
    die "No models found in LM Studio. Load a model and rerun."
  fi

  if (( ${#models[@]} == 1 )); then
    OPENCLAW_AMD_MODEL_ID="${models[0]}"
    info "Only one model loaded: ${OPENCLAW_AMD_MODEL_ID}"
    return 0
  fi

  # Multiple models — interactive arrow-key picker
  pick_from_menu OPENCLAW_AMD_MODEL_ID "Select a model from LM Studio:" "${models[@]}"
  info "Selected model: ${OPENCLAW_AMD_MODEL_ID}"
}

# ---------------------------------------------------------------------------
# Google Chrome — required so OpenClaw can drive a visible browser inside WSL2
# ---------------------------------------------------------------------------
install_chrome_if_missing() {
  if have google-chrome-stable || have google-chrome || have chromium-browser || have chromium; then
    info "Chrome/Chromium already installed — skipping"
    return 0
  fi

  info "Installing Google Chrome"
  apt_install_if_missing wget gnupg2

  wget -qO- https://dl.google.com/linux/linux_signing_key.pub \
    | run_root gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg

  printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main\n' \
    | run_root tee /etc/apt/sources.list.d/google-chrome.list >/dev/null

  run_root apt-get update
  DEBIAN_FRONTEND=noninteractive run_root apt-get install -y google-chrome-stable

  have google-chrome-stable || warn "Chrome install finished but 'google-chrome-stable' not found on PATH."

  apt_install_if_missing wslu

  info "Google Chrome installed"
}

# ---------------------------------------------------------------------------
# OpenClaw install
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Configure OpenClaw against LM Studio non-interactively.
# ---------------------------------------------------------------------------
run_noninteractive_onboard() {
  local base_url="$1"
  local provider_id="lmstudio"
  local api_key="lm-studio"

  local cmd=(
    openclaw onboard
    --non-interactive
    --mode local
    --auth-choice custom-api-key
    --custom-base-url "$base_url"
    --custom-model-id "$OPENCLAW_AMD_MODEL_ID"
    --custom-provider-id "$provider_id"
    --custom-compatibility "openai"
    --custom-api-key "$api_key"
    --secret-input-mode plaintext
    --gateway-port "$OPENCLAW_AMD_GATEWAY_PORT"
    --gateway-bind "$OPENCLAW_AMD_GATEWAY_BIND"
    --accept-risk
  )

  if (( SYSTEMD_READY )); then
    cmd+=(--install-daemon --daemon-runtime node)
  fi

  info "Configuring OpenClaw against LM Studio (${base_url})"
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
      --custom-model-id "$OPENCLAW_AMD_MODEL_ID"
      --custom-provider-id "$provider_id"
      --custom-compatibility "openai"
      --custom-api-key "$api_key"
      --secret-input-mode plaintext
      --gateway-port "$OPENCLAW_AMD_GATEWAY_PORT"
      --gateway-bind "$OPENCLAW_AMD_GATEWAY_BIND"
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

# ---------------------------------------------------------------------------
# Check if OpenClaw is already configured for LM Studio provider/model.
# ---------------------------------------------------------------------------
is_openclaw_configured() {
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 1
  python3 - <<'PY' "$OPENCLAW_CONFIG_FILE" "lmstudio" "$OPENCLAW_AMD_MODEL_ID"
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
provider = providers[provider_id]

models = provider.get('models', [])
if not any(isinstance(m, dict) and m.get('id') == model_id for m in models):
    sys.exit(1)

if not cfg.get('gateway'):
    sys.exit(1)
sys.exit(0)
PY
}

auto_tune_config() {
  [[ "$OPENCLAW_AMD_SKIP_TUNING" == "1" ]] && return 0
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 0

  local context_tokens="$OPENCLAW_AMD_CONTEXT_TOKENS"

  python3 - <<'PY' \
    "$OPENCLAW_CONFIG_FILE" \
    "lmstudio" \
    "$OPENCLAW_AMD_MODEL_ID" \
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
default_models[model_ref].setdefault('alias', 'lmstudio-local')

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

# --- Local embeddings for Memory.md (embeddinggemma-300m via node-llama-cpp) ---
ms = defaults.setdefault('memorySearch', {})
ms['enabled'] = True
ms['provider'] = 'local'
ms.setdefault('local', {})
ms['local']['modelPath'] = 'hf:ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/embeddinggemma-300m-qat-Q8_0.gguf'
ms.setdefault('query', {})
ms['query']['maxResults'] = 30
ms['query']['minScore'] = 0.15
ms['query'].setdefault('hybrid', {})
ms['query']['hybrid']['enabled'] = True
ms['query']['hybrid']['vectorWeight'] = 0.7
ms['query']['hybrid']['textWeight'] = 0.3

# --- Browser profile: connect to Chrome via CDP on port 9222 ---
browser = cfg.setdefault('browser', {})
profiles = browser.setdefault('profiles', {})
chrome_profile = profiles.setdefault('default', {})
chrome_profile['cdpUrl'] = 'http://127.0.0.1:9222'
chrome_profile.setdefault('color', '4A90D9')

config_path.write_text(json.dumps(cfg, indent=2, sort_keys=False) + "\n", encoding='utf-8')
PY

  info "Applied OpenClaw tuning to ${OPENCLAW_CONFIG_FILE}"
  info "Local embeddings configured (embeddinggemma-300m — will auto-download on first use)"
}

# ---------------------------------------------------------------------------
# Seed workspace files if missing (fixes known bug #16457 where BOOTSTRAP.md
# is not created on fresh installs).
# ---------------------------------------------------------------------------
seed_workspace() {
  local ws_dir="$HOME/.openclaw/workspace"
  mkdir -p "$ws_dir/memory" "$ws_dir/skills"

  # BOOTSTRAP.md — the hatching script. Only written if workspace is brand new.
  if [[ ! -f "$ws_dir/BOOTSTRAP.md" ]]; then
    info "Seeding BOOTSTRAP.md (first-run hatching script)"
    cat > "$ws_dir/BOOTSTRAP.md" <<'BOOTSTRAP'
# Bootstrap

Welcome to your first conversation! Let's get you set up.

Please walk me through the following, **one question at a time**:

1. **What should I call you?** (your name or preferred alias)
2. **What's your timezone?** (e.g., US/Eastern, Europe/London, Asia/Tokyo)
3. **What kind of work will we be doing together?** (e.g., coding, research, writing, DevOps)
4. **Any preferences for how I communicate?** (e.g., concise vs. detailed, formal vs. casual)

After we finish:
- Save my answers to `USER.md`
- Open `SOUL.md` and ask me if I'd like to customize your personality
- Create `IDENTITY.md` with a name I choose for you

When everything is set up, **delete this file** — you don't need a bootstrap script anymore. You're you now. Good luck out there.
BOOTSTRAP
  fi

  # SOUL.md — agent personality
  if [[ ! -f "$ws_dir/SOUL.md" ]]; then
    info "Seeding SOUL.md"
    cat > "$ws_dir/SOUL.md" <<'SOUL'
# Soul

You are a helpful, knowledgeable AI assistant. You are direct, honest, and efficient.

## Communication style
- Be concise but thorough
- Lead with the answer, then explain if needed
- Ask clarifying questions when requirements are ambiguous

## Values
- Accuracy over speed
- Security-conscious by default
- Respect the user's time and preferences
SOUL
  fi

  # AGENTS.md — operating instructions
  if [[ ! -f "$ws_dir/AGENTS.md" ]]; then
    info "Seeding AGENTS.md"
    cat > "$ws_dir/AGENTS.md" <<'AGENTS'
# Agents

## Operating Instructions
- Always read files before modifying them
- Prefer editing existing files over creating new ones
- Run tests after making changes when a test suite exists
- Ask before taking destructive or irreversible actions
AGENTS
  fi

  # USER.md — filled in during hatching
  if [[ ! -f "$ws_dir/USER.md" ]]; then
    info "Seeding USER.md"
    cat > "$ws_dir/USER.md" <<'USER'
# User

<!-- This file will be filled in during your first conversation (hatching). -->
USER
  fi

  # IDENTITY.md — filled in during hatching
  if [[ ! -f "$ws_dir/IDENTITY.md" ]]; then
    info "Seeding IDENTITY.md"
    cat > "$ws_dir/IDENTITY.md" <<'IDENTITY'
# Identity

<!-- This file will be filled in during your first conversation (hatching). -->
IDENTITY
  fi

  # MEMORY.md — long-term memory
  if [[ ! -f "$ws_dir/MEMORY.md" ]]; then
    info "Seeding MEMORY.md"
    cat > "$ws_dir/MEMORY.md" <<'MEMORY'
# Memory

<!-- The agent will add notes here as it learns about you and your projects. -->
MEMORY
  fi

  # TOOLS.md — environment notes
  if [[ ! -f "$ws_dir/TOOLS.md" ]]; then
    info "Seeding TOOLS.md"
    cat > "$ws_dir/TOOLS.md" <<'TOOLS'
# Tools

## Environment
- Platform: WSL2 (Ubuntu) on Windows
- LLM Backend: LM Studio (local, OpenAI-compatible API)
- Browser: Google Chrome (WSL2, CDP on port 9222)
TOOLS
  fi

  info "Workspace seeded at ${ws_dir}"
}

print_summary() {
  printf '\n'
  info "${SCRIPT_NAME} ${SCRIPT_VERSION} complete"
  printf '  LM Studio endpoint : %s\n' "$LMSTUDIO_BASE_URL"
  printf '  Model              : %s\n' "$OPENCLAW_AMD_MODEL_ID"
  printf '  Context tokens     : %s\n' "$OPENCLAW_AMD_CONTEXT_TOKENS"
  printf '  Max tokens         : %s\n' "$OPENCLAW_AMD_MODEL_MAX_TOKENS"
  printf '  Agent concurrency  : %s\n' "$OPENCLAW_AMD_MAX_AGENTS"
  printf '  Subagent conc.     : %s\n' "$OPENCLAW_AMD_MAX_SUBAGENTS"
  printf '\n'
}

# ---------------------------------------------------------------------------
# Start the OpenClaw gateway and open the dashboard in Chrome inside WSL2.
# ---------------------------------------------------------------------------
launch_openclaw() {
  print_summary

  if (( DAEMON_INSTALLED )); then
    info "Gateway daemon is installed — ensuring it is running"
    openclaw gateway start 2>/dev/null || true
  else
    info "Starting OpenClaw gateway in the background"
    nohup openclaw gateway run \
      --port "$OPENCLAW_AMD_GATEWAY_PORT" \
      --bind "$OPENCLAW_AMD_GATEWAY_BIND" \
      >/tmp/openclaw-gateway.log 2>&1 &
    disown
  fi

  # Wait for gateway to be fully ready
  local gw_ready=0
  local gw_attempts=0
  while (( gw_attempts < 20 )); do
    if curl -fsS --max-time 1 \
         "http://127.0.0.1:${OPENCLAW_AMD_GATEWAY_PORT}/" >/dev/null 2>&1; then
      gw_ready=1
      break
    fi
    sleep 0.5
    (( gw_attempts++ )) || true
  done
  if (( ! gw_ready )); then
    warn "Gateway may not be fully ready; dashboard might take a moment to load."
  fi

  # Get the dashboard URL (includes access token)
  local dashboard_url=""
  local dashboard_output
  dashboard_output="$(openclaw dashboard --no-open 2>&1 || true)"
  dashboard_url="$(printf '%s' "$dashboard_output" | grep -oP 'https?://\S+' | head -1 || true)"

  # If openclaw dashboard didn't return a URL, try to extract the token from config
  if [[ -z "$dashboard_url" ]] && [[ -f "$OPENCLAW_CONFIG_FILE" ]]; then
    local gw_token
    gw_token="$(python3 -c "
import json, sys
from pathlib import Path
try:
    cfg = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
    token = cfg.get('gateway', {}).get('auth', {}).get('token', '')
    if token:
        print(token)
except Exception:
    pass
" "$OPENCLAW_CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$gw_token" ]]; then
      dashboard_url="http://127.0.0.1:${OPENCLAW_AMD_GATEWAY_PORT}/#token=${gw_token}"
    fi
  fi

  if [[ -z "$dashboard_url" ]]; then
    dashboard_url="http://127.0.0.1:${OPENCLAW_AMD_GATEWAY_PORT}/"
    warn "Could not retrieve dashboard token. You may need to authenticate manually."
  fi
  info "Dashboard: ${dashboard_url}"

  # Open dashboard in Chrome inside WSL2
  local chrome_bin=""
  if have google-chrome-stable; then
    chrome_bin="google-chrome-stable"
  elif have google-chrome; then
    chrome_bin="google-chrome"
  elif have chromium-browser; then
    chrome_bin="chromium-browser"
  elif have chromium; then
    chrome_bin="chromium"
  fi

  local chrome_debug_port=9222
  local chrome_user_data="$HOME/.openclaw/browser/chrome-profile"
  mkdir -p "$chrome_user_data"

  if [[ -n "$chrome_bin" ]]; then
    info "Launching Chrome with remote debugging (port ${chrome_debug_port}) for OpenClaw browser control"
    nohup "$chrome_bin" \
      --no-first-run \
      --no-default-browser-check \
      --remote-debugging-port="$chrome_debug_port" \
      --remote-allow-origins="*" \
      --user-data-dir="$chrome_user_data" \
      "$dashboard_url" >/dev/null 2>&1 &
    disown
    info "Chrome running with CDP on port ${chrome_debug_port}"
  else
    warn "Chrome not found in WSL2. Open the dashboard manually:"
    info "  $dashboard_url"
  fi

  info "Gateway is running in the background."
  info "To check status:  openclaw gateway status"
  info "To stop gateway:  openclaw gateway stop"
}

main() {
  print_banner
  require_linux
  apt_install_if_missing ca-certificates curl git python3 build-essential wget gnupg2
  prepare_npm_global_prefix
  maybe_enable_wsl_systemd

  # LM Studio detection
  resolve_lmstudio_url
  wait_for_lmstudio
  select_lmstudio_model

  # Chrome (needed for OpenClaw browser control inside WSL2)
  install_chrome_if_missing

  # OpenClaw install
  install_or_update_openclaw
  prepare_npm_global_prefix
  require_openclaw

  # Risk acknowledgement (shown to user before onboard)
  if ! is_openclaw_configured; then
    printf '\n'
    warn "============================================================"
    warn "  IMPORTANT: OpenClaw is a highly autonomous AI agent."
    warn "  Giving any AI agent access to your system may result in"
    warn "  unpredictable actions with unpredictable outcomes."
    warn "  AMD recommends running on a separate, clean PC with no"
    warn "  personal data, or within a virtual machine."
    warn "============================================================"
    printf '\n'
    local accept=""
    read -r -p "Do you accept the risk and wish to continue? [y/N]: " accept < /dev/tty
    if [[ ! "$accept" =~ ^[Yy] ]]; then
      die "Risk not accepted. Exiting."
    fi
    printf '\n'
  fi

  # Onboard or skip if already configured
  local configured=0
  if is_openclaw_configured; then
    info "OpenClaw already configured for lmstudio/${OPENCLAW_AMD_MODEL_ID} — skipping onboard"
    configured=1
    RAN_ONBOARD=1
    DAEMON_INSTALLED=$(( SYSTEMD_READY ? 1 : 0 ))
  else
    backup_openclaw_config "$OPENCLAW_CONFIG_FILE"
    if run_noninteractive_onboard "$LMSTUDIO_BASE_URL"; then
      configured=1
    else
      warn "Non-interactive onboard failed."
    fi
    (( configured == 1 )) || die "OpenClaw onboarding against LM Studio failed. Check the output above."
  fi

  auto_tune_config
  seed_workspace

  # Interactive onboard pass — lets the user configure hooks, skills, channels
  # The non-interactive pass above already set up provider/model/gateway,
  # so this second pass detects existing config and only walks through the
  # remaining steps (hooks, skills, channels, web search).
  info "Launching interactive onboard for hooks, skills, and channels setup..."
  printf '\n'
  openclaw onboard < /dev/tty || warn "Interactive onboard exited with an error. You can re-run it later with: openclaw onboard"
  printf '\n'

  print_summary
  info "Setup complete. OpenClaw is ready."
}

main "$@"
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="openclaw-amd"
SCRIPT_VERSION="0.5.0"

OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
LMSTUDIO_BASE_URL="${LMSTUDIO_BASE_URL:-}"
OPENCLAW_AMD_MODEL_ID="${OPENCLAW_AMD_MODEL_ID:-}"
OPENCLAW_AMD_CONTEXT_TOKENS="${OPENCLAW_AMD_CONTEXT_TOKENS:-190000}"
OPENCLAW_AMD_MODEL_MAX_TOKENS="${OPENCLAW_AMD_MODEL_MAX_TOKENS:-64000}"
OPENCLAW_AMD_MAX_AGENTS="${OPENCLAW_AMD_MAX_AGENTS:-2}"
OPENCLAW_AMD_MAX_SUBAGENTS="${OPENCLAW_AMD_MAX_SUBAGENTS:-2}"
OPENCLAW_AMD_GATEWAY_PORT="${OPENCLAW_AMD_GATEWAY_PORT:-18789}"
OPENCLAW_AMD_GATEWAY_BIND="${OPENCLAW_AMD_GATEWAY_BIND:-loopback}"
OPENCLAW_AMD_SKIP_TUNING="${OPENCLAW_AMD_SKIP_TUNING:-0}"

SYSTEMD_READY=0
DAEMON_INSTALLED=0
RAN_ONBOARD=0

print_banner() {
  printf '\033[1;31m░████░█░░░░░█████░█░░░█░███░░████░░████░░▀█▀\033[0m\n'
  printf '\033[1;31m█░░░░░█░░░░░█░░░█░█░█░█░█░░█░█░░░█░█░░░█░░█░\033[0m\n'
  printf '\033[1;31m█░░░░░█░░░░░█████░█░█░█░█░░█░████░░█░░░█░░█░\033[0m\n'
  printf '\033[1;31m█░░░░░█░░░░░█░░░█░█░█░█░█░░█░█░░█░░█░░░█░░█░\033[0m\n'
  printf '\033[1;31m░████░█████░█░░░█░░█░█░░███░░████░░░███░░░█░\033[0m\n'
  printf '\033[1;33m  🦞  AMD Quick Start (LM Studio + OpenClaw)  🦞\033[0m\n'
  printf '\n'
}

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
  mkdir -p "$HOME/.config/systemd/user" "$HOME/.npm-global" "$HOME/.local/bin"

  # Persist both ~/.npm-global/bin and ~/.local/bin (where openclaw may install)
  local path_line='export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"'
  append_line_if_missing "$HOME/.profile" "$path_line"
  append_line_if_missing "$HOME/.bashrc" "$path_line"
  if [[ -f "$HOME/.zshrc" ]]; then
    append_line_if_missing "$HOME/.zshrc" "$path_line"
  fi

  export NPM_CONFIG_PREFIX="$HOME/.npm-global"
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  if have npm; then
    npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true
    # Also add the npm global prefix bin to profiles
    local npm_prefix
    npm_prefix="$(npm prefix -g 2>/dev/null || true)"
    if [[ -n "$npm_prefix" && "$npm_prefix" != "$HOME/.npm-global" ]]; then
      local npm_path_line="export PATH=\"${npm_prefix}/bin:\$PATH\""
      append_line_if_missing "$HOME/.profile" "$npm_path_line"
      append_line_if_missing "$HOME/.bashrc" "$npm_path_line"
      export PATH="${npm_prefix}/bin:$PATH"
    fi
  fi
  hash -r 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# LM Studio detection — resolve Windows host IP from inside WSL2
# ---------------------------------------------------------------------------

LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"

# Probe a candidate IP for a reachable LM Studio API.
# Tries the native /api/v1 endpoint first, then the OpenAI-compat /v1 endpoint.
probe_lmstudio() {
  local ip="$1"
  curl -fsS --max-time 2 "http://${ip}:${LMSTUDIO_PORT}/v1/models" >/dev/null 2>&1 \
    || curl -fsS --max-time 2 "http://${ip}:${LMSTUDIO_PORT}/api/v1/models" >/dev/null 2>&1
}

resolve_lmstudio_url() {
  # Already set via environment (e.g. forwarded from PowerShell)
  if [[ -n "$LMSTUDIO_BASE_URL" ]]; then
    info "LM Studio base URL from environment: $LMSTUDIO_BASE_URL"
    return 0
  fi

  info "Detecting LM Studio on Windows host..."

  # Collect unique candidate IPs to try, in priority order
  local -a candidates=()

  # 1. Mirrored networking (newer Windows 11) — localhost works directly
  candidates+=("127.0.0.1")

  # 2. Default gateway — usually the Windows host in WSL2 NAT mode
  local gw_ip
  gw_ip="$(ip route show default 2>/dev/null | awk '{print $3}' | head -1 || true)"
  if [[ -n "$gw_ip" ]] && [[ "$gw_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    candidates+=("$gw_ip")
  fi

  # 3. /etc/resolv.conf nameserver
  local dns_ip
  if [[ -f /etc/resolv.conf ]]; then
    dns_ip="$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}' || true)"
    if [[ -n "$dns_ip" ]] && [[ "$dns_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      candidates+=("$dns_ip")
    fi
  fi

  # 4. Ask PowerShell for ALL host IPv4 addresses (WSL adapter, LAN, Wi-Fi, etc.)
  #    This catches the real LAN IP (e.g. 192.168.0.218) that LM Studio binds to
  #    when "Serve on Local Network" is enabled.
  local ps_ips
  ps_ips="$(powershell.exe -NoProfile -Command \
    'Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } | ForEach-Object { $_.IPAddress }' \
    2>/dev/null | tr -d '\r' || true)"
  local ps_ip
  while IFS= read -r ps_ip; do
    ps_ip="${ps_ip// /}"
    if [[ -n "$ps_ip" ]] && [[ "$ps_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      candidates+=("$ps_ip")
    fi
  done <<< "$ps_ips"

  # De-duplicate while preserving order
  local -a unique=()
  local -A seen=()
  local c
  for c in "${candidates[@]}"; do
    if [[ -z "${seen[$c]+x}" ]]; then
      seen[$c]=1
      unique+=("$c")
    fi
  done

  # Probe each candidate
  for c in "${unique[@]}"; do
    info "  Trying ${c}:${LMSTUDIO_PORT} ..."
    if probe_lmstudio "$c"; then
      LMSTUDIO_BASE_URL="http://${c}:${LMSTUDIO_PORT}/v1"
      info "LM Studio found at: $LMSTUDIO_BASE_URL"
      return 0
    fi
  done

  # None worked — ask the user
  warn "Could not auto-detect LM Studio. Tried: ${unique[*]}"
  warn "Ensure LM Studio is running on Windows with a model loaded."
  warn "Ensure 'Serve on Local Network' is enabled in LM Studio settings."
  warn "Ensure Windows Firewall allows inbound connections on port ${LMSTUDIO_PORT}."
  printf '\n'
  read -r -p "Enter the LM Studio host IP (e.g. 192.168.0.218): " user_ip < /dev/tty
  user_ip="${user_ip// /}"
  if [[ -z "$user_ip" ]]; then
    die "No IP provided. Set LMSTUDIO_BASE_URL manually (e.g. LMSTUDIO_BASE_URL=http://192.168.0.218:${LMSTUDIO_PORT}/v1)."
  fi
  LMSTUDIO_BASE_URL="http://${user_ip}:${LMSTUDIO_PORT}/v1"
  info "Using user-provided LM Studio URL: $LMSTUDIO_BASE_URL"
}

wait_for_lmstudio() {
  local url="${LMSTUDIO_BASE_URL}/models"
  local attempts=0
  local max_attempts=10

  info "Checking LM Studio API at ${url}"
  while (( attempts < max_attempts )); do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      info "LM Studio API is reachable"
      return 0
    fi
    (( attempts++ )) || true
    if (( attempts == 1 )); then
      warn "LM Studio not reachable yet."
      warn "Ensure LM Studio is running on Windows with a model loaded."
      warn "Ensure Windows Firewall allows inbound connections on port 1234."
    fi
    sleep 2
  done

  die "LM Studio API at ${url} is not reachable after ${max_attempts} attempts. Start LM Studio, load a model, check firewall, and rerun."
}

# ---------------------------------------------------------------------------
# Dynamic model selection from LM Studio
# ---------------------------------------------------------------------------

# Interactive arrow-key menu.  Reads from /dev/tty so it works even when
# the script itself is piped in via  curl … | bash.
#
# Usage:  pick_from_menu RESULT_VAR "Prompt text" item1 item2 …
pick_from_menu() {
  local _result_var="$1"; shift
  local _prompt="$1"; shift
  local -a _items=("$@")
  local _count=${#_items[@]}
  local _cur=0

  # Save terminal state and switch to raw mode on /dev/tty
  local _old_stty
  _old_stty="$(stty -g < /dev/tty 2>/dev/null)"
  stty -echo -icanon min 1 time 0 < /dev/tty 2>/dev/null

  # Hide cursor
  printf '\033[?25l' > /dev/tty

  _draw_menu() {
    # Move cursor to start of menu area and redraw
    local i
    for i in "${!_items[@]}"; do
      printf '\r\033[2K' > /dev/tty
      if (( i == _cur )); then
        printf '  \033[1;7;36m > %s \033[0m\n' "${_items[$i]}" > /dev/tty
      else
        printf '  \033[0;90m   %s\033[0m\n' "${_items[$i]}" > /dev/tty
      fi
    done
    printf '\r\033[2K\033[0;33m  ↑↓ move  ⏎ select\033[0m' > /dev/tty
    # Move cursor back up to top of menu + hint line
    printf '\033[%dA' "$(( _count ))" > /dev/tty
  }

  printf '\n' > /dev/tty
  printf '\033[1;34m[INFO]\033[0m %s\n\n' "$_prompt" > /dev/tty
  _draw_menu

  local _key
  while true; do
    # Read one byte from /dev/tty
    IFS= read -r -n1 _key < /dev/tty 2>/dev/null || true

    if [[ "$_key" == $'\x1b' ]]; then
      # Escape sequence — read two more bytes for arrow keys
      local _seq1 _seq2
      IFS= read -r -n1 -t 0.1 _seq1 < /dev/tty 2>/dev/null || true
      IFS= read -r -n1 -t 0.1 _seq2 < /dev/tty 2>/dev/null || true
      if [[ "$_seq1" == "[" ]]; then
        case "$_seq2" in
          A) # Up arrow
            (( _cur > 0 )) && (( _cur-- ))
            _draw_menu
            ;;
          B) # Down arrow
            (( _cur < _count - 1 )) && (( _cur++ )) || true
            _draw_menu
            ;;
        esac
      fi
    elif [[ "$_key" == "" || "$_key" == $'\n' ]]; then
      # Enter pressed — accept selection
      break
    elif [[ "$_key" == "k" ]]; then
      (( _cur > 0 )) && (( _cur-- ))
      _draw_menu
    elif [[ "$_key" == "j" ]]; then
      (( _cur < _count - 1 )) && (( _cur++ )) || true
      _draw_menu
    fi
  done

  # Move past the menu and hint line, show cursor, restore terminal
  printf '\033[%dB' "$(( _count ))" > /dev/tty
  printf '\r\033[2K\n' > /dev/tty
  printf '\033[?25h' > /dev/tty
  stty "$_old_stty" < /dev/tty 2>/dev/null || true

  eval "$_result_var=\${_items[\$_cur]}"
}

select_lmstudio_model() {
  # If model already set by env var, skip selection
  if [[ -n "$OPENCLAW_AMD_MODEL_ID" ]]; then
    info "Using model from environment: $OPENCLAW_AMD_MODEL_ID"
    return 0
  fi

  local models_url="${LMSTUDIO_BASE_URL}/models"
  local response
  response="$(curl -fsS --max-time 5 "$models_url")" \
    || die "Failed to query models from LM Studio at ${models_url}"

  # Parse model IDs, filter out embedding models
  local model_list
  model_list="$(printf '%s' "$response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
models = data.get('data', [])
if not models:
    sys.exit(1)
for m in models:
    mid = m.get('id', '')
    if 'embed' in mid.lower():
        continue
    print(mid)
" 2>/dev/null)" || die "No models loaded in LM Studio. Load a model in LM Studio and rerun."

  # Read into array
  local -a models=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && models+=("$line")
  done <<< "$model_list"

  if (( ${#models[@]} == 0 )); then
    die "No models found in LM Studio. Load a model and rerun."
  fi

  if (( ${#models[@]} == 1 )); then
    OPENCLAW_AMD_MODEL_ID="${models[0]}"
    info "Only one model loaded: ${OPENCLAW_AMD_MODEL_ID}"
    return 0
  fi

  # Multiple models — interactive arrow-key picker
  pick_from_menu OPENCLAW_AMD_MODEL_ID "Select a model from LM Studio:" "${models[@]}"
  info "Selected model: ${OPENCLAW_AMD_MODEL_ID}"
}

# ---------------------------------------------------------------------------
# Google Chrome — required so OpenClaw can drive a visible browser inside WSL2
# ---------------------------------------------------------------------------
install_chrome_if_missing() {
  if have google-chrome-stable || have google-chrome || have chromium-browser || have chromium; then
    info "Chrome/Chromium already installed — skipping"
    return 0
  fi

  info "Installing Google Chrome"
  apt_install_if_missing wget gnupg2

  wget -qO- https://dl.google.com/linux/linux_signing_key.pub \
    | run_root gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg

  printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main\n' \
    | run_root tee /etc/apt/sources.list.d/google-chrome.list >/dev/null

  run_root apt-get update
  DEBIAN_FRONTEND=noninteractive run_root apt-get install -y google-chrome-stable

  have google-chrome-stable || warn "Chrome install finished but 'google-chrome-stable' not found on PATH."

  apt_install_if_missing wslu

  info "Google Chrome installed"
}

# ---------------------------------------------------------------------------
# OpenClaw install
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Configure OpenClaw against LM Studio non-interactively.
# ---------------------------------------------------------------------------
run_noninteractive_onboard() {
  local base_url="$1"
  local provider_id="lmstudio"
  local api_key="lm-studio"

  local cmd=(
    openclaw onboard
    --non-interactive
    --mode local
    --auth-choice custom-api-key
    --custom-base-url "$base_url"
    --custom-model-id "$OPENCLAW_AMD_MODEL_ID"
    --custom-provider-id "$provider_id"
    --custom-compatibility "openai"
    --custom-api-key "$api_key"
    --secret-input-mode plaintext
    --gateway-port "$OPENCLAW_AMD_GATEWAY_PORT"
    --gateway-bind "$OPENCLAW_AMD_GATEWAY_BIND"
    --accept-risk
  )

  if (( SYSTEMD_READY )); then
    cmd+=(--install-daemon --daemon-runtime node)
  fi

  info "Configuring OpenClaw against LM Studio (${base_url})"
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
      --custom-model-id "$OPENCLAW_AMD_MODEL_ID"
      --custom-provider-id "$provider_id"
      --custom-compatibility "openai"
      --custom-api-key "$api_key"
      --secret-input-mode plaintext
      --gateway-port "$OPENCLAW_AMD_GATEWAY_PORT"
      --gateway-bind "$OPENCLAW_AMD_GATEWAY_BIND"
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

# ---------------------------------------------------------------------------
# Check if OpenClaw is already configured for LM Studio provider/model.
# ---------------------------------------------------------------------------
is_openclaw_configured() {
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 1
  python3 - <<'PY' "$OPENCLAW_CONFIG_FILE" "lmstudio" "$OPENCLAW_AMD_MODEL_ID"
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
provider = providers[provider_id]

models = provider.get('models', [])
if not any(isinstance(m, dict) and m.get('id') == model_id for m in models):
    sys.exit(1)

if not cfg.get('gateway'):
    sys.exit(1)
sys.exit(0)
PY
}

auto_tune_config() {
  [[ "$OPENCLAW_AMD_SKIP_TUNING" == "1" ]] && return 0
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 0

  local context_tokens="$OPENCLAW_AMD_CONTEXT_TOKENS"

  python3 - <<'PY' \
    "$OPENCLAW_CONFIG_FILE" \
    "lmstudio" \
    "$OPENCLAW_AMD_MODEL_ID" \
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
default_models[model_ref].setdefault('alias', 'lmstudio-local')

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

# --- Local embeddings for Memory.md (embeddinggemma-300m via node-llama-cpp) ---
ms = defaults.setdefault('memorySearch', {})
ms['enabled'] = True
ms['provider'] = 'local'
ms.setdefault('local', {})
ms['local']['modelPath'] = 'hf:ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/embeddinggemma-300m-qat-Q8_0.gguf'
ms.setdefault('query', {})
ms['query']['maxResults'] = 30
ms['query']['minScore'] = 0.15
ms['query'].setdefault('hybrid', {})
ms['query']['hybrid']['enabled'] = True
ms['query']['hybrid']['vectorWeight'] = 0.7
ms['query']['hybrid']['textWeight'] = 0.3

# --- Browser profile: connect to Chrome via CDP on port 9222 ---
browser = cfg.setdefault('browser', {})
profiles = browser.setdefault('profiles', {})
chrome_profile = profiles.setdefault('default', {})
chrome_profile['cdpUrl'] = 'http://127.0.0.1:9222'
chrome_profile.setdefault('color', 'blue')

config_path.write_text(json.dumps(cfg, indent=2, sort_keys=False) + "\n", encoding='utf-8')
PY

  info "Applied OpenClaw tuning to ${OPENCLAW_CONFIG_FILE}"
  info "Local embeddings configured (embeddinggemma-300m — will auto-download on first use)"
}

# ---------------------------------------------------------------------------
# Seed workspace files if missing (fixes known bug #16457 where BOOTSTRAP.md
# is not created on fresh installs).
# ---------------------------------------------------------------------------
seed_workspace() {
  local ws_dir="$HOME/.openclaw/workspace"
  mkdir -p "$ws_dir/memory" "$ws_dir/skills"

  # BOOTSTRAP.md — the hatching script. Only written if workspace is brand new.
  if [[ ! -f "$ws_dir/BOOTSTRAP.md" ]]; then
    info "Seeding BOOTSTRAP.md (first-run hatching script)"
    cat > "$ws_dir/BOOTSTRAP.md" <<'BOOTSTRAP'
# Bootstrap

Welcome to your first conversation! Let's get you set up.

Please walk me through the following, **one question at a time**:

1. **What should I call you?** (your name or preferred alias)
2. **What's your timezone?** (e.g., US/Eastern, Europe/London, Asia/Tokyo)
3. **What kind of work will we be doing together?** (e.g., coding, research, writing, DevOps)
4. **Any preferences for how I communicate?** (e.g., concise vs. detailed, formal vs. casual)

After we finish:
- Save my answers to `USER.md`
- Open `SOUL.md` and ask me if I'd like to customize your personality
- Create `IDENTITY.md` with a name I choose for you

When everything is set up, **delete this file** — you don't need a bootstrap script anymore. You're you now. Good luck out there.
BOOTSTRAP
  fi

  # SOUL.md — agent personality
  if [[ ! -f "$ws_dir/SOUL.md" ]]; then
    info "Seeding SOUL.md"
    cat > "$ws_dir/SOUL.md" <<'SOUL'
# Soul

You are a helpful, knowledgeable AI assistant. You are direct, honest, and efficient.

## Communication style
- Be concise but thorough
- Lead with the answer, then explain if needed
- Ask clarifying questions when requirements are ambiguous

## Values
- Accuracy over speed
- Security-conscious by default
- Respect the user's time and preferences
SOUL
  fi

  # AGENTS.md — operating instructions
  if [[ ! -f "$ws_dir/AGENTS.md" ]]; then
    info "Seeding AGENTS.md"
    cat > "$ws_dir/AGENTS.md" <<'AGENTS'
# Agents

## Operating Instructions
- Always read files before modifying them
- Prefer editing existing files over creating new ones
- Run tests after making changes when a test suite exists
- Ask before taking destructive or irreversible actions
AGENTS
  fi

  # USER.md — filled in during hatching
  if [[ ! -f "$ws_dir/USER.md" ]]; then
    info "Seeding USER.md"
    cat > "$ws_dir/USER.md" <<'USER'
# User

<!-- This file will be filled in during your first conversation (hatching). -->
USER
  fi

  # IDENTITY.md — filled in during hatching
  if [[ ! -f "$ws_dir/IDENTITY.md" ]]; then
    info "Seeding IDENTITY.md"
    cat > "$ws_dir/IDENTITY.md" <<'IDENTITY'
# Identity

<!-- This file will be filled in during your first conversation (hatching). -->
IDENTITY
  fi

  # MEMORY.md — long-term memory
  if [[ ! -f "$ws_dir/MEMORY.md" ]]; then
    info "Seeding MEMORY.md"
    cat > "$ws_dir/MEMORY.md" <<'MEMORY'
# Memory

<!-- The agent will add notes here as it learns about you and your projects. -->
MEMORY
  fi

  # TOOLS.md — environment notes
  if [[ ! -f "$ws_dir/TOOLS.md" ]]; then
    info "Seeding TOOLS.md"
    cat > "$ws_dir/TOOLS.md" <<'TOOLS'
# Tools

## Environment
- Platform: WSL2 (Ubuntu) on Windows
- LLM Backend: LM Studio (local, OpenAI-compatible API)
- Browser: Google Chrome (WSL2, CDP on port 9222)
TOOLS
  fi

  info "Workspace seeded at ${ws_dir}"
}

print_summary() {
  printf '\n'
  info "${SCRIPT_NAME} ${SCRIPT_VERSION} complete"
  printf '  LM Studio endpoint : %s\n' "$LMSTUDIO_BASE_URL"
  printf '  Model              : %s\n' "$OPENCLAW_AMD_MODEL_ID"
  printf '  Context tokens     : %s\n' "$OPENCLAW_AMD_CONTEXT_TOKENS"
  printf '  Max tokens         : %s\n' "$OPENCLAW_AMD_MODEL_MAX_TOKENS"
  printf '  Agent concurrency  : %s\n' "$OPENCLAW_AMD_MAX_AGENTS"
  printf '  Subagent conc.     : %s\n' "$OPENCLAW_AMD_MAX_SUBAGENTS"
  printf '\n'
}

# ---------------------------------------------------------------------------
# Start the OpenClaw gateway and open the dashboard in Chrome inside WSL2.
# ---------------------------------------------------------------------------
launch_openclaw() {
  print_summary

  if (( DAEMON_INSTALLED )); then
    info "Gateway daemon is installed — ensuring it is running"
    openclaw gateway start 2>/dev/null || true
  else
    info "Starting OpenClaw gateway in the background"
    nohup openclaw gateway run \
      --port "$OPENCLAW_AMD_GATEWAY_PORT" \
      --bind "$OPENCLAW_AMD_GATEWAY_BIND" \
      >/tmp/openclaw-gateway.log 2>&1 &
    disown
  fi

  # Wait for gateway to be fully ready
  local gw_ready=0
  local gw_attempts=0
  while (( gw_attempts < 20 )); do
    if curl -fsS --max-time 1 \
         "http://127.0.0.1:${OPENCLAW_AMD_GATEWAY_PORT}/" >/dev/null 2>&1; then
      gw_ready=1
      break
    fi
    sleep 0.5
    (( gw_attempts++ )) || true
  done
  if (( ! gw_ready )); then
    warn "Gateway may not be fully ready; dashboard might take a moment to load."
  fi

  # Get the dashboard URL (includes access token)
  local dashboard_url=""
  local dashboard_output
  dashboard_output="$(openclaw dashboard --no-open 2>&1 || true)"
  dashboard_url="$(printf '%s' "$dashboard_output" | grep -oP 'https?://\S+' | head -1 || true)"

  # If openclaw dashboard didn't return a URL, try to extract the token from config
  if [[ -z "$dashboard_url" ]] && [[ -f "$OPENCLAW_CONFIG_FILE" ]]; then
    local gw_token
    gw_token="$(python3 -c "
import json, sys
from pathlib import Path
try:
    cfg = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
    token = cfg.get('gateway', {}).get('auth', {}).get('token', '')
    if token:
        print(token)
except Exception:
    pass
" "$OPENCLAW_CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$gw_token" ]]; then
      dashboard_url="http://127.0.0.1:${OPENCLAW_AMD_GATEWAY_PORT}/#token=${gw_token}"
    fi
  fi

  if [[ -z "$dashboard_url" ]]; then
    dashboard_url="http://127.0.0.1:${OPENCLAW_AMD_GATEWAY_PORT}/"
    warn "Could not retrieve dashboard token. You may need to authenticate manually."
  fi
  info "Dashboard: ${dashboard_url}"

  # Open dashboard in Chrome inside WSL2
  local chrome_bin=""
  if have google-chrome-stable; then
    chrome_bin="google-chrome-stable"
  elif have google-chrome; then
    chrome_bin="google-chrome"
  elif have chromium-browser; then
    chrome_bin="chromium-browser"
  elif have chromium; then
    chrome_bin="chromium"
  fi

  local chrome_debug_port=9222
  local chrome_user_data="$HOME/.openclaw/browser/chrome-profile"
  mkdir -p "$chrome_user_data"

  if [[ -n "$chrome_bin" ]]; then
    info "Launching Chrome with remote debugging (port ${chrome_debug_port}) for OpenClaw browser control"
    nohup "$chrome_bin" \
      --no-first-run \
      --no-default-browser-check \
      --remote-debugging-port="$chrome_debug_port" \
      --remote-allow-origins="*" \
      --user-data-dir="$chrome_user_data" \
      "$dashboard_url" >/dev/null 2>&1 &
    disown
    info "Chrome running with CDP on port ${chrome_debug_port}"
  else
    warn "Chrome not found in WSL2. Open the dashboard manually:"
    info "  $dashboard_url"
  fi

  info "Gateway is running in the background."
  info "To check status:  openclaw gateway status"
  info "To stop gateway:  openclaw gateway stop"
}

main() {
  print_banner
  require_linux
  apt_install_if_missing ca-certificates curl git python3 build-essential wget gnupg2
  prepare_npm_global_prefix
  maybe_enable_wsl_systemd

  # LM Studio detection
  resolve_lmstudio_url
  wait_for_lmstudio
  select_lmstudio_model

  # Chrome (needed for OpenClaw browser control inside WSL2)
  install_chrome_if_missing

  # OpenClaw install
  install_or_update_openclaw
  prepare_npm_global_prefix
  require_openclaw

  # Risk acknowledgement (shown to user before onboard)
  if ! is_openclaw_configured; then
    printf '\n'
    warn "============================================================"
    warn "  IMPORTANT: OpenClaw is a highly autonomous AI agent."
    warn "  Giving any AI agent access to your system may result in"
    warn "  unpredictable actions with unpredictable outcomes."
    warn "  AMD recommends running on a separate, clean PC with no"
    warn "  personal data, or within a virtual machine."
    warn "============================================================"
    printf '\n'
    local accept=""
    read -r -p "Do you accept the risk and wish to continue? [y/N]: " accept < /dev/tty
    if [[ ! "$accept" =~ ^[Yy] ]]; then
      die "Risk not accepted. Exiting."
    fi
    printf '\n'
  fi

  # Onboard or skip if already configured
  local configured=0
  if is_openclaw_configured; then
    info "OpenClaw already configured for lmstudio/${OPENCLAW_AMD_MODEL_ID} — skipping onboard"
    configured=1
    RAN_ONBOARD=1
    DAEMON_INSTALLED=$(( SYSTEMD_READY ? 1 : 0 ))
  else
    backup_openclaw_config "$OPENCLAW_CONFIG_FILE"
    if run_noninteractive_onboard "$LMSTUDIO_BASE_URL"; then
      configured=1
    else
      warn "Non-interactive onboard failed."
    fi
    (( configured == 1 )) || die "OpenClaw onboarding against LM Studio failed. Check the output above."
  fi

  auto_tune_config
  seed_workspace

  # Interactive onboard pass — lets the user configure hooks, skills, channels
  # The non-interactive pass above already set up provider/model/gateway,
  # so this second pass detects existing config and only walks through the
  # remaining steps (hooks, skills, channels, web search).
  info "Launching interactive onboard for hooks, skills, and channels setup..."
  printf '\n'
  openclaw onboard < /dev/tty || warn "Interactive onboard exited with an error. You can re-run it later with: openclaw onboard"
  printf '\n'

  print_summary
  info "Setup complete. OpenClaw is ready."
}

main "$@"
