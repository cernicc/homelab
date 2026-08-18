#!/bin/sh
# Regenerates config.yaml's mcp_servers block and model key on every container
# start, wiring in OPENCODE_GO_API_KEY so nothing gets committed to git.
#
# This means config.yaml on the hermes-data volume is NOT a place for manual/
# persistent edits -- it gets overwritten on every restart. Add more MCP servers
# or change defaults by editing this script.
set -eu

if [ -z "${OPENCODE_GO_API_KEY:-}" ]; then
  echo "ai: OPENCODE_GO_API_KEY is not set -- refusing to start (see stacks/ai/README.md)" >&2
  exit 1
fi

# Both the custom MCP server below and Hermes' own native browser tool (see
# stacks/ai/README.md's "known limitation") attach over CDP rather than launching
# their own Chromium. We launch a real headless Chromium ourselves and point both
# at it, rather than depending on Browser Use Cloud (the docs' default suggestion
# for headless machines).
# Deliberately NOT on the /opt/data volume: a profile dir that survives container
# restarts keeps its SingletonLock file around too (Chrome can't clean it up on a
# hard SIGKILL), and every subsequent launch then fails immediately with "profile
# appears to be in use by another Chromium process" -- crash-looping forever with no
# error surfaced anywhere except /opt/data/chromium.log. /tmp is container-local and
# guaranteed fresh on every start, so there's never a stale lock to hit. Cost: no
# persistent cookies/login state across restarts -- acceptable for now.
CHROMIUM_CDP_PORT=9222
CHROMIUM_PROFILE_DIR=/tmp/chromium-profile
mkdir -p "$CHROMIUM_PROFILE_DIR"

chromium \
  --headless=new \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --remote-debugging-port="$CHROMIUM_CDP_PORT" \
  --remote-debugging-address=127.0.0.1 \
  --remote-allow-origins=* \
  --user-data-dir="$CHROMIUM_PROFILE_DIR" \
  >/opt/data/chromium.log 2>&1 &

# Wait (up to ~30s) for Chromium's CDP endpoint to come up before starting Hermes.
python3 -c "
import urllib.request, time
for _ in range(30):
    try:
        urllib.request.urlopen('http://127.0.0.1:${CHROMIUM_CDP_PORT}/json/version', timeout=1)
        break
    except Exception:
        time.sleep(1)
"

# browser-use's MCP server (browser_use/mcp/server.py) does NOT read BU_CDP_URL --
# it builds its BrowserProfile from ~/.config/browseruse/config.json, in a
# "DB-style" schema (browser_profile/llm/agent dicts keyed by id, one entry flagged
# "default": true, extra fields like cdp_url allowed through) -- confirmed by
# reading browser_use/config.py directly. Without this file, the MCP server tries
# to launch its own separate browser, reliably hanging ~30s per tool call before
# a BrowserStartEvent timeout.
mkdir -p /opt/data/.config/browseruse
cat > /opt/data/.config/browseruse/config.json <<EOF
{
  "browser_profile": {
    "browser-use-mcp-default": {
      "id": "browser-use-mcp-default",
      "default": true,
      "cdp_url": "http://127.0.0.1:${CHROMIUM_CDP_PORT}"
    }
  },
  "llm": {},
  "agent": {}
}
EOF

mkdir -p /opt/data
cat > /opt/data/config.yaml <<EOF
# OPENCODE_GO_API_KEY alone makes \`opencode-go\` an authenticated provider (Hermes
# has a built-in preset for it, no base_url needed); the model id still has to be
# picked explicitly. Override by setting AI_MODEL to another id from
# https://opencode.ai/zen/go/v1/models (e.g. kimi-k2.7-code, deepseek-v4-pro).
model: "opencode-go/${AI_MODEL:-glm-5.3}"

mcp_servers:
  browser-use:
    command: "/opt/browser-use-venv/bin/browser-use"
    args: ["--mcp"]
    env:
      # browser-use's own LLM calls (page reasoning) go through OpenAI-SDK-compatible
      # env vars. OpenCode Go exposes an OpenAI-compatible /v1/chat/completions at
      # https://opencode.ai/zen/go/v1 (see https://opencode.ai/docs/go/). Not a
      # documented integration on either project's side, but confirmed working for
      # browser_navigate/browser_get_html against the raw MCP protocol (~0.4s).
      OPENAI_API_KEY: "${OPENCODE_GO_API_KEY}"
      OPENAI_BASE_URL: "https://opencode.ai/zen/go/v1"
    # Chromium is launched once per container start (above), not per MCP-server
    # lifecycle, so these only recycle the browser-use subprocess itself, not the
    # underlying browser -- verify that's an acceptable tradeoff in practice.
    idle_timeout_seconds: 900
    max_lifetime_seconds: 86400
EOF

# Also read by Hermes' own native browser tool (tools/browser_use_cli.py --
# _resolve_backend_cdp checks this before its config-based browser.cdp_url
# override) and by browser-use's separate browser_harness daemon. Doesn't fix the
# known limitation below (that native tool's own local-Chrome detection doesn't
# reliably honor it), but costs nothing to set and helps if that ever gets sorted.
export BU_CDP_URL="http://127.0.0.1:${CHROMIUM_CDP_PORT}"

exec hermes gateway run
