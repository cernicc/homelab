# ai

[Hermes Agent](https://hermes-agent.nousresearch.com/) — self-improving AI agent from Nous Research — using [browser-use](https://github.com/browser-use/browser-use) as its browsing backend, fronted by Traefik at `ai.${DOMAIN_NAME}` (Hermes' dashboard, port 9119).

## Architecture: Hermes' native browser-use integration, not a custom MCP server

The first version of this stack hand-configured browser-use as a custom MCP server (`mcp_servers` in `config.yaml`, its own stdio subprocess). That worked at the raw-protocol level, but Hermes turned out to ship its **own native integration** with the exact same browser-use CLI: a single `browser_exec` tool (toolset `browser`) that Hermes drives itself, auto-enabled whenever a `browser-use` binary is discoverable (confirmed by reading `/opt/hermes/tools/browser_use_cli.py` + `toolsets.py` directly in the built image). With both wired up, the model had two different, competing "browser" tools to pick from and reliably chose the native one — so the custom MCP server was just dead weight. This version drops it and leans on the native path instead, which is simpler and is what the model reaches for anyway.

- **`Dockerfile`** installs a real Chromium via apt (see below), and a pinned `browser-use[cli]` into a dedicated `uv` venv added to `PATH` — so Hermes' own CLI-discovery (`shutil.which("browser-use")`) finds this offline copy instead of falling back to a live `uvx` fetch from PyPI on every single tool call.
- **`entrypoint.sh`** launches that Chromium headless, regenerates `config.yaml`'s `model` key from `OPENCODE_GO_API_KEY` on every start (so the secret never gets committed to git — **`config.yaml` is not a place for manual/persistent edits**), and exports `BU_CDP_URL` so Hermes' browser tool attaches to it.

## Gotcha: `uv venv` must NOT use its own managed Python interpreter

`uv venv` defaults to downloading its own managed CPython build, landing under `/root/.local/share/uv/python/...` (owned by root, mode `700`). Hermes runs as an unprivileged `hermes` user (uid 10000) that can't traverse into `/root` at all — every exec of a script shebanged at such a python silently fails with `Permission denied`, which surfaced as nothing more informative than a generic MCP `Connection closed` while this was still a custom MCP server. Confirmed by reproducing with `su hermes -s /bin/sh -c '.../browser-use --help'` → `Permission denied`.

Fix (still relevant — this is what makes the CLI runnable by Hermes at all): `uv venv --python /usr/bin/python3 /opt/browser-use-venv` — pins it to the base image's own system interpreter (normal `/usr` permissions, world-executable).

## Gotcha: Chromium's profile dir must be ephemeral

Chromium's `--user-data-dir` is deliberately `/tmp/chromium-profile`, not on the `/opt/data` volume: a profile dir that survives a hard container restart keeps its `SingletonLock` file too (Chrome can't clean it up on SIGKILL), and every subsequent launch then fails instantly with *"profile appears to be in use by another Chromium process"* — a silent crash-loop, visible only in `/opt/data/chromium.log` (`ps` just shows a stream of defunct `chromium`/`chrome_crashpad` processes). `/tmp` is guaranteed fresh every start. Cost: no persistent cookies/login state across restarts.

## Gotcha: `BU_CDP_URL` vs. `BROWSER_CDP_URL` vs. `browser.cdp_url`

Traced by reading Hermes' own source (`tools/browser_use_cli.py::_resolve_backend_cdp`): resolution order is (1) `BU_CDP_WS`/`BU_CDP_URL` already in the subprocess env — wins outright, untouched, (2) `BROWSER_CDP_URL` env / `browser.cdp_url` config, (3) a configured cloud provider, (4) nothing → tries to launch its own browser (and, in this container, hung on a slow first-time daemon bootstrap rather than erroring cleanly). `entrypoint.sh` exports `BU_CDP_URL` — highest priority, and also the same var browser-use's separate `browser_harness` daemon reads for its own interactive-REPL code path, so it covers both.

## Gotcha: don't export `OPENAI_API_KEY`/`OPENAI_BASE_URL` process-wide

Tempting, since browser-use itself reads those for its own LLM calls — but Hermes deliberately **strips credentials** from the env it hands to the browser subprocess (`tools/browser_tool.py::_build_browser_env`, `inherit_credentials=False`), passing through only a fixed allowlist (Browserbase/`BROWSER_USE_API_KEY`/Firecrawl keys — no generic OpenAI/Anthropic key). Setting them at the Hermes *process* level instead doesn't reach the child scoped — it just leaks into Hermes' own top-level model resolution and breaks it: confirmed `HTTP 401: Missing Authentication header` on a plain "reply pong" prompt with no browser involved at all, purely from those two vars being present process-wide. Turns out no key is needed anyway — `browser_exec`'s navigate/read/eval actions worked end-to-end with just `BU_CDP_URL` set, no LLM key at all (it's executing literal script Hermes' own model already wrote, not doing its own separate page-reasoning call).

## Required `.env` vars

- `OPENCODE_GO_API_KEY` — [OpenCode Go](https://opencode.ai/docs/go/), $10/mo subscription. Required; the container refuses to start without it (both at `compose up` time and in `entrypoint.sh`). This is Hermes' own model key only — the browser-use CLI subprocess doesn't need or get one (see gotcha above).
- `AI_MODEL` — optional, any model id from `https://opencode.ai/zen/go/v1/models` (e.g. `kimi-k2.7-code`, `deepseek-v4-pro`). Defaults to `glm-5.3`. Sets `model: opencode-go/<id>` in `config.yaml` on every boot — Hermes has a built-in `opencode-go` provider preset, no `base_url` needed.

## First-boot checklist

- `podman compose logs -f hermes` starts cleanly and the container doesn't restart-loop. ✓ verified
- `hermes -z "Use the browser tool to navigate to https://example.com and tell me the exact page title."` completes and gives a real answer (`🐴 Example Domain`). ✓ verified end-to-end
- The *first* browser call after a fresh container start may take noticeably longer than later ones — `browser_harness`'s daemon bootstraps its own `uv`-managed venv on first use and caches it after.
- The dashboard on port 9119 has no auth of its own documented — same trust model as `stirling-pdf`/`jellyfin` (anyone reachable on the tailnet can use it). Check whether Hermes has grown an auth option worth turning on, given this agent can take real actions on the web.
