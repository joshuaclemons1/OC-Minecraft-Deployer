#!/usr/bin/env bash
# The host firewall — the thing that makes manually-built Oracle instances
# unreachable with no useful error message.
#
# Oracle's Ubuntu images ship with iptables rules roughly like:
#
#   -A INPUT   -m state --state RELATED,ESTABLISHED -j ACCEPT
#   -A INPUT   -p tcp -m state --state NEW --dport 22 -j ACCEPT
#   -A INPUT   -j REJECT --reject-with icmp-host-prohibited
#   -A FORWARD -j REJECT --reject-with icmp-host-prohibited
#
# Two separate problems come out of that:
#
# 1. INPUT rejects everything except SSH, so any service on the host is dead.
#
# 2. FORWARD rejects everything, and *that* is the one that bites Docker.
#    Traffic to a published container port is DNAT'd and traverses FORWARD,
#    not INPUT, so adding INPUT rules alone does not help. Docker inserts its
#    own jumps at the top of FORWARD when it starts, which normally lands them
#    above Oracle's REJECT — but if the order is ever the other way round,
#    every published port is silently black-holed.
#
# We therefore fix both chains, and reassert them at boot with a systemd unit
# ordered after docker.service rather than via iptables-persistent. Saving the
# live ruleset with netfilter-persistent would capture Docker's runtime chains
# and duplicate them on every reboot, which is its own mess.

_mcd_fw_first_block_index() {
    # Line number of the first blanket REJECT/DROP in a chain, if any.
    local chain="$1"
    iptables -L "$chain" -n --line-numbers 2>/dev/null \
        | awk 'NR>2 && ($2=="REJECT" || $2=="DROP") {print $1; exit}'
}

_mcd_fw_ensure_input() {
    # Insert an ACCEPT above the blanket REJECT, or append if there is none.
    local proto="$1" dport="$2" label="$3"
    if iptables -C INPUT -p "$proto" --dport "$dport" -j ACCEPT 2>/dev/null; then
        skip "INPUT already allows $label"
        return 0
    fi
    local idx
    idx="$(_mcd_fw_first_block_index INPUT)"
    if [ -n "$idx" ]; then
        iptables -I INPUT "$idx" -p "$proto" --dport "$dport" -j ACCEPT
    else
        iptables -A INPUT -p "$proto" --dport "$dport" -j ACCEPT
    fi
    ok "INPUT allows $label"
}

_mcd_fw_fix_forward() {
    # Make sure a blanket FORWARD REJECT cannot sit above Docker's chains.
    local spec='-A FORWARD -j REJECT --reject-with icmp-host-prohibited'
    local rules reject_pos docker_pos
    rules="$(iptables -S FORWARD 2>/dev/null)" || return 0

    grep -qxF -- "$spec" <<<"$rules" || { skip "No blanket FORWARD REJECT to reorder"; return 0; }

    reject_pos="$(grep -nxF -- "$spec" <<<"$rules" | head -n1 | cut -d: -f1)"
    docker_pos="$(grep -n -- '-A FORWARD -j DOCKER-USER' <<<"$rules" | head -n1 | cut -d: -f1)"

    if [ -z "$docker_pos" ]; then
        # Docker has not set up its chains yet; it will insert above on start.
        skip "Docker FORWARD chains not present yet"
        return 0
    fi

    if [ "$reject_pos" -lt "$docker_pos" ]; then
        warn "Oracle's FORWARD REJECT sits above Docker's chains — all published"
        warn "container ports would be dropped. Moving it to the end."
        # shellcheck disable=SC2086
        iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited
        iptables -A FORWARD -j REJECT --reject-with icmp-host-prohibited
        ok "FORWARD reordered so Docker traffic is evaluated first"
    else
        ok "FORWARD order is correct (Docker evaluated before the REJECT)"
    fi
}

# Applied both at install time and at every boot. Must be idempotent.
mcd_firewall_apply() {
    if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        # ufw is in charge of INPUT. Work with it rather than inserting raw
        # rules it does not know about and would overwrite on reload.
        info "ufw is active; adding rules through ufw"
        ufw --force allow 80/tcp                               >/dev/null
        ufw --force allow 443/tcp                              >/dev/null
        ufw --force allow "${MC_PORT_START}:${MC_PORT_END}/tcp" >/dev/null
        ufw --force allow "${BEDROCK_PORT}/udp"                 >/dev/null
        ok "ufw rules applied"
    else
        _mcd_fw_ensure_input tcp 80 "HTTP (certificate issuing)"
        _mcd_fw_ensure_input tcp 443 "HTTPS (the web panel)"
        _mcd_fw_ensure_input tcp "${MC_PORT_START}:${MC_PORT_END}" \
            "Minecraft ${MC_PORT_START}-${MC_PORT_END}"
        _mcd_fw_ensure_input udp "$BEDROCK_PORT" "Bedrock ${BEDROCK_PORT}"
    fi

    _mcd_fw_fix_forward
}

run_firewall() {
    step "Opening the host firewall"

    if ! have iptables; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq iptables >>"$MCD_LOGFILE" 2>&1 \
            || die "Could not install iptables."
    fi

    mcd_firewall_apply

    # Reassert at boot, after Docker has built its chains.
    local unit=/etc/systemd/system/mcd-firewall.service
    if [ ! -f "$unit" ]; then
        cat >"$unit" <<EOT
[Unit]
Description=Reapply OC-Minecraft-Deployer firewall rules
# After netfilter-persistent as well as docker: Oracle's images ship
# iptables-persistent, which restores /etc/iptables/rules.v4 at boot. That
# file holds Oracle's original rules without ours, and iptables-restore
# flushes the chains it defines, so running before it would see our rules
# wiped moments later.
After=docker.service netfilter-persistent.service network-online.target
Wants=docker.service
Requires=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mcd firewall apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOT
        systemctl daemon-reload
        systemctl enable mcd-firewall.service >/dev/null 2>&1
        ok "Firewall rules will be reapplied on boot"
    else
        skip "Boot-time firewall unit already installed"
    fi

    printf '\n' >&2
    warn "${C_BOLD}This only fixed the firewall inside the instance.${C_RESET}"
    warn "Oracle has a second, separate firewall in the cloud console, and"
    warn "your server stays unreachable until you open these there too:"
    warn ""
    warn "  Networking -> Virtual Cloud Networks -> your VCN -> Subnets"
    warn "    -> your subnet -> Security Lists -> Add Ingress Rules"
    warn ""
    warn "    0.0.0.0/0  TCP  80                 (certificate issuing)"
    warn "    0.0.0.0/0  TCP  443                (the web panel)"
    warn "    0.0.0.0/0  TCP  ${MC_PORT_START}-${MC_PORT_END}      (Minecraft)"
    warn "    0.0.0.0/0  UDP  ${BEDROCK_PORT}              (Bedrock, optional)"
    printf '\n' >&2
}
