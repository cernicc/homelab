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

mkdir -p /opt/data
cat > /opt/data/config.yaml <<EOF
mcp_servers:
  browser-use:
    command: "/opt/browser-use-venv/bin/browser-use"
    args: ["--mcp"]
    # browser-use's own LLM calls (page reasoning) go through langchain-openai's
    # ChatOpenAI, which resolves OPENAI_API_KEY/OPENAI_BASE_URL the way the OpenAI SDK
    # always does. OpenCode Go exposes an OpenAI-compatible /v1/chat/completions at
    # https://opencode.ai/zen/go/v1 (see https://opencode.ai/docs/go/), so that's
    # what's wired in here. This isn't a documented integration on either project's
    # side (Hermes' own OpenCode support is only for Hermes' own model, not for MCP
    # subprocess env) -- verify it actually works on first boot (see README).
    env:
      OPENAI_API_KEY: "${OPENCODE_GO_API_KEY}"
      OPENAI_BASE_URL: "https://opencode.ai/zen/go/v1"
    # Chromium stays resident in memory after browser-use's first tool call; recycle
    # the process periodically instead of letting it grow unbounded.
    idle_timeout_seconds: 900
    max_lifetime_seconds: 86400
EOF

# Hermes' own model provider (separate from browser-use above). OPENCODE_GO_API_KEY
# alone is enough to make `opencode-go` show up as an authenticated provider -- no
# base_url needed, Hermes has a built-in preset for it. Pick the actual model via
# `hermes model` (dashboard or CLI) on first boot; not set declaratively here since
# the exact model id under opencode-go isn't pinned down.

exec hermes gateway run
