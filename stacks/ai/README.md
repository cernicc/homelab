# ai

[Hermes Agent](https://hermes-agent.nousresearch.com/) — self-improving AI agent from Nous Research — with [browser-use](https://github.com/browser-use/browser-use) baked in as a local MCP tool for web browsing/automation, fronted by Traefik at `ai.${DOMAIN_NAME}` (Hermes' dashboard, port 9119).

## Why one container

browser-use's MCP server only speaks stdio — there's no HTTP/SSE transport in the open-source package, and neither project documents running it as a separate networked service (browser-use's own answer to "remote/production" is their paid Cloud API, not self-hosting). Hermes' own docs are built around spawning stdio MCP servers as local subprocesses it owns directly, including recycling long-lived ones via `idle_timeout_seconds`/`max_lifetime_seconds` — which only works if Hermes owns the process. So browser-use is installed straight into the Hermes image (`Dockerfile`) and spawned as a subprocess, not run as a sidecar.

`entrypoint.sh` regenerates `/opt/data/config.yaml`'s `mcp_servers` block on every container start from `OPENCODE_GO_API_KEY`, so the secret never gets committed to git. **This means `config.yaml` is not a place for manual/persistent edits** — it's overwritten on every restart. To add more MCP servers, edit `entrypoint.sh`.

## Browser: self-launched Chromium over CDP, not Playwright

browser-use no longer bundles/manages a Playwright-installed Chromium (confirmed against its actual `pyproject.toml`: depends on `cdp-use` + `browser-harness`, no `playwright`/`patchright`). It now expects to attach to a browser over CDP — via `BU_CDP_URL`/`BU_CDP_WS`, a paid Browser Use Cloud session, or an already-running local Chrome. The docs' own recommendation for a headless machine is Cloud Browsers; to stay fully self-hosted, the `Dockerfile` installs `chromium` via apt and `entrypoint.sh` launches it itself (`--headless=new`, CDP on `127.0.0.1:9222`, `--remote-allow-origins=*` to dodge Chrome's CDP-origin-check trap), then points browser-use at it via `BU_CDP_URL`.

One consequence: Chromium is launched once per **container** start, not per MCP-server subprocess — so `idle_timeout_seconds`/`max_lifetime_seconds` below only recycle the `browser-use` process, not the underlying browser. Fine for a first pass; revisit if memory creeps up over long uptimes.

## Required `.env` vars

- `OPENCODE_GO_API_KEY` — [OpenCode Go](https://opencode.ai/docs/go/), $10/mo subscription. Required; the container refuses to start without it (both at `compose up` time and in `entrypoint.sh`). Used for both Hermes' own model (Hermes has a built-in `opencode-go` provider preset — pick the actual model via `hermes model` on first boot) and browser-use's page-reasoning calls.

### browser-use + OpenCode Go — unverified

`entrypoint.sh` points browser-use's `OPENAI_API_KEY`/`OPENAI_BASE_URL` at `https://opencode.ai/zen/go/v1` (OpenCode Go's OpenAI-compatible endpoint). This is **not a documented integration on either project's side** — Hermes' OpenCode support only covers Hermes' own model selection, and browser-use's MCP server docs only mention `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`, nothing about OpenCode or a custom base URL. It's inferred from browser-use using `ChatOpenAI` (which resolves `OPENAI_BASE_URL` the way the OpenAI SDK normally does) plus OpenCode Go being genuinely OpenAI-compatible. **Confirm it actually works on first boot** — since there's no other provider configured, if this routing doesn't work browser-use has no working key at all and that MCP tool will just fail (Hermes itself is unaffected).

## First-boot checklist

This setup is assembled from Hermes/browser-use docs rather than a tested reference deployment (both are fast-moving projects) — verify on first deploy:

- `podman compose logs -f hermes` starts cleanly and the container doesn't restart-loop.
- The base `nousresearch/hermes-agent` image's own entrypoint doesn't require anything beyond `hermes gateway run` to reach a working gateway (this Dockerfile fully replaces it with `entrypoint.sh`, bypassing whatever init the upstream image normally does).
- `hermes model` (or the dashboard) shows `opencode-go` as an authenticated provider if `OPENCODE_GO_API_KEY` is set, and pick an actual model — it isn't pinned declaratively here.
- Ask Hermes (via the dashboard or gateway API) to do something requiring the browser — confirms the `browser-use` MCP entry actually loaded (`hermes mcp list` inside the container should show it as connected) **and** that the OpenCode Go routing above actually works.
- The dashboard on port 9119 has no auth of its own documented — same trust model as `stirling-pdf`/`jellyfin` (anyone reachable on the tailnet can use it). Check whether Hermes has grown an auth option worth turning on, given this agent can take real actions on the web.
