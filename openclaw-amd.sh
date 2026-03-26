#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="openclaw-amd"
SCRIPT_VERSION="0.4.0"

OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
OPENCLAW_AMD_MODEL_ID="${OPENCLAW_AMD_MODEL_ID:-minimax-m2.5:cloud}"
OPENCLAW_AMD_CONTEXT_TOKENS="${OPENCLAW_AMD_CONTEXT_TOKENS:-190000}"
OPENCLAW_AMD_MODEL_MAX_TOKENS="${OPENCLAW_AMD_MODEL_MAX_TOKENS:-64000}"
OPENCLAW_AMD_MAX_AGENTS="${OPENCLAW_AMD_MAX_AGENTS:-2}"
OPENCLAW_AMD_MAX_SUBAGENTS="${OPENCLAW_AMD_MAX_SUBAGENTS:-2}"
OPENCLAW_AMD_GATEWAY_PORT="${OPENCLAW_AMD_GATEWAY_PORT:-18789}"
OPENCLAW_AMD_GATEWAY_BIND="${OPENCLAW_AMD_GATEWAY_BIND:-loopback}"
OPENCLAW_AMD_SKIP_TUNING="${OPENCLAW_AMD_SKIP_TUNING:-0}"

# Ollama cloud settings
OLLAMA_API_KEY="${OLLAMA_API_KEY:-}"
OLLAMA_CLOUD_BASE_URL="https://ollama.com/v1"
OLLAMA_LOCAL_BASE_URL="http://127.0.0.1:11434/v1"
OLLAMA_BIN=""

SYSTEMD_READY=0
DAEMON_INSTALLED=0
RAN_ONBOARD=0
BREW_BIN=""

print_banner() {
  printf '\033[1;31m░████░█░░░░░█████░█░░░█░███░░████░░████░░▀█▀\033[0m\n'
  printf '\033[1;31m█░░░░░█░░░░░█░░░█░█░█░█░█░░█░█░░░█░█░░░█░░█░\033[0m\n'
  printf '\033[1;31m█░░░░░█░░░░░█████░█░█░█░█░░█░████░░█░░░█░░█░\033[0m\n'
  printf '\033[1;31m█░░░░░█░░░░░█░░░█░█░█░█░█░░█░█░░█░░█░░░█░░█░\033[0m\n'
  printf '\033[1;31m░████░█████░█░░░█░░█░█░░███░░████░░░███░░░█░\033[0m\n'
  printf '\033[1;33m  🦞  AMD Quick Start (Ollama + MiniMax M2.5)  🦞\033[0m\n'
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
# Ollama installation
# ---------------------------------------------------------------------------
install_ollama_if_missing() {
  refresh_ollama_path

  if [[ -n "$OLLAMA_BIN" ]]; then
    info "Ollama already installed at ${OLLAMA_BIN}"
    return 0
  fi

  info "Installing Ollama"
  curl -fsSL https://ollama.com/install.sh | sh

  refresh_ollama_path
  [[ -n "$OLLAMA_BIN" ]] || die "Ollama installed, but 'ollama' was not found on PATH. Open a new shell and rerun."
}

refresh_ollama_path() {
  export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null || true
  if have ollama; then
    OLLAMA_BIN="$(command -v ollama)"
  fi
}

persist_ollama_path() {
  local path_line='export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"'
  append_line_if_missing "$HOME/.profile" "$path_line"
  append_line_if_missing "$HOME/.bashrc"  "$path_line"
  if [[ -f "$HOME/.zshrc" ]]; then
    append_line_if_missing "$HOME/.zshrc" "$path_line"
  fi
}

# ---------------------------------------------------------------------------
# Ensure Ollama API key is set for cloud models.
# Prompts the user if not found in environment.
# ---------------------------------------------------------------------------
require_ollama_api_key() {
  if [[ -n "$OLLAMA_API_KEY" ]]; then
    info "OLLAMA_API_KEY is set"
    return 0
  fi

  # Check if it was previously persisted in shell profiles
  local sourced_key
  sourced_key="$(grep -hE '^export OLLAMA_API_KEY=' \
    "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" 2>/dev/null \
    | head -1 | sed "s/^export OLLAMA_API_KEY=//;s/['\"]//g" || true)"
  if [[ -n "$sourced_key" ]]; then
    export OLLAMA_API_KEY="$sourced_key"
    info "OLLAMA_API_KEY loaded from shell profile"
    return 0
  fi

  warn "OLLAMA_API_KEY is not set. A free API key is required for cloud models."
  warn "Get yours at: https://ollama.com/settings"
  printf '\n'
  read -r -p "Paste your Ollama API key and press Enter: " user_key
  user_key="${user_key// /}"
  [[ -n "$user_key" ]] || die "No API key provided. Re-run with OLLAMA_API_KEY=<key> to skip this prompt."
  export OLLAMA_API_KEY="$user_key"

  # Persist it so future shells and re-runs don't need to prompt again
  local export_line="export OLLAMA_API_KEY='${user_key}'"
  append_line_if_missing "$HOME/.profile" "$export_line"
  append_line_if_missing "$HOME/.bashrc"  "$export_line"
  if [[ -f "$HOME/.zshrc" ]]; then
    append_line_if_missing "$HOME/.zshrc" "$export_line"
  fi
  info "OLLAMA_API_KEY saved to shell profiles"
}

# ---------------------------------------------------------------------------
# Determine whether to use the Ollama cloud API or local server.
# Cloud is used when the model tag contains ":cloud".
# ---------------------------------------------------------------------------
is_cloud_model() {
  [[ "$OPENCLAW_AMD_MODEL_ID" == *":cloud" ]]
}

get_ollama_base_url() {
  if is_cloud_model; then
    printf '%s\n' "$OLLAMA_CLOUD_BASE_URL"
  else
    printf '%s\n' "$OLLAMA_LOCAL_BASE_URL"
  fi
}

get_ollama_api_key_for_provider() {
  if is_cloud_model; then
    printf '%s\n' "$OLLAMA_API_KEY"
  else
    # Local Ollama doesn't require a real key
    printf 'ollama\n'
  fi
}

# ---------------------------------------------------------------------------
# Start local Ollama server (only needed for non-cloud models).
# ---------------------------------------------------------------------------
start_ollama_server_if_local() {
  is_cloud_model && return 0

  if curl -fsS --max-time 2 "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; then
    info "Ollama local server already running"
    return 0
  fi

  info "Starting Ollama local server"
  nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
  disown

  local attempts=0
  while (( attempts < 20 )); do
    if curl -fsS --max-time 2 "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    (( attempts++ )) || true
  done
  curl -fsS --max-time 2 "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1 \
    || die "Ollama local server did not become reachable after 20 seconds."
  info "Ollama local server is up"
}

# ---------------------------------------------------------------------------
# Verify the cloud endpoint is reachable and the model is accessible.
# ---------------------------------------------------------------------------
verify_ollama_cloud_model() {
  is_cloud_model || return 0

  info "Verifying access to ${OPENCLAW_AMD_MODEL_ID} on Ollama cloud"
  local model_name="${OPENCLAW_AMD_MODEL_ID%%:cloud}"

  local response
  response="$(curl -fsS --max-time 10 \
    -H "Authorization: Bearer ${OLLAMA_API_KEY}" \
    "${OLLAMA_CLOUD_BASE_URL}/models" 2>/dev/null || true)"

  if [[ -z "$response" ]]; then
    warn "Could not reach Ollama cloud API at ${OLLAMA_CLOUD_BASE_URL}. Check your internet connection."
    return 1
  fi

  if printf '%s' "$response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
models = [m.get('id','') for m in data.get('data',[])]
sys.exit(0 if any('$model_name' in m for m in models) else 1)
" 2>/dev/null; then
    info "Model ${OPENCLAW_AMD_MODEL_ID} is available on Ollama cloud"
    return 0
  fi

  warn "Model ${model_name} was not listed. It may still be accessible — continuing."
  return 0
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
# Google Chrome installation
# Required so that `openclaw dashboard` can open a browser tab from WSL2.
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
# Configure OpenClaw against Ollama (cloud or local) non-interactively.
# ---------------------------------------------------------------------------
run_noninteractive_onboard() {
  local base_url="$1"
  local api_key="$2"
  local provider_id="ollama"

  # Strip the :cloud suffix for the model ID passed to OpenClaw
  local model_id="${OPENCLAW_AMD_MODEL_ID%%:cloud}"

  local cmd=(
    openclaw onboard
    --non-interactive
    --mode local
    --auth-choice custom-api-key
    --custom-base-url "$base_url"
    --custom-model-id "$model_id"
    --custom-provider-id "$provider_id"
    --custom-compatibility "openai"
    --custom-api-key "$api_key"
    --secret-input-mode plaintext
    --gateway-port "$OPENCLAW_AMD_GATEWAY_PORT"
    --gateway-bind "$OPENCLAW_AMD_GATEWAY_BIND"
    --skip-skills
    --accept-risk
  )

  if (( SYSTEMD_READY )); then
    cmd+=(--install-daemon --daemon-runtime node)
  fi

  info "Configuring OpenClaw against Ollama (${base_url})"
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
      --custom-model-id "$model_id"
      --custom-provider-id "$provider_id"
      --custom-compatibility "openai"
      --custom-api-key "$api_key"
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

# ---------------------------------------------------------------------------
# Check if OpenClaw is already configured for the current Ollama provider/model.
# ---------------------------------------------------------------------------
is_openclaw_configured() {
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 1
  local model_id="${OPENCLAW_AMD_MODEL_ID%%:cloud}"
  python3 - <<'PY' "$OPENCLAW_CONFIG_FILE" "ollama" "$model_id"
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

  local model_id="${OPENCLAW_AMD_MODEL_ID%%:cloud}"
  local context_tokens="$OPENCLAW_AMD_CONTEXT_TOKENS"

  python3 - <<'PY' \
    "$OPENCLAW_CONFIG_FILE" \
    "ollama" \
    "$model_id" \
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
default_models[model_ref].setdefault('alias', 'ollama-cloud')

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

  info "Applied OpenClaw tuning to ${OPENCLAW_CONFIG_FILE}"
}

print_summary() {
  printf '\n'
  info "${SCRIPT_NAME} ${SCRIPT_VERSION} complete"
  if is_cloud_model; then
    printf '  Ollama endpoint   : %s\n' "$OLLAMA_CLOUD_BASE_URL"
  else
    printf '  Ollama endpoint   : %s\n' "$OLLAMA_LOCAL_BASE_URL"
  fi
  printf '  Model             : %s\n' "$OPENCLAW_AMD_MODEL_ID"
  printf '  Context tokens    : %s\n' "$OPENCLAW_AMD_CONTEXT_TOKENS"
  printf '  Max tokens        : %s\n' "$OPENCLAW_AMD_MODEL_MAX_TOKENS"
  printf '  Agent concurrency : %s\n' "$OPENCLAW_AMD_MAX_AGENTS"
  printf '  Subagent conc.    : %s\n' "$OPENCLAW_AMD_MAX_SUBAGENTS"
  printf '\n'
  printf 'Ollama quick-reference:\n'
  printf '  ollama list                         # list local models\n'
  printf '  ollama run minimax-m2.5:cloud       # chat with MiniMax M2.5 cloud\n'
  printf '  ollama launch openclaw --model minimax-m2.5:cloud  # relaunch OpenClaw\n'
  printf '\n'
}

# ---------------------------------------------------------------------------
# Start the OpenClaw gateway, open the dashboard in Chrome, then hatch TUI.
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

    local attempts=0
    while (( attempts < 15 )); do
      if curl -fsS --max-time 1 \
           "http://127.0.0.1:${OPENCLAW_AMD_GATEWAY_PORT}/" >/dev/null 2>&1; then
        break
      fi
      sleep 1
      (( attempts++ )) || true
    done
  fi

  info "Opening OpenClaw dashboard"
  local dashboard_url
  dashboard_url="$(openclaw dashboard --no-open 2>/dev/null | grep -oP 'https?://\S+' | head -1 || true)"
  if [[ -n "$dashboard_url" ]]; then
    info "Dashboard: ${dashboard_url}"
    if have xdg-open; then
      xdg-open "$dashboard_url" >/dev/null 2>&1 &
      disown
    elif have wslview; then
      wslview "$dashboard_url" >/dev/null 2>&1 &
      disown
    fi
  else
    info "Dashboard: http://127.0.0.1:${OPENCLAW_AMD_GATEWAY_PORT}/"
  fi

  info "Hatching in TUI — press Q to quit the TUI (gateway keeps running)"
  printf '\n'
  stty sane 2>/dev/null || true
  exec openclaw tui
}

main() {
  print_banner
  require_linux
  apt_install_if_missing ca-certificates curl git python3 build-essential wget gnupg2
  prepare_npm_global_prefix
  maybe_enable_wsl_systemd

  install_homebrew_if_missing
  install_chrome_if_missing
  install_or_update_openclaw
  prepare_npm_global_prefix
  require_openclaw

  # Install Ollama
  install_ollama_if_missing
  persist_ollama_path

  # Require API key for cloud models
  if is_cloud_model; then
    require_ollama_api_key
    verify_ollama_cloud_model
  else
    start_ollama_server_if_local
  fi

  local base_url
  base_url="$(get_ollama_base_url)"
  local api_key
  api_key="$(get_ollama_api_key_for_provider)"

  local configured=0
  if is_openclaw_configured; then
    info "OpenClaw already configured for ollama/${OPENCLAW_AMD_MODEL_ID%%:cloud} — skipping onboard"
    configured=1
    RAN_ONBOARD=1
    DAEMON_INSTALLED=$(( SYSTEMD_READY ? 1 : 0 ))
  else
    backup_openclaw_config "$OPENCLAW_CONFIG_FILE"
    if run_noninteractive_onboard "$base_url" "$api_key"; then
      configured=1
    else
      warn "Non-interactive onboard failed."
    fi
    (( configured == 1 )) || die "OpenClaw onboarding against Ollama failed. Check the output above."
  fi

  auto_tune_config
  launch_openclaw
}

main "$@"
