#!/bin/bash
# Rust toolchain for the dev user. Runs as root inside a dev VM via
# `homelab-dev install <project> rust`; safe to re-run.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# C toolchain too: cargo needs a linker, and many crates build C code.
apt-get update -q
apt-get install -y -q build-essential pkg-config rustup

# Only the default; projects pin their own version in rust-toolchain.toml.
su - dev -c "rustup default stable"
