#!/usr/bin/env bash
set -euo pipefail

IMAGE="${MATRIX_LOCAL_IMAGE:-matrixdotorg/synapse:latest}"
CONTAINER="${MATRIX_LOCAL_CONTAINER:-centaur-local-synapse}"
DATA_DIR="${MATRIX_LOCAL_DATA_DIR:-.local/matrix-synapse}"
PORT="${MATRIX_LOCAL_PORT:-8008}"
SERVER_NAME="${MATRIX_LOCAL_SERVER_NAME:-localhost}"
SHARED_SECRET_FILE="$DATA_DIR/registration_shared_secret"

usage() {
  cat <<'EOF'
Usage: scripts/local-matrix.sh <command>

Commands:
  start                       Start a disposable local Synapse container.
  stop                        Stop the local Synapse container.
  reset                       Stop Synapse and remove its local data directory.
  ensure-user USER PASS [--admin]
                              Register USER if needed, then print login JSON.
  env [USER] [PASS]           Ensure bot user and print Matrixbot env exports.
  create-room [USER] [PASS]   Ensure users, create a room, invite/join bot.
  send-mention ROOM_ID [TEXT] Send a mention from the test user.

Defaults:
  bot user:  centaur / centaur-local-password
  test user: alice   / alice-local-password

Environment overrides:
  MATRIX_LOCAL_IMAGE, MATRIX_LOCAL_CONTAINER, MATRIX_LOCAL_DATA_DIR,
  MATRIX_LOCAL_PORT, MATRIX_LOCAL_SERVER_NAME
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "FATAL: required command not found: $1" >&2
    exit 1
  fi
}

base_url() {
  printf 'http://localhost:%s' "$PORT"
}

container_running() {
  docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1
}

wait_ready() {
  local url
  url="$(base_url)/_matrix/client/versions"
  for _ in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  echo "FATAL: Synapse did not become ready at $url" >&2
  docker logs "$CONTAINER" --tail 100 >&2 || true
  exit 1
}

ensure_config() {
  mkdir -p "$DATA_DIR"
  if [[ ! -f "$DATA_DIR/homeserver.yaml" ]]; then
    docker run --rm \
      -v "$PWD/$DATA_DIR:/data" \
      -e SYNAPSE_SERVER_NAME="$SERVER_NAME" \
      -e SYNAPSE_REPORT_STATS=no \
      "$IMAGE" generate >/dev/null
  fi

  if [[ ! -f "$SHARED_SECRET_FILE" ]]; then
    openssl rand -hex 32 > "$SHARED_SECRET_FILE"
  fi

  if ! grep -q '^registration_shared_secret:' "$DATA_DIR/homeserver.yaml"; then
    {
      printf '\n'
      printf 'registration_shared_secret: "%s"\n' "$(cat "$SHARED_SECRET_FILE")"
      printf 'enable_registration: false\n'
    } >> "$DATA_DIR/homeserver.yaml"
  fi

  if ! grep -q '^# Centaur local-dev rate limits' "$DATA_DIR/homeserver.yaml"; then
    cat >> "$DATA_DIR/homeserver.yaml" <<'EOF'

# Centaur local-dev rate limits
rc_login:
  address:
    per_second: 10000
    burst_count: 10000
  account:
    per_second: 10000
    burst_count: 10000
  failed_attempts:
    per_second: 10000
    burst_count: 10000
rc_registration:
  per_second: 10000
  burst_count: 10000
EOF
  fi
}

start() {
  require_cmd docker
  require_cmd curl
  require_cmd openssl
  ensure_config

  if container_running; then
    wait_ready
    return
  fi

  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d \
    --name "$CONTAINER" \
    -p "127.0.0.1:$PORT:8008" \
    -v "$PWD/$DATA_DIR:/data" \
    "$IMAGE" >/dev/null
  wait_ready
  echo "Synapse ready at $(base_url)"
}

stop() {
  require_cmd docker
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

reset() {
  stop
  rm -rf "$DATA_DIR"
}

login() {
  local user="$1"
  local password="$2"
  curl -fsS -X POST "$(base_url)/_matrix/client/v3/login" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$user\"},\"password\":\"$password\"}"
}

ensure_user() {
  local user="$1"
  local password="$2"
  local admin="${3:-}"

  start >/dev/null
  if login "$user" "$password" >/dev/null 2>&1; then
    login "$user" "$password"
    return
  fi

  local args=(-c /data/homeserver.yaml http://localhost:8008 -u "$user" -p "$password" --exists-ok)
  if [[ "$admin" == "--admin" ]]; then
    args+=(-a)
  else
    args+=(--no-admin)
  fi
  docker exec "$CONTAINER" register_new_matrix_user "${args[@]}" >/dev/null
  login "$user" "$password"
}

token_field() {
  local field="$1"
  require_cmd jq
  jq -r --arg field "$field" '.[$field]'
}

env_exports() {
  local user="${1:-centaur}"
  local password="${2:-centaur-local-password}"
  local login_json
  login_json="$(ensure_user "$user" "$password")"
  local token user_id device_id
  token="$(printf '%s' "$login_json" | token_field access_token)"
  user_id="$(printf '%s' "$login_json" | token_field user_id)"
  device_id="$(printf '%s' "$login_json" | token_field device_id)"
  printf 'export MATRIX_HOMESERVER_URL=%q\n' "$(base_url)"
  printf 'export MATRIX_ACCESS_TOKEN=%q\n' "$token"
  printf 'export MATRIX_USER_ID=%q\n' "$user_id"
  printf 'export MATRIX_DEVICE_ID=%q\n' "$device_id"
}

create_room() {
  local user="${1:-alice}"
  local password="${2:-alice-local-password}"
  local bot_user="${MATRIX_LOCAL_BOT_USER:-centaur}"
  local bot_password="${MATRIX_LOCAL_BOT_PASSWORD:-centaur-local-password}"
  local user_login bot_login user_token bot_token bot_id room_id

  user_login="$(ensure_user "$user" "$password")"
  bot_login="$(ensure_user "$bot_user" "$bot_password")"
  user_token="$(printf '%s' "$user_login" | token_field access_token)"
  bot_token="$(printf '%s' "$bot_login" | token_field access_token)"
  bot_id="$(printf '%s' "$bot_login" | token_field user_id)"

  room_id="$(
    curl -fsS -X POST "$(base_url)/_matrix/client/v3/createRoom" \
      -H "Authorization: Bearer $user_token" \
      -H "Content-Type: application/json" \
      -d '{"preset":"private_chat","name":"Centaur local smoke"}' \
      | token_field room_id
  )"
  curl -fsS -X POST "$(base_url)/_matrix/client/v3/rooms/$(urlencode "$room_id")/invite" \
    -H "Authorization: Bearer $user_token" \
    -H "Content-Type: application/json" \
    -d "{\"user_id\":\"$bot_id\"}" >/dev/null
  curl -fsS -X POST "$(base_url)/_matrix/client/v3/join/$(urlencode "$room_id")" \
    -H "Authorization: Bearer $bot_token" \
    -H "Content-Type: application/json" \
    -d '{}' >/dev/null

  printf '%s\n' "$room_id"
}

send_mention() {
  local room_id="$1"
  local text="${2:-reply with exactly PONG}"
  local user="${MATRIX_LOCAL_USER:-alice}"
  local password="${MATRIX_LOCAL_PASSWORD:-alice-local-password}"
  local bot_id="${MATRIX_LOCAL_BOT_ID:-@centaur:$SERVER_NAME}"
  local login_json token txn
  login_json="$(ensure_user "$user" "$password")"
  token="$(printf '%s' "$login_json" | token_field access_token)"
  txn="centaur-local-$(date +%s)-$RANDOM"
  curl -fsS -X PUT "$(base_url)/_matrix/client/v3/rooms/$(urlencode "$room_id")/send/m.room.message/$txn" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"msgtype\":\"m.text\",\"body\":\"$bot_id $text\",\"m.mentions\":{\"user_ids\":[\"$bot_id\"]}}"
}

urlencode() {
  require_cmd node
  node -e 'console.log(encodeURIComponent(process.argv[1]))' "$1"
}

case "${1:-}" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  reset)
    reset
    ;;
  ensure-user)
    shift
    [[ $# -ge 2 ]] || { usage >&2; exit 2; }
    ensure_user "$@"
    ;;
  env)
    shift
    env_exports "$@"
    ;;
  create-room)
    shift
    create_room "$@"
    ;;
  send-mention)
    shift
    [[ $# -ge 1 ]] || { usage >&2; exit 2; }
    send_mention "$@"
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
