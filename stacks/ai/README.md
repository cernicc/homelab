# ai

[Hermes Agent](https://hermes-agent.nousresearch.com/) — self-improving AI agent from Nous Research — using its [native browser tool](https://hermes-agent.nousresearch.com/docs/user-guide/features/browser) (driven by [browser-use](https://github.com/browser-use/browser-use)) for web browsing/automation, fronted by Traefik at `ai.${DOMAIN_NAME}` (Hermes' dashboard, port 9119).

## Architecture: Hermes' native browser tool, pointed at a self-launched Chromium

Hermes ships its own integration with browser-use: a `browser_exec` tool it drives itself, auto-enabled whenever a `browser-use` binary is discoverable. Two earlier versions of this stack tried wiring browser-use in by hand instead — first as a custom MCP server, then chasing an undocumented env var (`BU_CDP_URL`) to point the native tool at a local Chromium — both unnecessarily complicated and, in the `BU_CDP_URL` case, unreliable. The actual fix, once found in [Hermes' own browser docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/browser): set `browser.cdp_url` in `config.yaml` to the browser's **websocket** devtools URL (`ws://host:port/devtools/browser/<id>`, from Chromium's own `/json/version` response) — not a bare `http://host:port`, and not the `BU_CDP_URL` env var (a different, lower-level mechanism read by browser-use's own `browser_harness` daemon, not by Hermes' native tool). Verified end-to-end, repeatedly: `hermes -z` with a real browsing prompt correctly drives the self-launched Chromium and returns accurate page content.

- **`Dockerfile`** installs a real Chromium via apt, and a pinned `browser-use[cli]` into a dedicated `uv` venv added to `PATH` — so Hermes' own CLI-discovery (`shutil.which("browser-use")`) finds this offline copy instead of falling back to a live `uvx` fetch from PyPI on every tool call.
- **`entrypoint.sh`** launches that Chromium headless, queries its actual websocket devtools URL, and regenerates `config.yaml`'s `model` and `browser.cdp_url` keys from that + `OPENCODE_GO_API_KEY` on every start (so nothing has to be committed to git — **`config.yaml` is not a place for manual/persistent edits**).

## Gotcha: `uv venv` must NOT use its own managed Python interpreter

`uv venv` defaults to downloading its own managed CPython build, which lands under `/root/.local/share/uv/python/...` (owned by root, mode `700`). Hermes runs as an unprivileged `hermes` user (uid 10000) that can't traverse into `/root` at all — every exec of a script shebanged at such a python silently fails with `Permission denied`. Confirmed by reproducing with `su hermes -s /bin/sh -c '.../browser-use --help'` → `Permission denied`.

Fix: `uv venv --python /usr/bin/python3 /opt/browser-use-venv` — pins it to the base image's own system interpreter (normal `/usr` permissions, world-executable).

## Gotcha: Chromium's profile dir must be ephemeral

Chromium's `--user-data-dir` is deliberately `/tmp/chromium-profile`, not on the `/opt/data` volume: a profile dir that survives a hard container restart keeps its `SingletonLock` file too (Chrome can't clean it up on SIGKILL), and every subsequent launch then fails instantly with *"profile appears to be in use by another Chromium process"* — a silent crash-loop, visible only in `/opt/data/chromium.log`. `/tmp` is guaranteed fresh every start. Cost: no persistent cookies/login state across restarts.

## Gotcha: `browser.cdp_url` wants a websocket URL, not `BU_CDP_URL`

This is the one that actually mattered. `BU_CDP_URL` (a plain `http://host:port`) is read by `browser_harness` — the daemon behind browser-use's own interactive REPL, a separate code path from Hermes' native tool — and setting it did **not** reliably get Hermes' `browser_exec` to attach to our Chromium (hung, or failed with `fatal: chrome-not-running`, across many repeated tests). [Hermes' own docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/browser) are explicit that the supported config is `browser.cdp_url` in `config.yaml`, set to the actual `ws://.../devtools/browser/<id>` URL from Chromium's `/json/version` response — `entrypoint.sh` fetches that dynamically (the UUID in it changes every launch) and writes it in. Fixed the problem completely on the first try once set correctly.

## Required `.env` vars

- `OPENCODE_GO_API_KEY` — [OpenCode Go](https://opencode.ai/docs/go/), $10/mo subscription. Required; the container refuses to start without it. This is Hermes' own model key — the browser tool doesn't need or get one (Hermes strips credentials from that subprocess's env by design; the navigate/read/click actions used here don't need their own LLM call anyway).
- `AI_MODEL` — optional, any model id from `https://opencode.ai/zen/go/v1/models` (e.g. `kimi-k2.7-code`, `deepseek-v4-pro`). Defaults to `glm-5.3`.

## Two minor, harmless quirks noticed while verifying

- `browser_harness` silently prepends a 🐴 emoji to tab titles as its own internal tab-marker convention (see its `daemon.py`/`run.py` comments) — the model sometimes reports it as part of the "real" page title, since from its view that's what the tool returned. Cosmetic only, not a bug in this stack.
- The model occasionally double-checks a browsing result with a few extra tool calls (e.g. re-fetching to confirm a title) before answering — correct behavior, just slower wall-clock than a single round-trip. Give test prompts a couple minutes, not a couple of seconds.

## First-boot checklist

- `podman compose logs -f hermes` starts cleanly and the container doesn't restart-loop. ✓ verified
- `hermes -z "Use the browser tool to navigate to https://example.com and tell me the exact page title."` completes and gives a real, correct answer. ✓ verified repeatedly (4/4 test runs, including a fresh container from a clean deploy)
- The dashboard on port 9119 has no auth of its own documented — same trust model as `stirling-pdf`/`jellyfin` (anyone reachable on the tailnet can use it). Check whether Hermes has grown an auth option worth turning on, given this agent can take real actions on the web.
