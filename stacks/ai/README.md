# ai

[Hermes Agent](https://hermes-agent.nousresearch.com/) — self-improving AI agent from Nous Research — using its [native browser tool](https://hermes-agent.nousresearch.com/docs/user-guide/features/browser) (driven by [browser-use](https://github.com/browser-use/browser-use)) for web browsing/automation. Two services: `hermes` runs the actual agent (no exposed UI of its own), `hermes-webui` ([nesquena/hermes-webui](https://github.com/nesquena/hermes-webui), a third-party web UI reading the agent's state directly) is what's fronted by Traefik at `ai.${DOMAIN_NAME}`.

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

## Gotcha: our own `ENTRYPOINT` bypassed the base image's dashboard supervision

`ai.${DOMAIN_NAME}` returned a clean **502 Bad Gateway** — Traefik could reach the container, but nothing was listening on 9119 despite `HERMES_DASHBOARD=1`. The base image's real `ENTRYPOINT` is `/opt/hermes/docker/entrypoint-dispatch.sh`, which hands off to **s6-overlay's `/init`** — that's what actually starts the dashboard as a separately-supervised service (`hermes gateway run --help` says as much: *"gateway run is automatically redirected to the supervised s6 service... plus a supervised dashboard if HERMES_DASHBOARD is set"*). Our custom `Dockerfile` replaces `ENTRYPOINT` outright to run our own setup first, so `entrypoint.sh` calling `hermes gateway run` directly skipped all of that — the gateway itself started fine (visible in `podman logs`), just with no dashboard behind it. Confirmed via `podman inspect nousresearch/hermes-agent:latest` for the original entrypoint, and by reading `entrypoint-dispatch.sh`/`main-wrapper.sh` in the built image.

Fixed by ending `entrypoint.sh` with `exec /opt/hermes/docker/entrypoint-dispatch.sh gateway run` instead of `exec hermes gateway run` — our script is already PID 1 at that point, which routes it into the real `/init` supervision path (the dispatcher checks `[ "$$" -eq 1 ]`) instead of the non-PID-1 fallback, giving the gateway auto-restart-on-crash. Still needed even though `HERMES_DASHBOARD` itself is no longer set (see below) — the gateway API server (`API_SERVER_ENABLED`) that `hermes-webui` talks to lives in the same `hermes gateway run` process either way.

At the time this was written the built-in dashboard on port 9119 *was* what got exposed via Traefik — including a real requirement it surfaced (the dashboard hard-refuses to bind to anything but `127.0.0.1` without an auth provider configured, *"no unauthenticated public-bind option"*, by design). That's since been replaced by `hermes-webui` below, so `HERMES_DASHBOARD` isn't set at all any more — noted here in case that built-in dashboard route is ever wanted back.

## hermes-webui: a nicer UI, sharing the agent's state directly

[nesquena/hermes-webui](https://github.com/nesquena/hermes-webui) is a separate, third-party project — not Nous Research's own dashboard. It doesn't run its own agent; it reads the **same** Hermes state (config, sessions, skills, memory) as the `hermes` service by sharing the `hermes-data` volume, mounted at the path its image expects (`/home/hermeswebui/.hermes`). A few things that aren't obvious from its own docs/compose examples:

- **UID/GID must match the actual image, not the upstream example's default.** `hermes-webui`'s own compose examples default `WANTED_UID`/`WANTED_GID` to `1000`, matching a typical Docker default user — but *this* image's `hermes` user is uid/gid **`10000`** (confirmed directly: `podman exec ai-hermes-1 id hermes`). Get this wrong and files `hermes-webui` writes onto the shared volume become unreadable/unwritable by the `hermes` service. Set explicitly in `docker-compose.yml`, not left at the library default.
- **It needs a copy of the agent's own source+deps** (what upstream calls the `hermes-agent-src` volume) to build a matching Python environment for itself — it imports Hermes' own Python modules in-process rather than only talking to it over HTTP. `hermes-src` here is a named volume mounted at `/opt/hermes` in the `hermes` service (auto-populated from the image on first `up`, standard behavior for a fresh named volume over a non-empty image path) and read-only in `hermes-webui` at `/home/hermeswebui/.hermes/hermes-agent`. **This volume does NOT auto-refresh** if the `hermes` image is later rebuilt with a materially different Hermes version — stop the stack and `podman volume rm ai_hermes-src` to force a fresh copy if that ever matters.
- **The gateway API server** (`API_SERVER_ENABLED=true` on `hermes`, port 8642, internal-only — not Traefik-routed) is what `hermes-webui`'s Tasks/cron health check polls via `HERMES_API_URL=http://hermes:8642`, authenticated with the same `API_SERVER_KEY` both services share.
- Upstream's reference "three-container" compose runs a *second*, vanilla `nousresearch/hermes-agent` instance alongside `hermes-webui` and a separate dashboard container. Deliberately not used here — we already have one fully-configured agent (browser-use, Chromium, OpenCode Go) in the `hermes` service; running a second, uncustomized one would just fragment state and lack browser capability entirely.

## Gotcha: this is the only stack in the repo with a `Dockerfile`, and `homelab-sync` rebuilds unconditionally

`~/.local/bin/homelab-sync` (the script the 5-minute `homelab-sync.timer` runs) ends with `systemctl --user reload docker-compose@*.service` — **unconditionally, every cycle, for every enabled stack**, no diffing. The shared unit's `ExecReload` is `podman compose up -d --build`. For every other stack (fixed upstream `image:` tags, no `build:` key) that's a genuine no-op. `ai` is the only stack that actually builds something, so it's the only one where that matters:

- An unpinned `pip install 'browser-use[cli]'` means every one of those 5-minute rebuilds could silently pick up a newer release mid-session — fixed by pinning the version (see `Dockerfile`).
- (Historical, while the built-in dashboard was still exposed here.) Even fully cached/unchanged, a dashboard login got invalidated on every container recreate because the auth signing key was regenerated fresh each time — fixed by persisting a secret to the `/opt/data` volume instead of leaving it random-per-process. `hermes-webui`'s own session handling hasn't been stress-tested against this same restart cadence yet — worth checking if logins there turn out to be similarly short-lived.

None of this stops a *real* redeploy (an actual code change) from recreating the container and dropping active sessions — that's inherent to `--build` always being in the loop for this stack. It does mean routine, no-op sync cycles stop being disruptive.

## Required `.env` vars

- `OPENCODE_GO_API_KEY` — [OpenCode Go](https://opencode.ai/docs/go/), $10/mo subscription. Required; the container refuses to start without it. This is Hermes' own model key — the browser tool doesn't need or get one (Hermes strips credentials from that subprocess's env by design; the navigate/read/click actions used here don't need their own LLM call anyway).
- `AI_MODEL` — optional, any model id from `https://opencode.ai/zen/go/v1/models` (e.g. `kimi-k2.7-code`, `deepseek-v4-pro`). Defaults to `glm-5.3`.
- `API_SERVER_KEY` — required; any string 16+ characters. Shared between `hermes` (enables its gateway API listener) and `hermes-webui` (authenticates against it) — not meant to be memorized/typed, just needs to match on both sides.
- `HERMES_WEBUI_PASSWORD` — required; login for `hermes-webui` at `ai.${DOMAIN_NAME}` (same pattern as `TRANSMISSION_USER`/`TRANSMISSION_PASS` in the `media` stack, minus the username — `hermes-webui` is password-only, no username field).

## Two minor, harmless quirks noticed while verifying

- `browser_harness` silently prepends a 🐴 emoji to tab titles as its own internal tab-marker convention (see its `daemon.py`/`run.py` comments) — the model sometimes reports it as part of the "real" page title, since from its view that's what the tool returned. Cosmetic only, not a bug in this stack.
- The model occasionally double-checks a browsing result with a few extra tool calls (e.g. re-fetching to confirm a title) before answering — correct behavior, just slower wall-clock than a single round-trip. Give test prompts a couple minutes, not a couple of seconds.

## First-boot checklist

- `podman compose logs -f hermes` starts cleanly and the container doesn't restart-loop. ✓ verified
- `hermes -z "Use the browser tool to navigate to https://example.com and tell me the exact page title."` completes and gives a real, correct answer. ✓ verified repeatedly (4/4 test runs, including a fresh container from a clean deploy)
- `podman compose logs hermes-webui` shows it actually finding/using the `hermes-src` volume at startup rather than falling back to installing its own copy from PyPI — check this got seeded correctly on first `up`.
- `ai.${DOMAIN_NAME}` loads `hermes-webui` (not a 502) and prompts for the `HERMES_WEBUI_PASSWORD` login, and its Tasks/System gateway status shows reachable (confirms `API_SERVER_KEY` matches on both services and `HERMES_API_URL` resolves).
- A chat sent through `hermes-webui` can actually use the browser tool — same prompt as above, through the UI instead of `hermes -z`.
