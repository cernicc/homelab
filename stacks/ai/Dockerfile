# Hermes Agent (https://hermes-agent.nousresearch.com/) with browser-use
# (https://github.com/browser-use/browser-use) as a custom MCP server.
#
# browser-use's MCP server only speaks stdio -- there is no HTTP/SSE transport in the
# open-source package, and neither project documents running it as a separate
# networked service. So it's installed straight into the Hermes image and spawned as
# a local stdio subprocess (config.yaml mcp_servers, see entrypoint.sh) rather than
# run as a sidecar container.
#
# Hermes ALSO ships its own native browser integration (a `browser_exec` tool,
# toolset "browser", driven by this same browser-use CLI) -- see the "known
# limitation" in stacks/ai/README.md for why the MCP server is what's actually
# wired up as primary despite that existing.
#
# browser-use itself no longer bundles/manages a Playwright-installed Chromium
# (confirmed: current pyproject.toml depends on cdp-use + browser-harness, not
# playwright/patchright) -- it expects to attach to an existing browser over CDP.
# Browser Use Cloud is the docs' answer for a headless machine; to stay fully
# self-hosted, we install real Chromium via apt and launch it ourselves (see
# entrypoint.sh).
FROM nousresearch/hermes-agent:latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends chromium \
    && rm -rf /var/lib/apt/lists/*

# Dedicated venv so browser-use's own dependency pins can't collide with Hermes'
# uv-managed environment. Explicitly --python /usr/bin/python3 (the base image's own
# system interpreter) rather than letting `uv venv` pick/download its own managed
# CPython build: that build lands in /root/.local/share/uv (owned by root, mode 700),
# and Hermes runs as an unprivileged `hermes` user (uid 10000) that can't traverse
# into /root -- every exec of a script shebanged at such a python fails with a
# silent Permission Denied.
RUN uv venv --python /usr/bin/python3 /opt/browser-use-venv \
    && uv pip install --python /opt/browser-use-venv/bin/python 'browser-use[cli]'

# So Hermes' own CLI-discovery (tools/browser_use_cli.py::_find_cli, a plain
# shutil.which("browser-use") probe) finds this pinned, offline copy instead of
# falling back to a live `uvx` fetch from PyPI on every single browser_exec call.
ENV PATH="/opt/browser-use-venv/bin:${PATH}"

COPY entrypoint.sh /usr/local/bin/ai-entrypoint.sh
RUN chmod +x /usr/local/bin/ai-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/ai-entrypoint.sh"]
