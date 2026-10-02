#!/usr/bin/env bash
#
# OC-Minecraft-Deployer installer.
#
# Idempotent: safe to run repeatedly. Every step checks the current state
# before changing anything, and no step destroys Minecraft data.
#
# Usage:
#   sudo bash install.sh [--unattended] [--yes]
#
# Every prompt can be pre-answered from the environment, which is how the
# test runs are driven:
#   sudo MCD_HOSTNAME=foo.duckdns.org MCD_DUCKDNS_TOKEN=... \
#        MCD_EMAIL=me@example.com MCD_MC_MEMORY=6144 \
#        MCD_UNATTENDED=1 bash install.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

for arg in "$@"; do
    case "$arg" in
        --unattended) MCD_UNATTENDED=1; MCD_INTERACTIVE=0 ;;
        --yes|-y)     MCD_ASSUME_YES=1 ;;
        --help|-h)
            sed -n "3,20p" "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "Unknown option: $arg" "Run with --help to see the options." ;;
    esac
done

require_root
install -d -m 0755 "$(dirname "$MCD_LOGFILE")"
touch "$MCD_LOGFILE"; chmod 0640 "$MCD_LOGFILE"
_log_raw "=== install.sh starting ($(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)) ==="

printf '\n%s%sOC-Minecraft-Deployer%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET" >&2
printf 'A free Oracle Cloud Minecraft server with a web control panel.\n' >&2

conf_load

for stepfile in "$HERE"/lib/[0-9][0-9]-*.sh; do
    # shellcheck disable=SC1090
    . "$stepfile"
done

# A dropped SSH session must not be able to strand the install, so every
# question the user has to answer is asked first, before any work begins. The
# hostname step holds all of the prompts; it used to sit sixth, which meant a
# disconnect during the Docker install left the installer blocked on a prompt it
# could no longer read, half finished. Asking first also gives DNS the whole
# install to propagate.
run_preflight
run_hostname

run_host

# Before Docker: installing it reloads netfilter and flushes conntrack, and
# Oracle's SSH rule is NEW-only, so an open session would be reset mid-install.
protect_ssh

# Docker before the firewall proper: that step inspects Docker's own FORWARD
# chains to decide whether Oracle's blanket REJECT is sitting above them.
run_docker
run_firewall
run_java
run_stack
run_finalize

_log_raw "=== install.sh finished ==="
