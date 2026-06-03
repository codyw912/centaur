#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NAMESPACE="${CENTAUR_NAMESPACE:-centaur}"
RELEASE="${CENTAUR_RELEASE:-centaur}"
CHART="${CENTAUR_CHART:-contrib/chart}"
DEV_VALUES="${CENTAUR_DEV_VALUES:-contrib/chart/values.dev.yaml}"
E2E_DIR="${MATRIXBOT_K8S_E2E_DIR:-.local/matrixbot-k8s-e2e}"
MATRIX_USER="${MATRIX_LOCAL_USER:-alice}"
MATRIX_PASSWORD="${MATRIX_LOCAL_PASSWORD:-alice-local-password}"
MATRIXBOT_API_KEY="${MATRIXBOT_API_KEY:-aiv2_matrixbot_local}"
MATRIX_DEFAULT_HARNESS="${MATRIX_DEFAULT_HARNESS:-claude-code}"
RUN_ID="${MATRIXBOT_K8S_E2E_RUN_ID:-$(date +%s)-$RANDOM}"
SKIP_BUILD=0
SKIP_STACK_UP=0
KEEP_MATRIXBOT=0
HELM_RELEASE_READY=0

usage() {
  cat <<'EOF'
Usage: scripts/local-matrix-k8s-e2e.sh [--skip-build] [--skip-stack-up] [--keep-matrixbot]

Runs the production-shape Matrix E2E locally:
  1. starts/reuses local Synapse
  2. exposes Synapse through a temporary HTTPS cloudflared tunnel
  3. builds the local matrixbot image unless --skip-build is set
  4. starts/reuses the local Centaur Helm stack
  5. deploys Helm-managed matrixbot in-cluster with firewall proxy env
  6. sends a Matrix mention and waits for a real PONG reply
  7. releases the Centaur runtime and disables matrixbot unless --keep-matrixbot is set

Requires OP_SERVICE_ACCOUNT_TOKEN and OP_VAULT for Centaur's 1Password-backed
LLM credential injection. Slack env vars default to local dummy values because
this test deploys slackbot disabled.

If helm or cloudflared are not installed globally, the script uses nix-shell
when available.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --skip-stack-up)
      SKIP_STACK_UP=1
      shift
      ;;
    --keep-matrixbot)
      KEEP_MATRIXBOT=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "FATAL: required command not found: $1" >&2
    exit 1
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "FATAL: $name is required in the shell environment" >&2
    exit 1
  fi
}

shell_quote_args() {
  printf '%q ' "$@"
}

run_helm() {
  if command -v helm >/dev/null 2>&1; then
    helm "$@"
    return
  fi
  if command -v nix-shell >/dev/null 2>&1; then
    nix-shell -p kubernetes-helm --run "helm $(shell_quote_args "$@")"
    return
  fi
  echo "FATAL: helm not found and nix-shell is unavailable" >&2
  exit 1
}

start_cloudflared() {
  local url="$1"
  local log_file="$2"
  if command -v cloudflared >/dev/null 2>&1; then
    cloudflared tunnel --url "$url" > "$log_file" 2>&1 &
    TUNNEL_PID="$!"
    return
  fi
  if command -v nix-shell >/dev/null 2>&1; then
    nix-shell -p cloudflared --run "cloudflared tunnel --url $(printf '%q' "$url")" \
      > "$log_file" 2>&1 &
    TUNNEL_PID="$!"
    return
  fi
  echo "FATAL: cloudflared not found and nix-shell is unavailable" >&2
  exit 1
}

urlencode() {
  node -e 'console.log(encodeURIComponent(process.argv[1]))' "$1"
}

wait_for_tunnel_url() {
  local log_file="$1"
  for _ in $(seq 1 120); do
    local url
    url="$(grep -Eo 'https://[-a-zA-Z0-9.]+\.trycloudflare\.com' "$log_file" 2>/dev/null | tail -1 || true)"
    if [[ -n "$url" ]]; then
      printf '%s\n' "$url"
      return
    fi
    sleep 0.5
  done
  echo "FATAL: cloudflared did not publish a trycloudflare URL" >&2
  tail -100 "$log_file" >&2 || true
  return 1
}

wait_http() {
  local url="$1"
  local label="$2"
  for _ in $(seq 1 240); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return
    fi
    sleep 0.5
  done
  echo "FATAL: $label did not become ready at $url" >&2
  return 1
}

start_synapse_tunnel() {
  local origin_url="$1"
  local log_file="$2"
  for attempt in 1 2 3; do
    : > "$log_file"
    start_cloudflared "$origin_url" "$log_file"
    local tunnel_url
    if ! tunnel_url="$(wait_for_tunnel_url "$log_file")"; then
      echo "WARN: cloudflared tunnel attempt $attempt did not publish a URL; retrying" >&2
      kill "$TUNNEL_PID" >/dev/null 2>&1 || true
      unset TUNNEL_PID
      sleep 2
      continue
    fi
    if wait_http "$tunnel_url/_matrix/client/versions" "cloudflared Synapse tunnel"; then
      printf '%s\n' "$tunnel_url"
      return
    fi
    echo "WARN: cloudflared tunnel attempt $attempt did not become reachable; retrying" >&2
    kill "$TUNNEL_PID" >/dev/null 2>&1 || true
    unset TUNNEL_PID
    sleep 2
  done
  echo "FATAL: cloudflared Synapse tunnel did not become reachable after 3 attempts" >&2
  tail -100 "$log_file" >&2 || true
  return 1
}

token_field() {
  local field="$1"
  jq -r --arg field "$field" '.[$field]'
}

api_deploy() {
  printf '%s-centaur-api' "$RELEASE"
}

stack_is_up() {
  kubectl -n "$NAMESPACE" get deploy "$(api_deploy)" >/dev/null 2>&1
}

helm_release_listed() {
  run_helm list -n "$NAMESPACE" --all --filter "^$RELEASE$" --short 2>/dev/null \
    | grep -qx "$RELEASE"
}

helm_release_deployed() {
  run_helm list -n "$NAMESPACE" --deployed --filter "^$RELEASE$" --short 2>/dev/null \
    | grep -qx "$RELEASE"
}

recover_non_deployed_release() {
  if ! helm_release_deployed && helm_release_listed; then
    echo "Removing non-deployed Helm release record for $RELEASE in namespace $NAMESPACE"
    run_helm uninstall "$RELEASE" -n "$NAMESPACE" >/dev/null || true
  fi
}

bootstrap_secrets() {
  export MATRIXBOT_API_KEY
  export SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-xoxb-local-dummy}"
  export SLACK_SIGNING_SECRET="${SLACK_SIGNING_SECRET:-local-dummy}"
  export SLACKBOT_API_KEY="${SLACKBOT_API_KEY:-aiv2_slackbot_dummy}"
  just bootstrap-secrets
}

deploy_stack() {
  run_helm dependency update "$CHART" >/dev/null
  recover_non_deployed_release
  run_helm upgrade --install "$RELEASE" "$CHART" \
    -n "$NAMESPACE" \
    --create-namespace \
    -f "$DEV_VALUES" \
    --set slackbot.enabled=false \
    --set api.image.pullPolicy=IfNotPresent \
    --set ironProxy.image.pullPolicy=IfNotPresent \
    --set sandbox.image.pullPolicy=IfNotPresent \
    --set postgres.image.pullPolicy=IfNotPresent \
    --set matrixbot.image.pullPolicy=IfNotPresent
}

ensure_stack() {
  bootstrap_secrets
  if stack_is_up; then
    HELM_RELEASE_READY=1
    kubectl -n "$NAMESPACE" rollout status "deploy/$(api_deploy)"
    return
  fi
  if [[ "$SKIP_STACK_UP" == "1" ]]; then
    echo "FATAL: Centaur stack is not up in namespace $NAMESPACE" >&2
    exit 1
  fi
  if [[ "$SKIP_BUILD" != "1" ]]; then
    just build
  fi
  deploy_stack
  HELM_RELEASE_READY=1
  kubectl -n "$NAMESPACE" rollout status "deploy/$(api_deploy)"
}

deploy_matrixbot() {
  local homeserver_url="$1"
  local user_id="$2"
  local room_id="$3"
  run_helm upgrade "$RELEASE" "$CHART" \
    -n "$NAMESPACE" \
    --reuse-values \
    --set matrixbot.enabled=true \
    --set "matrixbot.homeserverUrl=$homeserver_url" \
    --set "matrixbot.userId=$user_id" \
    --set "matrixbot.allowedRooms=$room_id" \
    --set "matrixbot.syncTokenPath=/var/lib/centaur-matrixbot/sync-token-$RUN_ID" \
    --set matrixbot.persistence.enabled=true \
    --set matrixbot.image.pullPolicy=IfNotPresent \
    --set "matrixbot.defaultHarness=$MATRIX_DEFAULT_HARNESS"
  kubectl -n "$NAMESPACE" rollout status "deploy/$RELEASE-centaur-matrixbot"
}

disable_matrixbot() {
  if [[ "$HELM_RELEASE_READY" != "1" ]] && ! helm_release_deployed; then
    return
  fi
  run_helm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" --reuse-values --set matrixbot.enabled=false >/dev/null || true
}

wait_for_matrixbot_initial_sync() {
  for _ in $(seq 1 120); do
    if kubectl -n "$NAMESPACE" logs "deploy/$RELEASE-centaur-matrixbot" --tail=200 2>/dev/null \
      | grep -q '"event":"matrix_initial_sync_skipped"'
    then
      return
    fi
    sleep 0.5
  done
  echo "FATAL: in-cluster Matrixbot did not finish initial sync" >&2
  kubectl -n "$NAMESPACE" logs "deploy/$RELEASE-centaur-matrixbot" --tail=200 >&2 || true
  return 1
}

wait_for_pong() {
  local homeserver="$1"
  local token="$2"
  local room_id="$3"
  local encoded_room_id messages_file
  encoded_room_id="$(urlencode "$room_id")"
  messages_file="$E2E_DIR/messages.json"
  for _ in $(seq 1 180); do
    curl -fsS "$homeserver/_matrix/client/v3/rooms/$encoded_room_id/messages?dir=b&limit=20" \
      -H "Authorization: Bearer $token" > "$messages_file"
    if jq -er --arg bot "$MATRIX_USER_ID" '
      .chunk[]?
      | select(.sender == $bot)
      | .content.body? // empty
      | select(contains("PONG"))
    ' "$messages_file" >/dev/null
    then
      return
    fi
    sleep 1
  done
  echo "FATAL: did not observe Matrixbot PONG reply" >&2
  kubectl -n "$NAMESPACE" logs "deploy/$RELEASE-centaur-matrixbot" --tail=200 >&2 || true
  return 1
}

release_thread() {
  local room_id="$1"
  local event_id="$2"
  local thread_key encoded_thread_key
  thread_key="matrix:$(urlencode "$room_id"):$(urlencode "$event_id")"
  encoded_thread_key="$(urlencode "$thread_key")"
  kubectl -n "$NAMESPACE" exec "deploy/$(api_deploy)" -- \
    curl -fsS -X POST "http://localhost:8000/agent/threads/$encoded_thread_key/release" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $MATRIXBOT_API_KEY" \
      -d '{}' >/dev/null || true
}

cleanup() {
  if [[ -n "${ROOM_ID:-}" && -n "${MENTION_EVENT_ID:-}" ]]; then
    release_thread "$ROOM_ID" "$MENTION_EVENT_ID"
  fi
  if [[ "$KEEP_MATRIXBOT" != "1" ]]; then
    disable_matrixbot
  fi
  if [[ -n "${TUNNEL_PID:-}" ]]; then
    kill "$TUNNEL_PID" >/dev/null 2>&1 || true
  fi
}

main() {
  require_cmd bun
  require_cmd curl
  require_cmd docker
  require_cmd jq
  require_cmd just
  require_cmd kubectl
  require_cmd node
  require_env OP_SERVICE_ACCOUNT_TOKEN
  require_env OP_VAULT

  trap cleanup EXIT
  mkdir -p "$E2E_DIR"

  scripts/local-matrix.sh start
  eval "$(scripts/local-matrix.sh env)"
  export MATRIXBOT_API_KEY
  export MATRIX_ACCESS_TOKEN

  local user_login user_token tunnel_url send_response
  user_login="$(scripts/local-matrix.sh ensure-user "$MATRIX_USER" "$MATRIX_PASSWORD")"
  user_token="$(printf '%s' "$user_login" | token_field access_token)"
  ROOM_ID="$(scripts/local-matrix.sh create-room "$MATRIX_USER" "$MATRIX_PASSWORD")"

  local matrix_local_port="${MATRIX_LOCAL_PORT:-8008}"
  tunnel_url="$(start_synapse_tunnel "http://127.0.0.1:$matrix_local_port" "$E2E_DIR/cloudflared.log")"

  if [[ "$SKIP_BUILD" != "1" ]]; then
    just build-one matrixbot
  fi

  ensure_stack
  deploy_matrixbot "$tunnel_url" "$MATRIX_USER_ID" "$ROOM_ID"
  wait_for_matrixbot_initial_sync

  send_response="$(scripts/local-matrix.sh send-mention "$ROOM_ID" "reply with exactly PONG" )"
  MENTION_EVENT_ID="$(printf '%s' "$send_response" | token_field event_id)"
  wait_for_pong "$MATRIX_HOMESERVER_URL" "$user_token" "$ROOM_ID"

  local encoded_room_id messages_file
  encoded_room_id="$(urlencode "$ROOM_ID")"
  messages_file="$E2E_DIR/messages.json"
  curl -fsS "$MATRIX_HOMESERVER_URL/_matrix/client/v3/rooms/$encoded_room_id/messages?dir=b&limit=5" \
    -H "Authorization: Bearer $user_token" > "$messages_file"

  echo "Matrixbot Kubernetes E2E passed"
  echo "Tunnel: $tunnel_url"
  echo "Room: $ROOM_ID"
  echo "Recent room messages:"
  jq -r '.chunk[]? | select(.content.body?) | "\(.sender): \(.content.body)"' "$messages_file"
}

main "$@"
