#!/usr/bin/env bash
# Shared configuration, logging, and helpers for OC-Minecraft-Deployer.
# Sourced by install.sh, every lib/NN-*.sh step, and bin/mcd.

# Most definitions here are consumed by the lib/NN-*.sh steps and by bin/mcd,
# which source this file. shellcheck analyses each file alone and so reports
# them as unused; they are not.
# shellcheck disable=SC2034

# --------------------------------------------------------------- source --

MCD_REPO_URL="${MCD_REPO_URL:-https://github.com/joshuaclemons1/OC-Minecraft-Deployer.git}"
MCD_BRANCH="${MCD_BRANCH:-main}"
MCD_RAW_URL="${MCD_RAW_URL:-https://raw.githubusercontent.com/joshuaclemons1/OC-Minecraft-Deployer/main}"

# ---------------------------------------------------------------- paths --

MCD_ROOT="${MCD_ROOT:-/opt/mcd}"
MCD_SRC="$MCD_ROOT/src"
MCD_CONF="$MCD_ROOT/mcd.conf"
MCD_SECRETS="$MCD_ROOT/secrets"
MCD_JAVA="$MCD_ROOT/java"
MCD_DATA="$MCD_ROOT/crafty"
MCD_BACKUPS="$MCD_ROOT/backups"
MCD_CADDY="$MCD_ROOT/caddy"
MCD_STATE="$MCD_ROOT/state"
MCD_LOGFILE="${MCD_LOGFILE:-/var/log/mcd.log}"

# ------------------------------------------------------------- versions --

# Floor, not preference. Crafty < 4.10.8 is vulnerable to CVE-2026-13716
# (CVSS 9.1 path traversal in import/upload -> RCE, exploitable by ANY
# authenticated user). 4.11.0 additionally fixes CVE-2026-18516 and
# CVE-2026-90821 (stored XSS). We expose this panel publicly, so the floor
# is 4.11.0 and anything older is refused outright.
CRAFTY_MIN_VERSION="4.11.0"
CRAFTY_TAG="${CRAFTY_TAG:-4.11.0}"
CRAFTY_IMAGE="${CRAFTY_IMAGE:-registry.gitlab.com/crafty-controller/crafty-4}"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"

# The Crafty container's entrypoint starts as root, but it drops the actual
# application to uid 1000 ("crafty") with gid 0. Bind-mounted directories must
# therefore be writable by that uid, not just by root. Getting this wrong makes
# server creation fail with a CRITICAL "Permission denied: /crafty/servers/<id>"
# in Crafty's session.log, which the API unhelpfully reports as
# "No such file or directory: '/crafty/servers/<id>/server.properties'".
CRAFTY_UID="${CRAFTY_UID:-1000}"
CRAFTY_GID="${CRAFTY_GID:-0}"

# Minecraft 26.x needs Java 25; 1.20.5-1.21.11 need 21. The stock Crafty
# image ships only 8/11/17, so we supply these two and mount them in.
JAVA_VERSIONS=(21 25)

# ---------------------------------------------------------------- ports --

MC_PORT_START="${MC_PORT_START:-25565}"
MC_PORT_END="${MC_PORT_END:-25575}"
BEDROCK_PORT="${BEDROCK_PORT:-19132}"

# Memory held back from Minecraft for the OS, Docker, Crafty and page cache.
# Scaled to the box rather than flat: 2.5 GB is about right on a 12 GB
# instance but is 42% of a 6 GB one, which would leave a small box with an
# absurdly small heap. An explicit MCD_RESERVE_MB always wins.
MCD_RESERVE_MB="${MCD_RESERVE_MB:-}"
MCD_MIN_HEAP_MB="${MCD_MIN_HEAP_MB:-1024}"

# -------------------------------------------------------------- logging --

if [ -t 2 ] && [ "${NO_COLOR:-}" = "" ]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'; C_BOLD=$'\033[1m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

_log_raw() {
    # Timestamped copy to the logfile when we can write it; never fatal.
    if [ -w "$(dirname "$MCD_LOGFILE")" ] 2>/dev/null || [ -w "$MCD_LOGFILE" ] 2>/dev/null; then
        printf '%s %s\n' "$(date -Is)" "$*" >>"$MCD_LOGFILE" 2>/dev/null || true
    fi
}

step() { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2; _log_raw "STEP $*"; }
info() { printf '    %s\n' "$*" >&2; _log_raw "INFO $*"; }
ok()   { printf '    %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; _log_raw "OK   $*"; }
skip() { printf '    %s·%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; _log_raw "SKIP $*"; }
warn() { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log_raw "WARN $*"; }
err()  { printf '    %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; _log_raw "ERR  $*"; }

# Every failure path should name the fix, not just the symptom.
die() {
    printf '\n%s%sInstall failed:%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$1" >&2
    shift
    for line in "$@"; do printf '  %s\n' "$line" >&2; done
    printf '\nFull log: %s\n' "$MCD_LOGFILE" >&2
    _log_raw "DIE  $*"
    exit 1
}

# ---------------------------------------------------------------- guards --

have() { command -v "$1" >/dev/null 2>&1; }

# True only when /dev/tty can actually be opened, i.e. there is a controlling
# terminal and therefore a human who can answer a prompt.
tty_available() { (exec 3</dev/tty) 2>/dev/null; }

# Strip carriage returns and surrounding whitespace from a pasted value.
# Pasting from a Windows clipboard can carry a trailing CR, which would be sent
# verbatim inside the DuckDNS update URL and rejected with no useful explanation.
trim() {
    local s="$1"
    s="${s//$'\r'/}"
    s="${s//$'\n'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This needs to run as root." \
            "Re-run it with sudo:" \
            "    curl -fsSL $MCD_RAW_URL/bootstrap.sh | sudo bash"
    fi
}

# ------------------------------------------------------------------ tty --

# Critical for "curl ... | sudo bash": stdin is the pipe carrying the script,
# so a bare `read` consumes script text or sees EOF instantly. Always read the
# human from /dev/tty, and treat "no tty" as non-interactive rather than
# hanging or silently taking an empty answer.
MCD_INTERACTIVE=0
# Attempt the open rather than testing the node. /dev/tty exists and is
# world-readable with no controlling terminal attached, so `[ -r /dev/tty ]`
# returns true and every subsequent read from it fails with ENXIO - which looks
# like a hung or crashed installer rather than "there is nobody to ask".
if tty_available; then MCD_INTERACTIVE=1; fi
[ "${MCD_UNATTENDED:-0}" = "1" ] && MCD_INTERACTIVE=0

# ask VAR "Prompt" "default"
# Honours a pre-set environment variable of the same name, so every prompt can
# be driven non-interactively: MCD_HOSTNAME=foo ... bash bootstrap.sh
ask() {
    local __var="$1" __prompt="$2" __default="${3:-}" __current __reply
    __current="$(eval "printf '%s' \"\${$__var:-}\"")"

    if [ -n "$__current" ]; then
        info "$__prompt: $__current (from environment)"
        return 0
    fi

    if [ "$MCD_INTERACTIVE" != "1" ]; then
        if [ -z "$__default" ]; then
            die "Need a value for $__var but there is no terminal to ask on." \
                "Set it in the environment and re-run, for example:" \
                "    sudo $__var='...' bash $0"
        fi
        eval "$__var=\$__default"
        info "$__prompt: $__default (default)"
        return 0
    fi

    if [ -n "$__default" ]; then
        printf '    %s [%s]: ' "$__prompt" "$__default" >/dev/tty
    else
        printf '    %s: ' "$__prompt" >/dev/tty
    fi
    IFS= read -r __reply </dev/tty || __reply=''
    __reply="$(trim "$__reply")"
    [ -z "$__reply" ] && __reply="$__default"
    eval "$__var=\$__reply"
}

# ask_secret VAR "Prompt" - same, without echoing to the screen.
ask_secret() {
    local __var="$1" __prompt="$2" __reply __current
    __current="$(eval "printf '%s' \"\${$__var:-}\"")"
    if [ -n "$__current" ]; then
        info "$__prompt: (set from environment)"
        return 0
    fi
    if [ "$MCD_INTERACTIVE" != "1" ]; then
        eval "$__var=''"
        return 0
    fi
    printf '    %s: ' "$__prompt" >/dev/tty
    IFS= read -rs __reply </dev/tty || __reply=''
    printf '\n' >/dev/tty
    eval "$__var=\$__reply"
}

# confirm "Question" [default_yes]
confirm() {
    local prompt="$1" default="${2:-no}" reply
    if [ "${MCD_ASSUME_YES:-0}" = "1" ]; then return 0; fi
    if [ "$MCD_INTERACTIVE" != "1" ]; then
        [ "$default" = "yes" ] && return 0 || return 1
    fi
    if [ "$default" = "yes" ]; then
        printf '    %s [Y/n]: ' "$prompt" >/dev/tty
    else
        printf '    %s [y/N]: ' "$prompt" >/dev/tty
    fi
    IFS= read -r reply </dev/tty || reply=''
    [ -z "$reply" ] && reply="$default"
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# --------------------------------------------------------------- helpers --

# Semantic version compare: version_ge 4.11.0 4.10.8 -> true
version_ge() {
    [ "$1" = "$2" ] && return 0
    local greater
    greater="$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)"
    [ "$greater" = "$1" ]
}

gen_password() {
    # Avoid shell-awkward and visually ambiguous characters: this gets copied
    # out of a terminal by hand and pasted into a browser.
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

total_mem_mb() { awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }

reserve_mb() {
    if [ -n "${MCD_RESERVE_MB:-}" ]; then printf '%d' "$MCD_RESERVE_MB"; return; fi
    local total
    total="$(total_mem_mb)"
    if [ "$total" -le 8192 ]; then printf '1536'; else printf '2560'; fi
}

# Heap we recommend for Minecraft given real installed memory.
suggested_heap_mb() {
    local total heap reserve
    total="$(total_mem_mb)"
    reserve="$(reserve_mb)"
    heap=$(( total - reserve ))
    [ "$heap" -lt 0 ] && heap=0
    # Round down to a whole gigabyte; odd megabyte values look like bugs.
    heap=$(( heap / 1024 * 1024 ))
    printf '%d' "$heap"
}

# Write key=value into mcd.conf, replacing any existing key. Idempotent.
conf_set() {
    local key="$1" value="$2" dir
    dir="$(dirname "$MCD_CONF")"
    [ -d "$dir" ] || install -d -m 0755 "$dir"
    [ -f "$MCD_CONF" ] || touch "$MCD_CONF"
    # World readable on purpose, and asserted on every write rather than only at
    # creation so an older 0640 file gets corrected. This holds no secrets - the
    # hostname, public IP, email and Java paths. Secrets live in $MCD_SECRETS at
    # 0600. If it were unreadable, every unprivileged `mcd` subcommand would die
    # in conf_load.
    chmod 0644 "$MCD_CONF" 2>/dev/null || true
    if grep -q "^${key}=" "$MCD_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$MCD_CONF"
    else
        printf '%s=%s\n' "$key" "$value" >>"$MCD_CONF"
    fi
}

conf_load() {
    # Never fatal. bin/mcd runs under `set -e`, and a config that cannot be read
    # should degrade to defaults rather than abort the command - read-only
    # subcommands like `mcd java` have no business requiring root.
    if [ -r "$MCD_CONF" ]; then
        # shellcheck disable=SC1090
        . "$MCD_CONF" 2>/dev/null || true
    fi
    return 0
}

compose() {
    docker compose -f "$MCD_ROOT/compose.yaml" --project-name mcd "$@"
}

# Render a template, substituting only the @@NAME@@ placeholders we define.
# Deliberately not envsubst: Caddyfiles and compose files are full of $ and {}
# that must survive untouched.
render() {
    local src="$1" dst="$2"; shift 2
    local tmp; tmp="$(mktemp)"
    cp "$src" "$tmp"
    while [ "$#" -gt 0 ]; do
        local key="$1" val="$2"; shift 2
        # '|' is not valid in any value we pass (hostnames, paths, numbers).
        sed -i "s|@@${key}@@|${val}|g" "$tmp"
    done
    if grep -q '@@[A-Z_]*@@' "$tmp"; then
        warn "Unsubstituted placeholders left in $(basename "$dst"):"
        grep -o '@@[A-Z_]*@@' "$tmp" | sort -u | while read -r p; do warn "  $p"; done
    fi
    install -m 0644 "$tmp" "$dst"
    rm -f "$tmp"
}

# Public IP of this instance, for the sslip.io hostname fallback and for
# telling the user where to point DNS.
public_ip() {
    local ip=''
    # Oracle's instance metadata service first: authoritative and never
    # rate-limited, unlike the public echo services.
    ip="$(curl -fsS --max-time 5 -H 'Authorization: Bearer Oracle' \
            'http://169.254.169.254/opc/v2/vnics/' 2>/dev/null \
          | grep -o '"publicIp"[[:space:]]*:[[:space:]]*"[^"]*"' \
          | head -n1 | sed 's/.*"\([0-9.]*\)"$/\1/')" || true
    if [ -z "$ip" ]; then
        ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null)" || true
    fi
    printf '%s' "$ip"
}

is_valid_ipv4() {
    case "$1" in
        *[!0-9.]*|'') return 1 ;;
    esac
    local IFS=. parts n
    read -ra parts <<<"$1"
    [ "${#parts[@]}" -eq 4 ] || return 1
    for n in "${parts[@]}"; do
        [ -n "$n" ] || return 1
        [ "$n" -le 255 ] || return 1
    done
    return 0
}
