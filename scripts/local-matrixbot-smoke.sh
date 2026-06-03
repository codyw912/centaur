#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SMOKE_DIR="${MATRIXBOT_SMOKE_DIR:-.local/matrixbot-smoke}"
STUB_PORT="${MATRIXBOT_SMOKE_STUB_PORT:-18080}"
BOT_PORT="${MATRIXBOT_SMOKE_BOT_PORT:-13002}"
MATRIX_USER="${MATRIX_LOCAL_USER:-alice}"
MATRIX_PASSWORD="${MATRIX_LOCAL_PASSWORD:-alice-local-password}"
BOT_USER_ID="${MATRIX_LOCAL_BOT_ID:-@centaur:${MATRIX_LOCAL_SERVER_NAME:-localhost}}"

usage() {
  cat <<'EOF'
Usage: scripts/local-matrixbot-smoke.sh

Runs a local smoke test for the Matrix backend:
  1. starts/reuses the local Synapse container
  2. creates a private room and joins the Matrixbot user
  3. starts a stub Centaur API
  4. starts Matrixbot with local Matrix credentials
  5. sends a Matrix mention and waits for a PONG final-delivery reply

Synapse is left running for reuse. Stop it with:
  scripts/local-matrix.sh stop
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "FATAL: required command not found: $1" >&2
    exit 1
  fi
}

token_field() {
  local field="$1"
  jq -r --arg field "$field" '.[$field]'
}

urlencode() {
  node -e 'console.log(encodeURIComponent(process.argv[1]))' "$1"
}

cleanup() {
  if [[ -n "${MATRIXBOT_PID:-}" ]]; then
    kill "$MATRIXBOT_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${STUB_PID:-}" ]]; then
    kill "$STUB_PID" >/dev/null 2>&1 || true
  fi
}

wait_http() {
  local url="$1"
  local label="$2"
  for _ in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return
    fi
    sleep 0.25
  done
  echo "FATAL: $label did not become ready at $url" >&2
  return 1
}

wait_for_bot_initial_sync() {
  local log_file="$1"
  for _ in $(seq 1 80); do
    if grep -q '"event":"matrix_initial_sync_skipped"' "$log_file"; then
      return
    fi
    sleep 0.25
  done
  echo "FATAL: Matrixbot did not finish initial sync" >&2
  tail -100 "$log_file" >&2 || true
  return 1
}

wait_for_pong() {
  local homeserver="$1"
  local token="$2"
  local room_id="$3"
  local encoded_room_id messages_file
  encoded_room_id="$(urlencode "$room_id")"
  messages_file="$SMOKE_DIR/messages.json"
  for _ in $(seq 1 80); do
    curl -fsS "$homeserver/_matrix/client/v3/rooms/$encoded_room_id/messages?dir=b&limit=20" \
      -H "Authorization: Bearer $token" > "$messages_file"
    if jq -er --arg bot "$BOT_USER_ID" '
      .chunk[]?
      | select(.sender == $bot)
      | .content.body? // empty
      | select(contains("PONG"))
    ' "$messages_file"
    then
      return
    fi
    sleep 0.5
  done
  echo "FATAL: did not observe Matrixbot PONG reply" >&2
  return 1
}

write_stub() {
  mkdir -p "$SMOKE_DIR"
  cat > "$SMOKE_DIR/stub-centaur.mjs" <<'EOF'
const port = Number(process.env.PORT || 18080)
const assignments = new Map()
const messages = new Map()
let delivery = null
let claimed = false
let delivered = false
let executionCounter = 0
let generationCounter = 0

function json(data, init = {}) {
  return Response.json(data, init)
}

function bad(message) {
  return json({ ok: false, error: message }, { status: 422 })
}

Bun.serve({
  port,
  async fetch(request) {
    const url = new URL(request.url)
    const body = request.method === 'POST' ? await request.json().catch(() => ({})) : {}

    if (url.pathname === '/health') return json({ ok: true })

    if (url.pathname === '/agent/spawn' && request.method === 'POST') {
      if (!body.thread_key) return bad('spawn requires thread_key')
      if (!body.harness) return bad('spawn requires harness')
      let assignment = assignments.get(body.thread_key)
      if (!assignment) {
        generationCounter += 1
        assignment = {
          thread_key: body.thread_key,
          assignment_generation: generationCounter,
          harness: body.harness
        }
        assignments.set(body.thread_key, assignment)
      }
      console.log(JSON.stringify({ event: 'spawn', body }))
      return json({ ...assignment, runtime_id: 'rtm-smoke', state: 'assigned_idle' })
    }

    if (url.pathname === '/agent/message' && request.method === 'POST') {
      if (!body.thread_key) return bad('message requires thread_key')
      if (!Number.isInteger(body.assignment_generation)) {
        return bad('message requires assignment_generation')
      }
      if (!body.message_id) return bad('message requires message_id')
      if (!Array.isArray(body.parts) || body.parts.length === 0) {
        return bad('message requires parts')
      }
      const assignment = assignments.get(body.thread_key)
      if (!assignment || assignment.assignment_generation !== body.assignment_generation) {
        return bad('message assignment_generation does not match spawned assignment')
      }
      messages.set(`${body.thread_key}:${body.assignment_generation}`, body)
      console.log(JSON.stringify({ event: 'message', body }))
      return json({ ok: true, message_id: body.message_id })
    }

    if (url.pathname === '/agent/execute' && request.method === 'POST') {
      if (body.message) return bad('execute must not use auto-execute message shortcut')
      if (!body.thread_key) return bad('execute requires thread_key')
      if (!Number.isInteger(body.assignment_generation)) {
        return bad('execute requires assignment_generation')
      }
      if (!body.execute_id) return bad('execute requires execute_id')
      const assignment = assignments.get(body.thread_key)
      if (!assignment || assignment.assignment_generation !== body.assignment_generation) {
        return bad('execute assignment_generation does not match spawned assignment')
      }
      if (!messages.has(`${body.thread_key}:${body.assignment_generation}`)) {
        return bad('execute requires persisted message first')
      }
      executionCounter += 1
      const executionId = body.execute_id || `matrixbot-smoke-${executionCounter}`
      delivery = {
        execution_id: executionId,
        thread_key: body.thread_key,
        delivery: body.delivery,
        final_payload: { result_text: 'PONG' },
        trace_id: 'matrixbot-smoke'
      }
      claimed = false
      delivered = false
      console.log(JSON.stringify({ event: 'execute', body }))
      return json({ ok: true, execution_id: executionId, status: 'queued' })
    }

    if (url.pathname === '/agent/final-deliveries/claim' && request.method === 'POST') {
      if (delivery && !claimed && !delivered) {
        claimed = true
        console.log(JSON.stringify({ event: 'claim', execution_id: delivery.execution_id, body }))
        return json({ deliveries: [delivery] })
      }
      return json({ deliveries: [] })
    }

    const deliveredMatch = url.pathname.match(/^\/agent\/final-deliveries\/([^/]+)\/delivered$/)
    if (deliveredMatch && request.method === 'POST') {
      delivered = true
      console.log(JSON.stringify({ event: 'delivered', execution_id: deliveredMatch[1], body }))
      return json({ ok: true })
    }

    const failedMatch = url.pathname.match(/^\/agent\/final-deliveries\/([^/]+)\/failed$/)
    if (failedMatch && request.method === 'POST') {
      console.log(JSON.stringify({ event: 'failed', execution_id: failedMatch[1], body }))
      return json({ ok: true })
    }

    return json({ ok: false, error: 'not_found' }, { status: 404 })
  }
})

console.log(JSON.stringify({ event: 'stub_started', port }))
EOF
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    return
  fi

  require_cmd bun
  require_cmd curl
  require_cmd jq
  require_cmd node

  trap cleanup EXIT
  mkdir -p "$SMOKE_DIR"

  scripts/local-matrix.sh start
  eval "$(scripts/local-matrix.sh env)"

  local user_login user_token room_id
  user_login="$(scripts/local-matrix.sh ensure-user "$MATRIX_USER" "$MATRIX_PASSWORD")"
  user_token="$(printf '%s' "$user_login" | token_field access_token)"
  room_id="$(scripts/local-matrix.sh create-room "$MATRIX_USER" "$MATRIX_PASSWORD")"

  write_stub
  PORT="$STUB_PORT" bun "$SMOKE_DIR/stub-centaur.mjs" > "$SMOKE_DIR/stub.log" 2>&1 &
  STUB_PID="$!"
  wait_http "http://127.0.0.1:$STUB_PORT/health" "stub Centaur API"

  MATRIX_HOMESERVER_URL="$MATRIX_HOMESERVER_URL" \
    MATRIX_ACCESS_TOKEN="$MATRIX_ACCESS_TOKEN" \
    MATRIX_USER_ID="$MATRIX_USER_ID" \
    MATRIX_DEVICE_ID="$MATRIX_DEVICE_ID" \
    CENTAUR_API_URL="http://127.0.0.1:$STUB_PORT" \
    MATRIXBOT_API_KEY="aiv2_matrixbot_smoke" \
    MATRIX_PROCESS_INITIAL_SYNC=false \
    MATRIX_SYNC_TIMEOUT_MS=1000 \
    MATRIX_POLL_INTERVAL_MS=250 \
    MATRIX_DEFAULT_HARNESS=claude-code \
    PORT="$BOT_PORT" \
    bun services/matrixbot/src/index.ts > "$SMOKE_DIR/matrixbot.log" 2>&1 &
  MATRIXBOT_PID="$!"

  wait_http "http://127.0.0.1:$BOT_PORT/health" "Matrixbot"
  wait_for_bot_initial_sync "$SMOKE_DIR/matrixbot.log"

  scripts/local-matrix.sh send-mention "$room_id" "reply with exactly PONG" >/dev/null
  wait_for_pong "$MATRIX_HOMESERVER_URL" "$user_token" "$room_id"

  local encoded_room_id
  local messages_file="$SMOKE_DIR/messages.json"
  encoded_room_id="$(urlencode "$room_id")"
  echo "Matrixbot smoke passed"
  echo "Room: $room_id"
  echo "Recent room messages:"
  curl -fsS "$MATRIX_HOMESERVER_URL/_matrix/client/v3/rooms/$encoded_room_id/messages?dir=b&limit=5" \
    -H "Authorization: Bearer $user_token" > "$messages_file"
  jq -r '.chunk[]? | select(.content.body?) | "\(.sender): \(.content.body)"' "$messages_file"
}

main "$@"
