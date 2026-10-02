#!/usr/bin/env bash
# Host preparation: directory layout, swap, unattended security updates.

run_host() {
    step "Preparing the host"

    install -d -m 0755 "$MCD_ROOT"
    install -d -m 0755 "$MCD_DATA" "$MCD_CADDY" "$MCD_JAVA" "$MCD_STATE"
    install -d -m 0750 "$MCD_BACKUPS"
    install -d -m 0700 "$MCD_SECRETS"
    # Crafty's own data directories, created before the container starts so they
    # are owned correctly rather than appearing as root-owned mount points.
    install -d -m 0755 "$MCD_DATA/servers" "$MCD_DATA/config" "$MCD_DATA/logs" \
                       "$MCD_DATA/backups" "$MCD_DATA/import"

    # These are bind-mounted into the container, where the application runs as
    # uid 1000 / gid 0 rather than root. Left as root:root it can create neither
    # a server directory nor a backup directory. Only the mount points are
    # chowned, not their contents: worlds can be many gigabytes, and anything
    # Crafty creates inside is already owned correctly.
    local d target owner
    for d in servers config logs backups import; do
        target="$MCD_DATA/$d"
        owner="$(stat -c '%u:%g' "$target")"
        if [ "$owner" != "${CRAFTY_UID}:${CRAFTY_GID}" ]; then
            chown "${CRAFTY_UID}:${CRAFTY_GID}" "$target"
            ok "crafty/$d owned by ${CRAFTY_UID}:${CRAFTY_GID}"
        else
            skip "crafty/$d ownership already correct"
        fi
        chmod 0775 "$target"
    done
    ok "Layout under $MCD_ROOT"

    export DEBIAN_FRONTEND=noninteractive

    local want=(ca-certificates curl gnupg jq tar unattended-upgrades)
    local missing=()
    local pkg
    for pkg in "${want[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed' \
            || missing+=("$pkg")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        info "Installing: ${missing[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}" >>"$MCD_LOGFILE" 2>&1 \
            || die "apt-get install failed for: ${missing[*]}" "See $MCD_LOGFILE"
        ok "Base packages installed"
    else
        skip "Base packages already present"
    fi

    # --- swap -------------------------------------------------------------
    # 12 GB with no swap means an over-allocated heap gets the JVM OOM-killed
    # with no warning. A modest swapfile converts that into slowness, which is
    # recoverable, instead of a dead server.
    if [ "$(swapon --show --noheadings 2>/dev/null | wc -l)" -gt 0 ]; then
        skip "Swap already configured"
    elif [ -f /swapfile ]; then
        skip "/swapfile exists but is not active; leaving it alone"
    else
        info "Creating a 2 GB swapfile"
        if fallocate -l 2G /swapfile 2>/dev/null || \
           dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; then
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
            swapon /swapfile
            grep -q '^/swapfile' /etc/fstab || \
                printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
            ok "2 GB swap active"
        else
            warn "Could not create a swapfile; continuing without one"
        fi
    fi

    # Prefer reclaiming page cache over swapping the JVM heap out, which would
    # show up in game as severe stutter.
    if [ "$(cat /proc/sys/vm/swappiness)" != "10" ]; then
        printf 'vm.swappiness=10\n' >/etc/sysctl.d/99-mcd.conf
        sysctl -q -w vm.swappiness=10
        ok "vm.swappiness=10"
    else
        skip "vm.swappiness already 10"
    fi

    # --- unattended security updates --------------------------------------
    # The panel is internet-facing and Crafty has shipped three CVEs in 2026,
    # so staying patched is not optional. This covers the OS; `mcd update`
    # covers the panel itself.
    if [ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
        cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOT
        ok "Automatic security updates enabled"
    else
        skip "Automatic security updates already configured"
    fi

    conf_set MCD_INSTALLED_AT "$(date -Is)"
    conf_set MCD_ARCH "$MCD_ARCH"
}
