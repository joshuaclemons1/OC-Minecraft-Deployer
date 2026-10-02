#!/usr/bin/env bash
# Docker Engine + Compose plugin from Docker's own apt repository.
#
# Not docker.io from Ubuntu's archive: that lags, and on arm64 the compose
# plugin packaging there has been inconsistent. Not the get.docker.com
# convenience script either, because it is another curl-to-root-shell and we
# already ask the user for one of those.

run_docker() {
    step "Installing Docker"

    if have docker && docker compose version >/dev/null 2>&1; then
        skip "Docker $(docker --version | awk '{gsub(/,/,""); print $3}') with compose plugin"
    else
        export DEBIAN_FRONTEND=noninteractive

        install -m 0755 -d /etc/apt/keyrings
        if [ ! -s /etc/apt/keyrings/docker.asc ]; then
            curl -fsSL "https://download.docker.com/linux/$MCD_OS_ID/gpg" \
                -o /etc/apt/keyrings/docker.asc \
                || die "Could not download Docker's signing key."
            chmod a+r /etc/apt/keyrings/docker.asc
            ok "Docker signing key installed"
        fi

        local list=/etc/apt/sources.list.d/docker.list
        local line="deb [arch=$MCD_ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$MCD_OS_ID $MCD_OS_CODENAME stable"
        if [ ! -f "$list" ] || ! grep -qxF "$line" "$list"; then
            printf '%s\n' "$line" >"$list"
            ok "Docker apt repository configured"
        fi

        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin >>"$MCD_LOGFILE" 2>&1 \
            || die "Docker installation failed." "See $MCD_LOGFILE"
        ok "Docker installed"
    fi

    systemctl enable --now docker >/dev/null 2>&1 || true
    systemctl is-active --quiet docker \
        || die "Docker is installed but not running." \
               "Investigate with: systemctl status docker"
    ok "Docker service running"

    # Cap log growth. A Minecraft console is chatty and the default json-file
    # driver has no limit, which quietly eats a 50 GB boot volume over months.
    local daemon_json=/etc/docker/daemon.json
    if [ ! -f "$daemon_json" ]; then
        install -d -m 0755 /etc/docker
        cat >"$daemon_json" <<'EOT'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOT
        systemctl restart docker
        ok "Container log rotation configured"
    else
        skip "Existing $daemon_json left untouched"
    fi

    # Let the login user drive docker without sudo. Takes effect on next login.
    local login_user="${SUDO_USER:-}"
    if [ -n "$login_user" ] && [ "$login_user" != "root" ]; then
        if id -nG "$login_user" | tr ' ' '\n' | grep -qx docker; then
            skip "$login_user already in the docker group"
        else
            usermod -aG docker "$login_user"
            ok "Added $login_user to the docker group (log out and back in)"
        fi
    fi
}
