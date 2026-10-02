#!/usr/bin/env bash
# Preflight: refuse to run anywhere this cannot work, and refuse loudly
# anywhere Oracle will delete the instance out from under the user.

run_preflight() {
    step "Checking this machine"

    # --- OS ---------------------------------------------------------------
    [ -r /etc/os-release ] || die "Cannot read /etc/os-release, so I cannot tell what this system is."
    # shellcheck disable=SC1091
    . /etc/os-release
    MCD_OS_ID="${ID:-unknown}"
    MCD_OS_CODENAME="${VERSION_CODENAME:-}"

    case "$MCD_OS_ID" in
        ubuntu|debian) ok "${PRETTY_NAME:-$MCD_OS_ID}" ;;
        ol|rhel|centos|rocky|almalinux|fedora)
            # Oracle Linux is the *default* image in the OCI console, so this is
            # the single most likely way for someone to end up on the wrong OS:
            # they clicked Create without touching the image picker. Say exactly
            # that, because "unsupported distribution" would leave them guessing
            # at what they did wrong when the answer is "nothing, it is the
            # default". Failing here beats dying at the first apt-get.
            die "This is ${PRETTY_NAME:-$MCD_OS_ID}, which this installer does not support." \
                "" \
                "Oracle Linux is the default image in the Oracle Cloud console, so" \
                "this is easy to end up on without noticing. It uses dnf, firewalld" \
                "and SELinux rather than apt and iptables, and this installer is" \
                "built for Debian-family systems throughout." \
                "" \
                "Rebuild the instance with Canonical Ubuntu 24.04:" \
                "  1. Oracle console -> Compute -> Instances -> Create instance" \
                "  2. Under Image and shape, click 'Change image'" \
                "  3. Choose Canonical Ubuntu, version 24.04" \
                "  4. Shape: Ampere VM.Standard.A1.Flex, 2 OCPUs, 12 GB" \
                "" \
                "Nothing has been changed on this machine."
            ;;
        *)
            warn "This is built and tested for Ubuntu (and should work on Debian)."
            warn "Found: ${PRETTY_NAME:-$MCD_OS_ID}"
            confirm "Continue anyway?" no \
                || die "Stopping. Rebuild the instance with the Canonical Ubuntu 24.04 image."
            ;;
    esac

    if [ -z "$MCD_OS_CODENAME" ]; then
        die "No VERSION_CODENAME in /etc/os-release." \
            "The Docker apt repository is keyed on the codename, so it is required."
    fi

    # --- architecture -----------------------------------------------------
    MCD_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$MCD_ARCH" in
        arm64|aarch64)
            MCD_ARCH=arm64
            MCD_JAVA_ARCH=aarch64
            ok "ARM64 (Ampere A1) — the free shape"
            ;;
        amd64|x86_64)
            MCD_ARCH=amd64
            MCD_JAVA_ARCH=x64
            warn "This is x86_64, not ARM64."
            warn "Oracle's free Minecraft-capable shape is Ampere A1, which is ARM."
            warn "The free x86 shapes (1/8 OCPU, 1 GB) cannot run a Minecraft server."
            confirm "Continue anyway?" no || die "Stopping."
            ;;
        *) die "Unsupported architecture: $MCD_ARCH" ;;
    esac

    # --- memory, and the Oracle free-tier limits --------------------------
    local total_mb cores
    total_mb="$(total_mem_mb)"
    cores="$(nproc)"
    info "Detected ${cores} CPU(s) and ${total_mb} MB RAM"

    if [ "$total_mb" -lt 1800 ]; then
        die "Only ${total_mb} MB of RAM. A Minecraft server needs materially more." \
            "If this is an Oracle free x86 micro instance, it cannot host Minecraft." \
            "Create a VM.Standard.A1.Flex instance with 2 OCPUs and 12 GB instead."
    fi

    # Oracle halved the Always Free A1 allowance to 2 OCPU / 12 GB on
    # 2026-06-15 and started terminating over-limit instances on 2026-08-18.
    # Almost every guide online still says 4 OCPU / 24 GB. Warning here is
    # the single most valuable thing this script does for a new user, because
    # the failure mode is Oracle silently deleting their world.
    if [ "$cores" -gt 2 ] || [ "$total_mb" -gt 13312 ]; then
        printf '\n' >&2
        warn "${C_BOLD}This instance may exceed the Oracle Always Free limits.${C_RESET}"
        warn "Always Free has been 2 OCPU / 12 GB since 15 June 2026."
        warn "This instance has ${cores} OCPU / ${total_mb} MB."
        warn "Oracle has been terminating over-limit instances since 18 August 2026."
        warn ""
        warn "If this tenancy is Always Free, shut the instance down and rebuild"
        warn "it as 2 OCPUs / 12 GB before you put a world on it. If you are on"
        warn "Pay As You Go, you may keep the larger shape and can ignore this."
        printf '\n' >&2
        confirm "I understand the risk — continue?" no \
            || die "Stopping, nothing changed." \
                   "Resize the instance in the Oracle console, then run this again."
    else
        ok "Within the Always Free limits (2 OCPU / 12 GB)"
    fi

    MCD_HEAP_SUGGESTED="$(suggested_heap_mb)"
    if [ "$MCD_HEAP_SUGGESTED" -lt "$MCD_MIN_HEAP_MB" ]; then
        die "After reserving $(reserve_mb) MB for the system there is not enough left for Minecraft." \
            "Total RAM: ${total_mb} MB. Use an instance with at least 4 GB."
    fi
    info "Recommended Minecraft heap: ${MCD_HEAP_SUGGESTED} MB"

    # --- disk -------------------------------------------------------------
    local free_mb
    free_mb="$(df -Pm /opt | awk 'NR==2 {print $4}')"
    if [ "${free_mb:-0}" -lt 6144 ]; then
        die "Only ${free_mb} MB free on /opt. Need at least 6 GB." \
            "Two JDKs, the panel image and a world add up quickly."
    fi
    ok "${free_mb} MB free on /opt"

    # --- network ----------------------------------------------------------
    if ! curl -fsS --max-time 10 -o /dev/null https://api.adoptium.net/v3/info/available_releases; then
        die "Cannot reach api.adoptium.net." \
            "Check the instance has outbound internet (a NAT or internet gateway" \
            "on its subnet route table) before re-running."
    fi
    ok "Outbound internet works"

    export MCD_OS_ID MCD_OS_CODENAME MCD_ARCH MCD_JAVA_ARCH MCD_HEAP_SUGGESTED
}
