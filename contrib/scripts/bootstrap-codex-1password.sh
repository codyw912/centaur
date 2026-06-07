#!/usr/bin/env bash
set -euo pipefail

AUTH_JSON="${HOME}/.codex/auth.json"
CLIENT_ID="${OPENAI_CODEX_CLIENT_ID:-app_EMoamEEZ73f0CkXaXp7hrann}"
DRY_RUN=0
VAULT="${OP_VAULT:-}"

usage() {
  cat <<'EOF'
Usage: contrib/scripts/bootstrap-codex-1password.sh [--auth-json PATH] [--vault VAULT] [--client-id ID] [--dry-run]

Creates or updates the Centaur 1Password items used for brokered Codex
ChatGPT subscription auth:

  OPENAI_CODEX_CLIENT_ID
  OPENAI_CODEX_BLOB
  OPENAI_CODEX_ACCOUNT_ID

Each item gets a concealed field named "credential", matching Centaur's
op://$OP_VAULT/<ITEM>/credential convention. Values are read from a Codex
CLI auth.json created by `codex login`; secret values are never printed.

This helper is optional. If your organization manages 1Password items through
Terraform, SCIM, External Secrets, or another process, create equivalent items
with the same names and credential field.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auth-json)
      AUTH_JSON="${2:?--auth-json requires a path}"
      shift 2
      ;;
    --vault)
      VAULT="${2:?--vault requires a vault name or id}"
      shift 2
      ;;
    --client-id)
      CLIENT_ID="${2:?--client-id requires a value}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

require_cmd jq
require_cmd op

if [[ -z "$VAULT" ]]; then
  echo "FATAL: set OP_VAULT or pass --vault" >&2
  exit 1
fi
if [[ ! -r "$AUTH_JSON" ]]; then
  echo "FATAL: Codex auth file is not readable: $AUTH_JSON" >&2
  echo "Run 'codex login' on a trusted machine first, or pass --auth-json." >&2
  exit 1
fi

refresh_token="$(
  jq -er '
    .tokens.refresh_token
    // .refresh_token
    // .refreshToken
  ' "$AUTH_JSON"
)" || {
  echo "FATAL: could not find refresh token in $AUTH_JSON" >&2
  exit 1
}

account_id="$(
  jq -er '
    .tokens.account_id
    // .tokens.chatgpt_account_id
    // .tokens.chatgptAccountId
    // .chatgpt_account_id
    // .chatgptAccountId
    // .account_id
    // .accountId
  ' "$AUTH_JSON"
)" || {
  echo "FATAL: could not find ChatGPT account id in $AUTH_JSON" >&2
  exit 1
}

blob="$(jq -cn --arg refresh_token "$refresh_token" '{refresh_token: $refresh_token}')"

cleanup_files=()
cleanup() {
  local path
  for path in "${cleanup_files[@]}"; do
    [[ -n "$path" ]] && rm -f "$path"
  done
}
trap cleanup EXIT

tmp_file() {
  local path
  path="$(mktemp)"
  chmod 600 "$path"
  cleanup_files+=("$path")
  printf '%s\n' "$path"
}

write_item() {
  local name="$1"
  local value="$2"
  local value_file item_file updated_file

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'Would create/update 1Password item %s in vault %s\n' "$name" "$VAULT"
    return
  fi

  value_file="$(tmp_file)"
  item_file="$(tmp_file)"
  updated_file="$(tmp_file)"
  printf '%s' "$value" > "$value_file"

  if op item get "$name" --vault "$VAULT" --format json > "$item_file" 2>/dev/null; then
    jq --rawfile credential "$value_file" --arg title "$name" '
      .title = $title
      | .fields = (
          ([.fields[]? | select(.label != "credential" and .id != "credential")])
          + [{id: "credential", type: "CONCEALED", label: "credential", value: $credential}]
        )
    ' "$item_file" > "$updated_file"
    op item edit "$name" --vault "$VAULT" --template "$updated_file" >/dev/null
    printf 'Updated 1Password item %s in vault %s\n' "$name" "$VAULT"
  else
    op item template get "Secure Note" > "$item_file"
    jq --rawfile credential "$value_file" --arg title "$name" '
      .title = $title
      | .fields = (
          ([.fields[]? | select(.label != "credential" and .id != "credential")])
          + [{id: "credential", type: "CONCEALED", label: "credential", value: $credential}]
        )
    ' "$item_file" > "$updated_file"
    op item create --vault "$VAULT" --template "$updated_file" >/dev/null
    printf 'Created 1Password item %s in vault %s\n' "$name" "$VAULT"
  fi
}

write_item "OPENAI_CODEX_CLIENT_ID" "$CLIENT_ID"
write_item "OPENAI_CODEX_BLOB" "$blob"
write_item "OPENAI_CODEX_ACCOUNT_ID" "$account_id"

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'Dry run complete; no 1Password items were changed.\n'
else
  printf 'Codex 1Password bootstrap complete. Secret values were not printed.\n'
fi
