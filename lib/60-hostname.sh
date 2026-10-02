#!/usr/bin/env bash
# Hostname and DNS.
#
# Let's Encrypt will not issue a certificate for a bare IP address, so a
# hostname is required for the panel to have a real padlock. Three ways to get
# one, in order of preference:
#
#   duckdns  free hostname, we keep the record updated
#   custom   a domain the user already owns and has pointed here
#   sslip.io zero-signup fallback: 203-0-113-42.sslip.io resolves to that IP
#
# sslip.io is a best-effort fallback, not an equal option. It is NOT on the
# Public Suffix List, so Let's Encrypt treats the whole domain as a single
# registered domain and every user in the world shares one certificate
# budget. Let's Encrypt has raised the ceiling for these magic-DNS domains
# (nip.io sits at 250,000 per 7 days), so it works in practice, but there is
# no fallback if it is ever exhausted or the service goes away, and a
# rate-limit failure here is indistinguishable from a misconfiguration.
# DuckDNS gives a dedicated hostname with its own budget, which is why it is
# offered first.

_mcd_resolves_to() {
    # True when $1 resolves to $2. getent uses NSS, so no dig dependency.
    local host="$1" want="$2"
    getent hosts "$host" 2>/dev/null | awk '{print $1}' | grep -qxF "$want"
}

_mcd_duckdns_update() {
    local sub="$1" token="$2" response
    response="$(curl -fsS --max-time 20 \
        "https://www.duckdns.org/update?domains=${sub}&token=${token}&ip=" 2>&1)" || response="request failed"
    case "$response" in
        OK*) return 0 ;;
        *)   err "DuckDNS replied: $response"; return 1 ;;
    esac
}

run_hostname() {
    step "Setting up the hostname"

    MCD_PUBLIC_IP="${MCD_PUBLIC_IP:-$(public_ip)}"
    if is_valid_ipv4 "${MCD_PUBLIC_IP:-}"; then
        ok "Public IP: $MCD_PUBLIC_IP"
    else
        warn "Could not determine this instance's public IP automatically"
        ask MCD_PUBLIC_IP "Public IP address of this instance" ""
        is_valid_ipv4 "$MCD_PUBLIC_IP" \
            || die "'$MCD_PUBLIC_IP' is not a valid IPv4 address." \
                   "Find it in the Oracle console under Compute -> Instances."
    fi
    conf_set MCD_PUBLIC_IP "$MCD_PUBLIC_IP"

    # Already configured by a previous run?
    if [ -n "${MCD_HOSTNAME:-}" ]; then
        info "Hostname: $MCD_HOSTNAME"
    else
        if [ "$MCD_INTERACTIVE" = "1" ]; then
            cat >/dev/tty <<'EOT'

    How should people reach the web panel?

      1) DuckDNS          free hostname, e.g. yourname.duckdns.org  (recommended)
      2) My own domain    you have already pointed a record at this server
      3) Automatic        <ip>.sslip.io, no signup, works but ugly

EOT
        fi
        ask MCD_DNS_MODE "Choose 1, 2 or 3" "1"
    fi

    case "${MCD_DNS_MODE:-}" in
        1|duckdns)
            ask MCD_DUCKDNS_SUB "DuckDNS subdomain (just the name, no .duckdns.org)" ""
            [ -n "$MCD_DUCKDNS_SUB" ] \
                || die "A DuckDNS subdomain is required for that option." \
                       "Register one free at https://www.duckdns.org/ and re-run."
            # Tolerate someone pasting the whole hostname.
            MCD_DUCKDNS_SUB="${MCD_DUCKDNS_SUB%%.duckdns.org}"
            ask_secret MCD_DUCKDNS_TOKEN "DuckDNS token (from the top of duckdns.org)"
            [ -n "$MCD_DUCKDNS_TOKEN" ] \
                || die "A DuckDNS token is required." \
                       "It is shown at the top of https://www.duckdns.org/ once signed in."

            MCD_HOSTNAME="${MCD_DUCKDNS_SUB}.duckdns.org"
            info "Pointing $MCD_HOSTNAME at $MCD_PUBLIC_IP"
            _mcd_duckdns_update "$MCD_DUCKDNS_SUB" "$MCD_DUCKDNS_TOKEN" \
                || die "DuckDNS rejected the update." \
                       "Check the subdomain and token, then run this again."
            ok "DuckDNS record updated"

            # Keep it current. Oracle public IPs are stable in practice, but an
            # ephemeral IP survives neither a stop/start nor a host migration.
            printf '%s\n' "$MCD_DUCKDNS_TOKEN" >"$MCD_SECRETS/duckdns-token"
            chmod 0600 "$MCD_SECRETS/duckdns-token"
            conf_set MCD_DUCKDNS_SUB "$MCD_DUCKDNS_SUB"
            _mcd_install_duckdns_timer
            ;;
        2|custom)
            ask MCD_HOSTNAME "Your hostname (e.g. mc.example.com)" ""
            [ -n "$MCD_HOSTNAME" ] || die "A hostname is required for that option."
            ;;
        3|auto|sslip)
            MCD_HOSTNAME="$(printf '%s' "$MCD_PUBLIC_IP" | tr '.' '-').sslip.io"
            ok "Using $MCD_HOSTNAME"
            ;;
        *)
            die "Unrecognised choice: '${MCD_DNS_MODE:-}'" "Expected 1, 2 or 3."
            ;;
    esac

    conf_set MCD_DNS_MODE "${MCD_DNS_MODE:-}"
    conf_set MCD_HOSTNAME "$MCD_HOSTNAME"

    # Verify DNS before Caddy asks Let's Encrypt, because a failed validation
    # burns rate limit and produces a far more confusing error later.
    local waited=0
    while [ "$waited" -lt 60 ]; do
        if _mcd_resolves_to "$MCD_HOSTNAME" "$MCD_PUBLIC_IP"; then
            ok "$MCD_HOSTNAME resolves to $MCD_PUBLIC_IP"
            break
        fi
        [ "$waited" -eq 0 ] && info "Waiting for DNS to propagate..."
        sleep 5
        waited=$(( waited + 5 ))
    done

    if ! _mcd_resolves_to "$MCD_HOSTNAME" "$MCD_PUBLIC_IP"; then
        warn "$MCD_HOSTNAME does not resolve to $MCD_PUBLIC_IP yet."
        warn "Certificate issuing will fail until it does."
        if [ "${MCD_DNS_MODE:-}" = "2" ] || [ "${MCD_DNS_MODE:-}" = "custom" ]; then
            warn "Add this DNS record at your provider:    A  $MCD_HOSTNAME  ->  $MCD_PUBLIC_IP"
        fi
        confirm "Continue anyway?" yes \
            || die "Stopping. Re-run once DNS resolves correctly."
    fi

    ask MCD_EMAIL "Email for certificate expiry notices" "admin@${MCD_HOSTNAME}"
    conf_set MCD_EMAIL "$MCD_EMAIL"

    export MCD_HOSTNAME MCD_EMAIL MCD_PUBLIC_IP
}

_mcd_install_duckdns_timer() {
    cat >/etc/systemd/system/mcd-duckdns.service <<EOT
[Unit]
Description=Update the DuckDNS record for this instance
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mcd dns-update
EOT

    cat >/etc/systemd/system/mcd-duckdns.timer <<'EOT'
[Unit]
Description=Keep the DuckDNS record current

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOT

    systemctl daemon-reload
    systemctl enable --now mcd-duckdns.timer >/dev/null 2>&1
    ok "DuckDNS record will refresh every 30 minutes"
}
