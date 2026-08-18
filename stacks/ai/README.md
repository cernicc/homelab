# ai

[Hermes Agent](https://hermes-agent.nousresearch.com/) — self-improving AI agent from Nous Research — with [browser-use](https://github.com/browser-use/browser-use) baked in as a local MCP tool for web browsing/automation, fronted by Traefik at `ai.${DOMAIN_NAME}` (Hermes' dashboard, port 9119).

## Why one container

browser-use's MCP server only speaks stdio — there's no HTTP/SSE transport in the open-source package, and neither project documents running it as a separate networked service (browser-use's own answer to "remote/production" is their paid Cloud API, not self-hosting). Hermes' own docs are built around spawning stdio MCP servers as local subprocesses it owns directly, including recycling long-lived ones via `idle_timeout_seconds`/`max_lifetime_seconds` — which only works if Hermes owns the process. So browser-use is installed straight into the Hermes image (`Dockerfile`) and spawned as a subprocess, not run as a sidecar.

`entrypoint.sh` regenerates `/opt/data/config.yaml`'s `mcp_servers` block on every container start from `OPENCODE_GO_API_KEY`, so the secret never gets committed to git. **This means `config.yaml` is not a place for manual/persistent edits** — it's overwritten on every restart. To add more MCP servers, edit `entrypoint.sh`.

## Browser: self-launched Chromium over CDP, not Playwright

browser-use no longer bundles/manages a Playwright-installed Chromium (confirmed against its actual `pyproject.toml`: depends on `cdp-use` + `browser-harness`, no `playwright`/`patchright`). It now expects to attach to a browser over CDP — via `BU_CDP_URL`/`BU_CDP_WS`, a paid Browser Use Cloud session, or an already-running local Chrome. The docs' own recommendation for a headless machine is Cloud Browsers; to stay fully self-hosted, the `Dockerfile` installs `chromium` via apt and `entrypoint.sh` launches it itself (`--headless=new`, CDP on `127.0.0.1:9222`, `--remote-allow-origins=*` to dodge Chrome's CDP-origin-check trap), then points browser-use at it via `BU_CDP_URL`.

One consequence: Chromium is launched once per **container** start, not per MCP-server subprocess — so `idle_timeout_seconds`/`max_lifetime_seconds` below only recycle the `browser-use` process, not the underlying browser. Fine for a first pass; revisit if memory creeps up over long uptimes.

Chromium's `--user-data-dir` is deliberately `/tmp/chromium-profile`, not on the `/opt/data` volume: a profile dir that survives a hard container restart keeps its `SingletonLock` file too (Chrome can't clean it up on SIGKILL), and every subsequent launch then fails instantly with *"profile appears to be in use by another Chromium process"* — a silent crash-loop, no error anywhere except `/opt/data/chromium.log`, that also cascades into `browser-use` itself repeatedly trying (and failing) to spawn fallback local Chromiums. `/tmp` is guaranteed fresh every start. Cost: no persistent cookies/login state across restarts.

## Gotcha: the venv's Python must NOT be `uv`'s managed interpreter

`uv venv` defaults to downloading/using its own managed CPython build, which lands under `/root/.local/share/uv/python/...` (owned by root, mode `700`). Hermes' gateway runs as an unprivileged `hermes` user (uid 10000) and spawns MCP subprocesses as that same user — which can't traverse into `/root` at all. Every exec of a script shebanged at such a python silently fails with `Permission denied`, and Hermes' MCP client just reports it as `Connection closed` after burning its retry budget — no useful error surfaces anywhere in `podman logs`. Confirmed by reproducing the exact failure with `hermes mcp test browser-use`, then tracing it to a plain `su hermes -c '/opt/browser-use-venv/bin/browser-use-real --help'` → `Permission denied`.

Fix: `uv venv --python /usr/bin/python3 /opt/browser-use-venv` — pins it to the base image's own system interpreter (normal `/usr` permissions, world-executable) instead of a fresh root-owned one. If this stack ever gets a `Connection closed` MCP error again, check this first: `podman exec ai-hermes-1 su hermes -s /bin/sh -c '/opt/browser-use-venv/bin/browser-use --mcp </dev/null'` should exit `0` silently, not `Permission denied`.

## Required `.env` vars

- `OPENCODE_GO_API_KEY` — [OpenCode Go](https://opencode.ai/docs/go/), $10/mo subscription. Required; the container refuses to start without it (both at `compose up` time and in `entrypoint.sh`). Used for both Hermes' own model and browser-use's page-reasoning calls.
- `AI_MODEL` — optional, any model id from `https://opencode.ai/zen/go/v1/models` (e.g. `kimi-k2.7-code`, `deepseek-v4-pro`). Defaults to `glm-5.3`. Sets `model: opencode-go/<id>` in `config.yaml` on every boot — Hermes has a built-in `opencode-go` provider preset, no `base_url` needed.

### browser-use + OpenCode Go — confirmed working

`entrypoint.sh` points browser-use's `OPENAI_API_KEY`/`OPENAI_BASE_URL` at `https://opencode.ai/zen/go/v1` (OpenCode Go's OpenAI-compatible endpoint). Not a documented integration on either project's side, but verified end-to-end on first deploy: `hermes -z "Use the browser tool to navigate to https://example.com and tell me the exact page title."` successfully drove the self-launched Chromium and got a real answer back through OpenCode Go.

## First-boot checklist

- `podman compose logs -f hermes` starts cleanly and the container doesn't restart-loop. ✓ verified
- `hermes mcp list` inside the container shows `browser-use` connected (not parked). If it says `Connection closed`, see the venv-permissions gotcha above first.
- The dashboard on port 9119 has no auth of its own documented — same trust model as `stirling-pdf`/`jellyfin` (anyone reachable on the tailnet can use it). Check whether Hermes has grown an auth option worth turning on, given this agent can take real actions on the web.
