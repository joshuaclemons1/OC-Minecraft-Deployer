#!/usr/bin/env bash
#
# OC-Minecraft-Deployer bootstrap.
#
#   curl -fsSL https://raw.githubusercontent.com/joshuaclemons1/OC-Minecraft-Deployer/main/bootstrap.sh | sudo bash
#
# Or, to read it before running it as root (which is the better habit):
#
#   curl -fsSL https://raw.githubusercontent.com/joshuaclemons1/OC-Minecraft-Deployer/main/bootstrap.sh -o bootstrap.sh
#   less bootstrap.sh
#   sudo bash bootstrap.sh
#
# This stage only fetches the project and hands over to install.sh. It stays
# small on purpose: it is the part people pipe into a root shell sight unseen.

set -euo pipefail

MCD_REPO_URL="${MCD_REPO_URL:-https://github.com/joshuaclemons1/OC-Minecraft-Deployer.git}"
MCD_BRANCH="${MCD_BRANCH:-main}"
MCD_ROOT="${MCD_ROOT:-/opt/mcd}"
MCD_SRC="$MCD_ROOT/src"

if [ "$(id -u)" -ne 0 ]; then
    cat >&2 <<'EOT'

This installer has to run as root, and it is not running as root.

Add "sudo" to the command:

    curl -fsSL https://raw.githubusercontent.com/joshuaclemons1/OC-Minecraft-Deployer/main/bootstrap.sh | sudo bash

EOT
    exit 1
fi

printf '\n==> Fetching OC-Minecraft-Deployer\n' >&2

if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    printf '    installing git and curl\n' >&2
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq git curl ca-certificates
fi

if [ -d "$MCD_SRC/.git" ]; then
    printf '    updating existing checkout at %s\n' "$MCD_SRC" >&2
    git -C "$MCD_SRC" remote set-url origin "$MCD_REPO_URL"
    git -C "$MCD_SRC" fetch --quiet --depth 1 origin "$MCD_BRANCH"
    git -C "$MCD_SRC" checkout --quiet -B "$MCD_BRANCH" "origin/$MCD_BRANCH"
    # A re-run must not inherit local edits from a previous debugging session.
    git -C "$MCD_SRC" reset --quiet --hard "origin/$MCD_BRANCH"
else
    install -d -m 0755 "$MCD_ROOT"
    rm -rf -- "${MCD_SRC:?}"
    git clone --quiet --depth 1 --branch "$MCD_BRANCH" "$MCD_REPO_URL" "$MCD_SRC"
fi

printf '    at commit %s\n' "$(git -C "$MCD_SRC" rev-parse --short HEAD)" >&2

# Hand over. Pass the environment through so MCD_* overrides keep working, and
# keep stdin attached to the terminal rather than this script's pipe.
cd "$MCD_SRC"
if [ -r /dev/tty ]; then
    exec bash "$MCD_SRC/install.sh" "$@" </dev/tty
else
    exec bash "$MCD_SRC/install.sh" "$@"
fi
