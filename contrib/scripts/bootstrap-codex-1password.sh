#!/usr/bin/env bash
set -euo pipefail

AUTH_JSON="${HOME}/.codex/auth.json"
CLIENT_ID="${OPENAI_CODEX_CLIENT_ID:-app_EMoamEEZ73f0CkXaXp7hrann}"
DRY_RUN=0
ACCOUNT_VAULT="${OP_VAULT:-}"
BROKER_VAULT="${TOKEN_BROKER_OP_VAULT:-}"

usage() {
  cat <<'EOF'
Usage: contrib/scripts/bootstrap-codex-1password.sh [--auth-json PATH] [--vault VAULT] [--account-vault VAULT] [--broker-vault VAULT] [--client-id ID] [--dry-run]

Creates or updates the Centaur 1Password items used for brokered Codex
ChatGPT subscription auth:

  OPENAI_CODEX_CLIENT_ID
  OPENAI_CODEX_BLOB
  OPENAI_CODEX_ACCOUNT_ID

Each item gets a concealed field named "credential". Values are read from a
Codex CLI auth.json created by `codex login`; secret values are never printed.

By default, OP_VAULT targets the account/read-only vault and
TOKEN_BROKER_OP_VAULT targets the broker vault:

  OPENAI_CODEX_CLIENT_ID  -> broker vault
  OPENAI_CODEX_BLOB       -> broker vault
  OPENAI_CODEX_ACCOUNT_ID -> account/read-only vault

Use --vault only for legacy/simple deployments that intentionally keep all
three items in one vault.

This helper is optional. If your organization manages 1Password items through
Terraform, SCIM, External Secrets, or another process, create equivalent items
with the same names and credential field.

Run this helper with an `op` identity that can create/update items in both
target vaults. If OP_SERVICE_ACCOUNT_TOKEN is exported for Centaur runtime
bootstrap and is read-only, unset it before running this helper so `op` can use
your normal desktop/account sign-in instead.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auth-json)
      AUTH_JSON="${2:?--auth-json requires a path}"
      shift 2
      ;;
    --vault)
      ACCOUNT_VAULT="${2:?--vault requires a vault name or id}"
      BROKER_VAULT="$ACCOUNT_VAULT"
      shift 2
      ;;
    --account-vault)
      ACCOUNT_VAULT="${2:?--account-vault requires a vault name or id}"
      shift 2
      ;;
    --broker-vault)
      BROKER_VAULT="${2:?--broker-vault requires a vault name or id}"
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

if [[ -z "$ACCOUNT_VAULT" ]]; then
  echo "FATAL: set OP_VAULT, pass --vault, or pass --account-vault" >&2
  exit 1
fi
if [[ -z "$BROKER_VAULT" ]]; then
  echo "FATAL: set TOKEN_BROKER_OP_VAULT, pass --broker-vault, or pass --vault for explicit single-vault mode" >&2
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
  local vault="$2"
  local value="$3"
  local value_file item_file updated_file

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'Would create/update 1Password item %s in vault %s\n' "$name" "$vault"
    return
  fi

  value_file="$(tmp_file)"
  item_file="$(tmp_file)"
  updated_file="$(tmp_file)"
  printf '%s' "$value" > "$value_file"

  if op item get "$name" --vault "$vault" --format json > "$item_file" 2>/dev/null; then
    jq --rawfile credential "$value_file" --arg title "$name" '
      .title = $title
      | .fields = (
          ([.fields[]? | select(.label != "credential" and .id != "credential")])
          + [{id: "credential", type: "CONCEALED", label: "credential", value: $credential}]
        )
    ' "$item_file" > "$updated_file"
    op item edit "$name" --vault "$vault" --template "$updated_file" >/dev/null
    printf 'Updated 1Password item %s in vault %s\n' "$name" "$vault"
  else
    op item template get "Secure Note" > "$item_file"
    jq --rawfile credential "$value_file" --arg title "$name" '
      .title = $title
      | .fields = (
          ([.fields[]? | select(.label != "credential" and .id != "credential")])
          + [{id: "credential", type: "CONCEALED", label: "credential", value: $credential}]
        )
    ' "$item_file" > "$updated_file"
    op item create --vault "$vault" --template "$updated_file" >/dev/null
    printf 'Created 1Password item %s in vault %s\n' "$name" "$vault"
  fi
}

write_item "OPENAI_CODEX_CLIENT_ID" "$BROKER_VAULT" "$CLIENT_ID"
write_item "OPENAI_CODEX_BLOB" "$BROKER_VAULT" "$blob"
write_item "OPENAI_CODEX_ACCOUNT_ID" "$ACCOUNT_VAULT" "$account_id"

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'Dry run complete; no 1Password items were changed.\n'
else
  printf 'Codex 1Password bootstrap complete. Secret values were not printed.\n'
fi
