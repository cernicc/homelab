# Hermes Agent (https://hermes-agent.nousresearch.com/) with browser-use
# (https://github.com/browser-use/browser-use) as its browsing backend, using
# Hermes' own NATIVE integration
# (https://hermes-agent.nousresearch.com/docs/user-guide/features/browser) --
# a `browser_exec` tool it drives itself, using the same browser-use CLI, rather
# than a hand-rolled MCP server. An earlier version of this stack wired browser-use
# in as a custom MCP server instead; that turned out to be unnecessary complexity
# fighting Hermes' own already-built integration, and the real fix was just
# pointing `browser.cdp_url` (the documented config key -- wants the actual
# ws://.../devtools/browser/<id> URL, not a bare http://host:port) at the right
# place. See entrypoint.sh and stacks/ai/README.md for the full story.
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
