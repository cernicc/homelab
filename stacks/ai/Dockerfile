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
FROM nousresearch/hermes-agent:latest

# Dedicated venv so browser-use's own dependency pins can't collide with Hermes'
# uv-managed environment. Base image is Debian 13 (confirmed from upstream Dockerfile),
# so Playwright's `--with-deps` can pull Chromium's OS-level deps via apt.
RUN uv venv /opt/browser-use-venv \
    && uv pip install --python /opt/browser-use-venv/bin/python 'browser-use[cli]' \
    && /opt/browser-use-venv/bin/playwright install --with-deps chromium

COPY entrypoint.sh /usr/local/bin/ai-entrypoint.sh
RUN chmod +x /usr/local/bin/ai-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/ai-entrypoint.sh"]
