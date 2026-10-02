#!/usr/bin/env bash
# Java — the reason this project exists in its current shape.
#
# The stock Crafty image ships only Java 8, 11 and 17, so out of the box the
# panel cannot run anything newer than Minecraft 1.20.4:
#
#   Minecraft 26.x (current)  needs Java 25
#   Minecraft 1.20.5-1.21.11  needs Java 21
#   Minecraft 1.17-1.20.4     needs Java 17   (in the image)
#   Minecraft 1.16.5          needs Java 11   (in the image)
#   Minecraft < 1.16.5        needs Java 8    (in the image)
#
# We install Temurin 21 and 25 on the host and bind-mount them read-only into
# an otherwise untouched Crafty container. Chosen over building a derived
# image because the upstream image stays stock (Crafty only supports its own
# images), there is nothing to rebuild when Crafty publishes a new release,
# and a mounted JDK is unaffected by base-image changes.
#
# The real risk is glibc: a generic Temurin aarch64 tarball must run against
# the container's base distro. That is why this step ends by actually executing
# `java -version` inside the container rather than assuming it works.

_mcd_java_installed_version() {
    # Feature version of an installed JDK, or empty.
    local jdir="$1"
    [ -x "$jdir/bin/java" ] || return 0
    "$jdir/bin/java" -version 2>&1 \
        | awk -F'"' '/version/ {split($2, v, "."); print v[1]; exit}'
}

run_java() {
    step "Installing Java for Minecraft"

    local v jdir url tmp got
    for v in "${JAVA_VERSIONS[@]}"; do
        jdir="$MCD_JAVA/jdk-$v"

        got="$(_mcd_java_installed_version "$jdir")"
        if [ "$got" = "$v" ]; then
            skip "Temurin $v already installed"
            continue
        fi

        # Adoptium's redirector always points at the current GA build, so we
        # never hardcode a patch level that goes stale.
        url="https://api.adoptium.net/v3/binary/latest/${v}/ga/linux/${MCD_JAVA_ARCH}/jdk/hotspot/normal/eclipse"
        info "Downloading Temurin $v for $MCD_JAVA_ARCH"

        tmp="$(mktemp -d)"
        if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/jdk.tar.gz" "$url"; then
            rm -rf -- "${tmp:?}"
            die "Could not download Temurin $v for $MCD_JAVA_ARCH." \
                "Tried: $url" \
                "If Adoptium has no GA build for that pair yet, set" \
                "JAVA_VERSIONS in lib/common.sh to one that exists."
        fi

        rm -rf -- "${jdir:?}.new"
        install -d -m 0755 "$jdir.new"
        tar -xzf "$tmp/jdk.tar.gz" -C "$jdir.new" --strip-components=1 \
            || { rm -rf -- "${tmp:?}" "${jdir:?}.new"; die "Temurin $v archive did not extract."; }
        rm -rf -- "${tmp:?}"

        got="$(_mcd_java_installed_version "$jdir.new")"
        if [ "$got" != "$v" ]; then
            rm -rf -- "${jdir:?}.new"
            die "Extracted Temurin $v reports version '${got:-none}' on the host." \
                "The download may be corrupt or built for another architecture."
        fi

        # Swap in only once it is known good, so a failed run never leaves a
        # half-extracted JDK that a server would then try to start with.
        rm -rf -- "${jdir:?}"
        mv "$jdir.new" "$jdir"
        chmod -R a+rX "$jdir"
        ok "Temurin $v installed to $jdir"
    done

    # A stable name per feature version for the compose mount and for the
    # per-server Java path the panel is told to use.
    cat >"$MCD_STATE/java-map" <<EOT
# Minecraft version range -> Java executable inside the container.
# Set this as the server's Java executable in Crafty when creating a server.
26.x            /opt/java/jdk-25/bin/java
1.20.5-1.21.11  /opt/java/jdk-21/bin/java
1.17-1.20.4     /usr/lib/jvm/java-17-openjdk-${MCD_ARCH}/bin/java
1.16.5          /usr/lib/jvm/java-11-openjdk-${MCD_ARCH}/bin/java
below-1.16.5    /usr/lib/jvm/java-8-openjdk-${MCD_ARCH}/bin/java
EOT
    ok "Version-to-Java map written to $MCD_STATE/java-map"

    conf_set MCD_JAVA_LATEST "/opt/java/jdk-25/bin/java"
    conf_set MCD_JAVA_21 "/opt/java/jdk-21/bin/java"
}

# Run after the container is up: proves the mounted JDKs actually execute
# against the image's glibc. This is the check that decides whether the
# bind-mount approach holds or we need the derived-image fallback.
verify_java_in_container() {
    step "Verifying Java inside the container"

    local v out failed=0
    for v in "${JAVA_VERSIONS[@]}"; do
        if out="$(compose exec -T crafty "/opt/java/jdk-$v/bin/java" -version 2>&1)"; then
            ok "Java $v runs in the container: $(head -n1 <<<"$out")"
        else
            failed=1
            err "Java $v does NOT run inside the container"
            printf '%s\n' "$out" | sed 's/^/        /' >&2
        fi
    done

    if [ "$failed" -eq 1 ]; then
        warn ""
        warn "The mounted JDK will not execute in the container, which is almost"
        warn "certainly a glibc version mismatch with the image's base distro."
        warn "Minecraft 1.20.4 and older will still work using the image's own"
        warn "Java 8/11/17, but newer versions will not start."
        warn ""
        warn "The documented fallback is a thin derived image; see"
        warn "docs/ROADMAP.md, constraint 2. Please open an issue with the error"
        warn "above and the output of: docker compose exec crafty cat /etc/os-release"
        return 1
    fi
    return 0
}
