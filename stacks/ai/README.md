# ai

[Hermes Agent](https://hermes-agent.nousresearch.com/) — self-improving AI agent from Nous Research — using its [native browser tool](https://hermes-agent.nousresearch.com/docs/user-guide/features/browser) (driven by [browser-use](https://github.com/browser-use/browser-use)) for web browsing/automation, with [nesquena/hermes-webui](https://github.com/nesquena/hermes-webui) (a third-party web UI, reading the agent's state directly rather than being a separate agent of its own) as the front end fronted by Traefik at `ai.${DOMAIN_NAME}`. Single container/single service — see the `hermes-webui` section below for why.

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

## hermes-webui: merged into this same container, not run alongside it

[nesquena/hermes-webui](https://github.com/nesquena/hermes-webui) is a separate, third-party project — not Nous Research's own dashboard. It doesn't run its own agent; it reads the Hermes agent's state (config, sessions, skills, memory) directly, "in-process" as its own docs put it — it imports the agent's own Python modules rather than only talking to it over HTTP.

**First attempt was a second container sharing the `hermes-data` volume**, matching upstream's own two/three-container compose examples. That hit a hard wall: rootless Podman gives every container its own user namespace, so `hermes-webui`'s startup chown fixer — which aligns its files to the shared volume's owning uid — couldn't touch files the `hermes` container had written, even though both containers agreed the files were "owned by uid 10000" from their own numeric point of view. Reproduced directly, isolated from any of our own compose config: `podman run --rm ghcr.io/nesquena/hermes-webui:latest sh -c 'chown 10000:10000 <file-already-that-uid>'` → `Permission denied`. Not an app bug — it's the multi-container reference setup's own documented failure mode for exactly this: *"You're on Podman 3.4 or older without keep-id namespace support → see hermes-suite for an all-in-one image"*.

**Fixed by merging `hermes-webui` into this same image/container** instead — one user namespace, no cross-container chown at all. Reading `hermeswebui_init.bash` (its startup script) directly showed this needs no special path aliasing: it already probes `$HERMES_HOME` and `/opt/hermes` directly as fallback locations (for its own state-dir auto-detection and for finding the agent's source respectively) — once it's in this container, it just finds things on its own.

- `Dockerfile` pulls `hermes-webui`'s app code (`/apptoo`), its startup script (`/hermeswebui_init.bash`), and its compiled SQLite (their base image builds a newer one from source — the Debian package has a known WAL-corruption bug their Python code checks the linked version against) from `ghcr.io/nesquena/hermes-webui:latest` as a build stage, rather than reimplementing that build by hand. `uv` is already on `PATH` from the base Hermes image, so no need to install its copy too.
- `entrypoint.sh` launches `/hermeswebui_init.bash` as a background process (not s6-supervised, unlike the gateway — a crash here doesn't take the agent down, just the web UI) with `WANTED_UID=WANTED_GID=10000`, matching this image's real `hermes` user. Its own `usermod`/`chown` alignment step succeeds now — real root, same namespace, not a cross-container boundary.
- `HERMES_API_URL` points at `http://127.0.0.1:8642` (loopback, both processes in the same container) rather than a service-name DNS lookup — and `API_SERVER_HOST` only needs to bind `127.0.0.1` now too, tighter than the multi-container version's `0.0.0.0`.
- Its Python dependencies (including an editable install of the agent's own `pyproject.toml`) install into `/app/venv` at **first container start**, not at build time — matching upstream's own runtime-install design. Not persisted across restarts (no volume for `/app`), so expect a slower first request after every real redeploy while it reinstalls. Worth revisiting if that turns out to matter more than it does right now.

## Gotcha: this is the only stack in the repo with a `Dockerfile`, and `homelab-sync` rebuilds unconditionally

`~/.local/bin/homelab-sync` (the script the 5-minute `homelab-sync.timer` runs) ends with `systemctl --user reload docker-compose@*.service` — **unconditionally, every cycle, for every enabled stack**, no diffing. The shared unit's `ExecReload` is `podman compose up -d --build`. For every other stack (fixed upstream `image:` tags, no `build:` key) that's a genuine no-op. `ai` is the only stack that actually builds something, so it's the only one where that matters:

- An unpinned `pip install 'browser-use[cli]'` means every one of those 5-minute rebuilds could silently pick up a newer release mid-session — fixed by pinning the version (see `Dockerfile`).
- (Historical, while the built-in dashboard was still exposed here.) Even fully cached/unchanged, a dashboard login got invalidated on every container recreate because the auth signing key was regenerated fresh each time — fixed by persisting a secret to the `/opt/data` volume instead of leaving it random-per-process. `hermes-webui`'s own session handling hasn't been stress-tested against this same restart cadence yet — worth checking if logins there turn out to be similarly short-lived.

None of this stops a *real* redeploy (an actual code change) from recreating the container and dropping active sessions — that's inherent to `--build` always being in the loop for this stack. It does mean routine, no-op sync cycles stop being disruptive.

## Required `.env` vars

- `OPENCODE_GO_API_KEY` — [OpenCode Go](https://opencode.ai/docs/go/), $10/mo subscription. Required; the container refuses to start without it. This is Hermes' own model key — the browser tool doesn't need or get one (Hermes strips credentials from that subprocess's env by design; the navigate/read/click actions used here don't need their own LLM call anyway).
- `AI_MODEL` — optional, any model id from `https://opencode.ai/zen/go/v1/models` (e.g. `kimi-k2.7-code`, `deepseek-v4-pro`). Defaults to `glm-5.3`.
- `API_SERVER_KEY` — required; any string 16+ characters. Enables the gateway API listener and authenticates `hermes-webui` against it (both live in this same container) — not meant to be memorized/typed, just needs a value.
- `HERMES_WEBUI_PASSWORD` — required; login at `ai.${DOMAIN_NAME}` (same pattern as `TRANSMISSION_USER`/`TRANSMISSION_PASS` in the `media` stack, minus the username — password-only, no username field).

## Two minor, harmless quirks noticed while verifying

- `browser_harness` silently prepends a 🐴 emoji to tab titles as its own internal tab-marker convention (see its `daemon.py`/`run.py` comments) — the model sometimes reports it as part of the "real" page title, since from its view that's what the tool returned. Cosmetic only, not a bug in this stack.
- The model occasionally double-checks a browsing result with a few extra tool calls (e.g. re-fetching to confirm a title) before answering — correct behavior, just slower wall-clock than a single round-trip. Give test prompts a couple minutes, not a couple of seconds.

## First-boot checklist

- `podman compose logs -f hermes` starts cleanly and the container doesn't restart-loop. ✓ verified
- `hermes -z "Use the browser tool to navigate to https://example.com and tell me the exact page title."` completes and gives a real, correct answer. ✓ verified repeatedly (4/4 test runs, including a fresh container from a clean deploy)
- `podman exec ai-hermes-1 cat /tmp/hermes-webui.log` shows `agent dir: /opt/hermes [ok]`, `config file: /opt/data/config.yaml (found)`, and `Hermes Web UI listening on http://0.0.0.0:8787`. ✓ verified
- `podman exec ai-hermes-1 curl -s http://127.0.0.1:8642/health` (or equivalent) returns `{"status": "ok", ...}` — confirms the gateway API `hermes-webui`'s Tasks/System status depends on is actually up. ✓ verified
- `ai.${DOMAIN_NAME}` redirects to `/login` with a 200, not a 502. ✓ verified
- Not yet done end-to-end through a real browser: logging in with `HERMES_WEBUI_PASSWORD` and sending a chat that uses the browser tool through the UI itself, rather than `hermes -z`. Worth a manual pass.
