# Matrix Backend and Codex OAuth Design

Status: local draft

## Goals

- Add Matrix as a first-class chat backend without replacing Slack.
- Preserve the existing durable control-plane API:
  `spawn -> message -> execute -> events -> final delivery`.
- Keep Slack behavior stable while making shared backend concerns reusable.
- Add a path for Codex OAuth or access-token auth without weakening the current
  API-key-plus-proxy credential boundary.

## Non-Goals

- Do not introduce a broad generic bot framework up front.
- Do not refactor Slack streaming or rendering unless Matrix needs a shared
  primitive and the extraction is small.
- Do not make Codex OAuth the only auth mode. API-key mode must continue to work.
- Do not mix Matrix support and Codex OAuth in one PR-sized change.

## Current Shape

Slackbot is already a thin client over Centaur's durable API. It normalizes Slack
events, constructs a `slack:<team>:<channel>:<thread_ts>` thread key, hands the
turn to the API, then handles final-delivery outbox rows for Slack.

The API and sandbox layers are already platform-neutral for agent execution.
The platform-specific surface is concentrated in `services/slackbot`, Slack
delivery metadata, and Slack-specific rendering/status endpoints.

Sandbox harness credentials currently use placeholder environment variables,
for example `ANTHROPIC_API_KEY=ANTHROPIC_API_KEY`, and iron-proxy replaces those
placeholders on approved outbound hosts. Codex additionally logs in with
`codex login --with-api-key` from `CODEX_API_KEY` or `OPENAI_API_KEY`.

## Track 1: Matrix Backend

Add `services/matrixbot` as a sibling service to `services/slackbot`.

Matrixbot should own Matrix-specific concerns:

- Homeserver client configuration and access token handling.
- Event sync, deduplication, and mention/filter logic.
- Matrix thread key construction, likely:
  `matrix:<homeserver_id_or_domain>:<room_id>:<thread_root_or_event_id>`.
- Converting Matrix messages and attachments into Centaur message parts.
- Sending final responses back to Matrix rooms or threads.

The first Matrix implementation should use the API convenience path:
`POST /agent/execute` with `{thread_key, message, harness, delivery}`. This keeps
the bot small and avoids duplicating the manual spawn/message/execute sequence
until Matrix needs richer attachment handling or replay behavior.

Final delivery should claim rows with `platform: "matrix"` and a Matrix-specific
consumer id. Delivery metadata should include enough stable Matrix identifiers to
post idempotently:

- `room_id`
- `thread_root_event_id` or fallback parent event id
- `reply_to_event_id`
- optional `sender`

Matrix idempotency should not depend only on reading room history. Store a
Centaur execution id in Matrix event content metadata when possible, and keep
room-history checks as a best-effort duplicate guard.

## Track 2: Shared Chat Client Utilities

Only extract shared code after Matrixbot proves the duplicated shape.

Good candidates:

- A small Centaur API client for `execute`, final-delivery claim, delivered, and
  failed.
- Final-delivery polling loop parameterized by platform and delivery function.
- Common result-text extraction and chunking.
- Trace header construction.

Bad candidates:

- A shared event model that tries to erase Slack and Matrix semantics.
- A generic streaming renderer before Matrix has feature parity requirements.
- A shared bot runtime that forces Slack and Matrix into one service.

The target shared package can live under `packages/chat-bridge` or inside a
service-local module until a second service actually imports it.

## Track 3: Codex OAuth / Access-Token Auth

Codex upstream supports ChatGPT OAuth, device auth, API-key auth, and access
tokens. Centaur currently uses API-key mode because sandbox pods are non-
interactive and credential injection is mediated by iron-proxy.

Add an explicit Codex auth mode rather than replacing the current behavior:

- `codex_api_key`: current default, uses `OPENAI_API_KEY`/`CODEX_API_KEY` and
  iron-proxy injection.
- `codex_access_token`: reads a deployment-scoped or user-scoped access token
  from the configured secret source and runs
  `codex login --with-access-token`.
- `codex_cached_auth`: mounts or materializes a managed `auth.json` into
  `CODEX_HOME` for deployments that can safely store refreshed Codex login
  state.

The safest first implementation is `codex_access_token` if a refresh strategy is
available outside the sandbox. Cached OAuth state is more complex because it
introduces lifecycle, refresh, revocation, and per-user isolation questions.

Open security decisions:

- Is Codex OAuth deployment-scoped or per-user?
- Where is refreshable auth state stored?
- Can a sandbox write refreshed auth state back, or is auth read-only per turn?
- How does final delivery identify which user credential was used?

## Implementation Order

1. Add local Matrix design and service skeleton.
2. Implement Matrix inbound text-only mention to Claude/Codex with final reply.
3. Add Matrix final-delivery polling and idempotency.
4. Extract a minimal Centaur API/final-delivery helper if duplication is clear.
5. Add Matrix Helm values and disabled-by-default deployment.
6. Add Codex auth-mode design and tests.
7. Implement the smallest non-interactive Codex auth mode beyond API keys.

## Testing Plan

- Unit-test Matrix event normalization, thread key construction, and delivery
  metadata.
- Unit-test final-delivery claim/ack/fail behavior with mocked Matrix API calls.
- Add one API-only integration test that exercises `platform: "matrix"` final
  delivery rows.
- For local E2E, run Synapse or another lightweight Matrix homeserver, invite
  the bot to a room, send a mention, and verify one final response.
- Keep Slackbot tests unchanged during the initial Matrix service addition.

## Local Matrix Harness

Use `scripts/local-matrix.sh` for a disposable Synapse container:

```bash
scripts/local-matrix.sh start
scripts/local-matrix.sh env
ROOM_ID=$(scripts/local-matrix.sh create-room)
scripts/local-matrix.sh send-mention "$ROOM_ID" "reply with exactly PONG"
```

The script stores generated Synapse data under `.local/matrix-synapse`, which is
ignored by git. It configures a local registration shared secret, creates a bot
user (`centaur`) and test user (`alice`), disables local-dev rate limits, and
prints Matrixbot-compatible environment exports. Use
`scripts/local-matrix.sh reset` to remove the disposable server state.

## First Implementation Slice

The first useful slice is a text-only Matrixbot:

- Configuration: homeserver URL, access token, user id, Centaur API URL/key,
  default harness.
- Sync loop: receive room message events, ignore own messages, detect mentions.
- Handoff: call `POST /agent/execute` with `harness: "claude-code"` by default
  for local testing.
- Delivery: claim `platform: "matrix"` final-delivery rows and post plain text
  replies into the originating room/thread.

This proves the backend shape before touching Slack internals or Codex auth.
