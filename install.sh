#!/usr/bin/env bash
# pi4_home_network_stack_v3_8_1.sh
#
# Raspberry Pi 4B home-network appliance installer
# Target: Raspberry Pi OS Lite 64-bit, 2 GB RAM, 64 GB microSD
#
# Native:
#   - Pi-hole (DNS filtering, DHCP disabled)
#   - Unbound (recursive DNS + DNSSEC)
#   - strict Unbound -> Cloudflare failover watchdog
#   - Tailscale (remote access, Tailscale SSH, subnet routing)
#   - OpenSSH + one-minute SSH health watchdog
#
# Docker:
#   - Uptime Kuma v2
#   - Homepage professional dashboard
#
# Dashboard:
#   http://192.168.0.10:3000
#
# Uptime Kuma:
#   http://192.168.0.10:3001
#
# Pi-hole:
#   http://192.168.0.10/admin/
#
# Router remains the ONLY DHCP server.
#
# The installer is intentionally two-phase:
#   Phase 1 safely stages TARGET_IP without dropping the active SSH connection.
#   Phase 2 runs after reboot on TARGET_IP and installs/configures applications.
#
# Usage:
#   chmod +x pi4_home_network_stack_v3_8_1.sh
#   sudo ./pi4_home_network_stack_v3_8_1.sh
#
# Optional overrides:
#   sudo TARGET_IP=192.168.0.10 \
#        LAN_CIDR=192.168.0.0/24 \
#        ./pi4_home_network_stack_v3_8_1.sh

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# =============================================================================
# Configuration
# =============================================================================

TARGET_IP="${TARGET_IP:-192.168.0.10}"
PREFIX="${PREFIX:-24}"
LAN_CIDR="${LAN_CIDR:-192.168.0.0/24}"

# The Pi host itself deliberately does NOT depend on Pi-hole/Unbound.
HOST_DNS_1="${HOST_DNS_1:-1.1.1.1}"
HOST_DNS_2="${HOST_DNS_2:-9.9.9.9}"

# Used only when Unbound has failed its health check and restart attempt.
FALLBACK_DNS_1="${FALLBACK_DNS_1:-1.1.1.1}"
FALLBACK_DNS_2="${FALLBACK_DNS_2:-1.0.0.1}"

UNBOUND_PORT="${UNBOUND_PORT:-5335}"
DASHBOARD_PORT="${DASHBOARD_PORT:-3000}"
UPTIME_KUMA_PORT="${UPTIME_KUMA_PORT:-3001}"
STATUS_API_PORT="${STATUS_API_PORT:-9108}"
KUMA_STATUS_SLUG="${KUMA_STATUS_SLUG:-home-network}"
KUMA_CACHE_SECONDS="${KUMA_CACHE_SECONDS:-8}"

# Leave blank to keep the OS's current timezone.
TIMEZONE="${TIMEZONE:-}"

STATE_DIR="/var/lib/pi4-network-stack"
SSH_BACKUP="${STATE_DIR}/ssh-known-good.tgz"
DNS_MODE_FILE="${STATE_DIR}/dns-upstream-mode"
STATUS_TOKEN_FILE="${STATE_DIR}/dashboard-api-token"

APPS_DIR="/opt/home-network"
HOMEPAGE_DIR="${APPS_DIR}/homepage"
UPTIME_DIR="${APPS_DIR}/uptime-kuma"

PIHOLE_INSTALLER="/var/tmp/pihole-basic-install.sh"

# =============================================================================
# Helpers
# =============================================================================

log() {
    printf '\n\033[1;32m[+]\033[0m %s\n' "$*"
}

info() {
    printf '    %s\n' "$*"
}

warn() {
    printf '\n\033[1;33m[!]\033[0m %s\n' "$*" >&2
}

die() {
    printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

on_error() {
    local rc=$?
    warn "Installer stopped at line ${BASH_LINENO[0]} with exit code ${rc}."
    warn "The script does not intentionally bring Ethernet down during setup."
    exit "${rc}"
}
trap on_error ERR

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this script with sudo."
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

primary_ipv4() {
    ip -4 route get 1.1.1.1 2>/dev/null |
        sed -n 's/.* src \([^ ]*\).*/\1/p' |
        head -n1
}

has_ipv4() {
    local iface="$1"
    local address="$2"

    ip -4 -o addr show dev "${iface}" scope global |
        awk '{print $4}' |
        cut -d/ -f1 |
        grep -Fx "${address}" >/dev/null
}

retry() {
    local attempts="$1"
    local delay="$2"
    shift 2

    local n
    for n in $(seq 1 "${attempts}"); do
        if "$@"; then
            return 0
        fi
        (( n < attempts )) && sleep "${delay}"
    done
    return 1
}

# =============================================================================
# Platform / network preflight
# =============================================================================

preflight() {
    require_root

    command_exists systemctl || die "systemd is required."
    command_exists nmcli || die \
        "NetworkManager is required. Use a current Raspberry Pi OS release."

    source /etc/os-release

    MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
    ARCH="$(dpkg --print-architecture)"
    RAM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    FREE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"

    log "Hardware / operating-system preflight"
    info "Model        : ${MODEL:-unknown}"
    info "OS           : ${PRETTY_NAME:-unknown}"
    info "Architecture : ${ARCH}"
    info "RAM visible  : $(( RAM_KB / 1024 )) MB"
    info "Free storage : $(( FREE_KB / 1024 )) MB"

    [[ "${ARCH}" == "arm64" ]] ||
        die "Use Raspberry Pi OS Lite 64-bit (arm64) for this Pi 4 build."

    if [[ "${MODEL}" != *"Raspberry Pi 4 Model B"* ]]; then
        warn "This installer is tuned for a Raspberry Pi 4 Model B."
    fi

    (( RAM_KB >= 1000000 )) ||
        warn "Less than about 1 GB RAM is visible to Linux."

    (( FREE_KB >= 8388608 )) ||
        die "At least 8 GB free storage is required for this stack."

    mkdir -p "${STATE_DIR}" "${APPS_DIR}"
    chmod 700 "${STATE_DIR}"

    if [[ -n "${TIMEZONE}" ]]; then
        timedatectl set-timezone "${TIMEZONE}"
    fi

    ETH_IF="$(
        nmcli -t -f DEVICE,TYPE,STATE device status |
        awk -F: '$2=="ethernet" && $3=="connected" {print $1; exit}'
    )"

    if [[ -z "${ETH_IF}" ]]; then
        ETH_IF="$(
            nmcli -t -f DEVICE,TYPE device status |
            awk -F: '$2=="ethernet" {print $1; exit}'
        )"
    fi

    [[ -n "${ETH_IF}" ]] || die "No Ethernet interface was detected."

    NM_CONNECTION="$(
        nmcli -g GENERAL.CONNECTION device show "${ETH_IF}" |
        head -n1
    )"

    [[ -n "${NM_CONNECTION}" && "${NM_CONNECTION}" != "--" ]] ||
        die "No active NetworkManager profile found for ${ETH_IF}."

    GATEWAY="$(
        ip -4 route show default dev "${ETH_IF}" |
        awk '/default/ {print $3; exit}'
    )"

    [[ -n "${GATEWAY}" ]] ||
        die "No IPv4 gateway was detected on ${ETH_IF}."

    CURRENT_IP="$(primary_ipv4)"
    CURRENT_ADDRS="$(
        ip -4 -o addr show dev "${ETH_IF}" scope global |
        awk '{print $4}' |
        paste -sd, -
    )"

    HOSTNAME_SHORT="$(hostname -s)"

    log "Network preflight"
    info "Ethernet     : ${ETH_IF}"
    info "NM profile   : ${NM_CONNECTION}"
    info "Current IPv4 : ${CURRENT_ADDRS:-none}"
    info "Primary IPv4 : ${CURRENT_IP:-unknown}"
    info "Gateway      : ${GATEWAY}"
    info "Target IPv4  : ${TARGET_IP}/${PREFIX}"
    info "LAN          : ${LAN_CIDR}"
}

# =============================================================================
# Host DNS recovery
# =============================================================================

configure_host_dns() {
    log "Ensuring independent DNS for the Pi host"

    nmcli connection modify "${NM_CONNECTION}" \
        ipv4.ignore-auto-dns yes \
        ipv4.dns "${HOST_DNS_1} ${HOST_DNS_2}"

    # NetworkManager reapply does not intentionally tear down the connection.
    nmcli device reapply "${ETH_IF}" >/dev/null 2>&1 || true

    if getent ahostsv4 deb.debian.org >/dev/null 2>&1; then
        info "Host DNS is working."
        return
    fi

    if ! ping -c 1 -W 3 "${HOST_DNS_1}" >/dev/null 2>&1; then
        die "Internet routing is unavailable. Check the router/gateway."
    fi

    warn "Internet works but DNS does not. Applying temporary resolver recovery."
    cp -a /etc/resolv.conf "${STATE_DIR}/resolv.conf.before" 2>/dev/null || true

    # Preserve an existing symlink by writing through it.
    printf 'nameserver %s\nnameserver %s\n' \
        "${HOST_DNS_1}" "${HOST_DNS_2}" >/etc/resolv.conf

    getent ahostsv4 deb.debian.org >/dev/null 2>&1 ||
        die "DNS still fails after applying recovery resolvers."
}

# =============================================================================
# ALL prerequisites before applications
# =============================================================================

install_all_prerequisites() {
    log "Installing ALL base prerequisites before application packages"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    # Pi-hole's current Debian dependency meta-package requirements, plus
    # networking/dashboard installer prerequisites used by this script.
    apt-get install -y --no-install-recommends \
        arp-scan \
        avahi-utils \
        bash-completion \
        binutils \
        ca-certificates \
        cron \
        curl \
        dialog \
        bind9-dnsutils \
        dns-root-data \
        gawk \
        git \
        gnupg \
        grep \
        iproute2 \
        iputils-arping \
        iputils-ping \
        jq \
        libcap2 \
        libcap2-bin \
        logrotate \
        lsb-release \
        lshw \
        nmap \
        openssh-server \
        procps \
        psmisc \
        python3 \
        sudo \
        tzdata \
        unzip

    systemctl enable --now cron
    systemctl enable --now ssh

    local required=(
        arping arp-scan avahi-browse awk curl dig git gpg ip jq nmcli nmap ping python3
        ssh sshd systemctl
    )

    local tool
    for tool in "${required[@]}"; do
        command_exists "${tool}" ||
            die "Prerequisite verification failed: ${tool} is missing."
    done

    export -n DEBIAN_FRONTEND

    date -Is >"${STATE_DIR}/prerequisites.complete"
    info "Prerequisite stage verified."
}

# =============================================================================
# SSH resilience
# =============================================================================

configure_ssh_resilience() {
    log "Configuring SSH resilience"

    SSHD_BIN="$(command -v sshd)"
    "${SSHD_BIN}" -t || die "Current sshd configuration is invalid."

    if [[ ! -f "${SSH_BACKUP}" ]]; then
        local ssh_paths=(etc/ssh/sshd_config)
        [[ -d /etc/ssh/sshd_config.d ]] &&
            ssh_paths+=(etc/ssh/sshd_config.d)

        tar -C / -czf "${SSH_BACKUP}" "${ssh_paths[@]}"
        chmod 600 "${SSH_BACKUP}"
    fi

    mkdir -p /etc/systemd/system/ssh.service.d

    cat >/etc/systemd/system/ssh.service.d/10-resilience.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=5s
EOF

    # Newer OpenSSH releases may implement pre-auth source penalties.
    # Add the exemption only when the installed daemon supports it.
    mkdir -p /etc/ssh/sshd_config.d

    if "${SSHD_BIN}" -T 2>/dev/null |
       grep -i '^persourcepenaltyexemptlist ' >/dev/null; then
        cat >/etc/ssh/sshd_config.d/90-trusted-lan.conf <<EOF
PerSourcePenaltyExemptList 127.0.0.0/8,::1,${LAN_CIDR}
EOF

        if ! "${SSHD_BIN}" -t; then
            rm -f /etc/ssh/sshd_config.d/90-trusted-lan.conf
            warn "OpenSSH rejected the LAN penalty exemption; it was removed."
        fi
    fi

    # If the administrator already uses Fail2Ban, preserve LAN access.
    if command_exists fail2ban-client; then
        mkdir -p /etc/fail2ban/jail.d
        cat >/etc/fail2ban/jail.d/99-trusted-lan.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${LAN_CIDR}
EOF
        systemctl try-restart fail2ban.service >/dev/null 2>&1 || true
    fi

    cat >/usr/local/sbin/ssh-watchdog.sh <<'EOF'
#!/usr/bin/env bash
set -u

STATE_DIR="/var/lib/pi4-network-stack"
SSH_BACKUP="${STATE_DIR}/ssh-known-good.tgz"
SSHD_BIN="$(command -v sshd)"

restore_known_good() {
    [[ -r "${SSH_BACKUP}" ]] || return 1
    logger -t ssh-watchdog "Restoring last known-good SSH configuration"
    tar -xzf "${SSH_BACKUP}" -C / || return 1
    "${SSHD_BIN}" -t || return 1
    systemctl restart ssh
}

if ! "${SSHD_BIN}" -t >/dev/null 2>&1; then
    logger -t ssh-watchdog "Invalid sshd configuration detected"

    # Do not restart a working daemon with invalid new config.
    if ! systemctl is-active --quiet ssh; then
        restore_known_good
    fi
    exit 1
fi

if ! systemctl is-active --quiet ssh; then
    logger -t ssh-watchdog "ssh.service is inactive; restarting"
    systemctl restart ssh || restore_known_good
fi

PROBE_IP="$(
    ip -4 route get 1.1.1.1 2>/dev/null |
    sed -n 's/.* src \([^ ]*\).*/\1/p' |
    head -n1
)"
[[ -n "${PROBE_IP}" ]] || PROBE_IP="127.0.0.1"

# Catch the failure mode where TCP/22 opens but no SSH banner is returned.
if ! timeout 5 bash -c "
    exec 3<>/dev/tcp/${PROBE_IP}/22
    IFS= read -r -t 4 line <&3
    [[ \"\$line\" == SSH-* ]]
" >/dev/null 2>&1; then
    logger -t ssh-watchdog \
        "No valid SSH banner on ${PROBE_IP}:22; restarting ssh"
    systemctl restart ssh || restore_known_good
fi
EOF

    chmod 0755 /usr/local/sbin/ssh-watchdog.sh

    cat >/etc/systemd/system/ssh-watchdog.service <<'EOF'
[Unit]
Description=Verify that SSH is accepting protocol connections
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ssh-watchdog.sh
EOF

    cat >/etc/systemd/system/ssh-watchdog.timer <<'EOF'
[Unit]
Description=Run SSH health check every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=ssh-watchdog.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable ssh >/dev/null
    systemctl enable --now ssh-watchdog.timer >/dev/null

    "${SSHD_BIN}" -t
    systemctl is-active --quiet ssh ||
        die "SSH is not active after resilience configuration."
}

# =============================================================================
# Maintenance
# =============================================================================

configure_maintenance() {
    log "Configuring scheduled maintenance"

    if [[ ! -f "${STATE_DIR}/reboot-anchor-day" ]]; then
        echo "$(( $(date -u +%s) / 86400 ))" \
            >"${STATE_DIR}/reboot-anchor-day"
    fi

    cat >/usr/local/sbin/reboot-every-48h.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="/var/lib/pi4-network-stack"
ANCHOR="${STATE_DIR}/reboot-anchor-day"

[[ -r "${ANCHOR}" ]] || exit 0

anchor_day="$(cat "${ANCHOR}")"
today="$(( $(date -u +%s) / 86400 ))"
delta="$(( today - anchor_day ))"

if (( delta > 0 && delta % 2 == 0 )); then
    logger -t pi-maintenance "Scheduled alternate-day 03:00 reboot"
    /usr/bin/systemctl reboot
fi
EOF
    chmod 0755 /usr/local/sbin/reboot-every-48h.sh

    cat >/etc/tmpfiles.d/pi4-network-stack.conf <<'EOF'
d /tmp 1777 root root 1d -
EOF

    cat >/etc/cron.d/pi4-network-maintenance <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 3 * * * root /usr/local/sbin/reboot-every-48h.sh
15 4 * * * root /usr/bin/systemd-tmpfiles --clean
EOF

    chmod 0644 /etc/cron.d/pi4-network-maintenance

    mkdir -p /etc/systemd/journald.conf.d
    cat >/etc/systemd/journald.conf.d/20-sd-card-limits.conf <<'EOF'
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
MaxRetentionSec=14day
EOF

    systemctl restart cron
    systemctl restart systemd-journald
}

# =============================================================================
# Two-phase static IPv4 migration
# =============================================================================

stage_static_ip_if_needed() {
    CURRENT_IP="$(primary_ipv4)"

    if [[ "${CURRENT_IP}" == "${TARGET_IP}" ]]; then
        return 0
    fi

    log "PHASE 1: staging ${TARGET_IP}/${PREFIX} safely"

    if ! has_ipv4 "${ETH_IF}" "${TARGET_IP}"; then
        info "Checking that ${TARGET_IP} is unused."

        # iputils arping -D exits 0 when no duplicate address answers.
        if ! arping -D -I "${ETH_IF}" -c 3 -w 5 \
            "${TARGET_IP}" >/dev/null 2>&1; then
            die "${TARGET_IP} may already be in use on the LAN."
        fi

        ip addr add "${TARGET_IP}/${PREFIX}" dev "${ETH_IF}"
    fi

    nmcli connection show "${NM_CONNECTION}" \
        >"${STATE_DIR}/networkmanager-before.txt" || true

    nmcli connection modify "${NM_CONNECTION}" \
        ipv4.method manual \
        ipv4.addresses "${TARGET_IP}/${PREFIX}" \
        ipv4.gateway "${GATEWAY}" \
        ipv4.dns "${HOST_DNS_1} ${HOST_DNS_2}" \
        ipv4.ignore-auto-dns yes \
        ipv4.may-fail no \
        connection.autoconnect yes \
        connection.autoconnect-priority 100

    "${SSHD_BIN}" -t
    systemctl is-active --quiet ssh ||
        die "SSH is not active. Do not reboot."

    cat <<EOF

========================================================================
PHASE 1 COMPLETE

Prerequisites, SSH recovery and maintenance are installed.

The Pi should now answer on BOTH:
  current : ${CURRENT_IP}
  target  : ${TARGET_IP}

KEEP THIS SSH WINDOW OPEN.

From a SECOND Mac terminal:
  ssh ${SUDO_USER:-pi}@${TARGET_IP}

If that succeeds, ensure ${TARGET_IP} is reserved/excluded in your router's
DHCP pool, then reboot manually:
  sudo reboot

Reconnect:
  ssh ${SUDO_USER:-pi}@${TARGET_IP}

Then run this same script again:
  sudo bash $0

Applications are installed only during Phase 2.
========================================================================
EOF

    exit 0
}

verify_phase2_network() {
    log "PHASE 2: verifying permanent network"

    has_ipv4 "${ETH_IF}" "${TARGET_IP}" ||
        die "${TARGET_IP} is not active on ${ETH_IF}."

    retry 3 2 ping -c 1 -W 3 "${GATEWAY}" >/dev/null ||
        die "Gateway ${GATEWAY} is unreachable."

    retry 3 2 ping -c 1 -W 3 "${HOST_DNS_1}" >/dev/null ||
        die "Internet connectivity test failed."

    retry 3 2 getent ahostsv4 deb.debian.org >/dev/null ||
        die "Host DNS resolution failed."

    "${SSHD_BIN}" -t
    /usr/local/sbin/ssh-watchdog.sh ||
        die "SSH health validation failed."

    info "Permanent network validation passed."
}

# =============================================================================
# Tailscale
# =============================================================================

install_tailscale() {
    log "Installing/configuring Tailscale recovery access"

    if ! command_exists tailscale; then
        local installer="/var/tmp/tailscale-install.sh"
        curl -fsSL https://tailscale.com/install.sh -o "${installer}"
        chmod 0700 "${installer}"
        sh "${installer}"
    fi

    systemctl enable --now tailscaled

    cat >/etc/sysctl.d/99-tailscale-subnet-router.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
    sysctl -p /etc/sysctl.d/99-tailscale-subnet-router.conf >/dev/null

    if tailscale status >/dev/null 2>&1; then
        tailscale set \
            --accept-dns=false \
            --advertise-routes="${LAN_CIDR}" \
            --ssh
        return
    fi

    if [[ -t 0 ]]; then
        cat <<EOF

Tailscale authentication is next.
Open the login URL it provides on your Mac and approve this Pi.

This Pi will advertise:
  ${LAN_CIDR}

Tailscale DNS override on the Pi will remain disabled.
Tailscale SSH will be enabled.

EOF
        tailscale up \
            --accept-dns=false \
            --advertise-routes="${LAN_CIDR}" \
            --ssh || warn "Tailscale setup was not completed."
    else
        warn "Tailscale is installed but not authenticated."
    fi
}

# =============================================================================
# Unbound recursive DNS
# =============================================================================

unbound_query_ok() {
    dig @"127.0.0.1" -p "${UNBOUND_PORT}" \
        cloudflare.com A \
        +time=4 +tries=1 +short 2>/dev/null |
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null
}

install_unbound() {
    log "Installing Unbound recursive DNS"

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends unbound
    export -n DEBIAN_FRONTEND

    # Pi-hole's Unbound guide requires preventing resolvconf from replacing the
    # host resolver with 127.0.0.1 without the custom port.
    if systemctl list-unit-files unbound-resolvconf.service \
       >/dev/null 2>&1; then
        systemctl disable --now unbound-resolvconf.service \
            >/dev/null 2>&1 || true
    fi

    if [[ -f /etc/resolvconf.conf ]]; then
        sed -Ei 's/^unbound_conf=/#unbound_conf=/' /etc/resolvconf.conf
    fi
    rm -f /etc/unbound/unbound.conf.d/resolvconf_resolvers.conf

    mkdir -p /etc/unbound/unbound.conf.d

    cat >/etc/unbound/unbound.conf.d/pi-hole.conf <<EOF
server:
    verbosity: 0

    interface: 127.0.0.1
    port: ${UNBOUND_PORT}

    do-ip4: yes
    do-udp: yes
    do-tcp: yes

    # DNS records for IPv6 are still resolved; this only disables IPv6
    # transport from Unbound itself. Change to yes if native IPv6 is desired.
    do-ip6: no
    prefer-ip6: no

    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no

    edns-buffer-size: 1232
    prefetch: yes
    num-threads: 1
    so-rcvbuf: 1m

    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: fd00::/8
    private-address: fe80::/10

    private-address: 192.0.2.0/24
    private-address: 198.51.100.0/24
    private-address: 203.0.113.0/24
    private-address: 255.255.255.255/32
    private-address: 2001:db8::/32
EOF

    cat >/etc/sysctl.d/99-unbound.conf <<'EOF'
net.core.rmem_max=1048576
EOF
    sysctl -w net.core.rmem_max=1048576 >/dev/null

    unbound-checkconf

    # If Pi-hole already existed before Unbound, Debian may have attempted to
    # auto-start Unbound during package installation with the package default
    # listener on localhost:53. Pi-hole already owns port 53, so those attempts
    # can trip systemd's start-rate limit before this port-5335 config exists.
    # Clear the stale failed/rate-limit state only after the final config passes.
    systemctl reset-failed unbound.service || true
    systemctl enable unbound >/dev/null
    systemctl restart unbound

    retry 3 3 unbound_query_ok ||
        die "Unbound started but could not complete a recursive DNS query."

    log "Testing Unbound DNSSEC validation"

    local bad good
    bad="$(
        dig fail01.dnssec.works @"127.0.0.1" -p "${UNBOUND_PORT}" \
            +time=5 +tries=1 2>/dev/null || true
    )"

    good="$(
        dig +ad dnssec.works @"127.0.0.1" -p "${UNBOUND_PORT}" \
            +time=5 +tries=1 2>/dev/null || true
    )"

    grep -q 'status: SERVFAIL' <<<"${bad}" ||
        warn "DNSSEC negative validation did not return SERVFAIL."

    grep -q 'status: NOERROR' <<<"${good}" ||
        die "Unbound DNSSEC positive validation did not return NOERROR."

    grep -E 'flags:.*\bad\b' <<<"${good}" >/dev/null ||
        die "Unbound response did not contain the DNSSEC AD flag."

    info "Unbound recursive resolution and DNSSEC validation passed."
}

# =============================================================================
# Pi-hole
# =============================================================================

install_pihole() {
    if ! command_exists pihole; then
        log "Installing Pi-hole"

        [[ -t 0 ]] ||
            die "Pi-hole's official installer is interactive. Run from a terminal."

        curl -fsSL https://install.pi-hole.net -o "${PIHOLE_INSTALLER}"
        chmod 0700 "${PIHOLE_INSTALLER}"

        cat <<EOF

Pi-hole's official installer will open.

Choose:
  Interface       : ${ETH_IF}
  Static IP       : Continue / ${TARGET_IP}
  Temporary DNS   : Cloudflare is fine
  Web interface   : Yes
  DHCP            : do NOT enable

After installation this script will automatically switch Pi-hole upstream DNS
to Unbound at 127.0.0.1#${UNBOUND_PORT} and explicitly disable Pi-hole DHCP.

EOF

        bash "${PIHOLE_INSTALLER}"
    else
        log "Pi-hole already installed"
    fi

    command_exists pihole ||
        die "Pi-hole installation did not complete."

    command_exists pihole-FTL ||
        die "pihole-FTL command is missing."

    log "Configuring Pi-hole -> Unbound"

    pihole-FTL --config dhcp.active false
    pihole-FTL --config dns.upstreams \
        "[\"127.0.0.1#${UNBOUND_PORT}\"]"

    # Unbound performs DNSSEC validation.
    pihole-FTL --config dns.dnssec false

    systemctl restart pihole-FTL
    sleep 2

    systemctl is-active --quiet pihole-FTL ||
        die "pihole-FTL failed to start."

    dig @"${TARGET_IP}" example.com A \
        +time=4 +tries=1 >/dev/null ||
        die "Pi-hole direct DNS query failed."

    echo "unbound" >"${DNS_MODE_FILE}"

    # Reassert independent host DNS after Pi-hole installation.
    nmcli connection modify "${NM_CONNECTION}" \
        ipv4.ignore-auto-dns yes \
        ipv4.dns "${HOST_DNS_1} ${HOST_DNS_2}"
    nmcli device reapply "${ETH_IF}" >/dev/null 2>&1 || true

    pihole status || true
}

# =============================================================================
# Strict Unbound -> Cloudflare failover
# =============================================================================

install_dns_failover_watchdog() {
    log "Installing strict Unbound/Cloudflare DNS failover"

    cat >/usr/local/sbin/unbound-failover.sh <<EOF
#!/usr/bin/env bash
set -u

UNBOUND_PORT="${UNBOUND_PORT}"
MODE_FILE="${DNS_MODE_FILE}"
FALLBACK_1="${FALLBACK_DNS_1}"
FALLBACK_2="${FALLBACK_DNS_2}"

query_unbound() {
    dig @127.0.0.1 -p "\${UNBOUND_PORT}" \
        cloudflare.com A +time=3 +tries=1 +short 2>/dev/null |
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null
}

current_mode() {
    if [[ -r "\${MODE_FILE}" ]]; then
        cat "\${MODE_FILE}"
    else
        printf 'unbound\n'
    fi
}

set_unbound() {
    pihole-FTL --config dns.upstreams \
        "[\"127.0.0.1#\${UNBOUND_PORT}\"]" >/dev/null
    systemctl restart pihole-FTL
    printf 'unbound\n' >"\${MODE_FILE}"
    logger -t dns-failover "Pi-hole upstream restored to Unbound"
}

set_cloudflare() {
    pihole-FTL --config dns.upstreams \
        "[\"\${FALLBACK_1}\",\"\${FALLBACK_2}\"]" >/dev/null
    systemctl restart pihole-FTL
    printf 'cloudflare\n' >"\${MODE_FILE}"
    logger -t dns-failover \
        "Unbound unhealthy; Pi-hole upstream switched to Cloudflare"
}

command -v pihole-FTL >/dev/null 2>&1 || exit 0

if systemctl is-active --quiet unbound && query_unbound; then
    if [[ "\$(current_mode)" != "unbound" ]]; then
        set_unbound
    fi
    exit 0
fi

logger -t dns-failover "Unbound health check failed; attempting restart"
systemctl restart unbound
sleep 3

if query_unbound; then
    if [[ "\$(current_mode)" != "unbound" ]]; then
        set_unbound
    fi
    exit 0
fi

if [[ "\$(current_mode)" != "cloudflare" ]]; then
    set_cloudflare
fi
EOF

    chmod 0755 /usr/local/sbin/unbound-failover.sh

    cat >/etc/systemd/system/unbound-failover.service <<'EOF'
[Unit]
Description=Pi-hole Unbound health check and Cloudflare fallback
After=network-online.target unbound.service pihole-FTL.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/unbound-failover.sh
EOF

    cat >/etc/systemd/system/unbound-failover.timer <<'EOF'
[Unit]
Description=Check Unbound every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=unbound-failover.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now unbound-failover.timer
}

# =============================================================================
# Docker
# =============================================================================

install_docker() {
    if command_exists docker &&
       docker version >/dev/null 2>&1 &&
       docker compose version >/dev/null 2>&1; then
        log "Docker Engine already installed"
        systemctl enable --now docker
        return
    fi

    log "Installing Docker Engine from Docker's Debian arm64 repository"

    local conflicts=(
        docker.io docker-doc docker-compose podman-docker containerd runc
    )

    local installed=()
    local pkg

    for pkg in "${conflicts[@]}"; do
        if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null |
           grep -F 'install ok installed' >/dev/null; then
            installed+=("${pkg}")
        fi
    done

    if ((${#installed[@]})); then
        apt-get remove -y "${installed[@]}"
    fi

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    source /etc/os-release
    local codename="${VERSION_CODENAME:-}"
    [[ -n "${codename}" ]] ||
        die "Could not determine Debian codename for Docker."

    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${codename}
Components: stable
Architectures: arm64
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker

    docker version >/dev/null
    docker compose version >/dev/null
}

# =============================================================================
# Safe LAN network discovery
# =============================================================================

install_network_discovery() {
    log "Installing automatic conservative LAN network discovery"

    cat >/usr/local/sbin/pi-network-discover <<'PI_NETWORK_DISCOVER_PY'
#!/usr/bin/env python3
"""Automatic, conservative LAN discovery for the Pi home-network dashboard.

Discovery never creates or changes Uptime Kuma monitors. Automatic suggestions are
based only on observed network evidence. Persistent manual overrides remain
authoritative and are never overwritten by later scans.
"""

from __future__ import annotations

import argparse
import datetime as dt
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

STATE_FILE = Path(os.environ.get("DISCOVERY_STATE_FILE", "/var/lib/pi4-network-stack/network-discovery.json"))
DEFAULTS_FILE = Path("/etc/default/pi-network-status-api")
INVENTORY_CMD = Path("/usr/local/sbin/pi-device-inventory")

GROUPS = {
    "infrastructure": "Infrastructure",
    "storage": "Storage & Servers",
    "smart-home": "Smart Home & IoT",
    "security": "Cameras & Security",
    "services": "Services",
    "websites": "Websites",
    "other": "Other Devices",
    "unclassified": "Unclassified",
}

TYPE_TO_GROUP = {
    "access-point": "infrastructure",
    "router": "infrastructure",
    "switch": "infrastructure",
    "network-device": "infrastructure",
    "modem": "infrastructure",
    "nas": "storage",
    "storage": "storage",
    "server": "storage",
    "raspberry-pi": "infrastructure",
    "smart-home": "smart-home",
    "iot": "smart-home",
    "sensor": "smart-home",
    "bridge": "smart-home",
    "tv": "smart-home",
    "speaker": "smart-home",
    "camera": "security",
    "nvr": "security",
    "security": "security",
    "dns": "services",
    "service": "services",
    "website": "websites",
    "printer": "other",
    "other": "other",
}

SCAN_PORTS = [22, 53, 80, 443, 445, 548, 554, 631, 1883, 3000, 3001, 5000, 5001, 8000, 8080, 8123, 8443, 8883, 8899, 9100, 32400]
NETWORK_VENDOR_HINTS = (
    "ubiquiti", "cisco", "aruba", "mikrotik", "juniper", "ruckus",
    "netgear", "tp-link", "tplink", "zyxel", "extreme networks",
)
STORAGE_VENDOR_HINTS = ("synology", "qnap", "asustor", "western digital", "wdc")
PRINTER_MDNS = {"_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp"}
STORAGE_MDNS = {"_adisk._tcp", "_afpovertcp._tcp"}
CAMERA_MDNS = {"_onvif._tcp"}
SMART_MDNS = {
    "_hap._tcp", "_home-assistant._tcp", "_googlecast._tcp", "_spotify-connect._tcp",
    "_sonos._tcp", "_matter._tcp", "_matterc._udp", "_hue._tcp",
}


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def read_defaults() -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        for raw in DEFAULTS_FILE.read_text().splitlines():
            raw = raw.strip()
            if not raw or raw.startswith("#") or "=" not in raw:
                continue
            key, value = raw.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return values


def default_state() -> dict:
    return {"version": 1, "last_scan": None, "last_interface": None, "last_network": None, "devices": {}}


def load_state() -> dict:
    try:
        data = json.loads(STATE_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        data = default_state()
    if not isinstance(data, dict):
        data = default_state()
    data.setdefault("version", 1)
    data.setdefault("devices", {})
    return data


def save_state(data: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(STATE_FILE.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, STATE_FILE)


def run(cmd: list[str], timeout: int = 30, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=check)


def detect_interface_network() -> tuple[str, str, str, str]:
    defaults = read_defaults()
    target_ip = defaults.get("TARGET_IP", "")
    gateway = defaults.get("GATEWAY", "")

    route = run(["ip", "-4", "route", "show", "default"], timeout=5).stdout.splitlines()
    interface = ""
    if route:
        parts = route[0].split()
        if "dev" in parts:
            interface = parts[parts.index("dev") + 1]
        if not gateway and "via" in parts:
            gateway = parts[parts.index("via") + 1]
    if not interface:
        raise SystemExit("Could not determine the active IPv4 interface.")

    addr_lines = run(["ip", "-4", "-o", "addr", "show", "dev", interface, "scope", "global"], timeout=5).stdout.splitlines()
    if not addr_lines:
        raise SystemExit(f"No IPv4 address found on {interface}.")
    cidr = addr_lines[0].split()[3]
    iface = ipaddress.ip_interface(cidr)
    network = str(iface.network)
    own_ip = target_ip or str(iface.ip)
    return interface, network, gateway, own_ip


def normalize_mac(value: str) -> str | None:
    value = value.lower().strip()
    if re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", value):
        return value
    return None


def local_host_record(interface: str, own_ip: str, stamp: str) -> dict:
    """Build a deterministic record for the Raspberry Pi running the scanner."""
    try:
        mac = normalize_mac(Path(f"/sys/class/net/{interface}/address").read_text().strip()) or ""
    except Exception:
        mac = ""
    try:
        model = Path("/proc/device-tree/model").read_bytes().replace(b"\x00", b"").decode(errors="replace").strip()
    except Exception:
        model = "Raspberry Pi"
    return {
        "ip": own_ip,
        "mac": mac,
        "vendor": "Raspberry Pi",
        "hostname": socket.gethostname(),
        "model": model,
        "mdns": [],
        "open_ports": [],
        "suggested_type": "raspberry-pi",
        "suggested_group": "infrastructure",
        "confidence": 1.0,
        "evidence": [f"Local host running on {interface}: {model}"],
        "last_seen": stamp,
        "present": True,
        "local_host": True,
    }


def modem_ip_from_state(state: dict) -> str:
    """Return an explicitly classified modem IPv4 address; never infer one."""
    candidates = []
    for record in (state.get("devices") or {}).values():
        if not isinstance(record, dict):
            continue
        dtype = record.get("manual_type") or record.get("approved_type")
        if not dtype and float(record.get("confidence") or 0.0) >= 0.85:
            dtype = record.get("suggested_type")
        if dtype != "modem":
            continue
        ip = str(record.get("ip") or "").strip()
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if addr.version == 4:
            candidates.append((0 if record.get("present") else 1, int(addr), ip))
    return sorted(candidates)[0][2] if candidates else ""


def arp_discover(interface: str) -> dict[str, dict]:
    if shutil.which("arp-scan") is None:
        raise SystemExit("arp-scan is not installed.")
    proc = run(["arp-scan", "--interface", interface, "--localnet", "--plain", "--ignoredups"], timeout=90)
    if proc.returncode not in (0, 1):
        raise SystemExit(f"arp-scan failed: {proc.stderr.strip()}")
    found: dict[str, dict] = {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            parts = re.split(r"\s+", line.strip(), maxsplit=2)
        if len(parts) < 2:
            continue
        ip = parts[0].strip()
        mac = normalize_mac(parts[1])
        try:
            ipaddress.ip_address(ip)
        except ValueError:
            continue
        if not mac:
            continue
        vendor = parts[2].strip() if len(parts) >= 3 else ""
        found[ip] = {"ip": ip, "mac": mac, "vendor": vendor}
    return found


def neighbor_fallback(interface: str) -> dict[str, dict]:
    found: dict[str, dict] = {}
    proc = run(["ip", "neigh", "show", "dev", interface], timeout=5)
    for line in proc.stdout.splitlines():
        parts = line.split()
        if not parts:
            continue
        ip = parts[0]
        mac = None
        if "lladdr" in parts:
            idx = parts.index("lladdr")
            if idx + 1 < len(parts):
                mac = normalize_mac(parts[idx + 1])
        if mac:
            found[ip] = {"ip": ip, "mac": mac, "vendor": ""}
    return found


def reverse_hostname(ip: str) -> str:
    try:
        proc = run(["getent", "hosts", ip], timeout=2)
        if proc.returncode == 0 and proc.stdout.strip():
            parts = proc.stdout.split()
            if len(parts) >= 2:
                return parts[1].rstrip(".")
    except Exception:
        pass
    return ""


def avahi_services() -> dict[str, list[dict]]:
    result: dict[str, list[dict]] = {}
    if shutil.which("avahi-browse") is None:
        return result
    try:
        proc = run(["avahi-browse", "-artp", "--terminate"], timeout=20)
    except Exception:
        return result
    for line in proc.stdout.splitlines():
        if not line.startswith("="):
            continue
        fields = line.split(";")
        # =;iface;proto;name;type;domain;host;address;port;txt
        if len(fields) < 9:
            continue
        address = fields[7].strip()
        service_type = fields[4].strip()
        name = fields[3].replace("\\032", " ").strip()
        host = fields[6].replace("\\032", " ").rstrip(".").strip()
        try:
            port = int(fields[8])
        except ValueError:
            port = 0
        try:
            ipaddress.ip_address(address)
        except ValueError:
            continue
        result.setdefault(address, []).append({"type": service_type, "name": name, "host": host, "port": port})
    return result


def nmap_ports(ips: list[str]) -> dict[str, list[int]]:
    result: dict[str, list[int]] = {ip: [] for ip in ips}
    if not ips or shutil.which("nmap") is None:
        return result
    cmd = [
        "nmap", "-Pn", "-n", "-T4", "--max-retries", "1", "--host-timeout", "8s",
        "-p", ",".join(str(x) for x in SCAN_PORTS), "-oX", "-",
    ] + ips
    try:
        proc = run(cmd, timeout=max(60, min(240, 10 * len(ips))))
        root = ET.fromstring(proc.stdout)
    except Exception:
        return result
    for host in root.findall("host"):
        addr = host.find("address[@addrtype='ipv4']")
        if addr is None:
            continue
        ip = addr.attrib.get("addr", "")
        ports = []
        for port in host.findall("./ports/port"):
            state = port.find("state")
            if state is not None and state.attrib.get("state") == "open":
                try:
                    ports.append(int(port.attrib["portid"]))
                except Exception:
                    pass
        result[ip] = sorted(ports)
    return result


def classify(device: dict, gateway: str) -> tuple[str | None, str | None, float, list[str]]:
    ip = device.get("ip", "")
    vendor = device.get("vendor", "").lower()
    ports = set(device.get("open_ports") or [])
    mdns = {x.get("type", "") for x in device.get("mdns") or []}

    if gateway and ip == gateway:
        return "router", "infrastructure", 1.0, ["IP is the active default gateway"]

    printer_matches = sorted(mdns & PRINTER_MDNS)
    if printer_matches:
        return "printer", "other", 0.99, [f"mDNS advertises {printer_matches[0]}"]
    if 631 in ports and 9100 in ports:
        return "printer", "other", 0.96, ["IPP (631) and JetDirect (9100) are both open"]

    camera_matches = sorted(mdns & CAMERA_MDNS)
    if camera_matches:
        return "camera", "security", 0.99, [f"mDNS advertises {camera_matches[0]}"]
    if 554 in ports and ({8000, 8899} & ports):
        return "camera", "security", 0.94, ["RTSP plus a common camera-management port are open"]

    storage_matches = sorted(mdns & STORAGE_MDNS)
    if storage_matches:
        return "nas", "storage", 0.97, [f"mDNS advertises {storage_matches[0]}"]
    if any(v in vendor for v in STORAGE_VENDOR_HINTS) and 445 in ports:
        return "nas", "storage", 0.94, ["storage-appliance vendor plus SMB (445) detected"]

    smart_matches = sorted(mdns & SMART_MDNS)
    if smart_matches:
        return "iot", "smart-home", 0.94, [f"mDNS advertises {smart_matches[0]}"]

    if any(v in vendor for v in NETWORK_VENDOR_HINTS):
        return "network-device", "infrastructure", 0.85, ["MAC vendor is a network-equipment manufacturer"]

    return None, None, 0.0, []


def key_for(device: dict) -> str:
    mac = normalize_mac(device.get("mac", ""))
    return mac or f"ip:{device.get('ip', '')}"


def selector_match(selector: str, devices: dict[str, dict]) -> tuple[str, dict]:
    s = selector.lower().strip()
    exact = []
    for key, d in devices.items():
        fields = [key, d.get("mac", ""), d.get("ip", ""), d.get("hostname", "")]
        if any(str(x).lower() == s for x in fields if x):
            exact.append((key, d))
    if not exact:
        raise SystemExit(f"No discovered device exactly matches: {selector}")
    if len(exact) > 1:
        raise SystemExit(f"Selector is ambiguous: {selector}. Use the MAC address.")
    return exact[0]


def scan(_args) -> None:
    if os.geteuid() != 0:
        raise SystemExit("Run scan with sudo/root; arp-scan requires raw-socket access.")
    interface, network, gateway, own_ip = detect_interface_network()
    state = load_state()
    stamp = now_iso()

    try:
        found = arp_discover(interface)
    except SystemExit:
        found = neighbor_fallback(interface)
    if gateway and gateway not in found:
        try:
            run(["ping", "-c", "1", "-W", "1", gateway], timeout=3)
        except Exception:
            pass
        found.update(neighbor_fallback(interface))

    mdns = avahi_services()
    ports = nmap_ports(sorted(found))

    for old in state["devices"].values():
        old["present"] = False

    # The scanner cannot ARP-discover itself. Add the Pi explicitly from local OS
    # facts so it is always represented in Device Manager and dashboard groups.
    local = local_host_record(interface, own_ip, stamp)
    local_key = key_for(local)
    old_local = state["devices"].get(local_key, {})
    local["first_seen"] = old_local.get("first_seen", stamp)
    local["seen_count"] = int(old_local.get("seen_count", 0)) + 1
    local["state"] = old_local.get("state", "known")
    for field in (
        "approved_type", "approved_group", "kuma_monitor", "approved_at", "ignored_at",
        "manual_type", "manual_group", "manual_hidden", "manual_name", "manual_at",
    ):
        if field in old_local:
            local[field] = old_local[field]
    state["devices"][local_key] = local

    for ip, base in sorted(found.items(), key=lambda kv: ipaddress.ip_address(kv[0])):
        if ip == own_ip:
            continue
        device = dict(base)
        device["hostname"] = reverse_hostname(ip)
        device["mdns"] = mdns.get(ip, [])
        if not device["hostname"] and device["mdns"]:
            device["hostname"] = next((x.get("host") for x in device["mdns"] if x.get("host")), "")
        device["open_ports"] = ports.get(ip, [])
        dtype, group, confidence, evidence = classify(device, gateway)
        device.update({
            "suggested_type": dtype,
            "suggested_group": group,
            "confidence": confidence,
            "evidence": evidence,
            "last_seen": stamp,
            "present": True,
        })
        key = key_for(device)
        old = state["devices"].get(key, {})
        device["first_seen"] = old.get("first_seen", stamp)
        device["seen_count"] = int(old.get("seen_count", 0)) + 1
        device["state"] = old.get("state", "new")
        for field in (
            "approved_type", "approved_group", "kuma_monitor", "approved_at", "ignored_at",
            "manual_type", "manual_group", "manual_hidden", "manual_name", "manual_at",
        ):
            if field in old:
                device[field] = old[field]
        state["devices"][key] = device

    state["last_scan"] = stamp
    state["last_interface"] = interface
    state["last_network"] = network
    save_state(state)
    summary = compute_summary(state)
    print(
        f"Scan complete: {summary['total']} present, "
        f"{summary['classified']} automatically/manual classified, "
        f"{summary['unclassified']} unclassified."
    )


def compute_summary(state: dict) -> dict:
    devices = [d for d in state.get("devices", {}).values() if d.get("present")]
    classified = 0
    unclassified = 0
    manual = 0
    for d in devices:
        if d.get("manual_hidden"):
            continue
        if d.get("manual_type") or d.get("manual_group") or d.get("approved_type") or d.get("approved_group"):
            classified += 1
            manual += 1
        elif d.get("suggested_type") and d.get("suggested_group") and float(d.get("confidence") or 0) >= 0.85:
            classified += 1
        else:
            unclassified += 1
    new = sum(d.get("state") == "new" for d in devices)
    ignored = sum(d.get("state") == "ignored" for d in devices)
    return {
        "total": len(devices), "new": new, "review": unclassified,
        "approved": manual, "ignored": ignored, "suggested": classified - manual,
        "classified": classified, "unclassified": unclassified, "manual": manual,
    }


def list_devices(args) -> None:
    state = load_state()
    rows = []
    for key, d in state.get("devices", {}).items():
        if not args.all and not d.get("present"):
            continue
        rows.append((d.get("ip", ""), key, d))
    rows.sort(key=lambda x: ipaddress.ip_address(x[0]) if x[0] else ipaddress.ip_address("255.255.255.255"))
    print(f"{'IP':15} {'MAC':17} {'STATE':10} {'SUGGESTION':18} {'CONF':>5}  HOST/VENDOR")
    for _ip, key, d in rows:
        suggestion = d.get("approved_type") or d.get("suggested_type") or "-"
        conf = d.get("confidence", 0.0)
        label = d.get("hostname") or d.get("vendor") or "-"
        print(f"{d.get('ip','')[:15]:15} {d.get('mac','')[:17]:17} {d.get('state','')[:10]:10} {suggestion[:18]:18} {conf:>5.2f}  {label}")


def review(_args) -> None:
    state = load_state()
    pending = [(key, d) for key, d in state.get("devices", {}).items() if d.get("present") and d.get("state") in ("new", "review")]
    if not pending:
        print("No present devices need review.")
        return
    for key, d in sorted(pending, key=lambda x: ipaddress.ip_address(x[1].get("ip", "255.255.255.255"))):
        d["state"] = "review"
        print(f"\n{d.get('ip')}  {d.get('mac')}  {d.get('hostname') or '(no hostname)'}")
        print(f"  Vendor: {d.get('vendor') or '(unknown)'}")
        print(f"  Open ports: {', '.join(map(str,d.get('open_ports') or [])) or '(none detected)'}")
        services = sorted({x.get('type','') for x in d.get('mdns') or [] if x.get('type')})
        print(f"  mDNS: {', '.join(services) or '(none detected)'}")
        if d.get("suggested_type"):
            print(f"  Suggestion: {d['suggested_type']} / {d['suggested_group']}  confidence={d.get('confidence',0):.2f}")
            for ev in d.get("evidence") or []:
                print(f"    - {ev}")
        else:
            print("  Suggestion: none; explicit classification required")
        print(f"  Approve: sudo pi-network-discover approve {d.get('mac') or key} <device-type> [--monitor 'Exact Kuma monitor']")
    save_state(state)


def validate_type(device_type: str, group: str | None) -> str:
    if device_type not in TYPE_TO_GROUP:
        raise SystemExit(f"Unsupported device type: {device_type}. Run 'pi-network-discover types'.")
    group = group or TYPE_TO_GROUP[device_type]
    if group not in GROUPS or group == "unclassified":
        raise SystemExit(f"Unsupported approval group: {group}")
    return group


def inventory_set(monitor: str, device_type: str, group: str) -> None:
    if not INVENTORY_CMD.exists():
        raise SystemExit("pi-device-inventory is not installed; cannot classify a Kuma monitor.")
    proc = subprocess.run([str(INVENTORY_CMD), "set", monitor, device_type, group], text=True)
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)


def approve(args) -> None:
    state = load_state()
    key, d = selector_match(args.selector, state.get("devices", {}))
    group = validate_type(args.device_type, args.group)
    d["state"] = "approved"
    d["approved_type"] = args.device_type
    d["approved_group"] = group
    d["approved_at"] = now_iso()
    if args.monitor:
        inventory_set(args.monitor, args.device_type, group)
        d["kuma_monitor"] = args.monitor
    save_state(state)
    print(f"Approved {d.get('ip')} ({d.get('mac')}) -> {args.device_type} / {group}")
    if args.monitor:
        print(f"Kuma dashboard classification applied to exact monitor: {args.monitor}")
    else:
        print("No Kuma monitor was changed. Add --monitor 'Exact Kuma monitor' to classify an existing monitor.")


def approve_suggested(args) -> None:
    state = load_state()
    key, d = selector_match(args.selector, state.get("devices", {}))
    dtype = d.get("suggested_type")
    group = d.get("suggested_group")
    confidence = float(d.get("confidence") or 0)
    if not dtype or not group:
        raise SystemExit("This device has no deterministic suggestion. Use explicit 'approve <selector> <device-type>'.")
    if confidence < 0.90:
        raise SystemExit(f"Suggestion confidence {confidence:.2f} is below the 0.90 safe-approval threshold. Use explicit approve instead.")
    ns = argparse.Namespace(selector=args.selector, device_type=dtype, group=group, monitor=args.monitor)
    approve(ns)


def ignore(args) -> None:
    state = load_state()
    _key, d = selector_match(args.selector, state.get("devices", {}))
    d["state"] = "ignored"
    d["ignored_at"] = now_iso()
    save_state(state)
    print(f"Ignored {d.get('ip')} ({d.get('mac')})")


def summary(args) -> None:
    state = load_state()
    payload = {"last_scan": state.get("last_scan"), **compute_summary(state)}
    if args.json:
        print(json.dumps(payload, separators=(",", ":")))
    else:
        for k, v in payload.items():
            print(f"{k}: {v}")


def types(_args) -> None:
    print("DEVICE TYPES -> DEFAULT GROUP")
    for key in sorted(TYPE_TO_GROUP):
        print(f"  {key:18} {TYPE_TO_GROUP[key]:14} {GROUPS[TYPE_TO_GROUP[key]]}")


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Automatic conservative LAN discovery with persistent manual overrides")
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("scan", help="scan the active Ethernet LAN; does not modify Kuma").set_defaults(func=scan)
    ls = sub.add_parser("list", help="list discovered devices")
    ls.add_argument("--all", action="store_true", help="include devices not seen in the most recent scan")
    ls.set_defaults(func=list_devices)
    sub.add_parser("review", help="show devices needing explicit review").set_defaults(func=review)
    sub.add_parser("types", help="show supported device types and default groups").set_defaults(func=types)
    sm = sub.add_parser("summary", help="show discovery counts")
    sm.add_argument("--json", action="store_true")
    sm.set_defaults(func=summary)

    ap = sub.add_parser("approve", help="explicitly approve a discovered device classification")
    ap.add_argument("selector", help="exact MAC, IP, state key, or hostname")
    ap.add_argument("device_type", choices=sorted(TYPE_TO_GROUP))
    ap.add_argument("--group", choices=[g for g in GROUPS if g != "unclassified"])
    ap.add_argument("--monitor", help="exact existing Kuma monitor name or ID to classify in the dashboard inventory")
    ap.set_defaults(func=approve)

    aps = sub.add_parser("approve-suggested", help="accept a deterministic suggestion with confidence >= 0.90")
    aps.add_argument("selector", help="exact MAC, IP, state key, or hostname")
    aps.add_argument("--monitor", help="exact existing Kuma monitor name or ID to classify in the dashboard inventory")
    aps.set_defaults(func=approve_suggested)

    ig = sub.add_parser("ignore", help="mark a discovered device as intentionally ignored")
    ig.add_argument("selector")
    ig.set_defaults(func=ignore)
    return p


def main() -> None:
    args = parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
PI_NETWORK_DISCOVER_PY
    chmod 0755 /usr/local/sbin/pi-network-discover

    # Initialise state without overwriting prior approvals.
    if [[ ! -s "${STATE_DIR}/network-discovery.json" ]]; then
        printf '%s\n' '{"version":1,"last_scan":null,"last_interface":null,"last_network":null,"devices":{}}' \
            >"${STATE_DIR}/network-discovery.json"
        chmod 0644 "${STATE_DIR}/network-discovery.json"
    fi

    cat >/etc/systemd/system/pi-network-discovery.service <<'EOF'
[Unit]
Description=Automatic conservative local-network discovery for the home-network dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pi-network-discover scan
Nice=10
IOSchedulingClass=idle
EOF

    cat >/etc/systemd/system/pi-network-discovery.timer <<'EOF'
[Unit]
Description=Run automatic LAN discovery daily

[Timer]
OnCalendar=*-*-* 02:20:00
Persistent=true
RandomizedDelaySec=10m
Unit=pi-network-discovery.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now pi-network-discovery.timer >/dev/null

    # First scan populates the dashboard. Failure is non-fatal because discovery
    # must never affect DNS, SSH, or the network control plane.
    if ! systemctl start pi-network-discovery.service; then
        warn "Initial network discovery failed. Run 'sudo pi-network-discover scan' to retry."
    fi
}

# =============================================================================
# Local dashboard status API
# =============================================================================

install_status_api() {
    log "Installing local dashboard telemetry API"

    if [[ ! -s "${STATUS_TOKEN_FILE}" ]]; then
        python3 - <<'TOKENPY' >"${STATUS_TOKEN_FILE}"
import secrets
print(secrets.token_hex(32))
TOKENPY
        chmod 600 "${STATUS_TOKEN_FILE}"
    fi

    local status_token
    status_token="$(cat "${STATUS_TOKEN_FILE}")"

    install -d -m 0755 /usr/local/lib/pi-network-status

    cat >/usr/local/lib/pi-network-status/kuma_normalizer.py <<'KUMA_NORMALIZER_PY'
"""Merge published Uptime Kuma state with explicit local device inventory."""

from __future__ import annotations

from typing import Any
from urllib.parse import quote

STATUS_LABELS = {0: "Down", 1: "Up", 2: "Pending", 3: "Maintenance"}

DEVICE_TYPES = {
    "access-point", "router", "switch", "network-device",
    "nas", "storage", "server", "raspberry-pi",
    "smart-home", "iot", "sensor", "bridge", "tv", "speaker",
    "camera", "nvr", "security",
    "dns", "service", "website",
    "printer", "other",
}

GROUP_TITLES = {
    "infrastructure": "Infrastructure",
    "storage": "Storage & Servers",
    "smart-home": "Smart Home & IoT",
    "security": "Cameras & Security",
    "services": "Services",
    "websites": "Websites",
    "other": "Other Devices",
    "unclassified": "Unclassified",
}

DEFAULT_GROUP_BY_DEVICE = {
    "access-point": "infrastructure",
    "router": "infrastructure",
    "switch": "infrastructure",
    "network-device": "infrastructure",
    "nas": "storage",
    "storage": "storage",
    "server": "storage",
    "raspberry-pi": "storage",
    "smart-home": "smart-home",
    "iot": "smart-home",
    "sensor": "smart-home",
    "bridge": "smart-home",
    "tv": "smart-home",
    "speaker": "smart-home",
    "camera": "security",
    "nvr": "security",
    "security": "security",
    "dns": "services",
    "service": "services",
    "website": "websites",
    "printer": "other",
    "other": "other",
}

GROUP_ORDER = {
    "infrastructure": 10,
    "storage": 20,
    "smart-home": 30,
    "security": 40,
    "services": 50,
    "websites": 60,
    "other": 70,
    "unclassified": 90,
}


def _latest_heartbeat(beats: list[dict[str, Any]] | None) -> dict[str, Any] | None:
    beats = [beat for beat in (beats or []) if isinstance(beat, dict)]
    if not beats:
        return None
    return max(beats, key=lambda beat: str(beat.get("time", "")))


def _uptime_percent(uptime_list: dict[str, Any], monitor_id: int) -> float | None:
    raw = uptime_list.get(f"{monitor_id}_24")
    if raw is None:
        return None
    try:
        return round(float(raw) * 100, 2)
    except (TypeError, ValueError):
        return None


def _inventory_assignment(inventory: dict[str, Any] | None, monitor_id: int, name: str) -> dict[str, Any] | None:
    devices = (inventory or {}).get("devices") or {}
    if not isinstance(devices, dict):
        return None

    direct = devices.get(str(monitor_id))
    if isinstance(direct, dict):
        return direct

    legacy = devices.get(f"name:{name}")
    if isinstance(legacy, dict):
        return legacy

    # Exact-name fallback exists only to support hand-authored inventory files.
    # If the name is ambiguous, refuse to classify rather than guess.
    matches = [item for item in devices.values() if isinstance(item, dict) and item.get("name") == name]
    return matches[0] if len(matches) == 1 else None


def _classification(inventory: dict[str, Any] | None, monitor_id: int, name: str) -> tuple[str, str, bool]:
    assignment = _inventory_assignment(inventory, monitor_id, name)
    if not assignment:
        return "other", "unclassified", False

    device_type = str(assignment.get("type") or "").strip().lower()
    if device_type not in DEVICE_TYPES:
        return "other", "unclassified", False

    group_key = str(assignment.get("group") or DEFAULT_GROUP_BY_DEVICE.get(device_type, "other")).strip().lower()
    if group_key not in GROUP_TITLES:
        return "other", "unclassified", False

    return device_type, group_key, True


def normalize_kuma_status(
    status_page: dict[str, Any],
    heartbeat_page: dict[str, Any],
    kuma_public_url: str,
    slug: str,
    inventory: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Return dashboard groups using only explicit local inventory classification.

    Kuma contributes monitor identity and health data. The local inventory is the
    sole source of device type/group. Missing classifications are put in the
    Unclassified card. Monitor names, IPs, URLs and Kuma monitor types are never
    used to infer classification.
    """

    config = status_page.get("config") or {}
    groups_in = status_page.get("publicGroupList") or []
    heartbeat_list = heartbeat_page.get("heartbeatList") or {}
    uptime_list = heartbeat_page.get("uptimeList") or {}
    status_page_url = f"{kuma_public_url.rstrip('/')}/status/{quote(slug, safe='')}"

    grouped: dict[str, dict[str, Any]] = {}
    summary = {"total": 0, "up": 0, "down": 0, "pending": 0, "maintenance": 0, "unknown": 0}

    for public_group in groups_in:
        source_group = str(public_group.get("name") or "").strip()
        for monitor in public_group.get("monitorList") or []:
            try:
                monitor_id = int(monitor.get("id"))
            except (TypeError, ValueError):
                continue

            name = str(monitor.get("name") or f"Monitor {monitor_id}")
            device_type, group_key, classified = _classification(inventory, monitor_id, name)
            group_title = GROUP_TITLES[group_key]

            if group_key not in grouped:
                grouped[group_key] = {"key": group_key, "title": group_title, "monitors": []}

            beats = heartbeat_list.get(str(monitor_id), heartbeat_list.get(monitor_id, []))
            latest = _latest_heartbeat(beats)
            status = latest.get("status") if latest else None
            try:
                status = int(status) if status is not None else None
            except (TypeError, ValueError):
                status = None

            latency = latest.get("ping") if latest else None
            if latency is not None:
                try:
                    latency = round(float(latency), 1)
                    if latency.is_integer():
                        latency = int(latency)
                except (TypeError, ValueError, AttributeError):
                    latency = None

            summary["total"] += 1
            summary_key = {0: "down", 1: "up", 2: "pending", 3: "maintenance"}.get(status, "unknown")
            summary[summary_key] += 1

            grouped[group_key]["monitors"].append({
                "id": monitor_id,
                "name": name,
                "device_type": device_type,
                "classified": classified,
                "group": group_key,
                "source_group": source_group,
                "status": status,
                "status_label": STATUS_LABELS.get(status, "Unknown"),
                "latency_ms": latency,
                "uptime_24": _uptime_percent(uptime_list, monitor_id),
                "last_checked": latest.get("time") if latest else None,
                "message": latest.get("msg") if latest else None,
                "href": status_page_url,
            })

    groups = [grouped[key] for key in sorted(grouped, key=lambda key: GROUP_ORDER.get(key, 80))]
    inventory_devices = (inventory or {}).get("devices") or {}
    return {
        "configured": bool(config.get("published")),
        "published": bool(config.get("published")),
        "slug": slug,
        "status_page_url": status_page_url,
        "inventory_count": len(inventory_devices) if isinstance(inventory_devices, dict) else 0,
        "groups": groups,
        "summary": summary,
    }

KUMA_NORMALIZER_PY

    cat >/usr/local/sbin/pi-device-inventory <<'PI_DEVICE_INVENTORY_PY'
#!/usr/bin/env python3
"""Manage explicit Uptime Kuma dashboard device classifications."""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

INVENTORY_FILE = Path(os.environ.get("DEVICE_INVENTORY_FILE", "/var/lib/pi4-network-stack/device-inventory.json"))
DEFAULTS_FILE = Path("/etc/default/pi-network-status-api")

GROUPS = {
    "infrastructure": "Infrastructure",
    "storage": "Storage & Servers",
    "smart-home": "Smart Home & IoT",
    "security": "Cameras & Security",
    "services": "Services",
    "websites": "Websites",
    "other": "Other Devices",
    "unclassified": "Unclassified",
}

TYPE_TO_GROUP = {
    "access-point": "infrastructure", "router": "infrastructure", "switch": "infrastructure", "network-device": "infrastructure",
    "nas": "storage", "storage": "storage", "server": "storage", "raspberry-pi": "storage",
    "smart-home": "smart-home", "iot": "smart-home", "sensor": "smart-home", "bridge": "smart-home", "tv": "smart-home", "speaker": "smart-home",
    "camera": "security", "nvr": "security", "security": "security",
    "dns": "services", "service": "services",
    "website": "websites",
    "printer": "other", "other": "other",
}


def read_defaults():
    values = {}
    try:
        for raw in DEFAULTS_FILE.read_text().splitlines():
            raw = raw.strip()
            if not raw or raw.startswith("#") or "=" not in raw:
                continue
            key, value = raw.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return values


def endpoints():
    defaults = read_defaults()
    base = os.environ.get("KUMA_LOCAL_URL", defaults.get("KUMA_LOCAL_URL", "http://127.0.0.1:3001")).rstrip("/")
    slug = os.environ.get("KUMA_STATUS_SLUG", defaults.get("KUMA_STATUS_SLUG", "home-network"))
    return base, slug


def default_inventory():
    return {
        "version": 1,
        "groups": {key: {"title": title} for key, title in GROUPS.items()},
        "devices": {},
    }


def load_inventory():
    try:
        data = json.loads(INVENTORY_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        data = default_inventory()
    if not isinstance(data, dict):
        data = default_inventory()
    data.setdefault("version", 1)
    data.setdefault("devices", {})
    # Refresh canonical metadata while preserving all device assignments.
    data["groups"] = {key: {"title": title} for key, title in GROUPS.items()}
    return data


def save_inventory(data):
    INVENTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = INVENTORY_FILE.with_suffix(INVENTORY_FILE.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, INVENTORY_FILE)


def fetch_monitors():
    base, slug = endpoints()
    url = f"{base}/api/status-page/{slug}"
    req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "pi-device-inventory/1"})
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"Kuma status page '{slug}' is not available (HTTP {exc.code}).")
    except Exception as exc:
        raise SystemExit(f"Cannot read Kuma status page '{slug}': {type(exc).__name__}: {exc}")

    monitors = []
    for group in payload.get("publicGroupList") or []:
        for monitor in group.get("monitorList") or []:
            try:
                monitor_id = int(monitor.get("id"))
            except (TypeError, ValueError):
                continue
            monitors.append({"id": monitor_id, "name": str(monitor.get("name") or f"Monitor {monitor_id}")})
    return monitors


def resolve_monitor(selector, monitors):
    selector = str(selector)
    if selector.isdigit():
        monitor_id = int(selector)
        matches = [m for m in monitors if m["id"] == monitor_id]
    else:
        matches = [m for m in monitors if m["name"] == selector]
    if not matches:
        raise SystemExit(f"No published Kuma monitor exactly matches: {selector}")
    if len(matches) > 1:
        ids = ", ".join(str(m["id"]) for m in matches)
        raise SystemExit(f"Monitor name is ambiguous: {selector}. Use numeric monitor ID: {ids}")
    return matches[0]


def validate(device_type, group=None):
    if device_type not in TYPE_TO_GROUP:
        raise SystemExit(f"Unsupported device type: {device_type}. Run 'pi-device-inventory groups'.")
    group = group or TYPE_TO_GROUP[device_type]
    if group not in GROUPS or group == "unclassified":
        raise SystemExit(f"Unsupported assignment group: {group}")
    return group


def set_one(data, monitor, device_type, group=None):
    group = validate(device_type, group)
    data["devices"][str(monitor["id"])] = {
        "name": monitor["name"],
        "type": device_type,
        "group": group,
    }


def cmd_init(_args):
    data = load_inventory()
    save_inventory(data)
    print(INVENTORY_FILE)


def cmd_show(_args):
    print(json.dumps(load_inventory(), indent=2, sort_keys=True))


def cmd_groups(_args):
    print("GROUPS")
    for key, title in GROUPS.items():
        if key != "unclassified":
            print(f"  {key:16} {title}")
    print("\nDEVICE TYPES -> DEFAULT GROUP")
    for key in sorted(TYPE_TO_GROUP):
        print(f"  {key:16} {TYPE_TO_GROUP[key]}")


def cmd_list(_args):
    monitors = fetch_monitors()
    devices = load_inventory().get("devices", {})
    print(f"{'ID':>4}  {'MONITOR':32}  {'TYPE':16}  {'GROUP'}")
    for monitor in monitors:
        assignment = devices.get(str(monitor["id"]), {})
        print(f"{monitor['id']:>4}  {monitor['name'][:32]:32}  {assignment.get('type','unclassified'):16}  {assignment.get('group','unclassified')}")


def cmd_set(args):
    data = load_inventory()
    monitor = resolve_monitor(args.monitor, fetch_monitors())
    set_one(data, monitor, args.device_type, args.group)
    save_inventory(data)
    assignment = data["devices"][str(monitor["id"])]
    print(f"{monitor['name']} -> {assignment['type']} / {assignment['group']}")


def cmd_set_many(args):
    data = load_inventory()
    monitors = fetch_monitors()
    group = validate(args.device_type, args.group)
    for selector in args.monitors:
        monitor = resolve_monitor(selector, monitors)
        set_one(data, monitor, args.device_type, group)
        print(f"{monitor['name']} -> {args.device_type} / {group}")
    save_inventory(data)


def cmd_remove(args):
    data = load_inventory()
    devices = data.get("devices", {})
    if str(args.monitor).isdigit() and str(args.monitor) in devices:
        key = str(args.monitor)
    else:
        monitor = resolve_monitor(args.monitor, fetch_monitors())
        key = str(monitor["id"])
    old = devices.pop(key, None)
    if old is None:
        raise SystemExit(f"Monitor is not classified: {args.monitor}")
    save_inventory(data)
    print(f"Removed classification for {old.get('name', key)}")


def parser():
    p = argparse.ArgumentParser(description="Explicit device inventory for the Homepage/Kuma dashboard")
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("init").set_defaults(func=cmd_init)
    sub.add_parser("show").set_defaults(func=cmd_show)
    sub.add_parser("groups").set_defaults(func=cmd_groups)
    sub.add_parser("list").set_defaults(func=cmd_list)

    s = sub.add_parser("set", help="classify one exact Kuma monitor")
    s.add_argument("monitor", help="exact monitor name or numeric monitor ID")
    s.add_argument("device_type", choices=sorted(TYPE_TO_GROUP))
    s.add_argument("group", nargs="?", choices=[g for g in GROUPS if g != "unclassified"])
    s.set_defaults(func=cmd_set)

    sm = sub.add_parser("set-many", help="classify multiple exact Kuma monitors")
    sm.add_argument("device_type", choices=sorted(TYPE_TO_GROUP))
    sm.add_argument("monitors", nargs="+")
    sm.add_argument("--group", choices=[g for g in GROUPS if g != "unclassified"])
    sm.set_defaults(func=cmd_set_many)

    r = sub.add_parser("remove")
    r.add_argument("monitor", help="exact monitor name or numeric monitor ID")
    r.set_defaults(func=cmd_remove)
    return p


def main():
    args = parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

PI_DEVICE_INVENTORY_PY
    chmod 0755 /usr/local/sbin/pi-device-inventory

    # Create/refresh canonical inventory metadata without overwriting assignments.
    DEVICE_INVENTORY_FILE="${STATE_DIR}/device-inventory.json" \
        /usr/local/sbin/pi-device-inventory init >/dev/null

    cat >/usr/local/lib/pi-network-status/device_manager.py <<'DEVICE_MANAGER_PY'
#!/usr/bin/env python3
"""Shared classification and grouping helpers for network discovery + Kuma.

Classification never uses a device/monitor name. Automatic assignment is based only
on scanner-produced evidence fields. Manual overrides always win until cleared.
"""
from __future__ import annotations

import ipaddress
from typing import Any

AUTO_CONFIDENCE_THRESHOLD = 0.85

GROUPS = {
    "infrastructure": "Infrastructure",
    "storage": "Storage & Servers",
    "smart-home": "Smart Home & IoT",
    "security": "Cameras & Security",
    "services": "Services",
    "websites": "Websites",
    "other": "Other Devices",
    "unclassified": "Unclassified",
}

GROUP_ORDER = [
    "infrastructure", "storage", "smart-home", "security",
    "services", "websites", "other", "unclassified",
]

TYPE_TO_GROUP = {
    "access-point": "infrastructure",
    "router": "infrastructure",
    "switch": "infrastructure",
    "network-device": "infrastructure",
    "modem": "infrastructure",
    "nas": "storage",
    "storage": "storage",
    "server": "storage",
    "raspberry-pi": "infrastructure",
    "smart-home": "smart-home",
    "iot": "smart-home",
    "sensor": "smart-home",
    "bridge": "smart-home",
    "tv": "smart-home",
    "speaker": "smart-home",
    "camera": "security",
    "nvr": "security",
    "security": "security",
    "dns": "services",
    "service": "services",
    "website": "websites",
    "printer": "other",
    "other": "other",
}


def ipv4_sort_key(record: dict[str, Any]) -> tuple[int, int, str]:
    """Sort IPv4 addresses numerically; missing/non-IPv4 addresses sort last.

    Names are used only as a stable tie-breaker and never for classification.
    """
    value = str(record.get("ip") or "").strip()
    label = str(record.get("name") or record.get("hostname") or record.get("id") or "").lower()
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return (2, 0, label)
    if address.version == 4:
        return (0, int(address), label)
    return (1, int(address), label)


def effective_classification(record: dict[str, Any]) -> dict[str, Any]:
    """Return effective type/group while preserving the underlying evidence.

    Manual fields have precedence. Legacy approved_* fields are treated as manual
    for backward compatibility. Automatic suggestions are accepted only at or above
    AUTO_CONFIDENCE_THRESHOLD. No hostname/name field participates in this logic.
    """
    manual_type = record.get("manual_type") or record.get("approved_type")
    manual_group = record.get("manual_group") or record.get("approved_group")

    if manual_type or manual_group:
        device_type = manual_type or record.get("suggested_type") or "other"
        group = manual_group or TYPE_TO_GROUP.get(str(device_type), "unclassified")
        if group not in GROUPS:
            group = "unclassified"
        return {"type": str(device_type), "group": group, "source": "manual", "confidence": 1.0}

    confidence = float(record.get("confidence") or 0.0)
    suggested_type = record.get("suggested_type")
    suggested_group = record.get("suggested_group")
    if (
        suggested_type
        and suggested_group in GROUPS
        and confidence >= AUTO_CONFIDENCE_THRESHOLD
    ):
        return {
            "type": str(suggested_type),
            "group": str(suggested_group),
            "source": "automatic",
            "confidence": confidence,
        }

    return {"type": "other", "group": "unclassified", "source": "unclassified", "confidence": confidence}


def modem_ip_from_state(state: dict[str, Any]) -> str:
    """Return the IPv4 address of a device explicitly/effectively classified as modem."""
    candidates = []
    for record in (state.get("devices") or {}).values():
        if not isinstance(record, dict):
            continue
        if effective_classification(record)["type"] != "modem":
            continue
        value = str(record.get("ip") or "").strip()
        try:
            address = ipaddress.ip_address(value)
        except ValueError:
            continue
        if address.version == 4:
            candidates.append((0 if record.get("present") else 1, int(address), value))
    return sorted(candidates)[0][2] if candidates else ""


def device_label(record: dict[str, Any]) -> str:
    """Choose a display label only. This function is never used for classification."""
    return (
        record.get("manual_name")
        or record.get("hostname")
        or record.get("vendor")
        or record.get("ip")
        or record.get("mac")
        or "Unknown device"
    )


def _row(key: str, record: dict[str, Any]) -> dict[str, Any]:
    effective = effective_classification(record)
    present = bool(record.get("present"))
    ip = record.get("ip") or ""
    return {
        "id": f"discovery:{key}",
        "source": "discovery",
        "discovery_key": key,
        "name": device_label(record),
        "ip": ip,
        "mac": record.get("mac") or "",
        "vendor": record.get("vendor") or "",
        "hostname": record.get("hostname") or "",
        "device_type": effective["type"],
        "group": effective["group"],
        "classification_source": effective["source"],
        "classification_confidence": effective["confidence"],
        "status": 1 if present else 0,
        "status_label": "Online" if present else "Offline",
        "latency_ms": None,
        "uptime_24": None,
        "href": f"/devices#{key}",
        "classified": effective["group"] != "unclassified",
        "last_seen": record.get("last_seen"),
        "first_seen": record.get("first_seen"),
        "open_ports": list(record.get("open_ports") or []),
        "evidence": list(record.get("evidence") or []),
        "auto_type": record.get("suggested_type"),
        "auto_group": record.get("suggested_group"),
        "auto_confidence": float(record.get("confidence") or 0.0),
        "manual_type": record.get("manual_type") or record.get("approved_type"),
        "manual_group": record.get("manual_group") or record.get("approved_group"),
        "hidden": bool(record.get("manual_hidden", False)),
        "kuma_monitor": record.get("kuma_monitor"),
        "local_host": bool(record.get("local_host", False)),
        "model": record.get("model") or "",
    }


def build_discovered_groups(state: dict[str, Any]) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = {key: [] for key in GROUP_ORDER}
    hidden = 0
    total = 0
    for key, record in (state.get("devices") or {}).items():
        if not isinstance(record, dict):
            continue
        total += 1
        row = _row(str(key), record)
        if row["hidden"]:
            hidden += 1
            continue
        grouped[row["group"]].append(row)

    groups = []
    for group_key in GROUP_ORDER:
        rows = grouped[group_key]
        if not rows:
            continue
        rows.sort(key=ipv4_sort_key)
        groups.append({"key": group_key, "title": GROUPS[group_key], "monitors": rows})

    return {
        "configured": True,
        "groups": groups,
        "total": total,
        "hidden": hidden,
        "last_scan": state.get("last_scan"),
    }


def merge_with_kuma(discovery_state: dict[str, Any], kuma_payload: dict[str, Any] | None) -> dict[str, Any]:
    """Merge discovered LAN devices with Kuma-only monitors without name guessing.

    A discovered device is merged with Kuma only when an explicit `kuma_monitor`
    mapping matches the Kuma monitor ID or exact monitor name. Otherwise both remain
    independent records.
    """
    base = build_discovered_groups(discovery_state)
    rows_by_group: dict[str, list[dict[str, Any]]] = {key: [] for key in GROUP_ORDER}
    discovery_rows: list[dict[str, Any]] = []
    for group in base["groups"]:
        discovery_rows.extend(group["monitors"])

    kuma_rows: list[dict[str, Any]] = []
    for group in (kuma_payload or {}).get("groups") or []:
        for monitor in group.get("monitors") or []:
            m = dict(monitor)
            m.setdefault("group", group.get("key") or "unclassified")
            kuma_rows.append(m)

    matched_kuma_ids: set[str] = set()
    by_name = {str(m.get("name")): m for m in kuma_rows if m.get("name")}
    by_id = {str(m.get("id")): m for m in kuma_rows if m.get("id") is not None}

    for row in discovery_rows:
        mapping = row.get("kuma_monitor")
        match = None
        if mapping is not None:
            match = by_id.get(str(mapping)) or by_name.get(str(mapping))
        if match:
            for field in ("status", "status_label", "latency_ms", "uptime_24", "href"):
                if match.get(field) is not None:
                    row[field] = match[field]
            matched_kuma_ids.add(str(match.get("id")))
        rows_by_group[row["group"]].append(row)

    for monitor in kuma_rows:
        if str(monitor.get("id")) in matched_kuma_ids:
            continue
        group_key = monitor.get("group") or "unclassified"
        if group_key not in GROUPS:
            group_key = "unclassified"
        monitor = dict(monitor)
        monitor["source"] = "kuma"
        rows_by_group[group_key].append(monitor)

    groups = []
    for key in GROUP_ORDER:
        rows = rows_by_group[key]
        if not rows:
            continue
        rows.sort(key=ipv4_sort_key)
        groups.append({"key": key, "title": GROUPS[key], "monitors": rows})

    summary = {"total": 0, "up": 0, "down": 0, "pending": 0, "maintenance": 0, "unknown": 0}
    for group in groups:
        for item in group["monitors"]:
            summary["total"] += 1
            status = item.get("status")
            if status == 1:
                summary["up"] += 1
            elif status == 0:
                summary["down"] += 1
            elif status == 2:
                summary["pending"] += 1
            elif status == 3:
                summary["maintenance"] += 1
            else:
                summary["unknown"] += 1

    return {
        "configured": True,
        "groups": groups,
        "summary": summary,
        "kuma_summary": (kuma_payload or {}).get("summary", {}),
        "last_scan": base.get("last_scan"),
        "hidden": base.get("hidden", 0),
    }
DEVICE_MANAGER_PY

    mkdir -p /usr/local/share/pi-network-manager
    cat >/usr/local/share/pi-network-manager/devices.html <<'DEVICE_MANAGER_HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Network Device Manager</title>
<style>
:root{color-scheme:dark;--bg:#111c2f;--panel:#142238;--panel2:#0f1b2e;--line:rgba(148,163,184,.16);--text:#dbe5f2;--muted:#8190a6;--teal:#2dd4bf;--blue:#38bdf8;--amber:#f59e0b;--red:#f87171;--green:#10b981}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 15% 5%,rgba(30,64,175,.10),transparent 32%),var(--bg);font:14px/1.45 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:var(--text)}
a{color:inherit}.wrap{max-width:1500px;margin:0 auto;padding:24px 30px 60px}.top{display:flex;align-items:center;gap:14px;flex-wrap:wrap}.top h1{font-size:22px;font-weight:500;margin:0;flex:1}.actions{display:flex;gap:8px}.btn{border:1px solid rgba(148,163,184,.22);background:#1b2a42;color:var(--text);border-radius:9px;padding:9px 13px;cursor:pointer;text-decoration:none}.btn:hover{border-color:rgba(45,212,191,.55)}.btn.primary{border-color:rgba(45,212,191,.55);background:rgba(13,148,136,.16)}.btn:disabled{opacity:.55;cursor:wait}
.summary{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px;margin:22px 0}.metric{background:linear-gradient(145deg,rgba(20,34,56,.96),rgba(15,27,46,.9));border:1px solid var(--line);border-radius:13px;padding:13px 15px}.metric b{display:block;font-size:22px;font-weight:500}.metric small{color:var(--muted);text-transform:uppercase;font-size:10px;letter-spacing:.06em}
.toolbar{display:flex;gap:10px;align-items:center;margin-bottom:12px}.toolbar input,.toolbar select{background:#0f1b2e;border:1px solid var(--line);color:var(--text);border-radius:8px;padding:9px 10px}.toolbar input{min-width:260px}.status{margin-left:auto;color:var(--muted)}
.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:15px;background:rgba(15,27,46,.64)}table{width:100%;border-collapse:collapse;min-width:1180px}th,td{padding:10px 12px;border-bottom:1px solid rgba(148,163,184,.09);vertical-align:middle;text-align:left}th{position:sticky;top:0;background:#17253b;color:#9fb0c8;font-weight:500;font-size:11px;text-transform:uppercase;letter-spacing:.04em}tr:last-child td{border-bottom:0}tr:hover td{background:rgba(51,65,85,.20)}
.device{display:flex;align-items:center;gap:9px}.dot{width:9px;height:9px;border-radius:50%;background:var(--muted);box-shadow:0 0 0 3px rgba(129,144,166,.10)}.dot.up{background:var(--green)}.dot.down{background:var(--red)}.name{font-weight:500}.device-name{width:220px;max-width:100%;background:#101d31;border:1px solid rgba(148,163,184,.18);color:var(--text);border-radius:7px;padding:7px 9px;font:inherit}.device-name::placeholder{color:#7890ae}.sub{font-size:11px;color:var(--muted)}.auto{font-size:12px}.conf{color:var(--muted);font-size:11px}.select{width:170px;background:#101d31;border:1px solid rgba(148,163,184,.18);color:var(--text);border-radius:7px;padding:7px}.select.group{width:190px}.select.kuma{width:190px}.hide{display:flex;align-items:center;gap:6px}.reset{font-size:11px;padding:6px 8px}.evidence{max-width:260px;color:var(--muted);font-size:11px}.badge{display:inline-block;padding:2px 6px;border:1px solid rgba(148,163,184,.16);border-radius:999px;font-size:10px;color:#a9bad0}.badge.manual{border-color:rgba(45,212,191,.35);color:#5eead4}.badge.auto{border-color:rgba(56,189,248,.30);color:#7dd3fc}.badge.unclassified{border-color:rgba(245,158,11,.28);color:#fbbf24}
@media(max-width:800px){.wrap{padding:18px 14px}.summary{grid-template-columns:repeat(2,minmax(0,1fr))}.toolbar{align-items:stretch;flex-direction:column}.toolbar input{min-width:0;width:100%}.status{margin-left:0}}
</style>
</head>
<body>
<div class="wrap">
  <div class="top"><h1>Network Device Manager</h1><div class="actions"><a class="btn" href="http://__TARGET_IP__:3000/">← Dashboard</a><button id="scan" class="btn primary">↻ Refresh Network</button></div></div>
  <div class="summary"><div class="metric"><b id="total">0</b><small>Devices</small></div><div class="metric"><b id="online">0</b><small>Online</small></div><div class="metric"><b id="classified">0</b><small>Classified</small></div><div class="metric"><b id="unclassified">0</b><small>Unclassified</small></div><div class="metric"><b id="hidden">0</b><small>Hidden</small></div></div>
  <div class="toolbar"><input id="search" placeholder="Filter by name, IP, MAC or vendor"><select id="filter"><option value="all">All devices</option><option value="online">Online</option><option value="offline">Offline</option><option value="unclassified">Unclassified</option><option value="manual">Manual overrides</option><option value="hidden">Hidden</option></select><span id="status" class="status"></span></div>
  <div class="table-wrap"><table><thead><tr><th>Device</th><th>IP / MAC</th><th>Observed evidence</th><th>Detected as</th><th>Device type</th><th>Dashboard section</th><th>Kuma monitor</th><th>Visible</th><th></th></tr></thead><tbody id="rows"></tbody></table></div>
</div>
<script>
(() => {
'use strict';
const $ = (s) => document.querySelector(s);
let payload = {devices:[], groups:{}, types:{}, kuma_monitors:[]};
const esc = (v) => String(v ?? '').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#039;');
function ipKey(ip){const p=String(ip||'').split('.');if(p.length!==4||p.some(x=>!/^\d+$/.test(x)||Number(x)>255))return [1,0];return [0,p.reduce((n,x)=>(n*256)+Number(x),0)]}
function compareIp(a,b){const ka=ipKey(a.ip),kb=ipKey(b.ip);return ka[0]-kb[0]||ka[1]-kb[1]||String(a.name||'').localeCompare(String(b.name||''))}
async function api(path, options={}) { const r=await fetch(path,{cache:'no-store',...options,headers:{'Content-Type':'application/json',...(options.headers||{})}}); const body=await r.json(); if(!r.ok) throw new Error(body.error||`HTTP ${r.status}`); return body; }
function option(value,label,selected){return `<option value="${esc(value)}"${selected?' selected':''}>${esc(label)}</option>`}
function typeOptions(d){let out=option('auto','Auto',!d.manual_type); for(const t of Object.keys(payload.types).sort()) out+=option(t,t,d.manual_type===t); return out}
function groupOptions(d){let out=option('auto','Auto',!d.manual_group); for(const [k,v] of Object.entries(payload.groups)) out+=option(k,v,d.manual_group===k); return out}
function kumaOptions(d){let out=option('','None',!d.kuma_monitor); for(const m of payload.kuma_monitors) out+=option(String(m.id??m.name),m.name,String(d.kuma_monitor||'')===String(m.id??m.name)||String(d.kuma_monitor||'')===String(m.name)); return out}
function keep(d){const q=$('#search').value.trim().toLowerCase(); const f=$('#filter').value; const hay=[d.name,d.ip,d.mac,d.vendor,d.hostname].join(' ').toLowerCase(); if(q&&!hay.includes(q)) return false; if(f==='online'&&!d.present)return false;if(f==='offline'&&d.present)return false;if(f==='unclassified'&&d.effective_group!=='unclassified')return false;if(f==='manual'&&d.classification_source!=='manual')return false;if(f==='hidden'&&!d.hidden)return false;return true}
function render(){const ds=payload.devices.filter(keep).sort(compareIp); $('#rows').innerHTML=ds.map(d=>{const ev=(d.evidence||[]).join('; ')||((d.open_ports||[]).length?`Ports: ${d.open_ports.join(', ')}`:'No deterministic signature');const badge=d.classification_source==='manual'?'manual':d.classification_source==='automatic'?'auto':'unclassified';return `<tr id="${esc(d.key)}"><td><div class="device"><span class="dot ${d.present?'up':'down'}"></span><div><input class="device-name" data-key="${esc(d.key)}" value="${esc(d.manual_name||'')}" placeholder="${esc(d.detected_name||d.name||'Device name')}" aria-label="Custom device name"><div class="sub">${d.local_host?'Local Host · ':''}${d.manual_name?'Custom name':'Detected: '+esc(d.detected_name||d.name||'Unknown')} · ${d.present?'Online':'Not seen in latest scan'} · last ${esc(d.last_seen||'never')}</div></div></div></td><td><div>${esc(d.ip)}</div><div class="sub">${esc(d.mac)}</div><div class="sub">${esc(d.vendor)}</div></td><td class="evidence">${esc(ev)}</td><td class="auto">${esc(d.auto_type||'Unclassified')}<div class="conf">${esc(d.auto_group||'')} ${d.auto_confidence?Math.round(d.auto_confidence*100)+'%':''}</div><span class="badge ${badge}">${esc(d.classification_source)}</span></td><td><select class="select device-type" data-key="${esc(d.key)}">${typeOptions(d)}</select></td><td><select class="select group" data-key="${esc(d.key)}">${groupOptions(d)}</select></td><td><select class="select kuma" data-key="${esc(d.key)}">${kumaOptions(d)}</select></td><td><label class="hide"><input type="checkbox" class="visible" data-key="${esc(d.key)}" ${d.hidden?'':'checked'}> Show</label></td><td><button class="btn reset" data-reset="${esc(d.key)}">Reset Auto</button></td></tr>`}).join('');
  const all=payload.devices; $('#total').textContent=all.length; $('#online').textContent=all.filter(x=>x.present).length; $('#classified').textContent=all.filter(x=>x.effective_group!=='unclassified'&&!x.hidden).length; $('#unclassified').textContent=all.filter(x=>x.effective_group==='unclassified'&&!x.hidden).length; $('#hidden').textContent=all.filter(x=>x.hidden).length;
  document.querySelectorAll('.device-name,.device-type,.group,.kuma,.visible').forEach(el=>el.addEventListener('change',saveRow)); document.querySelectorAll('[data-reset]').forEach(el=>el.addEventListener('click',resetRow));
}
function rowValues(key){const q=(c)=>document.querySelector(`${c}[data-key="${CSS.escape(key)}"]`);return {key,manual_name:q('.device-name')?.value||'',type:q('.device-type')?.value||'auto',group:q('.group')?.value||'auto',kuma_monitor:q('.kuma')?.value||'',hidden:!(q('.visible')?.checked??true)}}
async function saveRow(e){const key=e.target.dataset.key; $('#status').textContent='Saving…'; try{await api('/manage/device',{method:'POST',body:JSON.stringify(rowValues(key))});await load();$('#status').textContent='Saved';setTimeout(()=>$('#status').textContent='',1500)}catch(err){$('#status').textContent=`Save failed: ${err.message}`}}
async function resetRow(e){const key=e.currentTarget.dataset.reset;$('#status').textContent='Resetting…';try{await api('/manage/device/reset',{method:'POST',body:JSON.stringify({key})});await load();$('#status').textContent='Returned to automatic classification'}catch(err){$('#status').textContent=`Reset failed: ${err.message}`}}
async function load(){payload=await api('/public/discovery/devices');render()}
async function scan(){const b=$('#scan');b.disabled=true;b.textContent='↻ Scanning…';$('#status').textContent='Network scan started';try{const before=payload.last_scan;await api('/manage/scan',{method:'POST',body:'{}'});for(let i=0;i<90;i++){await new Promise(r=>setTimeout(r,2000));const s=await api('/public/discovery/summary');$('#status').textContent=s.scanning?'Scanning network…':`Found ${s.total} devices`;if(!s.scanning&&s.last_scan&&s.last_scan!==before)break}await load()}catch(err){$('#status').textContent=`Scan failed: ${err.message}`}finally{b.disabled=false;b.textContent='↻ Refresh Network'}}
$('#scan').addEventListener('click',scan);$('#search').addEventListener('input',render);$('#filter').addEventListener('change',render);load().catch(e=>$('#status').textContent=e.message);setInterval(()=>load().catch(()=>{}),15000);
})();
</script>
</body></html>
DEVICE_MANAGER_HTML

    cat >/usr/local/sbin/pi-network-status-api.py <<'STATUS_API_PY'
#!/usr/bin/env python3

import datetime as dt
import http.server
import ipaddress
import json
import os
import shutil
import socketserver
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, "/usr/local/lib/pi-network-status")
from kuma_normalizer import normalize_kuma_status
from device_manager import GROUPS, TYPE_TO_GROUP, device_label, effective_classification, ipv4_sort_key, merge_with_kuma, modem_ip_from_state

TOKEN = os.environ["STATUS_API_TOKEN"]
PORT = int(os.environ.get("STATUS_API_PORT", "9108"))
TARGET_IP = os.environ.get("TARGET_IP", "192.168.0.10")
GATEWAY = os.environ.get("GATEWAY", "192.168.0.1")
LAN_CIDR = os.environ.get("LAN_CIDR", "192.168.0.0/24")
DASHBOARD_PORT = int(os.environ.get("DASHBOARD_PORT", "3000"))
UNBOUND_PORT = os.environ.get("UNBOUND_PORT", "5335")
KUMA_LOCAL_URL = os.environ.get("KUMA_LOCAL_URL", "http://127.0.0.1:3001").rstrip("/")
KUMA_PUBLIC_URL = os.environ.get("KUMA_PUBLIC_URL", f"http://{TARGET_IP}:3001").rstrip("/")
KUMA_STATUS_SLUG = os.environ.get("KUMA_STATUS_SLUG", "home-network")
KUMA_CACHE_SECONDS = max(2, int(os.environ.get("KUMA_CACHE_SECONDS", "8")))
DEVICE_INVENTORY_FILE = Path(os.environ.get("DEVICE_INVENTORY_FILE", "/var/lib/pi4-network-stack/device-inventory.json"))
DISCOVERY_STATE_FILE = Path(os.environ.get("DISCOVERY_STATE_FILE", "/var/lib/pi4-network-stack/network-discovery.json"))
DEVICE_MANAGER_HTML = Path(os.environ.get("DEVICE_MANAGER_HTML", "/usr/local/share/pi-network-manager/devices.html"))
MODE_FILE = Path("/var/lib/pi4-network-stack/dns-upstream-mode")

_KUMA_CACHE = {"at": 0.0, "payload": None}


def run(cmd, timeout=3):
    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
        return result.returncode, result.stdout.strip()
    except Exception:
        return 1, ""


def active(service):
    rc, _ = run(["systemctl", "is-active", "--quiet", service])
    return rc == 0


def cpu_percent():
    def snapshot():
        parts = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
        vals = [int(x) for x in parts]
        idle = vals[3] + vals[4]
        total = sum(vals)
        return idle, total

    i1, t1 = snapshot()
    time.sleep(0.12)
    i2, t2 = snapshot()
    delta_t = max(t2 - t1, 1)
    delta_i = i2 - i1
    return round((1 - delta_i / delta_t) * 100, 1)


def memory_percent():
    data = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        k, v = line.split(":", 1)
        data[k] = int(v.strip().split()[0])
    total = data["MemTotal"]
    available = data.get("MemAvailable", data.get("MemFree", 0))
    return round((total - available) * 100 / total, 1)


def temp_c():
    try:
        return round(int(Path("/sys/class/thermal/thermal_zone0/temp").read_text()) / 1000, 1)
    except Exception:
        return None


def uptime_seconds():
    return int(float(Path("/proc/uptime").read_text().split()[0]))


def dns_test(server, port=None):
    cmd = ["dig", f"@{server}"]
    if port:
        cmd += ["-p", str(port)]
    cmd += ["example.com", "A", "+time=2", "+tries=1", "+stats"]
    start = time.monotonic()
    rc, out = run(cmd, timeout=4)
    ms = round((time.monotonic() - start) * 1000)
    return rc == 0 and "status: NOERROR" in out, ms


def tail_ip():
    rc, out = run(["tailscale", "ip", "-4"])
    return out.splitlines()[0] if rc == 0 and out else "Not connected"


def docker_containers():
    rc, out = run(["docker", "ps", "--format", "{{.Names}}"], timeout=4)
    if rc != 0:
        return []
    return [x for x in out.splitlines() if x]


def mode():
    try:
        return MODE_FILE.read_text().strip().capitalize()
    except Exception:
        return "Unknown"


def _get_json(url, timeout=4):
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "pi-network-status/1"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def _load_json(path: Path, fallback):
    try:
        payload = json.loads(path.read_text())
        return payload if isinstance(payload, dict) else fallback
    except Exception:
        return fallback


def _load_inventory():
    return _load_json(DEVICE_INVENTORY_FILE, {"devices": {}})


def _load_discovery():
    return _load_json(DISCOVERY_STATE_FILE, {"version": 1, "last_scan": None, "devices": {}})


def _save_discovery(payload):
    DISCOVERY_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = DISCOVERY_STATE_FILE.with_suffix(DISCOVERY_STATE_FILE.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, DISCOVERY_STATE_FILE)


def _unconfigured_payload(error=None):
    payload = {
        "configured": False,
        "published": False,
        "slug": KUMA_STATUS_SLUG,
        "status_page_url": f"{KUMA_PUBLIC_URL}/status/{KUMA_STATUS_SLUG}",
        "groups": [],
        "summary": {"total": 0, "up": 0, "down": 0, "pending": 0, "maintenance": 0, "unknown": 0},
    }
    if error:
        payload["error"] = error
    return payload


def kuma_payload(force=False):
    now = time.monotonic()
    if not force and _KUMA_CACHE["payload"] is not None and now - _KUMA_CACHE["at"] < KUMA_CACHE_SECONDS:
        return _KUMA_CACHE["payload"]

    status_url = f"{KUMA_LOCAL_URL}/api/status-page/{KUMA_STATUS_SLUG}"
    heartbeat_url = f"{KUMA_LOCAL_URL}/api/status-page/heartbeat/{KUMA_STATUS_SLUG}"
    try:
        status_page = _get_json(status_url)
    except urllib.error.HTTPError as exc:
        payload = _unconfigured_payload("status page is not published" if exc.code == 404 else f"Kuma status page HTTP {exc.code}")
        _KUMA_CACHE.update(at=now, payload=payload)
        return payload
    except Exception as exc:
        payload = _unconfigured_payload(f"Kuma status page unavailable: {type(exc).__name__}")
        _KUMA_CACHE.update(at=now, payload=payload)
        return payload

    heartbeat_error = None
    try:
        heartbeat_page = _get_json(heartbeat_url)
    except Exception as exc:
        heartbeat_page = {"heartbeatList": {}, "uptimeList": {}}
        heartbeat_error = f"Kuma heartbeat data unavailable: {type(exc).__name__}"

    payload = normalize_kuma_status(status_page, heartbeat_page, KUMA_PUBLIC_URL, KUMA_STATUS_SLUG, _load_inventory())
    if heartbeat_error:
        payload["warning"] = heartbeat_error
    _KUMA_CACHE.update(at=now, payload=payload)
    return payload


def unified_devices_payload():
    return merge_with_kuma(_load_discovery(), kuma_payload())


def discovery_summary():
    state = _load_discovery()
    present = [d for d in (state.get("devices") or {}).values() if isinstance(d, dict) and d.get("present")]
    classified = 0
    manual = 0
    hidden = 0
    for d in present:
        if d.get("manual_hidden"):
            hidden += 1
        eff = effective_classification(d)
        if eff["group"] != "unclassified":
            classified += 1
        if eff["source"] == "manual":
            manual += 1
    return {
        "last_scan": state.get("last_scan"),
        "total": len(present),
        "classified": classified,
        "unclassified": len(present) - classified,
        "manual": manual,
        "hidden": hidden,
        "scanning": active("pi-network-discovery.service"),
    }


def discovery_manager_payload():
    state = _load_discovery()
    monitors = []
    seen = set()
    for group in (kuma_payload() or {}).get("groups") or []:
        for monitor in group.get("monitors") or []:
            key = str(monitor.get("id") if monitor.get("id") is not None else monitor.get("name"))
            if key in seen:
                continue
            seen.add(key)
            monitors.append({"id": monitor.get("id"), "name": monitor.get("name") or key})
    monitors.sort(key=lambda m: (m.get("name") or "").lower())

    devices = []
    for key, record in (state.get("devices") or {}).items():
        if not isinstance(record, dict):
            continue
        eff = effective_classification(record)
        devices.append({
            "key": str(key),
            "name": device_label(record),
            "manual_name": record.get("manual_name") or "",
            "detected_name": (record.get("hostname") or record.get("vendor") or record.get("ip") or record.get("mac") or "Unknown device"),
            "ip": record.get("ip") or "",
            "mac": record.get("mac") or "",
            "hostname": record.get("hostname") or "",
            "vendor": record.get("vendor") or "",
            "present": bool(record.get("present")),
            "last_seen": record.get("last_seen"),
            "first_seen": record.get("first_seen"),
            "open_ports": list(record.get("open_ports") or []),
            "evidence": list(record.get("evidence") or []),
            "auto_type": record.get("suggested_type"),
            "auto_group": record.get("suggested_group"),
            "auto_confidence": float(record.get("confidence") or 0.0),
            "manual_type": record.get("manual_type") or record.get("approved_type"),
            "manual_group": record.get("manual_group") or record.get("approved_group"),
            "effective_type": eff["type"],
            "effective_group": eff["group"],
            "classification_source": eff["source"],
            "hidden": bool(record.get("manual_hidden", False)),
            "kuma_monitor": record.get("kuma_monitor") or "",
            "local_host": bool(record.get("local_host", False)),
            "model": record.get("model") or "",
        })
    devices.sort(key=ipv4_sort_key)
    summary = discovery_summary()
    return {
        **summary,
        "devices": devices,
        "groups": GROUPS,
        "types": TYPE_TO_GROUP,
        "kuma_monitors": monitors,
    }


def _validate_update(payload):
    key = str(payload.get("key") or "").strip()
    if not key:
        raise ValueError("device key is required")
    device_type = str(payload.get("type") or "auto").strip()
    group = str(payload.get("group") or "auto").strip()
    manual_name = str(payload.get("manual_name") or "").strip()
    if len(manual_name) > 120:
        raise ValueError("device name must be 120 characters or fewer")
    if device_type != "auto" and device_type not in TYPE_TO_GROUP:
        raise ValueError(f"unsupported device type: {device_type}")
    if group != "auto" and group not in GROUPS:
        raise ValueError(f"unsupported dashboard section: {group}")
    return key, device_type, group, manual_name


def update_device(payload, reset=False):
    state = _load_discovery()
    devices = state.setdefault("devices", {})
    key = str(payload.get("key") or "").strip()
    if key not in devices:
        raise KeyError("device not found")
    record = devices[key]
    if reset:
        for field in ("manual_type", "manual_group", "manual_hidden", "manual_at", "approved_type", "approved_group", "approved_at"):
            record.pop(field, None)
    else:
        key, device_type, group, manual_name = _validate_update(payload)
        if manual_name:
            record["manual_name"] = manual_name
        else:
            record.pop("manual_name", None)
        if device_type == "auto":
            record.pop("manual_type", None)
            record.pop("approved_type", None)
        else:
            record["manual_type"] = device_type
            record.pop("approved_type", None)
        if group == "auto":
            record.pop("manual_group", None)
            record.pop("approved_group", None)
        else:
            record["manual_group"] = group
            record.pop("approved_group", None)
        record["manual_hidden"] = bool(payload.get("hidden", False))
        mapping = str(payload.get("kuma_monitor") or "").strip()
        if mapping:
            record["kuma_monitor"] = mapping
        else:
            record.pop("kuma_monitor", None)
        record["manual_at"] = dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")
    _save_discovery(state)
    return record


class Handler(http.server.BaseHTTPRequestHandler):
    @staticmethod
    def _address_allowed(address):
        return (
            address.is_loopback
            or address in ipaddress.ip_network(LAN_CIDR, strict=False)
            or address in ipaddress.ip_network("100.64.0.0/10")
        )

    def _client_allowed(self):
        try:
            address = ipaddress.ip_address(self.client_address[0])
            return self._address_allowed(address)
        except Exception:
            return False

    def _origin_allowed(self):
        origin = self.headers.get("Origin", "").strip()
        if not origin:
            return True
        try:
            parsed_origin = urlsplit(origin)
            parsed_host = urlsplit(f"//{self.headers.get('Host', '')}")
            if parsed_origin.scheme not in ("http", "https"):
                return False
            if parsed_origin.username is not None or parsed_origin.password is not None:
                return False
            if parsed_origin.path not in ("", "/") or parsed_origin.query or parsed_origin.fragment:
                return False
            if parsed_host.username is not None or parsed_host.password is not None:
                return False
            if parsed_host.path or parsed_host.query or parsed_host.fragment:
                return False
            origin_address = ipaddress.ip_address(parsed_origin.hostname or "")
            host_address = ipaddress.ip_address(parsed_host.hostname or "")
            origin_port = parsed_origin.port or (443 if parsed_origin.scheme == "https" else 80)
            host_port = parsed_host.port or 80
            return (
                origin_address == host_address
                and self._address_allowed(origin_address)
                and host_port == PORT
                and origin_port in (DASHBOARD_PORT, PORT)
            )
        except (TypeError, ValueError):
            return False

    def _json_content_type(self):
        media_type = self.headers.get("Content-Type", "").partition(";")[0].strip().lower()
        return media_type == "application/json"

    def _cors_origin(self):
        origin = self.headers.get("Origin", "").strip()
        if origin and self._client_allowed() and self._origin_allowed():
            return origin
        return None

    def _json(self, payload, status=200, public=False, writable=False):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        if public:
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET")
        elif writable:
            origin = self._cors_origin()
            if origin:
                self.send_header("Access-Control-Allow-Origin", origin)
                self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
                self.send_header("Access-Control-Allow-Headers", "Content-Type")
                self.send_header("Vary", "Origin")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, text, status=200):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        return self.headers.get("X-API-Token", "") == TOKEN

    def _read_json(self):
        try:
            length = min(int(self.headers.get("Content-Length", "0") or 0), 65536)
        except ValueError:
            length = 0
        if length <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception as exc:
            raise ValueError("invalid JSON request") from exc

    def do_OPTIONS(self):
        path = self.path.split("?", 1)[0]
        origin = self._cors_origin()
        if path.startswith("/manage/") and origin:
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Access-Control-Max-Age", "600")
            self.send_header("Vary", "Origin")
            self.end_headers()
            return
        self.send_response(403)
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path == "/devices":
            if not self._client_allowed():
                self._html("<h1>Forbidden</h1>", 403)
                return
            try:
                text = DEVICE_MANAGER_HTML.read_text().replace("__TARGET_IP__", TARGET_IP)
            except Exception:
                self._html("<h1>Device manager unavailable</h1>", 503)
                return
            self._html(text)
            return

        if path in ("/public/devices/groups", "/public/discovery/devices", "/public/discovery/summary") and not self._client_allowed():
            self._json({"error": "LAN/Tailscale access required"}, 403, public=True)
            return
        if path == "/public/devices/groups":
            self._json(unified_devices_payload(), public=True)
            return
        if path == "/public/discovery/devices":
            self._json(discovery_manager_payload(), public=True)
            return
        if path == "/public/discovery/summary":
            self._json(discovery_summary(), public=True)
            return

        if path == "/public/kuma/groups":
            self._json(kuma_payload(), public=True)
            return
        if path == "/public/kuma/summary":
            payload = kuma_payload()
            self._json({
                "configured": payload.get("configured", False),
                "inventory_count": payload.get("inventory_count", 0),
                "summary": payload.get("summary", {}),
                "status_page_url": payload.get("status_page_url"),
            }, public=True)
            return
        if path == "/public/kuma/config":
            payload = kuma_payload()
            self._json({
                "configured": payload.get("configured", False),
                "published": payload.get("published", False),
                "inventory_count": payload.get("inventory_count", 0),
                "slug": KUMA_STATUS_SLUG,
                "status_page_url": payload.get("status_page_url"),
            }, public=True)
            return

        if not self._authorized():
            self._json({"error": "unauthorized"}, 401)
            return

        if path == "/api/system":
            disk = shutil.disk_usage("/")
            self._json({"status": "Online", "cpu": cpu_percent(), "memory": memory_percent(), "temperature": temp_c(), "disk": round(disk.used * 100 / disk.total, 1), "uptime": uptime_seconds()})
            return
        if path == "/api/unbound":
            ok, latency = dns_test("127.0.0.1", UNBOUND_PORT)
            self._json({"status": "Active" if active("unbound") and ok else "Degraded", "resolver": "Recursive", "dnssec": "Enabled", "latency": latency, "mode": mode()})
            return
        if path == "/api/pihole":
            ok, latency = dns_test(TARGET_IP)
            self._json({"status": "Active" if active("pihole-FTL") and ok else "Degraded", "filtering": "Enabled" if active("pihole-FTL") else "Unknown", "dhcp": "Disabled", "upstream": mode(), "latency": latency})
            return
        if path == "/api/tailscale":
            self._json({"status": "Active" if active("tailscaled") else "Inactive", "address": tail_ip(), "subnet": "Advertised", "ssh": "Enabled"})
            return
        if path == "/api/docker":
            containers = docker_containers()
            self._json({"status": "Active" if active("docker") else "Inactive", "running": len(containers), "containers": ", ".join(containers) if containers else "None"})
            return
        if path == "/api/network":
            gateway_ok = run(["ping", "-c", "1", "-W", "1", GATEWAY])[0] == 0
            internet_ok = run(["ping", "-c", "1", "-W", "1", "1.1.1.1"])[0] == 0
            self._json({"gateway": "Online" if gateway_ok else "Down", "internet": "Online" if internet_ok else "Down", "address": TARGET_IP, "modem_ip": modem_ip_from_state(_load_discovery()) or "Not set", "dns_path": f"Pi-hole -> {mode()}"})
            return
        if path == "/api/ssh":
            self._json({"status": "Active" if active("ssh") else "Inactive", "watchdog": "Active" if active("ssh-watchdog.timer") else "Inactive", "port": 22})
            return
        if path == "/api/discovery":
            s = discovery_summary()
            self._json({
                "status": "Scanning" if s["scanning"] else ("Ready" if s["last_scan"] else "Never"),
                "total": s["total"],
                "classified": s["classified"],
                "unclassified": s["unclassified"],
                "manual": s["manual"],
                "last_scan": s["last_scan"] or "Never",
            })
            return
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if not path.startswith("/manage/"):
            self._json({"error": "not found"}, 404, writable=True)
            return
        if not self._client_allowed():
            self._json({"error": "management is restricted to LAN/Tailscale clients"}, 403, writable=True)
            return
        if not self._origin_allowed():
            self._json({"error": "management request origin is not allowed"}, 403, writable=True)
            return
        if not self._json_content_type():
            self._json({"error": "management requests require application/json"}, 415, writable=True)
            return
        try:
            payload = self._read_json()
            if path == "/manage/scan":
                if active("pi-network-discovery.service"):
                    self._json({"started": False, "scanning": True, **discovery_summary()}, 202, writable=True)
                    return
                rc = subprocess.run(["systemctl", "start", "--no-block", "pi-network-discovery.service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
                if rc != 0:
                    self._json({"error": "could not start network discovery"}, 500, writable=True)
                    return
                self._json({"started": True, "scanning": True}, 202, writable=True)
                return
            if path == "/manage/device":
                record = update_device(payload, reset=False)
                self._json({"saved": True, "effective": effective_classification(record)}, writable=True)
                return
            if path == "/manage/device/reset":
                record = update_device(payload, reset=True)
                self._json({"saved": True, "effective": effective_classification(record)}, writable=True)
                return
            self._json({"error": "not found"}, 404, writable=True)
        except KeyError as exc:
            self._json({"error": str(exc)}, 404, writable=True)
        except ValueError as exc:
            self._json({"error": str(exc)}, 400, writable=True)
        except Exception as exc:
            self._json({"error": f"management error: {type(exc).__name__}"}, 500, writable=True)

    def log_message(self, fmt, *args):
        return


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with Server(("0.0.0.0", PORT), Handler) as server:
        server.serve_forever()
STATUS_API_PY

    chmod 0755 /usr/local/sbin/pi-network-status-api.py
    chmod 0644 /usr/local/lib/pi-network-status/kuma_normalizer.py
    chmod 0644 /usr/local/lib/pi-network-status/device_manager.py
    chmod 0644 /usr/local/share/pi-network-manager/devices.html

    cat >/etc/default/pi-network-status-api <<EOF
STATUS_API_TOKEN=${status_token}
STATUS_API_PORT=${STATUS_API_PORT}
TARGET_IP=${TARGET_IP}
GATEWAY=${GATEWAY}
UNBOUND_PORT=${UNBOUND_PORT}
KUMA_LOCAL_URL=http://127.0.0.1:${UPTIME_KUMA_PORT}
KUMA_PUBLIC_URL=http://${TARGET_IP}:${UPTIME_KUMA_PORT}
KUMA_STATUS_SLUG=${KUMA_STATUS_SLUG}
KUMA_CACHE_SECONDS=${KUMA_CACHE_SECONDS}
DEVICE_INVENTORY_FILE=${STATE_DIR}/device-inventory.json
DISCOVERY_STATE_FILE=${STATE_DIR}/network-discovery.json
DEVICE_MANAGER_HTML=/usr/local/share/pi-network-manager/devices.html
LAN_CIDR=${LAN_CIDR}
DASHBOARD_PORT=${DASHBOARD_PORT}
EOF
    chmod 600 /etc/default/pi-network-status-api

    cat >/etc/systemd/system/pi-network-status-api.service <<'EOF'
[Unit]
Description=Home-network telemetry and LAN device-management API
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/default/pi-network-status-api
ExecStart=/usr/local/sbin/pi-network-status-api.py
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/run /var/lib/pi4-network-stack
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now pi-network-status-api.service
    systemctl restart pi-network-status-api.service

    retry 15 1 curl -fsS \
        -H "X-API-Token: ${status_token}" \
        "http://127.0.0.1:${STATUS_API_PORT}/api/system" >/dev/null ||
        die "Dashboard status API did not start."

    retry 15 1 curl -fsS \
        "http://127.0.0.1:${STATUS_API_PORT}/public/kuma/config" >/dev/null ||
        die "Dashboard Kuma integration API did not start."

    retry 15 1 curl -fsS \
        "http://127.0.0.1:${STATUS_API_PORT}/public/discovery/devices" >/dev/null ||
        die "Network device manager API did not start."
}

# =============================================================================
# Uptime Kuma + Homepage professional dashboard
# =============================================================================

install_dashboard_stack() {
    log "Installing Uptime Kuma and professional Homepage dashboard"

    STATUS_TOKEN="$(cat "${STATUS_TOKEN_FILE}")"

    mkdir -p \
        "${UPTIME_DIR}/data" \
        "${HOMEPAGE_DIR}/config"

    # Tailscale address is added to Homepage's allowed-host list when available.
    TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"

    HOMEPAGE_ALLOWED="${TARGET_IP}:${DASHBOARD_PORT},${HOSTNAME_SHORT}:${DASHBOARD_PORT},localhost:${DASHBOARD_PORT},127.0.0.1:${DASHBOARD_PORT}"

    if [[ -n "${TAILSCALE_IP}" ]]; then
        HOMEPAGE_ALLOWED="${HOMEPAGE_ALLOWED},${TAILSCALE_IP}:${DASHBOARD_PORT}"
    fi

    # Preserve an existing Uptime Kuma installation instead of deleting or
    # replacing its database. This is common when Kuma was installed earlier
    # under /opt/uptime-kuma/data. Only containers already owned by this Compose
    # project are managed by the stack.
    UPTIME_EXISTING=0
    EXISTING_UPTIME_PROJECT=""
    EXISTING_UPTIME_IMAGE=""
    EXISTING_UPTIME_DATA=""
    EXPECTED_COMPOSE_PROJECT="$(basename "${APPS_DIR}")"

    if docker inspect uptime-kuma >/dev/null 2>&1; then
        EXISTING_UPTIME_PROJECT="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' uptime-kuma 2>/dev/null || true)"
        EXISTING_UPTIME_IMAGE="$(docker inspect -f '{{.Config.Image}}' uptime-kuma 2>/dev/null || true)"
        EXISTING_UPTIME_DATA="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}' uptime-kuma 2>/dev/null || true)"

        if [[ "${EXISTING_UPTIME_IMAGE}" != louislam/uptime-kuma:* ]]; then
            die "Container name uptime-kuma is already used by unexpected image: ${EXISTING_UPTIME_IMAGE:-unknown}."
        fi

        if [[ "${EXISTING_UPTIME_PROJECT}" != "${EXPECTED_COMPOSE_PROJECT}" ]]; then
            UPTIME_EXISTING=1
            info "Adopting existing Uptime Kuma container without replacing its data."
            info "Existing data: ${EXISTING_UPTIME_DATA:-unknown}"

            if [[ "$(docker inspect -f '{{.State.Running}}' uptime-kuma 2>/dev/null || true)" != "true" ]]; then
                docker start uptime-kuma >/dev/null
            fi
        fi
    fi

    if (( UPTIME_EXISTING )); then
        # Existing Kuma remains owned by its original Compose project. Homepage
        # reaches it through the host-published port instead of Docker DNS.
        cat >"${APPS_DIR}/compose.yaml" <<EOF
services:
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    ports:
      - "${DASHBOARD_PORT}:3000"
    volumes:
      - ${HOMEPAGE_DIR}/config:/app/config
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      HOMEPAGE_ALLOWED_HOSTS: "${HOMEPAGE_ALLOWED}"
      LOG_TARGETS: stdout
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
    else
        cat >"${APPS_DIR}/compose.yaml" <<EOF
services:
  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    restart: unless-stopped
    volumes:
      - ${UPTIME_DIR}/data:/app/data
    ports:
      - "${UPTIME_KUMA_PORT}:3001"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    depends_on:
      - uptime-kuma
    ports:
      - "${DASHBOARD_PORT}:3000"
    volumes:
      - ${HOMEPAGE_DIR}/config:/app/config
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      HOMEPAGE_ALLOWED_HOSTS: "${HOMEPAGE_ALLOWED}"
      LOG_TARGETS: stdout
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
    fi

    cat >"${HOMEPAGE_DIR}/config/settings.yaml" <<'EOF'
title: Home Network
description: Raspberry Pi Network Operations
theme: dark
color: slate
headerStyle: clean
cardBlur: md
statusStyle: dot
fullWidth: true
useEqualHeights: true
disableCollapse: true
disableIndexing: true
target: _blank
language: en
layout:
  Core Network:
    style: row
    columns: 4
  Operations:
    style: row
    columns: 4
  System:
    style: row
    columns: 3
EOF

    cat >"${HOMEPAGE_DIR}/config/widgets.yaml" <<'EOF'
- greeting:
    text_size: xl
    text: Network Operations
- datetime:
    text_size: xl
    format:
      dateStyle: medium
      timeStyle: short
      hourCycle: h23
EOF

    cat >"${HOMEPAGE_DIR}/config/services.yaml" <<EOF
- Core Network:
    - Pi-hole:
        id: pihole-card
        icon: pi-hole.png
        href: http://${TARGET_IP}/admin/
        description: DNS filtering and network-wide blocking
        siteMonitor: http://host.docker.internal/admin/
        widget:
          type: customapi
          url: http://host.docker.internal:${STATUS_API_PORT}/api/pihole
          headers:
            X-API-Token: ${STATUS_TOKEN}
          refreshInterval: 10000
          mappings:
            - field: status
              label: Status
            - field: upstream
              label: Upstream
            - field: dhcp
              label: DHCP
            - field: latency
              label: DNS
              format: number
              suffix: " ms"

    - Unbound:
        id: unbound-card
        icon: mdi-shield-check
        description: Private recursive DNS with DNSSEC validation
        widget:
          type: customapi
          url: http://host.docker.internal:${STATUS_API_PORT}/api/unbound
          headers:
            X-API-Token: ${STATUS_TOKEN}
          refreshInterval: 10000
          mappings:
            - field: status
              label: Status
            - field: resolver
              label: Resolver
            - field: dnssec
              label: DNSSEC
            - field: latency
              label: Resolve
              format: number
              suffix: " ms"

    - Uptime Kuma:
        id: uptime-card
        icon: uptime-kuma.png
        href: http://${TARGET_IP}:${UPTIME_KUMA_PORT}
        description: Service availability and network monitoring
        siteMonitor: http://host.docker.internal:${UPTIME_KUMA_PORT}

    - Tailscale:
        id: tailscale-card
        icon: tailscale.png
        href: https://login.tailscale.com/admin/machines
        description: Secure remote access and subnet routing
        widget:
          type: customapi
          url: http://host.docker.internal:${STATUS_API_PORT}/api/tailscale
          headers:
            X-API-Token: ${STATUS_TOKEN}
          refreshInterval: 15000
          mappings:
            - field: status
              label: Status
            - field: address
              label: Tail IP
            - field: subnet
              label: Subnet
            - field: ssh
              label: SSH

- Operations:
    - Network:
        id: network-card
        icon: mdi-lan
        description: Gateway, Internet and DNS path
        widget:
          type: customapi
          url: http://host.docker.internal:${STATUS_API_PORT}/api/network
          headers:
            X-API-Token: ${STATUS_TOKEN}
          refreshInterval: 10000
          mappings:
            - field: gateway
              label: Gateway
            - field: internet
              label: Internet
            - field: address
              label: Pi IP
            - field: modem_ip
              label: Modem IP
            - field: dns_path
              label: DNS path

    - Docker:
        id: docker-card
        icon: docker.png
        description: Dashboard application runtime
        widget:
          type: customapi
          url: http://host.docker.internal:${STATUS_API_PORT}/api/docker
          headers:
            X-API-Token: ${STATUS_TOKEN}
          refreshInterval: 10000
          mappings:
            - field: status
              label: Engine
            - field: running
              label: Running
              format: number
            - field: containers
              label: Containers

    - SSH Recovery:
        id: ssh-card
        icon: mdi-console
        description: LAN administration with automatic health recovery
        widget:
          type: customapi
          url: http://host.docker.internal:${STATUS_API_PORT}/api/ssh
          headers:
            X-API-Token: ${STATUS_TOKEN}
          refreshInterval: 15000
          mappings:
            - field: status
              label: SSH
            - field: watchdog
              label: Watchdog
            - field: port
              label: Port
              format: number

    - Network Discovery:
        id: discovery-card
        icon: mdi-radar
        description: Automatic conservative discovery with persistent manual overrides
        widget:
          type: customapi
          url: http://host.docker.internal:${STATUS_API_PORT}/api/discovery
          headers:
            X-API-Token: ${STATUS_TOKEN}
          refreshInterval: 15000
          mappings:
            - field: status
              label: Status
            - field: total
              label: Devices
              format: number
            - field: classified
              label: Grouped
              format: number
            - field: unclassified
              label: Unclassified
              format: number

- System:
    - Raspberry Pi 4B:
        id: system-card
        icon: raspberry-pi.png
        description: Host resource health
        widget:
          type: customapi
          url: http://host.docker.internal:${STATUS_API_PORT}/api/system
          headers:
            X-API-Token: ${STATUS_TOKEN}
          refreshInterval: 5000
          mappings:
            - field: cpu
              label: CPU
              format: float
              suffix: " %"
            - field: memory
              label: Memory
              format: float
              suffix: " %"
            - field: temperature
              label: Temp
              format: float
              suffix: " °C"
            - field: disk
              label: Disk
              format: float
              suffix: " %"
EOF

    cat >"${HOMEPAGE_DIR}/config/bookmarks.yaml" <<EOF
- Administration:
    - Router:
        - icon: mdi-router-wireless
          href: http://${GATEWAY}
    - Tailscale Admin:
        - icon: tailscale.png
          href: https://login.tailscale.com/admin/machines
EOF

    cat >"${HOMEPAGE_DIR}/config/custom.css" <<'HOMEPAGE_CUSTOM_CSS'
/* Professional dark network-operations theme */

body {
  background:
    radial-gradient(circle at 15% 5%, rgba(20, 184, 166, 0.10), transparent 30%),
    radial-gradient(circle at 88% 12%, rgba(99, 102, 241, 0.11), transparent 32%),
    linear-gradient(145deg, #07111f 0%, #0b1220 45%, #090d17 100%) !important;
  background-attachment: fixed !important;
}

#page_container {
  max-width: 1680px !important;
  margin: 0 auto !important;
}

#pihole-card,
#unbound-card,
#uptime-card,
#tailscale-card,
#network-card,
#docker-card,
#ssh-card,
#discovery-card,
#system-card {
  border: 1px solid rgba(148, 163, 184, 0.12) !important;
  border-radius: 18px !important;
  background: linear-gradient(
    145deg,
    rgba(15, 23, 42, 0.88),
    rgba(17, 24, 39, 0.76)
  ) !important;
  box-shadow:
    0 18px 40px rgba(0, 0, 0, 0.23),
    inset 0 1px 0 rgba(255, 255, 255, 0.025) !important;
  transition:
    transform 160ms ease,
    border-color 160ms ease,
    box-shadow 160ms ease !important;
}

#pihole-card:hover,
#unbound-card:hover,
#uptime-card:hover,
#tailscale-card:hover,
#network-card:hover,
#docker-card:hover,
#ssh-card:hover,
#discovery-card:hover,
#system-card:hover {
  transform: translateY(-2px);
  border-color: rgba(45, 212, 191, 0.35) !important;
  box-shadow:
    0 22px 50px rgba(0, 0, 0, 0.30),
    0 0 0 1px rgba(45, 212, 191, 0.07) !important;
}

#pihole-card {
  border-top: 2px solid rgba(34, 197, 94, 0.65) !important;
}

#unbound-card {
  border-top: 2px solid rgba(56, 189, 248, 0.65) !important;
}

#uptime-card {
  border-top: 2px solid rgba(99, 102, 241, 0.70) !important;
}

#tailscale-card {
  border-top: 2px solid rgba(168, 85, 247, 0.70) !important;
}

#discovery-card {
  border-top: 2px solid rgba(245, 158, 11, 0.72) !important;
}

#system-card {
  border-top: 2px solid rgba(45, 212, 191, 0.65) !important;
}


.network-action-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.8rem;
  min-height: 3.35rem;
  margin-bottom: 0.7rem;
  padding: 0.62rem 0.72rem;
  border: 1px solid rgba(148, 163, 184, 0.12);
  border-radius: 12px;
  background: rgba(15, 23, 42, 0.70);
  box-sizing: border-box;
}
.network-scan-copy { display: flex; min-width: 0; align-items: baseline; gap: 0.5rem; flex-wrap: wrap; }
.network-scan-title { color: rgb(226, 232, 240); font-size: 0.84rem; font-weight: 600; }
.network-scan-total,
.network-scan-age,
.network-scan-message { color: rgb(100, 116, 139); font-size: 0.68rem; }
.network-scan-actions { display: flex; align-items: center; gap: 0.5rem; flex: 0 0 auto; }
.network-refresh-button,
.network-manage-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 2rem;
  padding: 0.38rem 0.72rem;
  border: 1px solid rgba(148, 163, 184, 0.20);
  border-radius: 9px;
  background: rgba(30, 41, 59, 0.72);
  color: rgb(203, 213, 225);
  font-size: 0.72rem;
  text-decoration: none;
  transition: border-color 140ms ease, background 140ms ease, transform 140ms ease;
}
.network-refresh-button {
  cursor: pointer;
  border-color: rgba(45, 212, 191, 0.42);
  background: rgba(13, 148, 136, 0.24);
  color: rgb(204, 251, 241);
  font: inherit;
  font-size: 0.72rem;
  font-weight: 600;
}
.network-refresh-button:hover, .network-manage-button:hover { border-color: rgba(45, 212, 191, 0.50); background: rgba(15, 118, 110, 0.15); transform: translateY(-1px); }
.network-refresh-button:disabled { opacity: 0.58; cursor: wait; transform: none; }
.network-scan-message { min-width: 8rem; }
@media (max-width: 680px) {
  .network-action-toolbar { align-items: stretch; flex-direction: column; }
  .network-scan-copy { align-items: flex-start; flex-direction: column; gap: 0.12rem; }
  .network-scan-actions { width: 100%; }
  .network-refresh-button, .network-manage-button { flex: 1 1 0; }
}

#kuma-monitored-devices {
  margin-top: 1.2rem;
  margin-bottom: 1.25rem;
}

.kuma-device-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  align-items: start;
  gap: 0.75rem;
}

.kuma-device-card {
  min-width: 0;
  overflow: hidden;
  border: 1px solid rgba(148, 163, 184, 0.12);
  border-radius: 18px;
  background: linear-gradient(145deg, rgba(15, 23, 42, 0.88), rgba(17, 24, 39, 0.76));
  box-shadow: 0 18px 40px rgba(0, 0, 0, 0.23), inset 0 1px 0 rgba(255, 255, 255, 0.025);
  transition: transform 160ms ease, border-color 160ms ease, box-shadow 160ms ease;
}

.kuma-device-card:hover {
  transform: translateY(-2px);
  border-color: rgba(45, 212, 191, 0.32);
  box-shadow: 0 22px 50px rgba(0, 0, 0, 0.28), 0 0 0 1px rgba(45, 212, 191, 0.05);
}

.kuma-device-card[data-kuma-group="infrastructure"] { border-top: 2px solid rgba(45, 212, 191, 0.72); }
.kuma-device-card[data-kuma-group="storage"]        { border-top: 2px solid rgba(56, 189, 248, 0.72); }
.kuma-device-card[data-kuma-group="smart-home"]     { border-top: 2px solid rgba(168, 85, 247, 0.74); }
.kuma-device-card[data-kuma-group="security"]       { border-top: 2px solid rgba(248, 113, 113, 0.70); }
.kuma-device-card[data-kuma-group="services"]       { border-top: 2px solid rgba(99, 102, 241, 0.76); }
.kuma-device-card[data-kuma-group="websites"]       { border-top: 2px solid rgba(34, 197, 94, 0.70); }
.kuma-device-card[data-kuma-group="other"]          { border-top: 2px solid rgba(251, 191, 36, 0.68); }
.kuma-device-card[data-kuma-group="unclassified"]   { border-top: 2px solid rgba(100, 116, 139, 0.72); }

.kuma-device-card-header {
  display: flex;
  align-items: center;
  gap: 0.55rem;
  min-height: 3rem;
  padding: 0.72rem 0.82rem 0.62rem;
  border-bottom: 1px solid rgba(148, 163, 184, 0.10);
}

.kuma-group-icon,
.kuma-device-type-icon,
.kuma-device-status-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: 0 0 auto;
}

.kuma-group-icon,
.kuma-device-type-icon { color: rgb(203, 213, 225); }
.kuma-group-icon svg { width: 1.15rem; height: 1.15rem; }
.kuma-device-type-icon svg { width: 1rem; height: 1rem; }
.kuma-device-status-icon svg { width: 1rem; height: 1rem; }

.kuma-group-title {
  min-width: 0;
  flex: 1 1 auto;
  color: rgb(226, 232, 240);
  font-size: 0.88rem;
  font-weight: 500;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.kuma-group-count { color: rgb(100, 116, 139); font-size: 0.68rem; }
.kuma-device-list { display: flex; flex-direction: column; }

.kuma-device-row {
  display: grid;
  grid-template-columns: 1.2rem minmax(0, 1fr) auto 1.15rem;
  align-items: center;
  gap: 0.5rem;
  min-height: 2.45rem;
  padding: 0.45rem 0.78rem;
  color: inherit;
  text-decoration: none;
  border-bottom: 1px solid rgba(148, 163, 184, 0.08);
  transition: background 140ms ease, transform 140ms ease;
}

.kuma-device-row:last-child { border-bottom: 0; }
.kuma-device-row:hover { background: rgba(51, 65, 85, 0.34); transform: translateX(1px); }
.kuma-device-copy { min-width: 0; }

.kuma-device-name {
  display: block;
  color: rgb(203, 213, 225);
  font-size: 0.79rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.kuma-device-uptime { display: block; margin-top: 0.05rem; color: rgb(100, 116, 139); font-size: 0.62rem; }
.kuma-device-latency { min-width: 2.9rem; text-align: right; color: rgb(148, 163, 184); font-size: 0.7rem; font-variant-numeric: tabular-nums; }
.kuma-status-up { color: rgb(16, 185, 129); }
.kuma-status-down { color: rgb(248, 113, 113); }
.kuma-status-pending { color: rgb(251, 191, 36); }
.kuma-status-maintenance { color: rgb(148, 163, 184); }
.kuma-status-unknown { color: rgb(100, 116, 139); }
.kuma-device-unclassified .kuma-device-type-icon { color: rgb(100, 116, 139); }

.kuma-summary-strip { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.35rem; margin-top: 0.5rem; }
.kuma-summary-cell { padding: 0.28rem 0.4rem; border-radius: 6px; background: rgba(15, 23, 42, 0.40); text-align: center; }
.kuma-summary-value { display: block; color: rgb(203, 213, 225); font-size: 0.72rem; }
.kuma-summary-label { display: block; margin-top: 0.08rem; color: rgb(100, 116, 139); font-size: 0.53rem; text-transform: uppercase; letter-spacing: 0.04em; }
.kuma-summary-down .kuma-summary-value,
.kuma-summary-down .kuma-summary-label { color: rgb(248, 113, 113); }

@media (max-width: 1180px) {
  .kuma-device-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

@media (max-width: 680px) {
  .kuma-device-grid { grid-template-columns: minmax(0, 1fr); }
}
HOMEPAGE_CUSTOM_CSS

    cat >"${HOMEPAGE_DIR}/config/custom.js" <<'HOMEPAGE_CUSTOM_JS'
/* Automatic-discovery device dashboard. Generated by pi4_home_network_stack_v3_8_1.sh. */
(() => {
  'use strict';

  const API_PORT = __STATUS_API_PORT__;
  const REFRESH_MS = 10000;
  const SECTION_ID = 'kuma-monitored-devices';
  const ACTION_ROW_ID = 'network-action-row';
  const API_BASE = `${window.location.protocol}//${window.location.hostname}:${API_PORT}`;

  const DEVICE_SVGS = {
    'access-point': '<path d="M4 9a12 12 0 0 1 16 0"/><path d="M7 12a8 8 0 0 1 10 0"/><path d="M10 15a4 4 0 0 1 4 0"/><circle cx="12" cy="18" r="1"/>',
    router: '<rect x="3" y="9" width="18" height="9" rx="2"/><path d="M7 9V5m10 4V5"/><circle cx="8" cy="13.5" r=".8"/><circle cx="11" cy="13.5" r=".8"/><path d="M15 14h3"/>',
    modem: '<rect x="4" y="5" width="16" height="14" rx="2"/><path d="M7 9h10M7 13h4"/><circle cx="16" cy="13" r="1"/>',
    switch: '<rect x="3" y="6" width="18" height="12" rx="2"/><rect x="6" y="10" width="2" height="2"/><rect x="10" y="10" width="2" height="2"/><rect x="14" y="10" width="2" height="2"/><path d="M6 15h12"/>',
    'network-device': '<circle cx="6" cy="12" r="2"/><circle cx="18" cy="7" r="2"/><circle cx="18" cy="17" r="2"/><path d="M8 12h5m1-1l2.5-2.5M14 13l2.5 2.5"/>',
    nas: '<ellipse cx="12" cy="5" rx="7" ry="3"/><path d="M5 5v6c0 1.7 3.1 3 7 3s7-1.3 7-3V5"/><path d="M5 11v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6"/>',
    storage: '<ellipse cx="12" cy="5" rx="7" ry="3"/><path d="M5 5v6c0 1.7 3.1 3 7 3s7-1.3 7-3V5"/><path d="M5 11v6c0 1.7 3.1 3 7 3s7-1.3 7-3v-6"/>',
    server: '<rect x="4" y="3" width="16" height="6" rx="1.5"/><rect x="4" y="10" width="16" height="6" rx="1.5"/><rect x="4" y="17" width="16" height="4" rx="1.5"/><circle cx="7" cy="6" r=".7"/><circle cx="7" cy="13" r=".7"/><circle cx="7" cy="19" r=".7"/>',
    'raspberry-pi': '<rect x="5" y="5" width="14" height="14" rx="2"/><path d="M9 2v3m6-3v3M9 19v3m6-3v3M2 9h3m-3 6h3m14-6h3m-3 6h3"/><circle cx="12" cy="12" r="3"/>',
    printer: '<path d="M7 8V3h10v5"/><rect x="4" y="8" width="16" height="9" rx="2"/><path d="M7 14h10v7H7z"/><circle cx="17" cy="11" r=".7"/>',
    camera: '<rect x="3" y="7" width="18" height="12" rx="2"/><path d="M8 7l1.5-3h5L16 7"/><circle cx="12" cy="13" r="3.5"/>',
    nvr: '<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="8" cy="12" r="2.5"/><path d="M13 9h5m-5 3h5m-5 3h3"/>',
    security: '<path d="M12 3l7 3v5c0 4.5-2.7 8-7 10-4.3-2-7-5.5-7-10V6l7-3z"/><path d="M9 12l2 2 4-5"/>',
    dns: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18"/>',
    website: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18"/>',
    service: '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9L12 3z"/><path d="M4 7.5l8 4.5 8-4.5M12 12v9"/>',
    'smart-home': '<path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/><circle cx="12" cy="14" r="2"/>',
    iot: '<rect x="6" y="6" width="12" height="12" rx="3"/><path d="M9 2v4m6-4v4M9 18v4m6-4v4M2 9h4m-4 6h4m12-6h4m-4 6h4"/><circle cx="12" cy="12" r="2"/>',
    sensor: '<path d="M12 3v10"/><circle cx="12" cy="17" r="4"/><path d="M8 6a6 6 0 0 0 0 8m8-8a6 6 0 0 1 0 8"/>',
    bridge: '<path d="M3 17h18M5 17V9m14 8V9M5 11h14M8 11V7m8 4V7M8 7h8"/>',
    tv: '<rect x="3" y="5" width="18" height="13" rx="2"/><path d="M8 22h8M12 18v4"/>',
    speaker: '<rect x="6" y="3" width="12" height="18" rx="2"/><circle cx="12" cy="9" r="2"/><circle cx="12" cy="16" r="3"/>',
    other: '<rect x="4" y="4" width="16" height="16" rx="3"/><path d="M8 12h8M12 8v8"/>',
  };

  const GROUP_ICONS = {
    infrastructure: 'switch',
    storage: 'nas',
    'smart-home': 'smart-home',
    security: 'security',
    services: 'service',
    websites: 'website',
    other: 'other',
    unclassified: 'other',
  };

  const STATUS_SVGS = {
    up: '<circle cx="12" cy="12" r="9"/><path d="M8 12.5l2.5 2.5L16.5 9"/>',
    down: '<circle cx="12" cy="12" r="9"/><path d="M9 9l6 6m0-6l-6 6"/>',
    pending: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    maintenance: '<circle cx="12" cy="12" r="9"/><path d="M10 9v6m4-6v6"/>',
    unknown: '<circle cx="12" cy="12" r="9"/><path d="M9.7 9a2.5 2.5 0 1 1 3.2 2.4c-.8.3-.9.9-.9 1.6"/><circle cx="12" cy="16.5" r=".6"/>',
  };

  function statusIconKey(status) { return ({ 0: 'down', 1: 'up', 2: 'pending', 3: 'maintenance' })[Number(status)] ?? 'unknown'; }
  function deviceIconKey(type) { return Object.hasOwn(DEVICE_SVGS, type) ? type : 'other'; }
  function safeText(value) { return String(value ?? '').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#039;'); }
  function svgIcon(markup) { return `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${markup}</svg>`; }

  function formatLatency(monitor) {
    if (monitor.status === 0) return 'DOWN';
    if (monitor.status === 3) return 'MAINT';
    if (monitor.latency_ms === null || monitor.latency_ms === undefined) {
      if (monitor.source === 'discovery' && monitor.ip) return monitor.ip;
      return monitor.status_label || 'Unknown';
    }
    return `${monitor.latency_ms} ms`;
  }

  function ipv4SortKey(value) {
    const parts = String(value || '').split('.');
    if (parts.length !== 4 || parts.some((part) => !/^\d+$/.test(part) || Number(part) > 255)) return [1, 0];
    return [0, parts.reduce((total, part) => (total * 256) + Number(part), 0)];
  }

  function compareByIp(a, b) {
    const left = ipv4SortKey(a?.ip);
    const right = ipv4SortKey(b?.ip);
    return (left[0] - right[0]) || (left[1] - right[1]) || String(a?.name || '').localeCompare(String(b?.name || ''));
  }

  function formatUptime(value) {
    if (value === null || value === undefined) return '';
    const number = Number(value);
    if (!Number.isFinite(number)) return '';
    return `${number.toFixed(number >= 99.995 ? 2 : 1)}% / 24h`;
  }

  function formatScanAge(value) {
    if (!value) return 'Not scanned yet';
    const scannedAt = new Date(value);
    if (Number.isNaN(scannedAt.getTime())) return 'Last scan unavailable';
    const seconds = Math.max(0, Math.floor((Date.now() - scannedAt.getTime()) / 1000));
    if (seconds < 60) return 'Last scanned just now';
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `Last scanned ${minutes}m ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `Last scanned ${hours}h ago`;
    return `Last scanned ${Math.floor(hours / 24)}d ago`;
  }

  function groupCard(group) {
    const groupIcon = GROUP_ICONS[group.key] || 'other';
    const rows = [...(group.monitors || [])].sort(compareByIp).map((monitor) => {
      const deviceKey = deviceIconKey(monitor.device_type);
      const statusKey = statusIconKey(monitor.status);
      const className = monitor.classified ? '' : ' kuma-device-unclassified';
      const uptime = formatUptime(monitor.uptime_24);
      const title = monitor.classified ? `${monitor.device_type} / ${monitor.group}` : 'Unclassified: use pi-device-inventory to assign type/group';
      const href = monitor.source === 'discovery' ? `${API_BASE}/devices#${encodeURIComponent(monitor.discovery_key || '')}` : monitor.href;
      return `
        <a class="kuma-device-row${className}" href="${safeText(href)}" target="_blank" rel="noopener noreferrer" title="${safeText(title)}">
          <span class="kuma-device-type-icon">${svgIcon(DEVICE_SVGS[deviceKey] || DEVICE_SVGS.other)}</span>
          <span class="kuma-device-copy">
            <span class="kuma-device-name">${safeText(monitor.name)}</span>
            ${uptime ? `<span class="kuma-device-uptime">${safeText(uptime)}</span>` : ''}
          </span>
          <span class="kuma-device-latency">${safeText(formatLatency(monitor))}</span>
          <span class="kuma-device-status-icon kuma-status-${statusKey}" title="${safeText(monitor.status_label || 'Unknown')}">${svgIcon(STATUS_SVGS[statusKey])}</span>
        </a>`;
    }).join('');

    return `
      <article class="kuma-device-card" data-kuma-group="${safeText(group.key)}">
        <header class="kuma-device-card-header">
          <span class="kuma-group-icon">${svgIcon(DEVICE_SVGS[groupIcon] || DEVICE_SVGS.other)}</span>
          <span class="kuma-group-title">${safeText(group.title)}</span>
          <span class="kuma-group-count">${Number(group.monitors?.length || 0)}</span>
        </header>
        <div class="kuma-device-list">${rows}</div>
      </article>`;
  }

  function findMountPoint() {
    const bookmarks = document.querySelector('#bookmarks');
    if (bookmarks?.parentElement) return { parent: bookmarks.parentElement, before: bookmarks };
    const services = document.querySelector('#services');
    if (services?.parentElement) return { parent: services.parentElement, before: services.nextSibling };
    const page = document.querySelector('#page_container');
    return page ? { parent: page, before: null } : null;
  }

  // The dynamically inserted Kuma section is a sibling of Homepage's own
  // sections, not one of Homepage's generated service groups. Derive its
  // horizontal inset from an existing Homepage section so it follows the same
  // left/right gutters at every viewport width instead of bleeding to the edge.
  function alignKumaSection(section) {
    if (!section) return;
    const mount = findMountPoint();
    if (!mount?.parent) return;

    const reference = document.querySelector('#bookmarks') || document.querySelector('#services');
    if (!reference) return;

    const parentRect = mount.parent.getBoundingClientRect();
    const referenceRect = reference.getBoundingClientRect();
    const leftInset = Math.max(0, Math.round(referenceRect.left - parentRect.left));
    const rightInset = Math.max(0, Math.round(parentRect.right - referenceRect.right));

    section.style.marginLeft = `${leftInset}px`;
    section.style.marginRight = `${rightInset}px`;
    section.style.width = 'auto';
    section.style.boxSizing = 'border-box';
  }

  function ensureSection() {
    let section = document.getElementById(SECTION_ID);
    if (section) {
      alignKumaSection(section);
      ensureNetworkToolbar(section);
      return section;
    }
    const mount = findMountPoint();
    if (!mount) return null;
    section = document.createElement('section');
    section.id = SECTION_ID;
    section.innerHTML = '<div class="kuma-device-grid"></div>';
    mount.parent.insertBefore(section, mount.before);
    ensureNetworkToolbar(section);
    alignKumaSection(section);
    window.requestAnimationFrame(() => alignKumaSection(section));
    return section;
  }

  function renderPayload(payload) {
    const section = ensureSection();
    if (!section) return;
    updateNetworkToolbar(payload?.last_scan, payload?.summary?.total);
    const grid = section.querySelector('.kuma-device-grid');
    if (!payload || payload.configured === false) {
      grid.innerHTML = '<article class="kuma-device-card" data-kuma-group="unclassified"><div class="kuma-device-card-header"><span class="kuma-group-title">Uptime Kuma status page unavailable</span></div></article>';
      return;
    }
    const groups = payload.groups || [];
    grid.innerHTML = groups.length ? groups.map(groupCard).join('') : '';
  }

  function updateKumaSummary(summary) {
    const card = document.getElementById('uptime-card');
    if (!card || !summary) return;
    let strip = card.querySelector('.kuma-summary-strip');
    if (!strip) { strip = document.createElement('div'); strip.className = 'kuma-summary-strip'; card.appendChild(strip); }
    strip.innerHTML = `
      <span class="kuma-summary-cell"><strong class="kuma-summary-value">${Number(summary.up || 0)}</strong><small class="kuma-summary-label">UP</small></span>
      <span class="kuma-summary-cell"><strong class="kuma-summary-value">${Number(summary.total || 0)}</strong><small class="kuma-summary-label">MONITORS</small></span>
      <span class="kuma-summary-cell ${Number(summary.down || 0) ? 'kuma-summary-down' : ''}"><strong class="kuma-summary-value">${Number(summary.down || 0)}</strong><small class="kuma-summary-label">DOWN</small></span>
      <span class="kuma-summary-cell"><strong class="kuma-summary-value">${Number(summary.maintenance || 0)}</strong><small class="kuma-summary-label">MAINT</small></span>`;
  }

  function ensureNetworkToolbar(section) {
    if (!section) return null;
    let row = document.getElementById(ACTION_ROW_ID);
    if (row) {
      if (row.parentElement !== section) section.insertBefore(row, section.firstChild);
      return row;
    }
    row = document.createElement('div');
    row.id = ACTION_ROW_ID;
    row.className = 'network-action-toolbar';
    row.innerHTML = `
      <div class="network-scan-copy">
        <span class="network-scan-title">Device status</span>
        <span class="network-scan-total"></span>
        <span class="network-scan-age">Last scan unavailable</span>
        <span class="network-scan-message" aria-live="polite">Status reflects the latest network scan</span>
      </div>
      <div class="network-scan-actions">
        <a class="network-manage-button" href="${API_BASE}/devices" target="_blank" rel="noopener noreferrer">Manage devices</a>
        <button class="network-refresh-button" type="button">↻ Scan network</button>
      </div>`;
    section.insertBefore(row, section.firstChild);
    row.querySelector('.network-refresh-button')?.addEventListener('click', refreshNetwork);
    return row;
  }

  function updateNetworkToolbar(lastScan, total) {
    const row = ensureNetworkToolbar(document.getElementById(SECTION_ID));
    const age = row?.querySelector('.network-scan-age');
    const count = row?.querySelector('.network-scan-total');
    if (age) age.textContent = formatScanAge(lastScan);
    if (count) count.textContent = Number.isFinite(Number(total)) ? `${Number(total)} devices` : '';
  }

  async function discoverySummary() {
    const response = await fetch(`${API_BASE}/public/discovery/summary`, { cache: 'no-store' });
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
    return payload;
  }

  async function refreshNetwork() {
    const row = ensureNetworkToolbar(ensureSection());
    const button = row?.querySelector('.network-refresh-button');
    const message = row?.querySelector('.network-scan-message');
    if (!button) return;
    button.disabled = true;
    button.textContent = '↻ Scanning…';
    try {
      const before = await discoverySummary().catch(() => ({ last_scan: null }));
      const response = await fetch(`${API_BASE}/manage/scan`, {
        method: 'POST',
        cache: 'no-store',
        headers: { 'Content-Type': 'application/json' },
        body: '{}',
      });
      const started = await response.json();
      if (!response.ok) throw new Error(started.error || `HTTP ${response.status}`);
      if (message) message.textContent = 'Scanning LAN…';
      for (let i = 0; i < 90; i += 1) {
        await new Promise((resolve) => window.setTimeout(resolve, 2000));
        const summary = await discoverySummary();
        if (message) message.textContent = summary.scanning ? 'Scanning LAN…' : `${summary.total} devices · ${summary.unclassified} unclassified`;
        if (!summary.scanning && summary.last_scan && summary.last_scan !== before.last_scan) break;
      }
      await refresh();
    } catch (error) {
      if (message) message.textContent = `Scan failed: ${error.message}`;
    } finally {
      button.disabled = false;
      button.textContent = '↻ Scan network';
      window.setTimeout(() => { if (message) message.textContent = ''; }, 5000);
    }
  }

  async function refresh() {
    const section = ensureSection();
    if (!section) return;
    try {
      const endpoint = `${API_BASE}/public/devices/groups`;
      const response = await fetch(endpoint, { cache: 'no-store' });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
      renderPayload(payload);
      updateKumaSummary(payload.kuma_summary || payload.summary);
    } catch (_error) {
      const grid = section.querySelector('.kuma-device-grid');
      if (grid) grid.innerHTML = '<article class="kuma-device-card" data-kuma-group="unclassified"><div class="kuma-device-card-header"><span class="kuma-group-title">Kuma monitor data unavailable</span></div></article>';
    }
  }

  const observer = new MutationObserver(() => { ensureSection(); });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener('resize', () => { alignKumaSection(document.getElementById(SECTION_ID)); }, { passive: true });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => { refresh(); }, { once: true }); else { refresh(); }
  window.setInterval(refresh, REFRESH_MS);
})();
HOMEPAGE_CUSTOM_JS

    sed -i \
        -e "s|__STATUS_API_PORT__|${STATUS_API_PORT}|g" \
        "${HOMEPAGE_DIR}/config/custom.js"

    cat >"${HOMEPAGE_DIR}/config/docker.yaml" <<'EOF'
# Docker socket integration intentionally disabled.
# Dashboard container state comes from the read-only local status API instead.
EOF

    # services.yaml contains the local telemetry API token used only by Homepage.
    chmod 600 "${HOMEPAGE_DIR}/config/services.yaml"
    chmod 644         "${HOMEPAGE_DIR}/config/settings.yaml"         "${HOMEPAGE_DIR}/config/widgets.yaml"         "${HOMEPAGE_DIR}/config/bookmarks.yaml"         "${HOMEPAGE_DIR}/config/custom.css"         "${HOMEPAGE_DIR}/config/custom.js"         "${HOMEPAGE_DIR}/config/docker.yaml"

    (
        cd "${APPS_DIR}"
        docker compose pull
        docker compose up -d
    )

    retry 30 2 curl -fsS \
        "http://127.0.0.1:${UPTIME_KUMA_PORT}" >/dev/null ||
        die "Uptime Kuma did not become reachable."

    retry 30 2 curl -fsS \
        -H "Host: ${TARGET_IP}:${DASHBOARD_PORT}" \
        "http://127.0.0.1:${DASHBOARD_PORT}" >/dev/null ||
        die "Homepage did not become reachable."
}

# =============================================================================
# Final validation
# =============================================================================

final_validation() {
    log "Final validation"

    "${SSHD_BIN}" -t
    systemctl is-active --quiet ssh
    systemctl is-enabled --quiet ssh-watchdog.timer

    systemctl is-active --quiet unbound
    unbound_query_ok

    systemctl is-active --quiet pihole-FTL
    dig @"${TARGET_IP}" example.com A +time=4 +tries=1 >/dev/null

    systemctl is-enabled --quiet unbound-failover.timer

    systemctl is-active --quiet docker
    docker inspect -f '{{.State.Running}}' uptime-kuma |
        grep -Fx true >/dev/null
    docker inspect -f '{{.State.Running}}' homepage |
        grep -Fx true >/dev/null

    systemctl is-active --quiet pi-network-status-api
    curl -fsS \
        "http://127.0.0.1:${STATUS_API_PORT}/public/kuma/config" >/dev/null

    local tailscale_ip
    tailscale_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"

    cat <<EOF

========================================================================
HOME NETWORK STACK COMPLETE

PRIMARY DASHBOARD
  http://${TARGET_IP}:${DASHBOARD_PORT}

Pi-hole
  http://${TARGET_IP}/admin/

Uptime Kuma
  http://${TARGET_IP}:${UPTIME_KUMA_PORT}

AUTOMATIC NETWORK DISCOVERY
  Dashboard:
      http://${TARGET_IP}:${DASHBOARD_PORT}

  Device manager:
      http://${TARGET_IP}:${STATUS_API_PORT}/devices

  Automatic classification uses only observed network evidence.
  Device names/hostnames are never used to infer device type.
  Manual dropdown overrides persist across later scans until reset to Auto.

  CLI scan (optional):
      sudo pi-network-discover scan

DNS PATH
  LAN clients
      -> Pi-hole ${TARGET_IP}:53
      -> Unbound 127.0.0.1:${UNBOUND_PORT}
      -> authoritative Internet DNS

STRICT FALLBACK
  If Unbound fails:
      restart Unbound
      -> if still unhealthy
      -> Pi-hole switches temporarily to
         ${FALLBACK_DNS_1} / ${FALLBACK_DNS_2}
      -> once Unbound recovers
      -> Pi-hole automatically returns to Unbound

DHCP
  Router:   ENABLED
  Pi-hole:  DISABLED

PI HOST DNS
  ${HOST_DNS_1}
  ${HOST_DNS_2}

REMOTE ACCESS
  Tailscale IP: ${tailscale_ip:-not authenticated yet}
  Advertised subnet: ${LAN_CIDR}

MAINTENANCE
  SSH watchdog:       every minute
  Unbound watchdog:   every minute
  Reboot:             alternate days at 03:00
  /tmp cleanup:       daily at 04:15
  journal storage:    capped at 100 MB / 14 days

ROUTER CHANGE
  Only after confirming:
      dig @${TARGET_IP} example.com

  configure your ROUTER DHCP/LAN DNS server to:
      ${TARGET_IP}

  Do NOT enable Pi-hole DHCP.

TAILSCALE
  Approve the advertised ${LAN_CIDR} subnet route in the Tailscale
  admin console if it is not auto-approved.

SECURITY
  Do not port-forward 22, 53, 80, 3000, 3001 or 9108 from the Internet.
  Use Tailscale for remote administration.
========================================================================
EOF
}

# =============================================================================
# Main
# =============================================================================

main() {
    preflight
    configure_host_dns

    # Explicit requirement:
    # all base prerequisites are installed and verified before applications.
    install_all_prerequisites

    configure_ssh_resilience
    configure_maintenance

    # If target IP is not primary, stop safely after staging.
    stage_static_ip_if_needed

    verify_phase2_network

    # Independent recovery path before changing core DNS services.
    install_tailscale

    # Native DNS stack.
    install_unbound
    install_pihole
    install_dns_failover_watchdog

    # Non-critical UI / monitoring layer.
    install_docker
    install_status_api
    install_network_discovery
    install_dashboard_stack

    final_validation
}

main "$@"
