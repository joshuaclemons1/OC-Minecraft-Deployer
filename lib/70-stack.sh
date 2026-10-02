#!/usr/bin/env bash
# Render the compose stack and bring it up.

# MCD_JAVA_DEGRADED and MCD_TLS_OK are read by lib/80-finalize.sh to decide
# what caveats the final summary needs to carry.
# shellcheck disable=SC2034

run_stack() {
    step "Starting the panel"

    # Refuse anything below the CVE floor, including an operator override.
    if ! version_ge "$CRAFTY_TAG" "$CRAFTY_MIN_VERSION"; then
        die "Refusing to install Crafty $CRAFTY_TAG." \
            "Versions below $CRAFTY_MIN_VERSION are affected by CVE-2026-13716," \
            "a CVSS 9.1 path traversal in the import and upload handlers that any" \
            "authenticated user can turn into remote code execution. This panel is" \
            "internet-facing, so that is not an acceptable risk." \
            "Remove the CRAFTY_TAG override and re-run."
    fi
    ok "Crafty $CRAFTY_TAG (floor is $CRAFTY_MIN_VERSION)"

    local tz
    tz="$(timedatectl show --property=Timezone --value 2>/dev/null || echo Etc/UTC)"

    render "$MCD_SRC/templates/compose.yaml.tmpl" "$MCD_ROOT/compose.yaml" \
        CRAFTY_IMAGE  "$CRAFTY_IMAGE" \
        CRAFTY_TAG    "$CRAFTY_TAG" \
        CADDY_IMAGE   "$CADDY_IMAGE" \
        TZ            "$tz" \
        MC_PORT_START "$MC_PORT_START" \
        MC_PORT_END   "$MC_PORT_END" \
        BEDROCK_PORT  "$BEDROCK_PORT" \
        MCD_DATA      "$MCD_DATA" \
        MCD_JAVA      "$MCD_JAVA" \
        MCD_CADDY     "$MCD_CADDY"
    ok "compose.yaml written"

    install -d -m 0755 "$MCD_CADDY/data" "$MCD_CADDY/config"
    render "$MCD_SRC/templates/Caddyfile.tmpl" "$MCD_CADDY/Caddyfile" \
        HOSTNAME "$MCD_HOSTNAME" \
        EMAIL    "$MCD_EMAIL"
    ok "Caddyfile written for $MCD_HOSTNAME"

    info "Pulling images (this is the slow part)"
    compose pull --quiet >>"$MCD_LOGFILE" 2>&1 \
        || die "Could not pull the container images." \
               "Check outbound internet and see $MCD_LOGFILE"
    ok "Images pulled"

    compose up -d >>"$MCD_LOGFILE" 2>&1 \
        || die "Could not start the stack." \
               "Inspect it with: docker compose -f $MCD_ROOT/compose.yaml logs"
    ok "Containers started"

    # All three of these report problems by returning non-zero, and all three
    # describe failures the user can still recover from: a slow first boot, a
    # glibc mismatch that only affects newer Minecraft, or a certificate that
    # cannot be issued until the Oracle security list is opened. Under `set -e`
    # a bare call would abort the installer here, skipping run_finalize and
    # leaving the box with no mcd command and no summary explaining what to fix.
    # Record the outcome instead and let the summary carry the caveats.
    _mcd_wait_for_crafty        || MCD_CRAFTY_SLOW=1
    _mcd_verify_writable        || MCD_WRITE_BROKEN=1
    verify_java_in_container    || MCD_JAVA_DEGRADED=1
    _mcd_wait_for_certificate   || MCD_TLS_OK=0

    return 0
}

# Confirm the application user can actually write to the bind mounts.
#
# Must run as CRAFTY_UID, not root. A `docker exec` without -u runs as the
# image's root user and will happily write to a root-owned mount, reporting
# success while the real application is locked out. That false negative cost an
# afternoon: server creation failed with a misleading "No such file or
# directory: .../server.properties" while the actual cause, logged only in
# Crafty's own session.log, was "Permission denied".
_mcd_verify_writable() {
    step "Checking the container can write to its data directories"

    local d failed=0
    for d in servers backups config logs import; do
        if compose exec -T -u "${CRAFTY_UID}:${CRAFTY_GID}" crafty \
                sh -c "mkdir -p /crafty/$d/.mcd-write-test && rmdir /crafty/$d/.mcd-write-test" \
                >/dev/null 2>&1; then
            ok "/crafty/$d writable by uid ${CRAFTY_UID}"
        else
            err "/crafty/$d NOT writable by uid ${CRAFTY_UID}"
            failed=1
        fi
    done

    if [ "$failed" -eq 1 ]; then
        warn ""
        warn "Crafty runs as uid ${CRAFTY_UID} inside the container and cannot write"
        warn "to the directories above, so creating a server will fail. Fix with:"
        warn "    sudo chown ${CRAFTY_UID}:${CRAFTY_GID} $MCD_DATA/{servers,backups,config,logs,import}"
        warn "    sudo mcd restart"
        return 1
    fi
    return 0
}

_mcd_wait_for_crafty() {
    # First run initialises a database and writes default-creds.txt, which can
    # take a couple of minutes on 2 ARM cores.
    info "Waiting for Crafty to finish starting"
    local waited=0 limit=300
    while [ "$waited" -lt "$limit" ]; do
        if [ -s "$MCD_DATA/config/default-creds.txt" ]; then
            ok "Crafty is up (took ${waited}s)"
            return 0
        fi
        if ! compose ps --status running --services 2>/dev/null | grep -qx crafty; then
            die "The Crafty container stopped while starting up." \
                "Read why with: docker compose -f $MCD_ROOT/compose.yaml logs crafty"
        fi
        sleep 5
        waited=$(( waited + 5 ))
    done
    warn "Crafty has not written its credentials file after ${limit}s."
    warn "It may still be initialising. Check: mcd logs"
    return 1
}

_mcd_wait_for_certificate() {
    info "Waiting for the TLS certificate"
    local waited=0 limit=120
    while [ "$waited" -lt "$limit" ]; do
        # Ask over the real hostname so this exercises DNS, the Oracle security
        # list, Caddy, ACME and the proxy hop in one check.
        if curl -fsS --max-time 10 -o /dev/null "https://${MCD_HOSTNAME}/" 2>/dev/null; then
            ok "https://${MCD_HOSTNAME} is live with a valid certificate"
            MCD_TLS_OK=1
            return 0
        fi
        sleep 5
        waited=$(( waited + 5 ))
    done

    MCD_TLS_OK=0
    warn "Could not reach https://${MCD_HOSTNAME} from the server itself after ${limit}s."
    warn ""
    warn "The most common cause by far is the Oracle security list: ports 80 and"
    warn "443 must be open there, separately from the firewall inside the"
    warn "instance. Certificate issuing needs port 80, not just 443."
    warn ""
    warn "Check what Caddy is reporting with:   mcd logs caddy"
    return 1
}
