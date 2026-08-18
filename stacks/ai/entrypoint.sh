#!/bin/sh
# Regenerates the mcp_servers section of config.yaml on every container start, wiring
# in OPENCODE_GO_API_KEY from the container environment so it never has to be
# committed to git.
#
# This means config.yaml on the hermes-data volume is NOT a place for manual/persistent
# edits -- it gets overwritten on every restart. Add more MCP servers by editing this
# script, not by running `hermes mcp add` by hand on the running container.
set -eu

if [ -z "${OPENCODE_GO_API_KEY:-}" ]; then
  echo "ai: OPENCODE_GO_API_KEY is not set -- refusing to start (see stacks/ai/README.md)" >&2
  exit 1
fi

# browser-use no longer launches/manages its own Chromium (no playwright/patchright
# dependency any more -- see Dockerfile). It expects an existing browser reachable
# over CDP via BU_CDP_URL. We launch our own headless Chromium here and point it at
# that, rather than depending on Browser Use Cloud.
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

# Wait (up to ~30s) for Chromium's CDP endpoint to come up before starting Hermes,
# since browser-use will try to attach to it as soon as its first tool call runs.
python3 -c "
import urllib.request, time
for _ in range(30):
    try:
        urllib.request.urlopen('http://127.0.0.1:${CHROMIUM_CDP_PORT}/json/version', timeout=1)
        break
    except Exception:
        time.sleep(1)
"

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
      # documented integration on either project's side -- verify on first boot.
      OPENAI_API_KEY: "${OPENCODE_GO_API_KEY}"
      OPENAI_BASE_URL: "https://opencode.ai/zen/go/v1"
      # Points browser-use at the Chromium launched above instead of Browser Use
      # Cloud (the docs' default recommendation for headless machines).
      BU_CDP_URL: "http://127.0.0.1:${CHROMIUM_CDP_PORT}"
    # Chromium is launched once per container start (above), not per MCP-server
    # lifecycle, so these only recycle the browser-use subprocess itself, not the
    # underlying browser -- verify that's an acceptable tradeoff in practice.
    idle_timeout_seconds: 900
    max_lifetime_seconds: 86400
EOF

exec hermes gateway run
