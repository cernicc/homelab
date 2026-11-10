# ai

AI tooling.

## LibreChat

[LibreChat](https://www.librechat.ai/) — self-hosted chat UI, used with the [OpenCode Go](https://opencode.ai/docs/go) subscription from any device on the tailnet. Fronted by a `librechat-ts` Tailscale sidecar (see [stacks/whoami/README.md](../whoami/README.md) for the pattern) at `https://chat.<tailnet-name>.ts.net`.

Containers:

- `librechat` — the app, listening on loopback `:3080` inside the sidecar's network namespace.
- `mongodb` — conversations, users, settings. Only on the stack's `ai` network.
- `meilisearch` — conversation search. Only on the `ai` network.

There is no RAG API / vector DB yet, so file search over uploaded documents is not available.

### Configuration

Everything is declarative, nothing is configured in the UI:

- [`docker-compose.yml`](docker-compose.yml) — env vars: domain, auth, the OpenCode API key.
- [`librechat.yaml`](librechat.yaml) — interface options, the OpenCode Go endpoint (models fetched live from its `/models`), and MCP servers. Users can't add MCP servers in the UI (`interface.mcpServers.create: false`).
- `~/homelab/.env` on `batcave` — secrets:
  - `LIBRECHAT_DOMAIN` — `https://chat.<tailnet-name>.ts.net`
  - `OPENCODE_API_KEY` — the OpenCode Go API key
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
