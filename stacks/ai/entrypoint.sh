#!/bin/sh
# Regenerates config.yaml's `model` and `browser.cdp_url` keys on every container
# start from OPENCODE_GO_API_KEY and the Chromium launched below, so nothing has to
# be committed to git.
#
# This means config.yaml on the hermes-data volume is NOT a place for manual/
# persistent edits -- it gets overwritten on every restart. Change defaults here.
set -eu

if [ -z "${OPENCODE_GO_API_KEY:-}" ]; then
  echo "ai: OPENCODE_GO_API_KEY is not set -- refusing to start (see stacks/ai/README.md)" >&2
  exit 1
fi

# Hermes' native browser tool (browser_exec, driven by the browser-use CLI on PATH --
# see Dockerfile) attaches to an existing browser over CDP rather than launching its
# own. We launch a real headless Chromium ourselves and point Hermes at it, rather
# than depending on Browser Use Cloud (the docs' default suggestion for headless
# machines: https://hermes-agent.nousresearch.com/docs/user-guide/features/browser).
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

# Wait (up to ~30s) for Chromium's CDP endpoint to come up, and capture its
# webSocketDebuggerUrl -- Hermes' browser.cdp_url config key documents wanting the
# actual ws:// devtools URL, not a bare http://host:port (the docs page is explicit
# about this: https://hermes-agent.nousresearch.com/docs/user-guide/features/browser
# -- "Set browser.cdp_url ... ws://your-host:port/devtools/browser/..."). An earlier
# version of this stack used BU_CDP_URL (an http:// URL) instead, which is a
# different, lower-level env var read by browser_harness's own daemon rather than
# this documented config key, and did not reliably work.
CHROMIUM_WS_URL=$(python3 -c "
import urllib.request, json, time
for _ in range(30):
    try:
        data = json.load(urllib.request.urlopen('http://127.0.0.1:${CHROMIUM_CDP_PORT}/json/version', timeout=1))
        print(data['webSocketDebuggerUrl'])
        break
    except Exception:
        time.sleep(1)
")

# Hermes' own built-in dashboard is NOT enabled here (no HERMES_DASHBOARD env var)
# -- hermes-webui (a separate service, see docker-compose.yml) is the one exposed
# via Traefik instead, so there's no second auth surface / password to manage on
# this container. `hermes gateway run` still goes through s6 supervision below for
# auto-restart-on-crash and to start the gateway API server (API_SERVER_ENABLED,
# set via docker-compose.yml) that hermes-webui's health checks talk to.
mkdir -p /opt/data
cat > /opt/data/config.yaml <<EOF
# OPENCODE_GO_API_KEY alone makes \`opencode-go\` an authenticated provider (Hermes
# has a built-in preset for it, no base_url needed); the model id still has to be
# picked explicitly. Override by setting AI_MODEL to another id from
# https://opencode.ai/zen/go/v1/models (e.g. kimi-k2.7-code, deepseek-v4-pro).
model: "opencode-go/${AI_MODEL:-glm-5.3}"

browser:
  cdp_url: "${CHROMIUM_WS_URL}"

# We never configured OpenRouter or Nous Portal, so Hermes' "auxiliary" lane
# (small background tasks, separate from the main chat model) was failing every
# call trying those as fallbacks and logging "payment / credit error" noise.
# free_only keeps it from trying paid OpenRouter models it has no key for.
auxiliary:
  free_only: true
EOF

# NOT `exec hermes gateway run` directly: the base image's real ENTRYPOINT is
# /opt/hermes/docker/entrypoint-dispatch.sh, which hands off to s6-overlay's
# /init -- the thing that gives the gateway auto-restart-on-crash supervision
# (and would start a supervised dashboard too, if HERMES_DASHBOARD were set).
# Calling `hermes gateway run` straight from our own entrypoint bypasses all of
# that (confirmed the hard way: it's how we ended up with a working gateway but
# a 502 at Traefik, back when this exposed the built-in dashboard). We're
# already PID 1 here, so this exec correctly routes into the real /init path
# (see entrypoint-dispatch.sh's own `[ "$$" -eq 1 ]` check) instead of its
# non-PID-1 fallback.
exec /opt/hermes/docker/entrypoint-dispatch.sh gateway run
