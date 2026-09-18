#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: lib/panel.sh
#  Installing, configuring and talking to the 3x-ui panel itself.
#
#  The installer is the *official* one (MHSanaei/3x-ui) driven through its
#  documented non-interactive environment variables, so upgrades keep working
#  exactly like a manual install:
#      XUI_NONINTERACTIVE=1 XUI_USERNAME=... bash install.sh [vX.Y.Z]
# =============================================================================

XUI_FOLDER="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
XUI_BIN="${XUI_FOLDER}/x-ui"
PANEL_INSTALL_LOG="${VPN_SANAI_LOG_DIR}/panel-installer.log"

# --- detection ---------------------------------------------------------------
panel_installed() {
    [[ -x "$XUI_BIN" || -x "$XUI_CLI" ]]
}

panel_service_name() { printf 'x-ui'; }

panel_service_status() {
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active x-ui 2>/dev/null ;;
        openrc)  rc-service x-ui status >/dev/null 2>&1 && echo active || echo inactive ;;
        *)       echo unknown ;;
    esac
}

panel_service_ctl() {
    local action="$1"
    case "$INIT_SYSTEM" in
        systemd) run systemctl "$action" x-ui ;;
        openrc)  run rc-service x-ui "$action" ;;
        *)       die "کنترل سرویس پنل در این سیستم پشتیبانی نمی‌شود" ;;
    esac
}

panel_db_path() { printf '%s' "${XUI_DB_DEFAULT}"; }

panel_version() {
    if [[ -x "$XUI_BIN" ]]; then
        "$XUI_BIN" -v 2>/dev/null | head -1
    elif has_cmd x-ui; then
        x-ui 2>/dev/null | head -1
    fi
}

# --- installer ---------------------------------------------------------------
# download_installer <dest> -> tries the official URL then the mirrors
download_installer() {
    local dest="$1"
    local -a urls=("${XUI_INSTALL_URL:-$XUI_INSTALL_URL_DEFAULT}" "${XUI_INSTALL_MIRROR_URLS[@]+"${XUI_INSTALL_MIRROR_URLS[@]}"}")
    local url
    for url in "${urls[@]}"; do
        [[ -n "$url" ]] || continue
        log_info "دانلود نصب‌کننده: ${url}"
        if curl -fsSL --connect-timeout 15 --retry 3 --retry-delay 2 --max-time 120 -o "$dest" "$url" 2>/dev/null; then
            if grep -q 'x-ui' "$dest" 2>/dev/null && [[ -s "$dest" ]]; then
                log_ok "نصب‌کننده دریافت شد ($(wc -c < "$dest") بایت، sha256=$(sha256sum "$dest" | awk '{print $1}'))"
                return 0
            fi
            log_warn "فایل دریافتی از ${url} معتبر به نظر نمی‌رسد"
        else
            log_warn "دانلود از ${url} ناموفق بود"
        fi
    done
    return 1
}

# panel_install <version> -> runs the official installer non-interactively
panel_install() {
    local version="${1:-$XUI_VERSION_DEFAULT}"
    local installer; installer="$(mktemp /tmp/x-ui-installer.XXXXXX.sh)"

    log_step "نصب پنل 3x-ui${version:+ (نسخهٔ ${version})}"
    download_installer "$installer" || die "دانلود نصب‌کنندهٔ رسمی ناموفق بود. اتصال/پروکسی خود را بررسی کنید یا با --installer-url آدرس دلخواه بدهید"

    local -a cmd=(bash "$installer")
    if [[ -n "$version" && "$version" != "latest" ]]; then
        cmd+=("$version")
    fi

    local -a env_vars=(
        "XUI_NONINTERACTIVE=1"
        "XUI_USERNAME=${PANEL_USER}"
        "XUI_PASSWORD=${PANEL_PASS}"
        "XUI_PANEL_PORT=${PANEL_PORT}"
        "XUI_WEB_BASE_PATH=${PANEL_BASE_PATH_RAW}"
        "XUI_SSL_MODE=${PANEL_SSL_MODE:-none}"
        "XUI_SERVER_IP=${SERVER_IP:-}"
        "XUI_DB_TYPE=sqlite"
        "XUI_MAIN_FOLDER=${XUI_FOLDER}"
        "XUI_ENABLE_FAIL2BAN=true"
    )

    log_info "اجرای نصب‌کنندهٔ رسمی (خروجی کامل در ${PANEL_INSTALL_LOG})"
    ensure_dir "$VPN_SANAI_LOG_DIR" 750

    if ((VPN_SANAI_DRY_RUN)); then
        printf '%s[dry-run]%s %s %s\n' "$C_YELLOW" "$C_RESET" \
            "${env_vars[*]}" "${cmd[*]}" >&2
        rm -f "$installer"
        return 0
    fi

    local rc=0
    if env "${env_vars[@]}" "${cmd[@]}" > >(tee -a "$PANEL_INSTALL_LOG") 2>&1; then
        rc=0
    else
        rc=$?
    fi
    rm -f "$installer"

    if ((rc != 0)); then
        log_error "نصب‌کنندهٔ رسمی با کد ${rc} پایان یافت؛ ۳۰ خط آخر لاگ:"
        tail -n 30 "$PANEL_INSTALL_LOG" >&2 || true
        die "نصب پنل ناموفق بود"
    fi

    panel_installed || die "پس از نصب، فایل اجرایی پنل پیدا نشد (${XUI_BIN})"
    log_ok "پنل 3x-ui نصب شد: $(panel_version)"
}

# --- certificate -------------------------------------------------------------
# Self-signed certificate for the panel. With no domain, a CA-issued
# certificate is impossible; a self-signed one still encrypts the session (and
# matters when the panel is reached over a tunnel / by IP).
panel_generate_self_signed() {
    local server_ip="${1:-}"
    local tls_dir="${VPN_SANAI_ETC}/tls"
    local crt="${tls_dir}/panel.crt" key="${tls_dir}/panel.key"
    local conf="${tls_dir}/openssl.cnf"

    ensure_dir "$tls_dir" 700
    if ! has_cmd openssl; then
        log_warn "openssl موجود نیست؛ گواهی self-signed ساخته نشد"
        return 1
    fi

    if ((VPN_SANAI_DRY_RUN)); then
        printf '%s[dry-run]%s generate self-signed cert for %s\n' "$C_YELLOW" "$C_RESET" "${server_ip:-panel}" >&2
        return 0
    fi

    local san="DNS:localhost,IP:127.0.0.1"
    [[ -n "$server_ip" ]] && san+=",IP:${server_ip}"

    atomic_write "$conf" 600 "$(cat <<EOF
[req]
default_bits       = 2048
prompt             = no
distinguished_name = dn
x509_extensions    = v3_req

[dn]
CN = vpn-sanai panel

[v3_req]
subjectAltName   = ${san}
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
basicConstraints = CA:FALSE
EOF
)"

    if openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout "$key" -out "$crt" -config "$conf" >/dev/null 2>&1; then
        chmod 600 "$key"; chmod 644 "$crt"
        log_ok "گواهی self-signed پنل ساخته شد (${crt})"
        PANEL_TLS_CERT="$crt"
        PANEL_TLS_KEY="$key"
        return 0
    fi
    log_warn "ساخت گواهی self-signed ناموفق بود"
    return 1
}

panel_apply_certificate() {
    local crt="$1" key="$2"
    [[ -f "$crt" && -f "$key" ]] || return 1
    log_info "اعمال گواهی TLS روی پنل"
    if [[ -x "$XUI_BIN" ]]; then
        run_quiet "$XUI_BIN" cert -webCert "$crt" -webCertKey "$key" \
            || log_warn "اعمال گواهی با خطا مواجه شد"
    elif has_cmd x-ui; then
        run_quiet x-ui cert -webCert "$crt" -webCertKey "$key" \
            || log_warn "اعمال گواهی با خطا مواجه شد"
    fi
    panel_service_ctl restart
    sleep 2
    PANEL_SCHEME="https"
}

# --- panel settings through the CLI -----------------------------------------
# panel_cli <args...> -> runs the bundled CLI with the right binary
panel_cli() {
    if [[ -x "$XUI_BIN" ]]; then
        "$XUI_BIN" "$@"
    elif has_cmd x-ui; then
        x-ui "$@"
    else
        return 127
    fi
}

# panel_set_listen <ip> — empty ip means "listen on all interfaces".
# The CLI only applies non-empty values (updateSetting ignores ""), so clearing
# has to go through the settings table while the panel is stopped.
panel_set_listen() {
    local listen_ip="$1"

    if [[ -n "$listen_ip" ]]; then
        log_info "تنظیم آدرس Listen پنل روی ${listen_ip}"
        run_quiet panel_cli setting -listenIP "$listen_ip" || log_warn "تنظیم Listen ناموفق بود"
        return 0
    fi

    local current
    current="$(panel_cli setting -getListen 2>/dev/null | sed -nE 's/^listenIP:[[:space:]]*//p' | head -1)"
    if [[ -z "$current" ]]; then
        log_debug "پنل از قبل روی همهٔ اینترفیس‌ها گوش می‌دهد"
        return 0
    fi

    log_info "برداشتن محدودیت Listen پنل (فعلی: ${current})"
    if (! has_cmd sqlite3); then
        log_warn "برای برداشتن Listen، باید در پنل (تنظیمات ← پنل ← Listen IP) مقدار را خالی کنید یا sqlite3 نصب باشد"
        return 1
    fi
    run_quiet panel_service_ctl stop || true
    sleep 1
    if run_quiet sqlite3 "$(panel_db_path)" "UPDATE settings SET value='' WHERE key='webListen';"; then
        run_quiet panel_service_ctl start || true
        sleep 2
        log_ok "Listen پنل روی همهٔ اینترفیس‌ها تنظیم شد"
        return 0
    fi
    run_quiet panel_service_ctl start || true
    log_warn "برداشتن Listen ناموفق بود؛ پنل را دستی از UI تغییر دهید"
    return 1
}

panel_restart() {
    log_info "راه‌اندازی مجدد پنل"
    panel_service_ctl restart
}

# Fetch (or mint) an API token. The installer leaves one in
# /etc/x-ui/install-result.env; otherwise x-ui regenerates one for us.
panel_get_api_token() {
    local token=""

    if [[ -r "$XUI_INSTALL_RESULT" ]]; then
        token="$(read_env_value "$XUI_INSTALL_RESULT" XUI_API_TOKEN || true)"
    fi

    if [[ -z "$token" ]]; then
        log_info "ساخت/بازخوانی توکن API با x-ui setting -getApiToken"
        local out
        out="$(panel_cli setting -getApiToken 2>/dev/null || true)"
        token="$(printf '%s' "$out" | sed -nE 's/^apiToken:[[:space:]]*//p' | head -1)"
    fi

    if [[ -z "$token" ]]; then
        return 1
    fi
    PANEL_API_TOKEN="$token"
    printf '%s' "$token"
}

panel_wait_ready() {
    local timeout="${1:-60}" waited=0
    while ((waited < timeout)); do
        if api_is_authenticated 2>/dev/null; then
            return 0
        fi
        sleep 2
        ((waited += 2))
    done
    return 1
}

# panel_read_install_result -> fills PANEL_* from install-result.env if present
panel_read_install_result() {
    [[ -r "$XUI_INSTALL_RESULT" ]] || return 1
    local v
    v="$(read_env_value "$XUI_INSTALL_RESULT" XUI_USERNAME || true)"; [[ -n "$v" ]] && PANEL_USER="$v"
    v="$(read_env_value "$XUI_INSTALL_RESULT" XUI_PASSWORD || true)"; [[ -n "$v" ]] && PANEL_PASS="$v"
    v="$(read_env_value "$XUI_INSTALL_RESULT" XUI_PANEL_PORT || true)"; [[ -n "$v" ]] && PANEL_PORT="$v"
    v="$(read_env_value "$XUI_INSTALL_RESULT" XUI_WEB_BASE_PATH || true)"; [[ -n "$v" ]] && PANEL_BASE_PATH="$(normalise_base_path "$v")"
    return 0
}

# panel_probe_settings -> reads port / base path / listen from the panel itself
panel_probe_settings() {
    local out
    out="$(panel_cli setting -show true 2>/dev/null || true)"
    [[ -n "$out" ]] || return 1

    local port base
    port="$(printf '%s' "$out" | sed -nE 's/^port:[[:space:]]*//p' | head -1)"
    base="$(printf '%s' "$out" | sed -nE 's/^webBasePath:[[:space:]]*//p' | head -1)"
    [[ -n "$port" ]] && PANEL_PORT="$port"
    [[ -n "$base" ]] && PANEL_BASE_PATH="$(normalise_base_path "$base")"

    if printf '%s' "$out" | grep -q 'hasDefaultCredential: true'; then
        log_warn "پنل هنوز روی نام کاربری/رمز پیش‌فرض (admin/admin) است"
        return 2
    fi
    return 0
}

# panel_reset_credentials <user> <pass> -> force credentials (recovery path)
panel_reset_credentials() {
    local user="$1" pass="$2"
    log_info "تنظیم نام کاربری و رمز پنل"
    run_quiet panel_cli setting -username "$user" -password "$pass" || return 1
    log_ok "نام کاربری و رمز پنل به‌روزرسانی شد"
}

# xray_restart -> restart xray core through the panel API, CLI as fallback
xray_restart() {
    if api_silent POST "/panel/api/server/restartXrayService"; then
        log_ok "هستهٔ Xray راه‌اندازی مجدد شد"
        return 0
    fi
    log_warn "راه‌اندازی مجدد Xray از طریق API ناموفق بود؛ تلاش با CLI"
    if has_cmd x-ui; then
        run_quiet x-ui restart-xray || log_warn "راه‌اندازی مجدد Xray ناموفق بود"
    fi
}

panel_status_summary() {
    local obj state version
    obj="$(api_get_obj "/panel/api/server/status" 2>/dev/null || true)"
    if [[ -n "$obj" ]]; then
        state="$(printf '%s' "$obj" | jq -r '.xray.state // "?"')"
        version="$(printf '%s' "$obj" | jq -r '.xray.version // "?"')"
        kv "پنل" "$(panel_service_status)"
        kv "Xray" "${state} (${version})"
    else
        kv "پنل" "$(panel_service_status)"
        kv "API" "پاسخ نمی‌دهد"
    fi
}
