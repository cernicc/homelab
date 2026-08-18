#!/bin/sh
# Regenerates config.yaml's `model` key on every container start from
# OPENCODE_GO_API_KEY, so nothing browser/model-related has to be committed to git.
#
# This means config.yaml on the hermes-data volume is NOT a place for manual/
# persistent edits -- it gets overwritten on every restart. Change defaults here.
set -eu

if [ -z "${OPENCODE_GO_API_KEY:-}" ]; then
  echo "ai: OPENCODE_GO_API_KEY is not set -- refusing to start (see stacks/ai/README.md)" >&2
  exit 1
fi

# Hermes' native browser tool (browser_exec, driven by the browser-use CLI on PATH --
# see Dockerfile) attaches over CDP rather than launching/managing its own Chromium.
# We launch a real headless Chromium ourselves and point Hermes at it, rather than
# depending on Browser Use Cloud (the docs' default suggestion for headless machines).
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

mkdir -p /opt/data
cat > /opt/data/config.yaml <<EOF
# OPENCODE_GO_API_KEY alone makes \`opencode-go\` an authenticated provider (Hermes
# has a built-in preset for it, no base_url needed); the model id still has to be
# picked explicitly. Override by setting AI_MODEL to another id from
# https://opencode.ai/zen/go/v1/models (e.g. kimi-k2.7-code, deepseek-v4-pro).
model: "opencode-go/${AI_MODEL:-glm-5.3}"

# Explicit rather than relying on auto-detection (unset "" enables Browser Use mode
# whenever the CLI is discoverable, which it now always is -- see Dockerfile PATH).
# "off" would fall back to Hermes' OWN built-in browser_* tools instead, which is
# NOT what this stack is for.
browser:
  backend: "browser-use"
EOF

# Read by tools/browser_use_cli.py::_resolve_backend_cdp (checked before Hermes'
# config-based browser.cdp_url override) -- points Hermes' browser_exec tool (and
# thus the browser-use CLI it spawns per call) at the Chromium launched above,
# instead of it trying to launch/manage its own. Also the same env var browser-use's
# own separate browser_harness daemon reads, so this covers both code paths.
#
# Deliberately NOT exporting OPENAI_API_KEY/OPENAI_BASE_URL globally here: Hermes
# scrubs credentials from the env it hands to this subprocess by design (see
# tools/browser_tool.py::_build_browser_env, inherit_credentials=False) and only
# passes through a fixed allowlist (Browserbase/BROWSER_USE_API_KEY/Firecrawl keys)
# -- there's no supported way to hand it a scoped LLM key for local-Chrome mode, and
# setting OPENAI_API_KEY/OPENAI_BASE_URL at the Hermes process level instead of
# scoped to the child broke Hermes' OWN top-level opencode-go calls too (confirmed:
# "HTTP 401: Missing Authentication header" on a plain "reply pong" prompt with no
# browser involved at all, purely from those two vars being set process-wide).
# Turns out no key is needed anyway for browser_exec's navigate/read/eval actions --
# confirmed end-to-end with BU_CDP_URL alone.
export BU_CDP_URL="http://127.0.0.1:${CHROMIUM_CDP_PORT}"

exec hermes gateway run
