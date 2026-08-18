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

## Gotcha: `BU_CDP_URL` is not read by the MCP server — needs `config.json`

`BU_CDP_URL` (used above) only exists for `browser_harness`, the daemon behind the interactive `browser-use <<PY ... PY` REPL — a completely separate code path from the MCP server (`browser_use/mcp/server.py`), which never reads it. Every `tools/call` for a browser action hung for exactly 30s then failed with `BrowserStartEvent timed out`, because with no `cdp_url` on its `BrowserProfile` the MCP server tries to launch and manage its *own* separate browser instead of attaching to ours.

Traced by reading `browser_use/config.py` directly: the MCP server builds its browser profile from `~/.config/browseruse/config.json`, in a "DB-style" schema — `browser_profile`/`llm`/`agent` dicts keyed by an id, one entry per section flagged `"default": true`, extra fields (like `cdp_url`) allowed through (`ConfigDict(extra='allow')` on `BrowserProfileEntry`). `entrypoint.sh` now writes this file with `cdp_url` pointed at the Chromium launched above. Verified directly against the raw MCP protocol: `browser_navigate` and `browser_get_html` both work in well under a second once this file is in place (`browser_extract_content`'s own LLM-based extraction returned "No content extracted" in testing — worth another look, but the core navigate/read/click path works).

If this stack ever regresses to hanging ~30s per browser tool call, check `podman exec -u hermes ai-hermes-1 cat /opt/data/.config/browseruse/config.json` first — that file has to exist with a `default: true` entry carrying a live `cdp_url`, and `entrypoint.sh` has to actually be the thing writing it (not a leftover from manual debugging).

## Gotcha: Hermes' own built-in "browser" toolset competes with browser-use

Hermes ships its own native browser tool (`browser_exec`, toolset `browser`, `hermes tools list`) built on the same `browser_harness` daemon as the interactive REPL — a third, separate code path from both the MCP server and the fix above, and one that was failing in this container (`browser-harness doctor` → `[FAIL] daemon alive`). With both the native tool and the `browser-use` MCP server enabled, the model has no reason to prefer one over the other — it picked the broken native one (`browser_exec` with `new_tab()`/`js()`-style code) and every browsing task hung indefinitely.

Fixed by disabling the native toolset in `config.yaml`'s `platform_toolsets.cli` list (`entrypoint.sh` writes the full default list minus `browser`), so `browser-use`'s MCP tools are the only browsing capability the model sees — which is the actual point of this stack. Confirmed via `hermes tools list` showing `✗ disabled browser` and `browser-use  all tools enabled`.

## Required `.env` vars

- `OPENCODE_GO_API_KEY` — [OpenCode Go](https://opencode.ai/docs/go/), $10/mo subscription. Required; the container refuses to start without it (both at `compose up` time and in `entrypoint.sh`). Used for both Hermes' own model and browser-use's page-reasoning calls.
- `AI_MODEL` — optional, any model id from `https://opencode.ai/zen/go/v1/models` (e.g. `kimi-k2.7-code`, `deepseek-v4-pro`). Defaults to `glm-5.3`. Sets `model: opencode-go/<id>` in `config.yaml` on every boot — Hermes has a built-in `opencode-go` provider preset, no `base_url` needed.

### browser-use + OpenCode Go

`entrypoint.sh` points browser-use's `OPENAI_API_KEY`/`OPENAI_BASE_URL` at `https://opencode.ai/zen/go/v1` (OpenCode Go's OpenAI-compatible endpoint). Not a documented integration on either project's side, but confirmed working for `browser_navigate`/`browser_get_html` against the raw MCP protocol.

## First-boot checklist

- `podman compose logs -f hermes` starts cleanly and the container doesn't restart-loop. ✓ verified
- `hermes mcp list` inside the container shows `browser-use` connected (not parked). If it says `Connection closed`, see the venv-permissions gotcha above.
- `hermes tools list` shows `✗ disabled browser` and `browser-use  all tools enabled`. If `browser` is still enabled, the model may reach for Hermes' own broken native browser tool instead — see gotcha above.
- `hermes -z "Use the browser tool to navigate to https://example.com and tell me the exact page title."` completes and gives a real answer. If it hangs, see the gotchas above (`config.json`/`cdp_url` first, then the native `browser` toolset).
- The dashboard on port 9119 has no auth of its own documented — same trust model as `stirling-pdf`/`jellyfin` (anyone reachable on the tailnet can use it). Check whether Hermes has grown an auth option worth turning on, given this agent can take real actions on the web.
