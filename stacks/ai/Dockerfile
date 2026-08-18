# Hermes Agent (https://hermes-agent.nousresearch.com/) with browser-use
# (https://github.com/browser-use/browser-use) baked in as a local MCP tool.
#
# browser-use's MCP server only speaks stdio -- there is no HTTP/SSE transport in the
# open-source package (browser_use/mcp/server.py hardcodes mcp.server.stdio), and
# neither project documents running it as a separate networked service. Hermes' own
# docs are built around spawning stdio MCP servers as local subprocesses it owns
# (idle_timeout_seconds / max_lifetime_seconds recycling), so that's the pattern used
# here: browser-use lives in the same image/container as Hermes, on the same volume
# scope. Splitting it into its own container would mean losing that recycling and
# building an undocumented stdio<->HTTP bridge for no real benefit in a single-user
# homelab.
#
# browser-use no longer bundles/manages a Playwright-installed Chromium (confirmed:
# current pyproject.toml depends on cdp-use + browser-harness, not playwright/
# patchright). It now expects to attach to an existing browser over CDP -- via
# BU_CDP_URL/BU_CDP_WS, a Browser Use Cloud session, or an already-running local
# Chrome. The docs' own answer for a headless machine is their paid Cloud Browser
# service; to stay fully self-hosted, we install a real Chromium via apt and launch
# it ourselves (see entrypoint.sh), then point browser-use at it over local CDP.
FROM nousresearch/hermes-agent:latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends chromium \
    && rm -rf /var/lib/apt/lists/*

# Dedicated venv so browser-use's own dependency pins can't collide with Hermes'
# uv-managed environment.
RUN uv venv /opt/browser-use-venv \
    && uv pip install --python /opt/browser-use-venv/bin/python 'browser-use[cli]'

COPY entrypoint.sh /usr/local/bin/ai-entrypoint.sh
RUN chmod +x /usr/local/bin/ai-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/ai-entrypoint.sh"]
