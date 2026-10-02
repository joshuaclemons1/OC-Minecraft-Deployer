#!/usr/bin/env bash
# Install mcd, set up backups, and print the handover summary.

run_finalize() {
    step "Finishing up"

    install -m 0755 "$MCD_SRC/bin/mcd" /usr/local/bin/mcd
    ok "mcd installed to /usr/local/bin/mcd"

    _mcd_install_backup_timer

    # Crafty generates its own admin password on first run and writes it here.
    # The file cannot be used to *set* a password, only to read the initial one,
    # so we copy it somewhere with tight permissions and tell the user once.
    # The file is JSON:
    #   { "username": "admin", "password": "...", "info": "..." }
    # Confirmed by reading a real one on a live install. Parse it with jq rather
    # than grep: the generated password contains #, ^, @, *, !, & and $, and a
    # regex that stops at whitespace happily swallows the closing quote and
    # comma, which is exactly what the first version printed.
    local creds="$MCD_DATA/config/default-creds.txt"
    local user='' pass=''
    if [ -s "$creds" ]; then
        if have jq && jq -e . "$creds" >/dev/null 2>&1; then
            user="$(jq -r '.username // empty' "$creds" 2>/dev/null)"
            pass="$(jq -r '.password // empty' "$creds" 2>/dev/null)"
        fi
        # Fall back to text scraping only if it is not valid JSON, in case a
        # future Crafty release changes the format again.
        if [ -z "$pass" ]; then
            user="$(sed -nE 's/.*"?username"?[[:space:]]*[:=][[:space:]]*"?([^"]*).*/\1/p' "$creds" | head -n1)"
            pass="$(sed -nE 's/.*"?password"?[[:space:]]*[:=][[:space:]]*"?([^"]*).*/\1/p' "$creds" | head -n1)"
        fi
        install -m 0600 "$creds" "$MCD_SECRETS/panel-creds.txt"
        conf_set MCD_PANEL_USER "${user:-admin}"
    fi

    _mcd_print_summary "${user:-admin}" "$pass"
}

_mcd_install_backup_timer() {
    cat >/etc/systemd/system/mcd-backup.service <<'EOT'
[Unit]
Description=Back up all Minecraft servers
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mcd backup --quiet
EOT

    cat >/etc/systemd/system/mcd-backup.timer <<'EOT'
[Unit]
Description=Nightly Minecraft backups

[Timer]
# Local time, a bit of jitter so it is not exactly on the hour.
OnCalendar=*-*-* 04:17:00
Persistent=true

[Install]
WantedBy=timers.target
EOT

    systemctl daemon-reload
    systemctl enable --now mcd-backup.timer >/dev/null 2>&1
    ok "Nightly backups scheduled for 04:17 local time"
}

_mcd_print_summary() {
    local user="$1" pass="$2"
    local heap="$MCD_HEAP_SUGGESTED"

    printf '\n' >&2
    printf '%s%s' "$C_GREEN" "$C_BOLD" >&2
    printf '  ============================================================\n' >&2
    printf '   Done.\n' >&2
    printf '  ============================================================%s\n' "$C_RESET" >&2
    printf '\n' >&2
    printf '   Panel:     %shttps://%s%s\n' "$C_BOLD" "$MCD_HOSTNAME" "$C_RESET" >&2
    printf '   Username:  %s\n' "$user" >&2
    if [ -n "$pass" ]; then
        printf '   Password:  %s%s%s\n' "$C_BOLD" "$pass" "$C_RESET" >&2
        printf '\n' >&2
        printf '   %sSave that password now.%s It is also at:\n' "$C_YELLOW" "$C_RESET" >&2
        printf '     %s/panel-creds.txt\n' "$MCD_SECRETS" >&2
        printf '   Change it in the panel under Panel Config -> Users.\n' >&2
    else
        printf '   Password:  see  sudo mcd creds\n' >&2
    fi
    printf '\n' >&2
    printf '   %sNext:%s create a server in the panel.\n' "$C_BOLD" "$C_RESET" >&2
    printf '     Give it about %s MB of memory on this instance.\n' "$heap" >&2
    printf '     Use a port between %s and %s.\n' "$MC_PORT_START" "$MC_PORT_END" >&2
    printf '\n' >&2

    if [ "${MCD_JAVA_DEGRADED:-0}" = "1" ]; then
        printf '   %s! Java 21/25 are not working in the container.%s\n' "$C_YELLOW" "$C_RESET" >&2
        printf '     Minecraft 1.20.4 and older will run; newer versions will not.\n' >&2
        printf '     See the note above and docs/ROADMAP.md constraint 2.\n\n' >&2
    else
        printf '   For Minecraft 26.x set the server Java path to:\n' >&2
        printf '     /opt/java/jdk-25/bin/java\n' >&2
        printf '   For 1.20.5 - 1.21.11:\n' >&2
        printf '     /opt/java/jdk-21/bin/java\n' >&2
        printf '   Older versions use the panel default. Full map: mcd java\n\n' >&2
    fi

    if [ "${MCD_TLS_OK:-0}" != "1" ]; then
        printf '   %s! The site was not reachable from here yet.%s\n' "$C_YELLOW" "$C_RESET" >&2
        printf '     Open 80, 443 and %s-%s in the Oracle security list,\n' \
            "$MC_PORT_START" "$MC_PORT_END" >&2
        printf '     then check:  mcd status\n\n' >&2
    fi

    printf '   Commands:   mcd status | backup | restore | update | logs\n' >&2
    printf '   Reset one world:        mcd wipe-server <name>\n' >&2
    printf '   Back to stock Ubuntu:   mcd uninstall\n' >&2
    printf '\n' >&2
}
