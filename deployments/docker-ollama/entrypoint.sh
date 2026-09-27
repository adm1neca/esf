#!/usr/bin/env bash
# Starts the Machinist control plane, a loopback forwarder for the web UI, and
# one managed worker whose OpenCode V2 executor uses an Ollama endpoint.
set -euo pipefail

log() { printf 'esf-docker: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

state="$HOME/.machinist"
bundled=/opt/esf-docker/config
overrides=/config
ollama_url=${OLLAMA_BASE_URL:-http://host.docker.internal:11434}
ollama_url=${ollama_url%/}
ollama_url=${ollama_url%/v1}
default_model=${OLLAMA_MODEL:-qwen3-coder:30b}
worker_name=${WORKER_NAME:-docker-ollama}
listen_port=7331
public_port=7332

# Values below are written into JSON and TOML, so restrict them to characters
# that never need escaping instead of escaping them.
[[ $ollama_url =~ ^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._~/-]*)?$ ]] \
  || die "OLLAMA_BASE_URL must look like http://host:port, got '$ollama_url'"
[[ $worker_name =~ ^[A-Za-z0-9._-]+$ ]] || die "WORKER_NAME may contain only letters, digits, '.', '_' and '-'"

# The default model first, then any extra OLLAMA_MODELS, without duplicates.
model_list=()
IFS=',' read -r -a requested_models <<<"$default_model,${OLLAMA_MODELS:-}"
for model in "${requested_models[@]}"; do
  model=$(printf '%s' "$model" | tr -d '[:space:]')
  [[ -n $model ]] || continue
  [[ $model =~ ^[A-Za-z0-9._:/-]+$ ]] || die "invalid Ollama model name '$model'"
  if [[ " ${model_list[*]} " != *" $model "* ]]; then model_list+=("$model"); fi
done

install -d -m 0700 "$state" "$state/server" "$state/worker"

# The worker token authenticates the worker to the control plane. It stays on
# the state volume so restarts keep the same credential.
token_file="$state/server/worker.token"
if [[ ! -s $token_file ]]; then
  (umask 077 && head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$token_file" && echo >>"$token_file")
  log "created worker token"
fi

# Git refuses bind-mounted repositories owned by another UID (the Windows
# Docker Desktop default) unless they are marked safe.
git config --global --get-all safe.directory | grep -qx '\*' || git config --global --add safe.directory '*'
git config --global user.name >/dev/null || git config --global user.name "${GIT_USER_NAME:-Machinist Agent}"
git config --global user.email >/dev/null || git config --global user.email "${GIT_USER_EMAIL:-machinist@localhost}"

# ── OpenCode provider configuration ──────────────────────────────────────────
# Same shape the factory harness writes (internal/agentharness/opencode.go),
# pointed at Ollama's OpenAI-compatible /v1 endpoint.
opencode_config="$HOME/.config/opencode/opencode.json"
install -d -m 0700 "$(dirname "$opencode_config")"
if [[ -f $overrides/opencode.json ]]; then
  cp "$overrides/opencode.json" "$opencode_config"
  log "using $overrides/opencode.json"
else
  model_entries=""
  for model in "${model_list[@]}"; do
    model_entries+="${model_entries:+,}
        \"$model\": { \"name\": \"$model\", \"modelID\": \"$model\" }"
  done
  cat >"$opencode_config" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "default_agent": "build",
  "shell": "/bin/bash",
  "model": "ollama/$default_model",
  "providers": {
    "ollama": {
      "name": "Ollama",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "$ollama_url/v1",
        "apiKey": "ollama"
      },
      "models": {$model_entries
      }
    }
  }
}
EOF
fi

# ── Machinist configuration ──────────────────────────────────────────────────
config_file="$bundled/config.toml"
if [[ -f $overrides/config.toml ]]; then
  config_file="$overrides/config.toml"
  log "using $config_file"
fi

worker_file="$state/worker.generated.toml"
if [[ -f $overrides/worker.toml ]]; then
  worker_file="$overrides/worker.toml"
  log "using $worker_file"
else
  {
    cat <<EOF
# Generated at container start; put a worker.toml in the config mount to
# replace it. Every Git repository directly under /workspace is registered.
name = "$worker_name"
data_directory = "~/.machinist/worker"

[control_plane]
url = "http://127.0.0.1:$listen_port"
token_file = "~/.machinist/server/worker.token"

[executors.opencode]
command = ["opencode2", "run", "--model={{machinist.model}}", "--standalone", "--auto", "--format", "json"]

# opencode-step decides the outcome from checks (a file was written, a commit
# was made) instead of trusting the model, and writes workflow step results.
[executors.opencode-commit]
command = ["opencode-step", "--require-commit", "--", "opencode2", "run", "--model={{machinist.model}}", "--standalone", "--auto", "--format", "json"]

[executors.opencode-plan]
command = ["opencode-step", "--require-output", "plan.md", "--", "opencode2", "run", "--model={{machinist.model}}", "--standalone", "--auto", "--format", "json"]
EOF
    shopt -s nullglob
    for repository in /workspace/*/; do
      repository=${repository%/}
      name=$(basename "$repository")
      if [[ ! -e $repository/.git ]]; then
        continue
      fi
      if [[ ! $name =~ ^[A-Za-z0-9._-]+$ ]]; then
        log "skipping $repository: rename it to letters, digits, '.', '_' or '-'"
        continue
      fi
      printf '\n[repositories.%s]\npath = "%s"\n' "$name" "$repository"
      log "registered repository $name -> $repository"
    done
  } >"$worker_file"
fi

if ! grep -q '^\[repositories\.' "$worker_file"; then
  log "no repositories registered: clone a Git repository into the workspace mount and restart"
fi

# ── Ollama reachability (advisory) ───────────────────────────────────────────
if tags=$(curl -fsS --max-time 5 "$ollama_url/api/tags" 2>/dev/null); then
  log "Ollama reachable at $ollama_url"
  for model in "${model_list[@]}"; do
    [[ $model == *:* ]] || model+=":latest"
    tr -d '[:space:]' <<<"$tags" | grep -qF "\"name\":\"$model\"" \
      || log "model $model is not pulled yet; run: ollama pull $model"
  done
else
  log "WARNING: Ollama is not reachable at $ollama_url (is it running and listening on 0.0.0.0?)"
fi

# ── Start services ───────────────────────────────────────────────────────────
pids=()
stop_services() {
  kill -TERM "${pids[@]}" 2>/dev/null || true
  wait || true
}
trap 'trap - TERM INT; stop_services; exit 0' TERM INT

machinist start --config "$config_file" --listen "127.0.0.1:$listen_port" &
pids+=($!)

health="http://127.0.0.1:$listen_port/healthz"
for _ in $(seq 1 50); do
  curl -fsS --max-time 2 "$health" >/dev/null 2>&1 && break
  sleep 0.2
done
curl -fsS --max-time 2 "$health" >/dev/null || { stop_services; die "control plane did not become healthy"; }

# The control plane accepts only loopback listen addresses. socat exposes it
# on the container network; compose publishes that port only on the host's
# 127.0.0.1, so the browser still reaches it as http://localhost:<port>.
socat "TCP-LISTEN:$public_port,fork,reuseaddr" "TCP:127.0.0.1:$listen_port" &
pids+=($!)

machinist worker start --config "$worker_file" &
pids+=($!)

log "web UI: http://localhost:${MACHINIST_PORT:-7331}"
set +e
wait -n "${pids[@]}"
status=$?
log "a service exited with status $status; stopping the container"
trap - TERM INT
stop_services
exit "$status"
