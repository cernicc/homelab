#!/bin/bash
# Claude Code for the dev user, via the native installer
# (https://code.claude.com/docs/en/setup). Runs as root inside a dev VM via
# `homelab-dev install <project> claude`; safe to re-run. Log in afterwards
# by running `claude` inside the VM -- no credentials are copied in.
set -euo pipefail

su - dev -c "curl -fsSL https://claude.ai/install.sh | bash"

# The installer puts it in ~/.local/bin, which is only on PATH in login
# shells; link it somewhere every shell looks.
ln -sf /home/dev/.local/bin/claude /usr/local/bin/claude
