---
title: Use 1Password
description: Configure Centaur to resolve tool and harness credentials from 1Password through iron-proxy.
---

# Use 1Password

Use 1Password when you want tool and harness credentials to stay out of sandbox
pods and out of the API process. Sandboxes receive placeholders. [iron-proxy](https://docs.iron.sh)
resolves the real credential and injects it only for allowed upstream hosts.

There are two source modes:

- `onepassword-connect` runs an in-cluster 1Password Connect server and has
  iron-proxy talk to it with a Connect token. **This is the preferred mode
  for production**, mostly because the service-account SDK is rate-limited
  by 1Password and Connect is not. Under any non-trivial agent load you
  will hit those limits with the SDK. Connect resolves locally against the
  in-cluster server and stays out of the way.
- `onepassword` uses a 1Password service-account token directly from
  iron-proxy. Simpler to set up and fine for local development or low-volume
  deployments, but expect throttling once real traffic shows up.

## Configure the chart (Connect, preferred)

```yaml
ironProxy:
  secretSource: onepassword-connect
  secretTtl: 10m

onepasswordConnect:
  connect:
    create: true
    credentialsName: centaur-onepassword-connect-credentials
    credentialsKey: 1password-credentials.json

secretManager:
  existingSecretName: centaur-infra-env
  envPrefix: ""
```

The credentials Secret must contain `1password-credentials.json`; local
bootstrap creates it when `OP_CONNECT_CREDENTIALS_FILE` points at that file.
The infra Secret must include:

```text
OP_CONNECT_TOKEN
OP_VAULT
```

## Configure the chart (service account)

```yaml
ironProxy:
  secretSource: onepassword
  secretTtl: 10m

secretManager:
  existingSecretName: centaur-infra-env
  envPrefix: ""
```

The infra Secret must include:

```text
OP_SERVICE_ACCOUNT_TOKEN
OP_VAULT
```

It must also include infrastructure secrets such as:

```text
DATABASE_URL
SLACKBOT_API_KEY
SLACK_BOT_TOKEN
SLACK_SIGNING_SECRET
SANDBOX_SIGNING_KEY
IRON_MANAGEMENT_API_KEY
```

Those are boot-time service secrets, not tool credentials.

## Name 1Password items

For the normal tool declaration:

```toml
[tool.centaur]
secrets = [
    {type = "http", name = "WAREHOUSE_API_KEY", match_headers = ["Authorization"], hosts = ["warehouse.internal.example.com"]},
]
```

Create a 1Password item named `WAREHOUSE_API_KEY` in `OP_VAULT`, with the value
stored in the `credential` field. [iron-proxy](https://docs.iron.sh) resolves:

```text
op://$OP_VAULT/WAREHOUSE_API_KEY/credential
```

The tool sees `WAREHOUSE_API_KEY` as a placeholder. For requests to
`warehouse.internal.example.com` whose `Authorization` header contains the
placeholder, [iron-proxy](https://docs.iron.sh) replaces it with the real
1Password value.

## Harness credentials

Store enabled harness credentials the same way:

| Credential | Used for |
|------------|----------|
| `OPENAI_API_KEY` | Codex default |
| `AMP_API_KEY` | Amp |
| `ANTHROPIC_API_KEY` | Claude Code and pi-mono |

Each item should live in `OP_VAULT` with its value in `credential`.

Codex ChatGPT subscription auth uses brokered OAuth-style fields instead of a
single API key. For deployments that use the standard Centaur item layout, the
optional helper can create or update the expected 1Password items from a local
`codex login`. Run it with both vaults:

```bash
codex login
unset OP_SERVICE_ACCOUNT_TOKEN # if your shell has the read-only runtime token
OP_VAULT=centaur-runtime-secrets TOKEN_BROKER_OP_VAULT=centaur-broker-tokens \
  contrib/scripts/bootstrap-codex-1password.sh
```

This writes `OPENAI_CODEX_CLIENT_ID`, `OPENAI_CODEX_BLOB`, and
`OPENAI_CODEX_ACCOUNT_ID` items with a concealed `credential` field. It is not
required; corporate deployments can create equivalent items through Terraform,
External Secrets, 1Password Connect Operator, or another managed process.

In split-vault mode, the client id and blob go to `TOKEN_BROKER_OP_VAULT`, and
the account id goes to `OP_VAULT`.

Run the helper with an `op` identity that can write both target vaults; the
runtime service-account tokens are for Centaur pods, not for this bootstrap
step.

For legacy/simple deployments that intentionally keep all three items in one
vault, pass `--vault <vault>` explicitly.

Whichever identity serves iron-token-broker must be able to read the
broker-served items and update `OPENAI_CODEX_BLOB`, because refreshed token
state is persisted back into that item.

For least privilege with service accounts, use a separate writable broker vault
and token instead of granting write access to the normal `OP_VAULT`:

```bash
export OP_VAULT=centaur-runtime-secrets
export OP_SERVICE_ACCOUNT_TOKEN=... # read-only
export TOKEN_BROKER_OP_VAULT=centaur-broker-tokens
export TOKEN_BROKER_OP_SERVICE_ACCOUNT_TOKEN=... # read/write for broker vault
just bootstrap-secrets
CODEX_AUTH_MODE=access_token just deploy
```

Only the token-broker pod receives `TOKEN_BROKER_OP_SERVICE_ACCOUNT_TOKEN`;
iron-proxy and ordinary API/tool secrets continue using the read-only
`OP_SERVICE_ACCOUNT_TOKEN`.

For least privilege with 1Password Connect, use a broker-specific Connect token
instead of granting the shared runtime Connect token write access to brokered
OAuth items:

```bash
export OP_CONNECT_CREDENTIALS_FILE=/path/to/1password-credentials.json
export OP_CONNECT_TOKEN=... # read-only/runtime Connect token
export TOKEN_BROKER_OP_CONNECT_TOKEN=... # broker Connect token
export TOKEN_BROKER_OP_VAULT=centaur-broker-tokens

just bootstrap-secrets
CODEX_AUTH_MODE=access_token just deploy
```

`just bootstrap-secrets` writes `TOKEN_BROKER_OP_CONNECT_TOKEN` to a broker-only
Secret named `${CENTAUR_RELEASE:-centaur}-token-broker-env` by default, not to
the shared `centaur-infra-env` Secret used by API and Slackbot `envFrom`.
`just deploy` maps that Secret into only the token-broker deployment with:

```yaml
tokenBroker:
  onepasswordConnect:
    tokenSecretName: centaur-token-broker-env
    tokenKey: TOKEN_BROKER_OP_CONNECT_TOKEN
```

If the broker token talks to a separate Connect service, also set the broker
Connect host and NetworkPolicy selector:

```yaml
tokenBroker:
  onepasswordConnect:
    host: http://broker-connect:8080
    egress:
      podSelector:
        app: broker-connect
      # namespaceSelector and port are available when the service is not the
      # chart-managed Connect pod in the same namespace.
```

## Verify

Check that the API and [iron-proxy](https://docs.iron.sh) received the expected source mode:

```bash
kubectl exec -n centaur-system deploy/centaur-centaur-api -- env | \
  grep -E 'FIREWALL_MANAGER_SECRET_SOURCE|OP_VAULT'
```

For Connect mode, also verify the Connect pod and token Secret exist:

```bash
kubectl get pods -n centaur-system -l app.kubernetes.io/name=connect
kubectl get secret -n centaur-system centaur-onepassword-connect-credentials
kubectl get secret -n centaur-system centaur-infra-env -o jsonpath='{.data.OP_CONNECT_TOKEN}' >/dev/null
```

Then run a tool or harness call that reaches an allowed host. If injection
fails, check the secret entry's `hosts` and `match_*` fields, the 1Password
item name, `OP_VAULT`, and whether the item has a `credential` field.
