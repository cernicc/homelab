# ai

AI tooling.

## LibreChat

[LibreChat](https://www.librechat.ai/) — self-hosted chat UI, used with the [OpenCode Go](https://opencode.ai/docs/go) subscription from any device on the tailnet. Fronted by a `librechat-ts` Tailscale sidecar (see [stacks/whoami/README.md](../whoami/README.md) for the pattern) at `https://chat.<tailnet-name>.ts.net`. Model calls go through [agentgateway](#agentgateway), not straight to OpenCode.

Containers:

- `librechat` — the app, listening on loopback `:3080` inside the sidecar's network namespace.
- `mongodb` — conversations, users, settings. Only on the stack's `ai` network.
- `meilisearch` — conversation search. Only on the `ai` network.

There is no RAG API / vector DB yet, so file search over uploaded documents is not available.

### Configuration

Everything is declarative, nothing is configured in the UI:

- [`docker-compose.yml`](docker-compose.yml) — env vars: domain, auth, LibreChat's agentgateway key.
- [`librechat.yaml`](librechat.yaml) — interface options, the OpenCode Go endpoint (pointed at `http://agentgateway:4000/v1`, models fetched live from agentgateway's `/models`), and MCP servers. Users can't add MCP servers in the UI (`interface.mcpServers.create: false`).
- `~/homelab/.env` on `batcave` — secrets:
  - `LIBRECHAT_DOMAIN` — `https://chat.<tailnet-name>.ts.net`
  - `LIBRECHAT_CREDS_KEY` — `openssl rand -hex 32`
  - `LIBRECHAT_CREDS_IV` — `openssl rand -hex 16`
  - `LIBRECHAT_JWT_SECRET`, `LIBRECHAT_JWT_REFRESH_SECRET`, `LIBRECHAT_MEILI_MASTER_KEY` — `openssl rand -hex 32` each

Changing `LIBRECHAT_CREDS_KEY`/`LIBRECHAT_CREDS_IV` makes stored credentials unreadable; changing the JWT secrets logs everyone out.

LibreChat reads `librechat.yaml` only at start, and `homelab-sync` doesn't recreate the container when only that file changes. After pushing a change to it, run `podman restart ai-librechat-1` on `batcave`.

When bumping the LibreChat image, also bump `version` in `librechat.yaml` to the one in `librechat.example.yaml` at the new tag.

### Accounts

Sign-up is disabled (`ALLOW_REGISTRATION=false`). Create accounts over SSH on `batcave`:

```bash
podman exec -it ai-librechat-1 npm run create-user
```

The first user created becomes the admin.

### Verifying

- `podman logs ai-librechat-1` — connects to MongoDB and Meilisearch, no config validation errors
- `https://chat.<tailnet-name>.ts.net` — login page with a valid cert; after logging in, the OpenCode Go models are listed

## agentgateway

[agentgateway](https://agentgateway.dev/) — LLM (and later MCP) gateway between clients and OpenCode Go. It holds the OpenCode key, gives each client its own gateway key, decides which models are offered, logs every request (tokens, latency) to SQLite, and serves a web UI. Fronted by an `agentgateway-ts` Tailscale sidecar at `https://agentgateway.<tailnet-name>.ts.net` (UI at `/ui`, OpenAI-compatible API at `/v1`).

Containers:

- `agentgateway` — the gateway on `:4000`, on the `ai` network. LibreChat reaches it as `http://agentgateway:4000/v1`.
- `agentgateway-ts` — tailnet ingress. Unlike `librechat-ts`, it doesn't share a namespace with the app: it proxies to `agentgateway:4000` over the `ai` network, so plain HTTP `:4000` is never on the tailnet while LibreChat can still reach it by name.

The admin endpoint (`:15000`, config dump, shutdown) stays on the container's loopback.

### Configuration

- [`agentgateway.yaml`](agentgateway.yaml) — gateway, UI, the OpenCode Go provider, the model list, and client keys. Dollar-prefixed names come from the container environment, even in comments, and agentgateway won't start if one is unset. Model and route changes reload live on push; the `config:` block (database, storage) needs `podman restart ai-agentgateway-1`.
- The UI is read-only (`config.storage.mode: readOnly`): the file in git is the only source of truth.
- `~/homelab/.env` on `batcave` — secrets:
  - `OPENCODE_API_KEY` — the OpenCode Go API key; only agentgateway gets it
  - `AGENTGATEWAY_LIBRECHAT_API_KEY` — LibreChat's gateway key, `openssl rand -hex 32`
  - `AGENTGATEWAY_SESSION_KEY` — encrypts the MCP session IDs the gateway hands to clients, `openssl rand -hex 32`. Changing it only ends open MCP sessions.
  - `AGENTGATEWAY_UNDERSTORY_API_KEY` — understory's gateway key (limited to `glm-5.3`), `openssl rand -hex 32`
  - `UNDERSTORY_AUTH_TOKEN` — what agentgateway sends to understory's `/mcp`, `openssl rand -hex 32`

The model list is explicit, so new OpenCode Go models don't show up until they're added to `agentgateway.yaml`. Get the current IDs with:

```bash
curl -s https://opencode.ai/zen/go/v1/models | jq -r '.data[].id'
```

To give another client (e.g. a coding agent on a laptop) access, add a key under `llm.policies.apiKey.keys` (from a new `.env` variable passed to the container) and point the client at `https://agentgateway.<tailnet-name>.ts.net/v1`.

The UI itself has no login; anyone on the tailnet can open it, the same as the other stacks.

### Verifying

- `podman logs ai-agentgateway-1` — config loaded, listening on `:4000`, no errors about unset variables
- `https://agentgateway.<tailnet-name>.ts.net/ui` — the UI, with the `opencode-go` provider and models listed
- `curl -s -H "Authorization: Bearer $AGENTGATEWAY_LIBRECHAT_API_KEY" https://agentgateway.<tailnet-name>.ts.net/v1/models` — the model list; without the header, 401
- Chat in LibreChat, then check the request appears in the UI's logs (or `podman logs ai-agentgateway-1`). The gateway passes client headers through, so LibreChat's `x-opencode-session` reaches OpenCode; a `400 MissingSessionID` means LibreChat stopped sending it.

MCP session IDs are encrypted with `AGENTGATEWAY_SESSION_KEY`, so the "no session key configured" warning shouldn't appear in the logs.

### MCP

MCP servers are targets under `mcp:` in [`agentgateway.yaml`](agentgateway.yaml), multiplexed into one endpoint, `http://agentgateway:4000/mcp` (or `https://agentgateway.<tailnet-name>.ts.net/mcp` from the tailnet). Clients use their gateway key, and the gateway adds each server's own credentials. LibreChat lists it under `mcpServers` in [`librechat.yaml`](librechat.yaml), with `mcpSettings.allowedAddresses` letting it past LibreChat's block on private addresses.

## understory

[understory](https://github.com/thecodacus/understory) — long-term memory for agents, kept as plain-markdown concepts that link into a graph, in the `understory-memory` volume. Every change is a git commit in that volume (`GIT_AUTOCOMMIT`). It exposes `memory_query`, `memory_add`, `memory_update`, `memory_status` and `memory_maintain`, and each call runs understory's own LLM agent, which uses `glm-5.3` through agentgateway on its own key.

- `understory` — on the `ai` network only, port 3800. `/mcp` and `/api` require `UNDERSTORY_AUTH_TOKEN`, which only agentgateway has.
- In LibreChat it's "Memory" under MCP Servers in the composer. One memory is shared by every LibreChat user.
- The image has no releases, only `latest` and per-commit `sha-*` tags, so it's pinned to a commit tag.
- Its web UI (graph view, chat) isn't exposed.

Verifying:

- `podman logs ai-understory-1` — listening on 3800, no auth or LLM errors
- `podman logs ai-agentgateway-1` — no MCP target errors; understory's own model calls show up as `/v1/chat/completions` requests for `glm-5.3`
- In LibreChat, turn on Memory, tell it something to remember, and ask about it in a new chat
