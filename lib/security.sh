#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: lib/security.sh
#  Host hardening: UFW, fail2ban, SSH (harden + optional port change),
#  BBR congestion control and a small sysctl tuning set.
#
#  Order matters and is enforced by install.sh:
#      1. UFW rules *before* anything restarts sshd or enables the firewall
#      2. SSH drop-in validated with `sshd -t` before any restart
#      3. fail2ban wardens the (possibly new) SSH port
# =============================================================================

SSH_DROPIN="/etc/ssh/sshd_config.d/99-vpn-sanai.conf"
SSH_DROPIN_FALLBACK_MARK="# vpn-sanai ssh hardening"
F2B_DEFAULTS="/etc/fail2ban/jail.d/00-vpn-sanai-defaults.local"
F2B_SSHD="/etc/fail2ban/jail.d/99-vpn-sanai-sshd.local"
SYSCTL_BBR="/etc/sysctl.d/99-vpn-sanai-bbr.conf"
SYSCTL_NET="/etc/sysctl.d/98-vpn-sanai-net.conf"

# --- service helpers ---------------------------------------------------------
service_restart() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd) run systemctl restart "$name" ;;
        openrc)  run rc-service "$name" restart ;;
        *)       return 1 ;;
    esac
}

service_enable_now() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd) run systemctl enable --now "$name" ;;
        openrc)  run rc-update add "$name" default && run rc-service "$name" start ;;
        *)       return 1 ;;
    esac
}

service_is_active() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet "$name" ;;
        openrc)  rc-service "$name" status >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
}

# --- UFW ---------------------------------------------------------------------
ufw_is_active() {
    has_cmd ufw || return 1
    ufw status 2>/dev/null | head -1 | grep -qi active
}

ufw_allow_port() {
    local port="$1" proto="${2:-tcp}" comment="${3:-vpn-sanai}"
    [[ -n "$port" ]] || return 0
    if ufw status 2>/dev/null | grep -qE "^${port}/${proto}\b"; then
        log_debug "قاعدهٔ UFW برای ${port}/${proto} از قبل وجود دارد"
        return 0
    fi
    log_info "UFW: باز کردن ${port}/${proto} (${comment})"
    run_quiet ufw allow "${port}/${proto}" comment "$comment" || log_warn "افزودن قاعدهٔ ${port}/${proto} ناموفق بود"
}

ufw_delete_port() {
    local port="$1" proto="${2:-tcp}" num
    [[ -n "$port" ]] || return 0
    if run_quiet ufw delete allow "${port}/${proto}" 2>/dev/null; then
        return 0
    fi
    # With a comment attached ufw refuses the by-spec delete; fall back to the
    # rule number.
    num="$(ufw status numbered 2>/dev/null | sed -nE "s/^\[([0-9]+)\][[:space:]]+${port}/${proto}.*/\1/p" | head -1)"
    if [[ -n "$num" ]]; then
        yes | ufw delete "$num" >/dev/null 2>&1 || true
    fi
}

# setup_ufw <ssh-ports...> -- remaining ports are passed through UFW_OPEN_TCP
setup_ufw() {
    local -a ssh_ports=("$@")

    is_true "${ENABLE_UFW:-yes}" || { log_info "UFW غیرفعال است (طبق انتخاب شما)"; return 0; }

    log_step "تنظیم فایروال UFW"
    if ! has_cmd ufw; then
        install_labels firewall || log_warn "نصب UFW ناموفق بود"
    fi
    if ! has_cmd ufw; then
        log_warn "UFW در دسترس نیست؛ از این مرحله می‌گذرم"
        return 0
    fi

    # Never reset an existing ruleset: this box may already be serving other
    # things. Defaults are only touched while the firewall is still inactive.
    if ! ufw_is_active; then
        run_quiet ufw default deny incoming
        run_quiet ufw default allow outgoing
    else
        log_info "UFW از قبل فعال است؛ قواعد موجود دست‌نخورده می‌مانند"
    fi

    local p
    for p in "${ssh_ports[@]}"; do
        [[ -n "$p" ]] && ufw_allow_port "$p" tcp "SSH"
    done

    if [[ "${PANEL_ACCESS_MODE:-tunnel}" == "public" ]]; then
        ufw_allow_port "$PANEL_PORT" tcp "3x-ui panel"
    else
        log_info "حالت تونل: پورت پنل (${PANEL_PORT}) در فایروال باز نمی‌شود"
    fi

    ufw_allow_port "${VLESS_PORT:-443}" tcp "VLESS Reality"
    if [[ -n "${XHTTP_PORT:-}" ]]; then
        ufw_allow_port "$XHTTP_PORT" tcp "VLESS Reality xhttp"
    fi
    if is_true "${ENABLE_SUBSCRIPTION:-yes}" && [[ -n "${SUB_PORT:-}" ]]; then
        ufw_allow_port "$SUB_PORT" tcp "subscription"
    fi

    for p in "${UFW_EXTRA_TCP_PORTS[@]+"${UFW_EXTRA_TCP_PORTS[@]}"}"; do
        ufw_allow_port "$p" tcp "extra"
    done

    run_quiet ufw --force enable || die "فعال‌سازی UFW ناموفق بود"
    log_ok "UFW فعال شد (ورودی‌ها به‌صورت پیش‌فرض بسته هستند)"
    ufw_status_summary
}

ufw_status_summary() {
    has_cmd ufw || return 0
    local rules
    rules="$(ufw status 2>/dev/null | sed -n '4,$p' | head -15)" || true
    printf '%s%s%s\n' "$C_DIM" "$rules" "$C_RESET" >&2
}

# --- fail2ban ----------------------------------------------------------------
setup_fail2ban() {
    local -a ssh_ports=("$@")
    is_true "${ENABLE_FAIL2BAN:-yes}" || { log_info "fail2ban غیرفعال است (طبق انتخاب شما)"; return 0; }

    log_step "راه‌اندازی fail2ban"
    if ! has_cmd fail2ban-client; then
        install_labels fail2ban iptables || true
    fi
    if ! has_cmd fail2ban-client; then
        log_warn "fail2ban نصب نشد؛ از این مرحله می‌گذرم"
        return 0
    fi

    # nftables ships separately on Debian 12+/Ubuntu 24+; without it the default
    # nft banaction fails with "nft: not found".
    has_cmd nft || install_labels nftables >/dev/null 2>&1 || true

    local port_list
    port_list="$(IFS=,; echo "${ssh_ports[*]}")"

    # Keep fail2ban on the iptables backend so its bans live in the same table
    # UFW manages, and prefer the journal on systemd hosts.
    atomic_write "$F2B_DEFAULTS" 644 "$(cat <<EOF
# Managed by ${VPN_SANAI_NAME} — do not edit by hand, use scripts/security.sh
[DEFAULT]
banaction = iptables-multiport
banaction_allports = iptables-allports
findtime  = 10m
bantime   = 1h
maxretry  = 5
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 5d
EOF
)"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        printf 'backend = systemd\n' >> "$F2B_DEFAULTS"
    fi

    atomic_write "$F2B_SSHD" 644 "$(cat <<EOF
# Managed by ${VPN_SANAI_NAME} — SSH jail (the panel keeps its own 3x-ipl jail)
[sshd]
enabled  = true
port     = ${port_list}
filter   = sshd
maxretry = 4
bantime  = 2h
EOF
)"

    service_restart fail2ban || service_enable_now fail2ban || true
    sleep 2
    if has_cmd fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then
        log_ok "fail2ban فعال است (jail sshd روی پورت‌های ${port_list})"
    else
        log_warn "fail2ban راه‌اندازی شد اما وضعیت jail sshd تأیید نشد؛ با 'fail2ban-client status' بررسی کنید"
    fi
}

# --- SSH ---------------------------------------------------------------------
ssh_ports_active() {
    local -a ports=()
    if has_cmd sshd; then
        while read -r p; do
            [[ -n "$p" ]] && ports+=("$p")
        done < <(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u)
    fi
    if ((${#ports[@]} == 0)) && has_cmd ss; then
        while read -r p; do
            [[ -n "$p" ]] && ports+=("$p")
        done < <(ss -H -lntp 2>/dev/null | awk '/sshd/ {print $4}' | sed -nE 's/.*:([0-9]+)$/\1/p' | sort -u)
    fi
    ((${#ports[@]})) || ports=(22)
    printf '%s\n' "${ports[@]}"
}

# sshd_supports_dropin -> modern OpenSSH includes /etc/ssh/sshd_config.d/*.conf
sshd_supports_dropin() {
    [[ -f /etc/ssh/sshd_config ]] || return 1
    grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config
}

# _ssh_write_dropin <content>
_ssh_write_dropin() {
    local content="$1"
    if sshd_supports_dropin; then
        ensure_dir /etc/ssh/sshd_config.d 755
        atomic_write "$SSH_DROPIN" 600 "$content"
        return 0
    fi
    # Older OpenSSH (CentOS 7, Debian 10): keep our block in the main file and
    # replace it wholesale on every run so edits stay idempotent.
    local tmp
    tmp="$(mktemp)"
    awk -v mark="$SSH_DROPIN_FALLBACK_MARK" '
        $0 == mark { skip = 1; next }
        skip && /^$/ { skip = 0; next }
        skip && /^#/ { next }
        skip { next }
        { print }
    ' /etc/ssh/sshd_config > "$tmp"
    {
        printf '\n%s\n' "$SSH_DROPIN_FALLBACK_MARK"
        printf '%s\n' "$content"
    } >> "$tmp"
    atomic_write /etc/ssh/sshd_config 600 "$(cat "$tmp")"
    rm -f "$tmp"
}

# sshd_validate_and_reload -> returns non-zero (keeping the old config) on error
sshd_validate_and_reload() {
    if has_cmd sshd; then
        if ! sshd -t 2>/tmp/sshd-test.err; then
            log_error "پیکربندی sshd نامعتبر است: $(cat /tmp/sshd-test.err 2>/dev/null | head -3)"
            return 1
        fi
    fi
    if ! service_restart ssh && ! service_restart sshd; then
        log_error "راه‌اندازی مجدد سرویس SSH ناموفق بود"
        return 1
    fi
    return 0
}

# harden_ssh -> conservative options only; never touches authentication methods
harden_ssh() {
    log_step "سخت‌سازی SSH"
    if [[ ! -f /etc/ssh/sshd_config ]]; then
        log_warn "sshd_config پیدا نشد؛ از این مرحله می‌گذرم"
        return 0
    fi

    local -a lines=(
        "# Managed by ${VPN_SANAI_NAME} ($(date '+%Y-%m-%d'))"
        "X11Forwarding no"
        "MaxAuthTries 4"
        "LoginGraceTime 30"
        "ClientAliveInterval 120"
        "ClientAliveCountMax 3"
        "AllowAgentForwarding no"
    )
    # Only tighten root login when the host currently allows it.
    if has_cmd sshd && sshd -T 2>/dev/null | grep -qE '^permitrootlogin yes$'; then
        lines+=("PermitRootLogin prohibit-password")
        log_info "ورود root فقط با کلید ممکن می‌شود (PermitRootLogin prohibit-password)"
        log_warn "اگر با رمز به‌عنوان root وارد می‌شوید، ابتدا یک کاربر sudo بسازید یا این خط را از ${SSH_DROPIN} حذف کنید"
    fi

    local content="" line
    for line in "${lines[@]}"; do content+="${line}"$'\n'; done
    _ssh_write_dropin "$content" || { log_warn "نوشتن تنظیمات SSH ناموفق بود"; return 0; }

    if sshd_validate_and_reload; then
        log_ok "تنظیمات امن‌سازی SSH اعمال شد"
    else
        log_warn "اعمال تنظیمات SSH ناموفق بود؛ پیکربندی دست‌نخورده ماند"
        return 1
    fi
}

# change_ssh_port <new-port> <old-ports...>
# Adds the new port and keeps the old ones open until ssh_finalize runs.
change_ssh_port() {
    local new_port="$1"; shift
    local -a old_ports=("$@")

    is_port "$new_port" || die "پورت SSH نامعتبر است: ${new_port}"
    port_in_use "$new_port" && die "پورت ${new_port} اشغال است؛ پورت دیگری انتخاب کنید"

    log_step "تغییر پورت SSH به ${new_port}"

    local content p
    content="# Managed by ${VPN_SANAI_NAME} ($(date '+%Y-%m-%d'))"$'\n'
    for p in "${old_ports[@]}"; do
        [[ -n "$p" && "$p" != "$new_port" ]] && content+="Port ${p}"$'\n'
    done
    content+="Port ${new_port}"$'\n'

    _ssh_write_dropin "$content" || die "نوشتن تنظیمات پورت SSH ناموفق بود"

    # The old port must stay reachable through the firewall, otherwise the
    # safety net disappears the moment UFW is enabled.
    if ufw_is_active; then
        ufw_allow_port "$new_port" tcp "SSH (new)"
    fi

    if ! sshd_validate_and_reload; then
        log_error "تغییر پورت SSH اعمال نشد"
        return 1
    fi

    local waited=0
    while ((waited < 10)); do
        if port_in_use "$new_port"; then break; fi
        sleep 1; ((waited++))
    done

    if port_in_use "$new_port"; then
        log_ok "SSH روی پورت ${new_port} فعال است (پورت‌های قبلی: ${old_ports[*]} تا زمان نهایی‌سازی باز می‌مانند)"
    else
        log_error "SSH روی پورت ${new_port} در حال شنود نیست — پیکربندی را بازمی‌گردانم"
        _ssh_write_dropin "# Managed by ${VPN_SANAI_NAME}"$'\n'
        sshd_validate_and_reload || true
        return 1
    fi

    state_set SSH_PORT "$new_port"
    state_set SSH_OLD_PORTS "$(IFS=,; echo "${old_ports[*]}")"
    log_info "برای بستن پورت(های) قبلی پس از آزمون اتصال:  ${VPN_SANAI_SELF:-install.sh} --ssh-finalize"
}

# ssh_finalize [new-port] -> drops every other Port directive.
# Without an argument the port recorded in state is used (the one that was set
# by the last --ssh-port run), never "whatever sshd happens to list first".
ssh_finalize() {
    local new_port="${1:-}"
    if [[ -z "$new_port" ]]; then
        new_port="$(state_get SSH_PORT)"
    fi
    is_port "$new_port" || die "پورت SSH نامعتبر: ${new_port:-خالی} (با --ssh-port مشخص کنید)"

    log_step "نهایی‌سازی پورت SSH روی ${new_port}"
    local content
    content="# Managed by ${VPN_SANAI_NAME} ($(date '+%Y-%m-%d'))"$'\n'"Port ${new_port}"$'\n'
    _ssh_write_dropin "$content" || die "نوشتن تنظیمات SSH ناموفق بود"
    sshd_validate_and_reload || die "اعمال پیکربندی SSH ناموفق بود"

    # Old ports are no longer served: remove their firewall rules.
    local -a stale=()
    if ufw_is_active; then
        while read -r p; do
            [[ -n "$p" && "$p" != "$new_port" ]] && stale+=("$p")
        done < <(ufw status 2>/dev/null | sed -nE 's/^([0-9]+)\/tcp.*SSH.*/\1/p')
        local p
        for p in "${stale[@]+"${stale[@]}"}"; do
            ufw_delete_port "$p" tcp
        done
    fi
    log_ok "SSH فقط روی پورت ${new_port} پاسخ می‌دهد"
    state_set SSH_PORT "$new_port"
    state_set SSH_OLD_PORT ""
}

# --- BBR / sysctl ------------------------------------------------------------
setup_bbr() {
    is_true "${ENABLE_BBR:-yes}" || { log_info "BBR غیرفعال است (طبق انتخاب شما)"; return 0; }
    log_step "فعال‌سازی BBR"

    if ! lsmod 2>/dev/null | grep -q '^tcp_bbr' && has_cmd modprobe; then
        run_quiet modprobe tcp_bbr || true
    fi
    printf 'tcp_bbr\n' > /etc/modules-load.d/vpn-sanai-bbr.conf 2>/dev/null || true

    atomic_write "$SYSCTL_BBR" 644 "$(cat <<'EOF'
# Managed by vpn-sanai — BBR congestion control + fair queueing
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
)"
    run_quiet sysctl --system >/dev/null 2>&1 || run_quiet sysctl -p "$SYSCTL_BBR" || true

    local cc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    if [[ "$cc" == "bbr" ]]; then
        log_ok "BBR فعال است"
    else
        log_warn "BBR فعال نشد (مقدار فعلی: ${cc:-?}). اگر کرنل شما ماژول tcp_bbr ندارد، این طبیعی است"
    fi
}

setup_sysctl_tuning() {
    is_true "${ENABLE_SYSCTL_TUNING:-yes}" || return 0
    log_step "اعمال تنظیمات شبکه (sysctl)"

    atomic_write "$SYSCTL_NET" 644 "$(cat <<'EOF'
# Managed by vpn-sanai — conservative tuning for many concurrent proxy conns
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 1048576
EOF
)"
    run_quiet sysctl --system >/dev/null 2>&1 || run_quiet sysctl -p "$SYSCTL_NET" || true
    log_ok "تنظیمات شبکه اعمال شد"
}

# --- summary -----------------------------------------------------------------
security_summary() {
    local f2b="نصب نیست" banned=""
    if has_cmd fail2ban-client; then
        f2b="فعال"
        banned="$(fail2ban-client status sshd 2>/dev/null | sed -nE 's/.*Currently banned:[[:space:]]*([0-9]+).*/\1/p' | head -1)"
        [[ -n "$banned" ]] && f2b+=" (بن‌شده: ${banned})"
    fi
    kv "UFW" "$(ufw_is_active && echo 'فعال' || echo 'غیرفعال')"
    kv "fail2ban" "$f2b"
    kv "BBR" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    kv "پورت SSH" "$(ssh_ports_active | paste -sd, -)"
}
