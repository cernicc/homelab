# ai

[Hermes Agent](https://hermes-agent.nousresearch.com/) — self-improving AI agent from Nous Research — with [browser-use](https://github.com/browser-use/browser-use) as a custom MCP tool for web browsing/automation, fronted by Traefik at `ai.${DOMAIN_NAME}` (Hermes' dashboard, port 9119).

## ⚠️ Known limitation: Hermes' own native browser tool wins the model's attention

Hermes ships its **own** integration with this exact same browser-use CLI: a `browser_exec` tool (toolset `browser`) it drives itself, auto-enabled whenever a `browser-use` binary is discoverable — which it now always is, since this image puts one on `PATH` for the MCP server below. With both available, the model consistently reaches for the native `browser_exec` instead of the MCP server's `browser_navigate`/etc, and that native path has **not** been made reliable here: it hung or failed (`fatal: chrome-not-running`) in every `hermes -z` end-to-end test, even with `BU_CDP_URL` set and `browser.backend: "browser-use"` forced — its own local-Chrome detection (`browser_harness`'s `DevToolsActivePort` file check) looks in a small fixed list of default profile directories that our custom `--user-data-dir` was never going to match, and the CDP-override path that's supposed to bypass that check didn't reliably kick in.

Tried and confirmed **not sufficient** to suppress it: disabling the `browser` toolset, disabling `computer_use` (which also bundles `browser_exec`), and forcing `agent.coding_context: "off"` (Hermes' auto-selected "coding" posture, which pulls browser tools in regardless of toolset config) — in every combination tested, `hermes -z` with a browsing prompt still reached for `browser_exec`. There's some other selection mechanism in play that hasn't been found yet.

**What *is* proven working**: the MCP server itself, tested directly against the raw MCP protocol (bypassing Hermes' tool selection) — `browser_navigate` and `browser_get_html` both resolve correctly in well under a second, real page content included. So the MCP server (`entrypoint.sh`, `mcp_servers.browser-use`) is correctly configured and functional; what's unresolved is getting Hermes' own model to actually pick it over its native tool. Next step for whoever picks this up: find what's overriding toolset selection for `-z`/chat sessions (grep `hermes_cli`/`agent` for wherever tool availability actually gets resolved at request time, since `platform_toolsets.cli` in `config.yaml` isn't the whole story), or find the flag that fully disables Hermes' native browser capability rather than just its toolset visibility.

## Why one container

browser-use's MCP server only speaks stdio — there's no HTTP/SSE transport in the open-source package, and neither project documents running it as a separate networked service (browser-use's own answer to "remote/production" is their paid Cloud API, not self-hosting). So it's installed straight into the Hermes image (`Dockerfile`) and spawned as a local stdio subprocess (`config.yaml`'s `mcp_servers`), not run as a sidecar.

`entrypoint.sh` regenerates `/opt/data/config.yaml` and `/opt/data/.config/browseruse/config.json` on every container start from `OPENCODE_GO_API_KEY`, so the secret never gets committed to git. **This means neither file is a place for manual/persistent edits** — both are overwritten on every restart. To change defaults, edit `entrypoint.sh`.

## Gotcha: the venv's Python must NOT be `uv`'s managed interpreter

`uv venv` defaults to downloading its own managed CPython build, which lands under `/root/.local/share/uv/python/...` (owned by root, mode `700`). Hermes runs as an unprivileged `hermes` user (uid 10000) that can't traverse into `/root` at all. Every exec of a script shebanged at such a python silently fails with `Permission denied`, and Hermes' MCP client just reports it as `Connection closed` after burning its retry budget — no useful error surfaces anywhere in `podman logs`. Confirmed by reproducing with `su hermes -s /bin/sh -c '.../browser-use --help'` → `Permission denied`.

Fix: `uv venv --python /usr/bin/python3 /opt/browser-use-venv` — pins it to the base image's own system interpreter (normal `/usr` permissions, world-executable).

## Gotcha: Chromium's profile dir must be ephemeral

Chromium's `--user-data-dir` is deliberately `/tmp/chromium-profile`, not on the `/opt/data` volume: a profile dir that survives a hard container restart keeps its `SingletonLock` file too (Chrome can't clean it up on SIGKILL), and every subsequent launch then fails instantly with *"profile appears to be in use by another Chromium process"* — a silent crash-loop, visible only in `/opt/data/chromium.log`. `/tmp` is guaranteed fresh every start. Cost: no persistent cookies/login state across restarts.

## Gotcha: `BU_CDP_URL` is not read by the MCP server — needs `config.json`

`BU_CDP_URL` only exists for `browser_harness` (the daemon behind Hermes' native tool and the interactive `browser-use <<PY ... PY` REPL) — a completely separate code path from the MCP server (`browser_use/mcp/server.py`), which never reads it. Every MCP `tools/call` for a browser action hung for exactly 30s then failed with `BrowserStartEvent timed out`, because with no `cdp_url` on its `BrowserProfile` the MCP server tries to launch and manage its *own* separate browser instead of attaching to ours.

Traced by reading `browser_use/config.py` directly: the MCP server builds its browser profile from `~/.config/browseruse/config.json`, in a "DB-style" schema — `browser_profile`/`llm`/`agent` dicts keyed by an id, one entry per section flagged `"default": true`, extra fields (like `cdp_url`) allowed through. `entrypoint.sh` writes this file. Verified directly against the raw MCP protocol: `browser_navigate` and `browser_get_html` both work in well under a second once this file is in place.

## Required `.env` vars

- `OPENCODE_GO_API_KEY` — [OpenCode Go](https://opencode.ai/docs/go/), $10/mo subscription. Required; the container refuses to start without it. Used for both Hermes' own model and browser-use's page-reasoning calls.
- `AI_MODEL` — optional, any model id from `https://opencode.ai/zen/go/v1/models` (e.g. `kimi-k2.7-code`, `deepseek-v4-pro`). Defaults to `glm-5.3`.

## First-boot checklist

- `podman compose logs -f hermes` starts cleanly and the container doesn't restart-loop. ✓ verified
- `hermes mcp list` inside the container shows `browser-use` connected (not parked). If it says `Connection closed`, see the venv-permissions gotcha above.
- Raw MCP protocol test (bypasses tool selection, confirms the server itself works): initialize → `tools/call browser_navigate` should resolve in well under a second, not hang ~30s. ✓ verified
- `hermes -z "Use the browser tool to navigate to https://example.com and tell me the exact page title."` — **currently unreliable**, see the known limitation above. Don't treat this as a smoke test until that's resolved.
- The dashboard on port 9119 has no auth of its own documented — same trust model as `stirling-pdf`/`jellyfin` (anyone reachable on the tailnet can use it). Check whether Hermes has grown an auth option worth turning on, given this agent can take real actions on the web.
