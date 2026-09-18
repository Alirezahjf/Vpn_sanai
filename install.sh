#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai — نصب و پیکربندی کامل پنل سنایی (3x-ui) + VLESS/REALITY
#
#  Usage:
#     bash install.sh [options]      (root required; re-executes via sudo)
#
#  Examples:
#     bash install.sh                          # نصب تعاملی با پیش‌فرض‌های امن
#     bash install.sh --yes                    # نصب کاملاً غیرتعاملی
#     bash install.sh --panel-mode public      # پنل روی https://IP:PORT
#     bash install.sh --ssh-port 2222 --yes    # تغییر پورت SSH در حین نصب
#     bash install.sh --status                 # وضعیت نصب فعلی
#     bash install.sh --add-client ali         # افزودن کلاینت جدید
#     bash install.sh --show-clients           # لینک و QR همهٔ کلاینت‌ها
#     bash install.sh --backup                 # پشتیبان‌گیری دستی
#     bash install.sh --uninstall              # حذف کامل
#
#  Options (see --help for the full list) are documented in README.md.
# =============================================================================

set -Eeuo pipefail

# --- locate ourselves --------------------------------------------------------
_self="${BASH_SOURCE[0]:-}"
if [[ -z "$_self" || "$_self" == /dev/fd/* || "$_self" == /proc/* ]]; then
    VPN_SANAI_SELF="${_self:-stdin}"
    SCRIPT_DIR=""
else
    VPN_SANAI_SELF="$(readlink -f "$_self" 2>/dev/null || echo "$_self")"
    SCRIPT_DIR="$(cd "$(dirname "$VPN_SANAI_SELF")" && pwd)"
fi
unset _self
export VPN_SANAI_SELF SCRIPT_DIR

LIB_DIR="${SCRIPT_DIR}/lib"
CONF_DIR="${SCRIPT_DIR}/config"

# When invoked through `curl | bash` only install.sh exists: fetch the rest of
# the tree first and re-execute the downloaded copy.
# shellcheck source=lib/bootstrap.sh
if [[ -f "${LIB_DIR}/bootstrap.sh" ]]; then
    source "${LIB_DIR}/bootstrap.sh"
elif [[ ! -f "${LIB_DIR}/common.sh" ]]; then
    # Bare install.sh without the bootstrap module: fetch that one file from a
    # mirror and let it download the rest of the tree.
    printf '[vpn-sanai] فایل‌های پروژه پیدا نشد؛ از GitHub دانلود می‌شوند...\n' >&2
    _tmpdir="$(mktemp -d /tmp/vpn-sanai-bootstrap.XXXXXX)"
    _ok=0
    for _url in \
        "https://raw.githubusercontent.com/Alirezahjf/Vpn_sanai/main/lib/bootstrap.sh" \
        "https://cdn.jsdelivr.net/gh/Alirezahjf/Vpn_sanai@main/lib/bootstrap.sh" \
        "https://gcore.jsdelivr.net/gh/Alirezahjf/Vpn_sanai@main/lib/bootstrap.sh" \
        "https://ghproxy.net/https://raw.githubusercontent.com/Alirezahjf/Vpn_sanai/main/lib/bootstrap.sh"; do
        if curl -fsSL --connect-timeout 15 --retry 2 --max-time 60 \
                -o "${_tmpdir}/bootstrap.sh" "$_url" 2>/dev/null && [[ -s "${_tmpdir}/bootstrap.sh" ]]; then
            _ok=1
            break
        fi
    done
    if ((!_ok)); then
        printf '[vpn-sanai] دانلود ناموفق بود؛ از پروکسی استفاده کنید یا کل ریپو را دانلود نمایید.\n' >&2
        exit 1
    fi
    exec bash -c 'source "$1" && bootstrap_self "${@:2}"' vpn-sanai-bootstrap "${_tmpdir}/bootstrap.sh" "$@"
fi

if [[ -f "${LIB_DIR}/bootstrap.sh" ]] && bootstrap_needed; then
    bootstrap_self "$@"
fi

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# Defaults are sourced *before* the CLI parser so flags always win.
# shellcheck source=config/defaults.conf
source "${CONF_DIR}/defaults.conf"
# shellcheck source=lib/preflight.sh
source "${LIB_DIR}/preflight.sh"
# shellcheck source=lib/api.sh
source "${LIB_DIR}/api.sh"
# shellcheck source=lib/panel.sh
source "${LIB_DIR}/panel.sh"
# shellcheck source=lib/reality.sh
source "${LIB_DIR}/reality.sh"
# shellcheck source=lib/clients.sh
source "${LIB_DIR}/clients.sh"
# shellcheck source=lib/security.sh
source "${LIB_DIR}/security.sh"
# shellcheck source=lib/backup.sh
source "${LIB_DIR}/backup.sh"

# --- runtime configuration ---------------------------------------------------
ACTION="install"
PANEL_PORT=""
PANEL_BASE_PATH_RAW=""
PANEL_USER=""
PANEL_PASS=""
PANEL_ACCESS_MODE=""
PANEL_SSL_MODE=""
FORCE_PANEL_INSTALL=0
SKIP_PANEL_INSTALL=0
VLESS_PORT=""
VLESS_SNI_CHOICE=""
CREATE_XHTTP=""
ENABLE_UFW=""
ENABLE_FAIL2BAN=""
ENABLE_BBR=""
ENABLE_SYSCTL_TUNING=""
ENABLE_TIMESYNC=""
ENABLE_SUBSCRIPTION=""
BACKUP_ENABLED=""
SSH_PORT_NEW=""
NO_BACKUP_CRON=0
CLIENT_EMAILS=()
ASSUME_YES=0

usage() {
    cat <<'EOF'
vpn-sanai — نصب‌کنندهٔ پنل 3x-ui + VLESS/REALITY

اجرا:
  bash install.sh [گزینه‌ها]

گزینه‌های پنل:
  --panel-mode MODE        tunnel (پیش‌فرض) | public
  --panel-port PORT        پورت پنل (پیش‌فرض: تصادفی آزاد)
  --panel-user NAME        نام کاربری پنل (پیش‌فرض: تصادفی)
  --panel-pass PASS        رمز عبور پنل (پیش‌فرض: تصادفی قوی)
  --panel-base-path PATH   مسیر مخفی پنل، مثال: /mysecretpath/
  --panel-tls MODE         self-signed (پیش‌فرض) | none
  --panel-version V        نسخهٔ 3x-ui (مثال v3.8.5) — پیش‌فرض: latest
  --installer-url URL      آدرس نصب‌کنندهٔ رسمی (برای شبکه‌های محدود)
  --skip-panel-install     پنل از قبل نصب است؛ فقط پیکربندی کن
  --reinstall-panel        نصب/به‌روزرسانی پنل حتی اگر نصب باشد

گزینه‌های کانفیگ VLESS/REALITY:
  --vless-port PORT        پورت کانفیگ (پیش‌فرض: 443، در صورت اشغال تصادفی)
  --sni HOST               دامنهٔ پوششی REALITY (پیش‌فرض: انتخاب خودکار بهترین)
  --xhttp                  ساخت یک Inbound اضافه با انتقال xhttp
  --xhttp-port PORT        پورت Inbound دوم (پیش‌فرض: 8443)
  --client-email EMAIL     نام کلاینت پیش‌فرض (پیش‌فرض: user1)
  --client-total-gb N      حجم مجاز کلاینت (0 = نامحدود)
  --client-days N          مدت اعتبار کلاینت به روز (0 = نامحدود)
  --client-ip-limit N      محدودیت تعداد IP هم‌زمان (0 = نامحدود)
  --sub-port PORT          پورت لینک اشتراک (پیش‌فرض: 2096)
  --no-subscription        غیرفعال کردن سرویس اشتراک

امنیت:
  --ssh-port PORT          تغییر پورت SSH (پورت قبلی تا --ssh-finalize باز می‌ماند)
  --ssh-finalize           بستن پورت(های) قبلی SSH
  --no-ufw                 نصب/فعال‌سازی UFW نکن
  --no-fail2ban            نصب/فعال‌سازی fail2ban نکن
  --no-bbr                 فعال‌سازی BBR نکن
  --no-sysctl              تنظیمات sysctl را اعمال نکن
  --no-timesync            همگام‌سازی ساعت را تنظیم نکن
  --no-backup              پشتیبان‌گیری زمان‌بندی‌شده را نصب نکن

عملیات:
  --status                 نمایش وضعیت نصب
  --add-client EMAIL       افزودن کلاینت و نمایش لینک/QR
  --show-clients           نمایش لینک/QR همهٔ کلاینت‌ها
  --backup                 پشتیبان‌گیری دستی
  --restore FILE           بازگردانی از فایل پشتیبان
  --update-panel           به‌روزرسانی پنل به آخرین نسخه
  --uninstall              حذف کامل پنل و تنظیمات vpn-sanai
  --menu                   منوی مدیریت (پیش‌فرض وقتی نصب موجود است)
  --telegram               راه‌اندازی ربات تلگرام (تنظیم و نصب سرویس)
  --tg-token TOKEN         توکن ربات (برای --telegram)
  --tg-admins IDS          شناسهٔ مدیران، جدا با کاما (برای --telegram)

عمومی:
  -y, --yes                بدون پرسش (غیرتعاملی)
  --dry-run                فقط نمایش دستورات، بدون اجرا
  --debug                  لاگ کامل
  --quiet                  فقط خطاها
  -h, --help               همین راهنما
  -V, --version            نسخهٔ اسکریپت
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --panel-mode)      PANEL_ACCESS_MODE="${2:?}"; shift 2 ;;
            --panel-port)      PANEL_PORT="${2:?}"; shift 2 ;;
            --panel-user)      PANEL_USER="${2:?}"; shift 2 ;;
            --panel-pass)      PANEL_PASS="${2:?}"; shift 2 ;;
            --panel-base-path) PANEL_BASE_PATH_RAW="${2:?}"; shift 2 ;;
            --panel-tls)       PANEL_SSL_MODE="${2:?}"; shift 2 ;;
            --panel-version)   XUI_VERSION_DEFAULT="${2:?}"; shift 2 ;;
            --installer-url)   XUI_INSTALL_URL="${2:?}"; shift 2 ;;
            --vless-port)      VLESS_PORT="${2:?}"; shift 2 ;;
            --sni)             VLESS_SNI_CHOICE="${2:?}"; shift 2 ;;
            --client-email)    DEFAULT_CLIENT_EMAIL="${2:?}"; shift 2 ;;
            --client-total-gb) DEFAULT_CLIENT_TOTAL_GB="${2:?}"; shift 2 ;;
            --client-days)     DEFAULT_CLIENT_EXPIRY_DAYS="${2:?}"; shift 2 ;;
            --client-ip-limit) DEFAULT_CLIENT_LIMIT_IP="${2:?}"; shift 2 ;;
            --sub-port)        SUB_PORT_DEFAULT="${2:?}"; shift 2 ;;
            --ssh-port)        SSH_PORT_NEW="${2:?}"; shift 2 ;;
            --add-client)      ACTION="add-client"; CLIENT_EMAILS+=("${2:?}"); shift 2 ;;
            --restore)         ACTION="restore"; RESTORE_FILE="${2:?}"; shift 2 ;;
            --ssh-finalize)    ACTION="ssh-finalize"; shift ;;
            --status)          ACTION="status"; shift ;;
            --show-clients)    ACTION="show-clients"; shift ;;
            --backup)          ACTION="backup"; shift ;;
            --update-panel)    ACTION="update-panel"; shift ;;
            --uninstall)       ACTION="uninstall"; shift ;;
            --menu)            ACTION="menu"; shift ;;
            --skip-panel-install) SKIP_PANEL_INSTALL=1; shift ;;
            --reinstall-panel) FORCE_PANEL_INSTALL=1; shift ;;
            --xhttp)           CREATE_XHTTP="yes"; shift ;;
            --xhttp-port)      XHTTP_PORT_DEFAULT="${2:?}"; shift 2 ;;
            --no-subscription) ENABLE_SUBSCRIPTION="no"; shift ;;
            --no-ufw)          ENABLE_UFW="no"; shift ;;
            --no-fail2ban)     ENABLE_FAIL2BAN="no"; shift ;;
            --no-bbr)          ENABLE_BBR="no"; shift ;;
            --no-sysctl)       ENABLE_SYSCTL_TUNING="no"; shift ;;
            --no-timesync)     ENABLE_TIMESYNC="no"; shift ;;
            --no-backup)       BACKUP_ENABLED="no"; NO_BACKUP_CRON=1; shift ;;
            -y|--yes)          ASSUME_YES=1; shift ;;
            --dry-run)         VPN_SANAI_DRY_RUN=1; shift ;;
            --debug)           VPN_SANAI_DEBUG=1; shift ;;
            --quiet)           VPN_SANAI_QUIET=1; shift ;;
            -h|--help)         usage; exit 0 ;;
            -V|--version)      printf '%s %s\n' "$VPN_SANAI_NAME" "$VPN_SANAI_VERSION"; exit 0 ;;
            *)                 log_error "گزینهٔ ناشناخته: $1"; usage; exit 2 ;;
        esac
    done
    ((ASSUME_YES)) && VPN_SANAI_NONINTERACTIVE=1
    export VPN_SANAI_NONINTERACTIVE
}

# --- state / config resolution ----------------------------------------------
load_existing_state() {
    if state_exists; then
        state_load || true
        PANEL_SCHEME="${PANEL_SCHEME:-$(state_get PANEL_SCHEME http)}"
        PANEL_PORT="${PANEL_PORT:-$(state_get PANEL_PORT)}"
        PANEL_BASE_PATH="${PANEL_BASE_PATH:-$(state_get PANEL_BASE_PATH '/')}"
        PANEL_BASE_PATH_RAW="${PANEL_BASE_PATH_RAW:-$(base_path_raw "$PANEL_BASE_PATH")}"
        PANEL_API_TOKEN="${PANEL_API_TOKEN:-$(state_get PANEL_API_TOKEN)}"
        SERVER_IP="${SERVER_IP:-$(state_get SERVER_IP)}"
        VLESS_UUID="${VLESS_UUID:-$(state_get VLESS_UUID)}"
        VLESS_SNI="${VLESS_SNI:-$(state_get VLESS_SNI)}"
        VLESS_SHORT_ID="${VLESS_SHORT_ID:-$(state_get VLESS_SHORT_ID)}"
    fi
}

confirm_server_ip() {
    local detected="" answer=""
    detected="$(get_public_ip 4 || true)"

    if [[ -n "${SERVER_IP:-}" ]]; then
        log_info "آدرس سرور از نصب قبلی: ${SERVER_IP}"
        detected="${detected:-$SERVER_IP}"
        return 0
    fi

    if [[ -z "$detected" ]]; then
        log_warn "آدرس عمومی سرور تشخیص داده نشد (ممکن است شبکه خروجی محدود باشد)"
        if ((VPN_SANAI_NONINTERACTIVE)); then
            die "آدرس عمومی را دستی بدهید:  export SERVER_IP=1.2.3.4"
        fi
        ask SERVER_IP "آدرس عمومی سرور (IP) را وارد کنید" ""
        is_ipv4 "$SERVER_IP" || die "آدرس وارد‌شده IPv4 معتبر نیست"
        return 0
    fi

    SERVER_IP="$detected"
    log_info "آدرس عمومی سرور: ${SERVER_IP}"

    if ((VPN_SANAI_NONINTERACTIVE)); then
        return 0
    fi
    ask answer "این آدرس درست است؟ اگر IP دیگری برای اتصال استفاده می‌کنید وارد کنید" "$detected"
    if [[ -n "$answer" ]]; then
        SERVER_IP="$answer"
    fi
}

collect_choices() {
    # ---- panel -------------------------------------------------------------
    if [[ -z "$PANEL_ACCESS_MODE" ]]; then
        if ((VPN_SANAI_NONINTERACTIVE)); then
            PANEL_ACCESS_MODE="$PANEL_ACCESS_MODE_DEFAULT"
        else
            printf '  %s(tunnel = فقط از طریق تونل SSH، امن‌ترین | public = https://IP:PORT)%s\n' \
                "$C_DIM" "$C_RESET" >&2
            ask_menu PANEL_ACCESS_MODE "روش دسترسی به پنل را انتخاب کنید:" "$PANEL_ACCESS_MODE_DEFAULT" \
                "tunnel" "public"
            case "$PANEL_ACCESS_MODE" in
                tunnel|public) ;;
                *) PANEL_ACCESS_MODE="$PANEL_ACCESS_MODE_DEFAULT" ;;
            esac
        fi
    fi
    [[ "$PANEL_ACCESS_MODE" == "public" || "$PANEL_ACCESS_MODE" == "tunnel" ]] \
        || die "حالت پنل باید tunnel یا public باشد"

    if [[ -z "$PANEL_PORT" ]]; then
        local suggested
        suggested="$(rand_port "$PANEL_PORT_RANGE_MIN" "$PANEL_PORT_RANGE_MAX")"
        if ((VPN_SANAI_NONINTERACTIVE)); then
            PANEL_PORT="$suggested"
        else
            ask PANEL_PORT "پورت پنل" "$suggested"
        fi
    fi
    is_port "$PANEL_PORT" || die "پورت پنل نامعتبر است: ${PANEL_PORT}"
    port_in_use "$PANEL_PORT" && PANEL_PORT="$(choose_free_port "$PANEL_PORT" "$PANEL_PORT_RANGE_MIN" "$PANEL_PORT_RANGE_MAX" "پورت پنل")"

    panel_heal_placeholder_secrets
    [[ -n "$PANEL_USER" ]] || PANEL_USER="$(_default_or_ask PANEL_USER_DEFAULT "$(rand_string 10 'a-z0-9')" "نام کاربری پنل")"
    [[ -n "$PANEL_PASS" ]] || PANEL_PASS="$(_default_or_ask PANEL_PASS_DEFAULT "$(rand_password 20)" "رمز عبور پنل")"
    [[ -n "$PANEL_BASE_PATH_RAW" ]] || PANEL_BASE_PATH_RAW="$(_default_or_ask PANEL_BASE_PATH_DEFAULT "$(rand_string 14 'a-zA-Z0-9')" "مسیر مخفی پنل")"
    PANEL_BASE_PATH="$(normalise_base_path "$PANEL_BASE_PATH_RAW")"
    PANEL_BASE_PATH_RAW="${PANEL_BASE_PATH#/}"; PANEL_BASE_PATH_RAW="${PANEL_BASE_PATH_RAW%/}"

    if [[ -z "$PANEL_SSL_MODE" ]]; then
        if [[ "$PANEL_ACCESS_MODE" == "tunnel" ]]; then
            PANEL_SSL_MODE="$(is_true "$PANEL_TLS_SELF_SIGNED_DEFAULT" && echo self-signed || echo none)"
        else
            PANEL_SSL_MODE="self-signed"
        fi
    fi

    # ---- vless -------------------------------------------------------------
    if [[ -z "$VLESS_PORT" ]]; then
        if ((VPN_SANAI_NONINTERACTIVE)); then
            VLESS_PORT="$VLESS_PORT_DEFAULT"
        else
            ask VLESS_PORT "پورت کانفیگ VLESS" "$VLESS_PORT_DEFAULT"
        fi
    fi
    is_port "$VLESS_PORT" || die "پورت VLESS نامعتبر است: ${VLESS_PORT}"
    if port_in_use "$VLESS_PORT"; then
        log_warn "پورت ${VLESS_PORT} اشغال است"
        explain_port_owner "$VLESS_PORT"
        VLESS_PORT="$(choose_free_port "" "$VLESS_PORT_FALLBACK_MIN" "$VLESS_PORT_FALLBACK_MAX" "پورت VLESS")"
        log_info "پورت جایگزین: ${VLESS_PORT}"
    fi

    if [[ -z "$CREATE_XHTTP" ]]; then
        if ((VPN_SANAI_NONINTERACTIVE)); then
            CREATE_XHTTP="$CREATE_XHTTP_INBOUND_DEFAULT"
        else
            ask_yesno "یک Inbound اضافه با انتقال xHTTP هم ساخته شود؟ (کندتر ولی مقاوم‌تر)" "n" \
                && CREATE_XHTTP="yes" || CREATE_XHTTP="no"
        fi
    fi

    # ---- security / extras --------------------------------------------------
    if [[ -z "$ENABLE_UFW" ]];        then ENABLE_UFW="$(_toggle_or_ask ENABLE_UFW_DEFAULT "فایروال UFW نصب و فعال شود؟")"; fi
    if [[ -z "$ENABLE_FAIL2BAN" ]];  then ENABLE_FAIL2BAN="$(_toggle_or_ask ENABLE_FAIL2BAN_DEFAULT "fail2ban برای محافظت از SSH فعال شود؟")"; fi
    if [[ -z "$ENABLE_BBR" ]];       then ENABLE_BBR="$(_toggle_or_ask ENABLE_BBR_DEFAULT "BBR برای بهبود سرعت فعال شود؟")"; fi
    if [[ -z "$ENABLE_SYSCTL_TUNING" ]]; then ENABLE_SYSCTL_TUNING="$(_toggle_or_ask ENABLE_SYSCTL_TUNING_DEFAULT "تنظیمات شبکه (sysctl) اعمال شود؟")"; fi
    if [[ -z "$ENABLE_TIMESYNC" ]];  then ENABLE_TIMESYNC="$(_toggle_or_ask ENABLE_TIMESYNC_DEFAULT "همگام‌سازی ساعت (مهم برای REALITY) فعال شود؟")"; fi

    if [[ -z "$SSH_PORT_NEW" ]] && ! ((VPN_SANAI_NONINTERACTIVE)); then
        if ask_yesno "پورت SSH را تغییر دهیم؟ (پورت قبلی تا تأیید اتصال باز می‌ماند)" "n"; then
            ask SSH_PORT_NEW "پورت جدید SSH" "$(rand_port 1024 60000)"
        fi
    fi

    # ---- client -------------------------------------------------------------
    if [[ -z "$DEFAULT_CLIENT_TOTAL_GB" || "$DEFAULT_CLIENT_TOTAL_GB" == "0" ]]; then
        if ! ((VPN_SANAI_NONINTERACTIVE)); then
            ask DEFAULT_CLIENT_TOTAL_GB "حجم مجاز کلاینت پیش‌فرض به گیگابایت (0 = نامحدود)" "$DEFAULT_CLIENT_TOTAL_GB"
        fi
    fi
    if [[ -z "$DEFAULT_CLIENT_EXPIRY_DAYS" || "$DEFAULT_CLIENT_EXPIRY_DAYS" == "0" ]]; then
        if ! ((VPN_SANAI_NONINTERACTIVE)); then
            ask DEFAULT_CLIENT_EXPIRY_DAYS "مدت اعتبار کلاینت پیش‌فرض به روز (0 = نامحدود)" "$DEFAULT_CLIENT_EXPIRY_DAYS"
        fi
    fi
}

# _default_or_ask <name-of-default-var> <fallback> <prompt>
# $1 is the NAME of a *_DEFAULT variable — resolved indirectly (${!1}).
_default_or_ask() {
    local from_file="${!1:-}" fallback="$2" prompt="$3"
    if [[ -n "$from_file" ]]; then
        printf '%s' "$from_file"; return 0
    fi
    if ((VPN_SANAI_NONINTERACTIVE)); then
        printf '%s' "$fallback"; return 0
    fi
    local answer="$fallback"
    ask answer "$prompt" "$fallback"
    printf '%s' "$answer"
}

# _toggle_or_ask <default> <prompt> -> yes/no
_toggle_or_ask() {
    local default="$1" prompt="$2"
    if ((VPN_SANAI_NONINTERACTIVE)); then
        printf '%s' "$default"; return 0
    fi
    if ask_yesno "$prompt" "$(is_true "$default" && echo y || echo n)"; then
        printf 'yes'
    else
        printf 'no'
    fi
}

# --- panel bootstrap ---------------------------------------------------------
# Older runs suffered a nameref bug in _default_or_ask that leaked the literal
# placeholder names ("PANEL_USER_DEFAULT", ...) into state AND into the panel's
# own credentials/base path. Detect those leftovers and regenerate them; the
# caller re-applies to the live panel when the CLI is available.
PANEL_HEALED_CREDS=0
PANEL_HEALED_BASE=0
panel_heal_placeholder_secrets() {
    PANEL_HEALED_CREDS=0
    PANEL_HEALED_BASE=0
    if [[ "${PANEL_USER:-}" == "PANEL_USER_DEFAULT" ]]; then
        PANEL_USER="$(rand_string 10 'a-z0-9')"
        PANEL_HEALED_CREDS=1
    fi
    if [[ "${PANEL_PASS:-}" == "PANEL_PASS_DEFAULT" ]]; then
        PANEL_PASS="$(rand_password 20)"
        PANEL_HEALED_CREDS=1
    fi
    if [[ "${PANEL_BASE_PATH_RAW:-}" == "PANEL_BASE_PATH_DEFAULT" \
       || "${PANEL_BASE_PATH:-}" == "/PANEL_BASE_PATH_DEFAULT/" ]]; then
        PANEL_BASE_PATH_RAW="$(rand_string 14 'a-zA-Z0-9')"
        PANEL_BASE_PATH="$(normalise_base_path "$PANEL_BASE_PATH_RAW")"
        PANEL_HEALED_BASE=1
    fi
    if ((PANEL_HEALED_CREDS || PANEL_HEALED_BASE)); then
        log_warn "مقادیر placeholder ذخیره‌شده از نسخهٔ قبلی پیدا و با مقادیر تصادفی جدید جایگزین شد"
    fi
    return 0
}

# _panel_plan_* helpers keep the flow readable.
bootstrap_panel() {
    local reinstall=0
    if panel_installed; then
        log_info "پنل از قبل نصب است ($(panel_version))"
        ((FORCE_PANEL_INSTALL)) && reinstall=1
    else
        reinstall=1
    fi
    ((SKIP_PANEL_INSTALL)) && reinstall=0

    if ((reinstall)); then
        panel_install "$XUI_VERSION_DEFAULT"
    fi

    # Credentials/port/base path: trust the panel's own report when it exists.
    panel_probe_settings 2>/dev/null || true
    panel_read_install_result || true
    PANEL_BASE_PATH_RAW="$(base_path_raw "$PANEL_BASE_PATH")"

    # Heal literal placeholder leftovers from the _default_or_ask nameref bug
    # and push the regenerated secrets into the live panel as well.
    panel_heal_placeholder_secrets
    if ((PANEL_HEALED_CREDS)) && [[ -x "${XUI_BIN:-}" ]]; then
        panel_reset_credentials "$PANEL_USER" "$PANEL_PASS" \
            || log_warn "اعمال نام کاربری/رمز ترمیم‌شده روی پنل ناموفق بود"
    fi
    if ((PANEL_HEALED_BASE)) && [[ -x "${XUI_BIN:-}" ]]; then
        run_quiet panel_cli setting -webBasePath "$PANEL_BASE_PATH_RAW" \
            || log_warn "اعمال مسیر مخفی ترمیم‌شده روی پنل ناموفق بود"
    fi

    PANEL_SCHEME="http"

    # Apply the panel port/base path we decided on if the panel disagrees
    # (fresh installs already carry them via env vars).
    if [[ "$(state_get PANEL_PORT)" != "$PANEL_PORT" ]] || [[ "$(state_get PANEL_BASE_PATH)" != "$PANEL_BASE_PATH" ]]; then
        if [[ -x "$XUI_BIN" ]]; then
            run_quiet panel_cli setting -port "$PANEL_PORT" -webBasePath "$PANEL_BASE_PATH_RAW" \
                || log_warn "اعمال پورت/مسیر پنل با خطا مواجه شد"
        fi
    fi

    if [[ "$PANEL_ACCESS_MODE" == "tunnel" ]]; then
        panel_set_listen 127.0.0.1
    else
        log_info "حالت public: پنل روی همهٔ اینترفیس‌ها شنود می‌کند"
        # A previous tunnel-mode install left webListen=127.0.0.1 in place.
        if [[ "$(state_get PANEL_ACCESS_MODE tunnel)" == "tunnel" ]] || state_exists; then
            panel_set_listen "" || log_warn "برای دسترسی عمومی، Listen را در تنظیمات پنل خالی کنید"
        fi
    fi

    if [[ "$PANEL_SSL_MODE" == "self-signed" ]]; then
        panel_generate_self_signed "$SERVER_IP" || true
        if [[ -n "${PANEL_TLS_CERT:-}" && -n "${PANEL_TLS_KEY:-}" ]]; then
            panel_apply_certificate "$PANEL_TLS_CERT" "$PANEL_TLS_KEY"
        fi
    else
        PANEL_SCHEME="http"
        panel_restart
    fi

    sleep 2
    if ! panel_detect_scheme; then
        log_warn "پنل روی 127.0.0.1:${PANEL_PORT} پاسخ نداد؛ وضعیت سرویس را بررسی می‌کنم"
        kv "سرویس x-ui" "$(panel_service_status)"
    fi

    # API token: from the installer result file, else minted through the CLI.
    if ! panel_get_api_token >/dev/null; then
        die "دریافت توکن API ناموفق بود. با دستور زیر دستی بسازید:  x-ui setting -getApiToken"
    fi
    export PANEL_API_TOKEN

    if ! panel_wait_ready 45; then
        log_warn "API پنل در ۴۵ ثانیه پاسخ نداد؛ ورود با رمز بررسی می‌شود"
        if ! api_silent GET "/panel/api/server/status"; then
            log_warn "توکن API معتبر نیست؛ تلاش برای ورود با نام کاربری/رمز"
            panel_login "$PANEL_USER" "$PANEL_PASS" && PANEL_API_TOKEN="" || true
        fi
    fi

    api_is_authenticated 2>/dev/null || log_warn "اتصال به API پنل تأیید نشد (پنل نصب شده اما دسترسی API بررسی نشد)"
}

persist_state_early() {
    state_set STATE_VERSION "1"
    state_set OS_ID "$OS_ID"
    state_set ARCH "$ARCH"
    state_set PANEL_PORT "$PANEL_PORT"
    state_set PANEL_BASE_PATH "$PANEL_BASE_PATH"
    state_set PANEL_USER "$PANEL_USER"
    state_set PANEL_PASS "$PANEL_PASS"
    state_set PANEL_SCHEME "$PANEL_SCHEME"
    state_set PANEL_ACCESS_MODE "$PANEL_ACCESS_MODE"
    state_set PANEL_SSL_MODE "$PANEL_SSL_MODE"
    state_set PANEL_API_TOKEN "${PANEL_API_TOKEN:-}"
    state_set SERVER_IP "$SERVER_IP"
    state_set XUI_VERSION "$(panel_version 2>/dev/null || echo unknown)"
    state_set INSTALLED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# --- reality inbound ---------------------------------------------------------
setup_reality_inbound() {
    local port="$1" network="$2" remark="$3" path="${4:-}"
    local flow="" sni priv pub sid payload id existing

    if [[ "$network" == "tcp" ]]; then
        flow="xtls-rprx-vision"
    fi

    existing="$(reality_inbound_exists "$port" "$network" || true)"
    if [[ -n "$existing" ]]; then
        log_info "Inbound موجود برای پورت ${port} (${network}) پیدا شد: شناسه ${existing}"
        id="$existing"
        # Re-runs (and hosts whose state file was lost) must still print links
        # that match what xray actually serves: read the material back.
        local fetched
        fetched="$(inbound_get_json "$id" 2>/dev/null || true)"
        reality_harvest_from_inbound "$fetched" || true
    else
        # Keys: TCP inbound generates them; the xhttp inbound reuses them so the
        # same public key/SNI pair stays valid for both.
        if [[ -n "${VLESS_PRIVATE_KEY:-}" && -n "${VLESS_PUBLIC_KEY:-}" ]]; then
            priv="$VLESS_PRIVATE_KEY"; pub="$VLESS_PUBLIC_KEY"
        else
            read -r priv pub <<< "$(reality_keypair)" || die "تولید کلید REALITY ناموفق بود"
        fi
        sid="${VLESS_SHORT_ID:-$(reality_short_id)}"
        sni="${VLESS_SNI:-$(pick_reality_sni "$VLESS_SNI_CHOICE")}"

        payload="$(reality_build_payload "dummy" "$DEFAULT_CLIENT_EMAIL" "" "$flow" "$port" "$sni" \
                    "$priv" "$sid" "$pub" "$remark" "$network" "$path" "$SERVER_IP")" || return 1

        # The client identity is created separately (client/add) so the same
        # email can be attached to more than one inbound; strip it here.
        payload="$(printf '%s' "$payload" | jq -c '.settings.clients = []')"

        log_info "ساخت Inbound ${network} روی پورت ${port} با SNI ${sni}"
        id="$(reality_create_inbound "$payload")" || return 1
        log_ok "Inbound ${network} ساخته شد (شناسه ${id})"

        VLESS_PRIVATE_KEY="$priv"
        VLESS_PUBLIC_KEY="$pub"
        VLESS_SHORT_ID="$sid"
        VLESS_SNI="$sni"
    fi

    printf '%s' "$id"
}

create_inbounds_and_clients() {
    local tcp_id xhttp_id path

    VLESS_REMARK="${VLESS_REMARK:-$(hostname -s 2>/dev/null || echo server)-reality}"
    VLESS_FLOW="xtls-rprx-vision"

    # setup_reality_inbound reuses an existing inbound when there is one, and
    # fills VLESS_UUID/VLESS_PUBLIC_KEY/... from it.
    tcp_id="$(setup_reality_inbound "$VLESS_PORT" tcp "$VLESS_REMARK")" || die "ساخت Inbound اصلی ناموفق بود"
    VLESS_INBOUND_ID="$tcp_id"
    # setup_reality_inbound necessarily runs inside a command-substitution
    # subshell, so the VLESS_* material it resolves (reality keypair, chosen
    # SNI, shortId) never reaches this shell. Read the inbound back and
    # harvest it here; otherwise `set -u` aborts the final report on
    # ${VLESS_PUBLIC_KEY}, persisted state/links come out empty, and the
    # xhttp inbound below mints a different keypair instead of reusing this
    # one. Retry a few times: the panel may need a beat before a freshly
    # created inbound is readable back.
    local _harvest_try _harvest_resp=""
    for _harvest_try in 1 2 3 4 5; do
        _harvest_resp="$(inbound_get_json "$tcp_id" 2>/dev/null || true)"
        reality_harvest_from_inbound "$_harvest_resp" || true
        [[ -n "${VLESS_PUBLIC_KEY:-}" ]] && break
        sleep 1
    done
    if [[ -z "${VLESS_PUBLIC_KEY:-}" ]]; then
        log_warn "بازیابی مشخصات Inbound ${tcp_id} از پنل ناموفق بود (لینک‌ها از روی API پنل ساخته می‌شوند)"
        log_warn "  پاسخ خام پنل (۲۰۰ نویسه): $(printf '%.200s' "${_harvest_resp:-<empty>}")"
    fi

    VLESS_UUID="${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || rand_hex 16)}"
    inbound_set_share_addr "$tcp_id" "$SERVER_IP" || true

    if is_true "$CREATE_XHTTP"; then
        path="${XHTTP_PATH_DEFAULT:-/$(rand_string 12 'a-z0-9')}"
        # The panel refuses a second inbound on a port that another inbound
        # already uses with an overlapping (wildcard) listen, so xHTTP always
        # gets its own port.
        XHTTP_PORT="$(choose_free_port "${XHTTP_PORT_DEFAULT:-8443}" \
                        "$VLESS_PORT_FALLBACK_MIN" "$VLESS_PORT_FALLBACK_MAX" "پورت xhttp")"
        xhttp_id="$(setup_reality_inbound "$XHTTP_PORT" xhttp "${VLESS_REMARK}-xhttp" "$path")" \
            || log_warn "ساخت Inbound xhttp ناموفق بود (ادامه می‌دهم)"
        if [[ -n "${xhttp_id:-}" ]]; then
            XHTTP_INBOUND_ID="$xhttp_id"
            XHTTP_PATH="$path"
            inbound_set_share_addr "$xhttp_id" "$SERVER_IP" || true
        else
            XHTTP_PORT=""
        fi
    fi

    xray_restart

    # ---- default client on the TCP inbound
    local email="$DEFAULT_CLIENT_EMAIL"
    if ! client_add "$email" "$tcp_id" "$DEFAULT_CLIENT_TOTAL_GB" "$DEFAULT_CLIENT_EXPIRY_DAYS" \
            "$DEFAULT_CLIENT_LIMIT_IP" "$VLESS_FLOW" "$VLESS_UUID"; then
        log_warn "ساخت کلاینت پیش‌فرض ناموفق بود؛ لینک از Inbound ساخته می‌شود"
    fi

    # Additional emails requested on the command line
    local extra
    for extra in "${CLIENT_EMAILS[@]+"${CLIENT_EMAILS[@]}"}"; do
        [[ "$extra" == "$email" ]] && continue
        client_add "$extra" "$tcp_id" "$DEFAULT_CLIENT_TOTAL_GB" "$DEFAULT_CLIENT_EXPIRY_DAYS" "$DEFAULT_CLIENT_LIMIT_IP" "$VLESS_FLOW" || true
    done

    if [[ -n "${xhttp_id:-}" ]]; then
        client_add "$email" "$xhttp_id" "$DEFAULT_CLIENT_TOTAL_GB" "$DEFAULT_CLIENT_EXPIRY_DAYS" "$DEFAULT_CLIENT_LIMIT_IP" "" || true
    fi

    # Wait for the inbound to be really listening before we claim success.
    local waited=0
    while ((waited < 20)); do
        port_in_use "$VLESS_PORT" && break
        sleep 1; ((waited++))
    done
    if port_in_use "$VLESS_PORT"; then
        log_ok "پورت ${VLESS_PORT} در حال شنود است"
    else
        log_warn "پورت ${VLESS_PORT} هنوز شنود نمی‌کند؛ 'journalctl -u x-ui -n 50' را بررسی کنید"
    fi
}

# --- state / report ----------------------------------------------------------
persist_state_full() {
    state_set VLESS_PORT "$VLESS_PORT"
    state_set VLESS_INBOUND_ID "${VLESS_INBOUND_ID:-}"
    state_set VLESS_UUID "${VLESS_UUID:-}"
    state_set VLESS_FLOW "${VLESS_FLOW:-}"
    state_set VLESS_SNI "${VLESS_SNI:-}"
    state_set VLESS_SHORT_ID "${VLESS_SHORT_ID:-}"
    state_set VLESS_PUBLIC_KEY "${VLESS_PUBLIC_KEY:-}"
    state_set VLESS_PRIVATE_KEY "${VLESS_PRIVATE_KEY:-}"
    state_set VLESS_REMARK "${VLESS_REMARK:-}"
    state_set XHTTP_PORT "${XHTTP_PORT:-}"
    state_set XHTTP_INBOUND_ID "${XHTTP_INBOUND_ID:-}"
    state_set XHTTP_PATH "${XHTTP_PATH:-}"
    state_set DEFAULT_CLIENT_EMAIL "$DEFAULT_CLIENT_EMAIL"
    state_set SUB_PORT "$SUB_PORT"
    state_set SUB_PATH "$SUB_PATH"
    state_set ENABLE_SUBSCRIPTION "${ENABLE_SUBSCRIPTION:-yes}"
    state_set ENABLE_UFW "${ENABLE_UFW:-no}"
    state_set ENABLE_FAIL2BAN "${ENABLE_FAIL2BAN:-no}"
    state_set ENABLE_BBR "${ENABLE_BBR:-no}"
    if [[ -z "$(state_get SSH_PORT)" ]]; then
        state_set SSH_PORT "$(ssh_ports_active | head -1)"
    fi
    state_set BACKUP_ENABLED "${BACKUP_ENABLED:-yes}"
    state_set BACKUP_CRON "${BACKUP_CRON:-$BACKUP_CRON_DEFAULT}"
    chmod 600 "$VPN_SANAI_STATE_FILE" 2>/dev/null || true
}

save_report() {
    local file="$VPN_SANAI_REPORT_FILE"
    local body
    body="$(cat <<EOF
=========================================================
 vpn-sanai report — $(date '+%Y-%m-%d %H:%M:%S')
=========================================================

[دسترسی به پنل]
  آدرس روی سرور: ${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}
  روش دسترسی   : ${PANEL_ACCESS_MODE} $( [[ "$PANEL_ACCESS_MODE" == "public" ]] && echo "(عمومی: https://${SERVER_IP}:${PANEL_PORT}${PANEL_BASE_PATH})" || echo "(فقط از طریق تونل SSH)" )
  نام کاربری   : ${PANEL_USER}
  رمز عبور     : ${PANEL_PASS}
  توکن API     : ${PANEL_API_TOKEN}

[کانفیگ VLESS + REALITY]
  پورت         : ${VLESS_PORT:-}
  SNI          : ${VLESS_SNI:-}
  ShortId      : ${VLESS_SHORT_ID:-}
  PublicKey    : ${VLESS_PUBLIC_KEY:-}
  UUID پیش‌فرض  : ${VLESS_UUID:-}
  Inbound ID   : ${VLESS_INBOUND_ID:-}
  xHTTP        : ${XHTTP_PORT:-غیرفعال} ${XHTTP_INBOUND_ID:+(inbound ${XHTTP_INBOUND_ID})}

[امنیت]
  UFW          : ${ENABLE_UFW:-?}
  fail2ban     : ${ENABLE_FAIL2BAN:-?}
  BBR          : ${ENABLE_BBR:-?}
  پورت SSH     : $(ssh_ports_active | paste -sd, -)

[پشتیبان‌گیری]
  مسیر         : ${VPN_SANAI_BACKUP_DIR}
  زمان‌بندی    : $( [[ -f "$BACKUP_CRON_FILE" ]] && echo "${BACKUP_CRON:-$BACKUP_CRON_DEFAULT}" || echo 'غیرفعال' )

[فایل‌ها]
  state        : ${VPN_SANAI_STATE_FILE}
  links        : ${VPN_SANAI_LINKS_DIR}
  log          : ${VPN_SANAI_LOG_FILE:--}
EOF
)"
    atomic_write "$file" 600 "$body"
    log_info "گزارش نصب ذخیره شد: ${file}"
}

final_summary() {
    print_rule "خلاصهٔ نصب"
    local -a ssh_ports_detected=()
    while read -r p; do [[ -n "$p" ]] && ssh_ports_detected+=("$p"); done < <(ssh_ports_active)
    local ssh_port="${ssh_ports_detected[0]:-22}"

    kv "پنل (روی سرور)" "${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}"
    if [[ "$PANEL_ACCESS_MODE" == "tunnel" ]]; then
        kv "دسترسی از سیستم شما" "ssh -N -L 8443:127.0.0.1:${PANEL_PORT} root@${SERVER_IP} -p ${ssh_port}"
        kv "سپس در مرورگر" "https://127.0.0.1:8443${PANEL_BASE_PATH}"
    else
        kv "دسترسی عمومی" "https://${SERVER_IP}:${PANEL_PORT}${PANEL_BASE_PATH}"
        [[ "$PANEL_SSL_MODE" == "self-signed" ]] && log_warn "گواهی self-signed است؛ مرورگر هشدار می‌دهد (برای اتصال امن، فایل گواهی را در کلاینت وارد کنید)"
    fi
    kv "نام کاربری پنل" "$PANEL_USER"
    kv "رمز عبور پنل" "$PANEL_PASS"
    print_rule "کانفیگ VLESS + REALITY"
    kv "آدرس کلاینت" "${SERVER_IP}:${VLESS_PORT:-}"
    kv "SNI" "${VLESS_SNI:-}"
    kv "ShortId" "${VLESS_SHORT_ID:-}"
    local sub_id sub_link=""
    sub_id="$(client_sub_id "$DEFAULT_CLIENT_EMAIL" 2>/dev/null || true)"
    [[ -n "$sub_id" ]] && sub_link="$(sub_url "$sub_id")"
    kv "لینک اشتراک" "${sub_link:-—}"
    print_rule ""
    print_client_link "$DEFAULT_CLIENT_EMAIL" || true
    if [[ -n "${XHTTP_INBOUND_ID:-}" && -n "${XHTTP_PORT:-}" ]]; then
        local xhttp_link
        xhttp_link="$(build_vless_link "${VLESS_UUID:-}" "$SERVER_IP" "$XHTTP_PORT" "xhttp" \
            "${VLESS_SNI:-}" "${VLESS_SHORT_ID:-}" "${VLESS_PUBLIC_KEY:-}" "" \
            "${VLESS_REMARK}-xhttp" "${XHTTP_PATH:-/}" "${XHTTP_MODE:-auto}")"
        print_rule "کانفیگ xHTTP (پورت ${XHTTP_PORT})"
        kv "لینک" "$xhttp_link"
        show_qr "$xhttp_link" "${VPN_SANAI_LINKS_DIR}/${DEFAULT_CLIENT_EMAIL}-xhttp.png" || true
    fi
    print_rule "فایل‌ها و لاگ‌ها"
    kv "گزارش نصب" "$VPN_SANAI_REPORT_FILE"
    kv "لینک‌ها" "${VPN_SANAI_LINKS_DIR}/"
    kv "لاگ نصب" "${VPN_SANAI_LOG_FILE:-$VPN_SANAI_LOG_DIR}"
    kv "پشتیبان‌ها" "$VPN_SANAI_BACKUP_DIR"
    printf '\n' >&2
    if ! [[ -r "${VPN_SANAI_ETC}/telegram.env" ]]; then
        log_info "💡 برای مدیریت کامل سرور از تلگرام:  bash install.sh --telegram"
    else
        log_info "🤖 ربات تلگرام فعال است:  vpn-sanai-telegram --status"
    fi
    log_ok "همه‌چیز آماده است ✨"
}

# --- operations --------------------------------------------------------------
do_full_install() {
    print_rule "vpn-sanai ${VPN_SANAI_VERSION} — نصب پنل 3x-ui + VLESS/REALITY"
    detect_platform
    print_platform
    require_supported_os
    check_resources
    check_network
    check_and_install_deps
    setup_timezone
    ensure_time_sync
    confirm_server_ip
    collect_choices

    SUB_PORT="${SUB_PORT:-$SUB_PORT_DEFAULT}"
    SUB_PATH="${SUB_PATH:-$SUB_PATH_DEFAULT}"
    if [[ -z "$ENABLE_SUBSCRIPTION" ]]; then ENABLE_SUBSCRIPTION="$ENABLE_SUBSCRIPTION_DEFAULT"; fi

    bootstrap_panel
    persist_state_early

    create_inbounds_and_clients

    # Security last: the panel and the inbound must be reachable before the
    # firewall closes every other door.
    local -a ssh_ports=()
    while read -r p; do [[ -n "$p" ]] && ssh_ports+=("$p"); done < <(ssh_ports_active)

    if [[ -n "$SSH_PORT_NEW" ]]; then
        change_ssh_port "$SSH_PORT_NEW" "${ssh_ports[@]}" || log_warn "تغییر پورت SSH انجام نشد"
        while read -r p; do [[ -n "$p" ]] && ssh_ports+=("$p"); done < <(ssh_ports_active)
    fi

    setup_ufw "${ssh_ports[@]}"
    setup_fail2ban "${ssh_ports[@]}"
    setup_bbr
    setup_sysctl_tuning

    if [[ -z "$BACKUP_ENABLED" ]]; then BACKUP_ENABLED="$BACKUP_ENABLED_DEFAULT"; fi
    backup_create "install" >/dev/null || log_warn "پشتیبان‌گیری اولیه ناموفق بود"
    ((NO_BACKUP_CRON)) || backup_cron_install
    backup_prune

    install_cli_wrapper
    persist_state_full
    save_report
    final_summary
}

# Keep a stable copy of the tool under /usr/local/lib: the directory the script
# ran from may be a temporary one (curl | bash) or a git checkout the user will
# move later.
install_tool_tree() {
    local dest="${VPN_SANAI_LIBEXEC}"
    [[ "$SCRIPT_DIR" == "$dest" ]] && return 0

    ensure_dir "$dest" 755
    local dir
    for dir in lib config scripts; do
        [[ -d "${SCRIPT_DIR}/${dir}" ]] || continue
        rm -rf "${dest:?}/${dir}"
        cp -a "${SCRIPT_DIR}/${dir}" "${dest}/" 2>/dev/null || log_warn "کپی ${dir} ناموفق بود"
    done
    cp -a "${SCRIPT_DIR}/install.sh" "${dest}/install.sh" 2>/dev/null || true
    chmod +x "${dest}/install.sh" "${dest}"/scripts/*.sh 2>/dev/null || true
    log_debug "نسخهٔ پایدار ابزار در ${dest} نصب شد"
}

install_cli_wrapper() {
    install_tool_tree

    local entry="${VPN_SANAI_LIBEXEC}/install.sh"
    [[ -f "$entry" ]] || entry="${VPN_SANAI_SELF}"

    local -A commands=(
        [vpn-sanai]="install.sh"
        [vpn-sanai-add-client]="scripts/add-client.sh"
        [vpn-sanai-clients]="scripts/show-clients.sh"
        [vpn-sanai-backup]="scripts/backup.sh"
        [vpn-sanai-security]="scripts/security.sh"
        [vpn-sanai-status]="scripts/status.sh"
        [vpn-sanai-uninstall]="scripts/uninstall.sh"
        [vpn-sanai-telegram]="scripts/telegram-bot.sh"
    )
    local name rel target
    for name in "${!commands[@]}"; do
        rel="${commands[$name]}"
        target="/usr/local/bin/${name}"
        atomic_write "$target" 755 "#!/usr/bin/env bash
# Managed by ${VPN_SANAI_NAME} — stable launcher for ${rel}
exec bash \"${VPN_SANAI_LIBEXEC}/${rel}\" \"\$@\"
"
    done
    log_info "دستورات مدیریتی نصب شدند: vpn-sanai، vpn-sanai-clients، vpn-sanai-status و ..."
}

show_status() {
    state_load || true
    print_rule "وضعیت vpn-sanai"
    if ! state_exists && ! panel_installed; then
        log_warn "نصبی پیدا نشد. برای نصب:  bash install.sh"
        return 0
    fi
    if panel_installed; then
        PANEL_PORT="${PANEL_PORT:-$(state_get PANEL_PORT)}"
        PANEL_BASE_PATH="${PANEL_BASE_PATH:-$(state_get PANEL_BASE_PATH '/')}"
        PANEL_BASE_PATH_RAW="${PANEL_BASE_PATH_RAW:-$(base_path_raw "$PANEL_BASE_PATH")}"
        PANEL_API_TOKEN="${PANEL_API_TOKEN:-$(state_get PANEL_API_TOKEN)}"
        PANEL_SCHEME="${PANEL_SCHEME:-$(state_get PANEL_SCHEME http)}"
        detect_platform
        panel_detect_scheme 2>/dev/null || true
        panel_status_summary
        kv "پنل" "${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}"
    else
        kv "پنل" "نصب نیست"
    fi
    kv "پورت VLESS" "$(state_get VLESS_PORT '?')"
    kv "SNI" "$(state_get VLESS_SNI '?')"
    kv "کلاینت پیش‌فرض" "$(state_get DEFAULT_CLIENT_EMAIL '?')"
    kv "state" "$VPN_SANAI_STATE_FILE"
    if panel_installed; then
        local code
        code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
                "$(api_url '/panel/api/server/status')" \
                -H "Authorization: Bearer ${PANEL_API_TOKEN:-}" 2>/dev/null || echo 000)"
        kv "API" "HTTP ${code}"
    fi
    backup_status
    security_summary 2>/dev/null || true
}

action_add_client() {
    local email="$1"
    state_load || die "ابتدا نصب را اجرا کنید"
    PANEL_PORT="${PANEL_PORT:-$(state_get PANEL_PORT)}"
    PANEL_BASE_PATH="$(state_get PANEL_BASE_PATH '/')"
    PANEL_API_TOKEN="${PANEL_API_TOKEN:-$(state_get PANEL_API_TOKEN)}"
    PANEL_SCHEME="${PANEL_SCHEME:-$(state_get PANEL_SCHEME http)}"
    SERVER_IP="${SERVER_IP:-$(state_get SERVER_IP)}"
    detect_platform
    api_is_authenticated 2>/dev/null || die "اتصال به API پنل برقرار نشد (پنل بالا است؟)"

    local inbound_id="${VLESS_INBOUND_ID:-$(state_get VLESS_INBOUND_ID)}"
    [[ -n "$inbound_id" ]] || die "شناسهٔ Inbound در state ثبت نشده است"

    client_add "$email" "$inbound_id" "$DEFAULT_CLIENT_TOTAL_GB" "$DEFAULT_CLIENT_EXPIRY_DAYS" "$DEFAULT_CLIENT_LIMIT_IP" "xtls-rprx-vision" || exit 1
    VLESS_UUID="$(state_get VLESS_UUID)"; VLESS_PORT="$(state_get VLESS_PORT)"
    VLESS_SNI="$(state_get VLESS_SNI)"; VLESS_SHORT_ID="$(state_get VLESS_SHORT_ID)"
    VLESS_PUBLIC_KEY="$(state_get VLESS_PUBLIC_KEY)"; VLESS_REMARK="$(state_get VLESS_REMARK)"
    VLESS_FLOW="xtls-rprx-vision"

    # Each client has its own UUID: read it back from the panel.
    local info uuid
    info="$(client_info "$email")" || true
    if [[ -n "$info" ]]; then
        uuid="$(printf '%s' "$info" | jq -r '.client.id // .id // empty')"
        [[ -n "$uuid" ]] && VLESS_UUID="$uuid"
    fi
    print_client_link "$email" || true
}

action_show_clients() {
    state_load || die "ابتدا نصب را اجرا کنید"
    PANEL_PORT="${PANEL_PORT:-$(state_get PANEL_PORT)}"
    PANEL_BASE_PATH="$(state_get PANEL_BASE_PATH '/')"
    PANEL_API_TOKEN="${PANEL_API_TOKEN:-$(state_get PANEL_API_TOKEN)}"
    PANEL_SCHEME="${PANEL_SCHEME:-$(state_get PANEL_SCHEME http)}"
    SERVER_IP="${SERVER_IP:-$(state_get SERVER_IP)}"

    local list
    list="$(client_list 2>/dev/null || api_get_obj "/panel/api/inbounds/list" 2>/dev/null || true)"
    if [[ -z "$list" ]]; then
        local email
        email="$(state_get DEFAULT_CLIENT_EMAIL user1)"
        print_client_link "$email" || die "فهرست کلاینت‌ها خوانده نشد"
        return 0
    fi

    local -a emails=()
    while read -r e; do [[ -n "$e" ]] && emails+=("$e"); done < <(
        printf '%s' "$list" | jq -r '
            if type=="array" and (.[0]|has("settings")?) then
                .[] | (.settings|fromjson?) | .clients[]? | .email
            else
                .[]? | (.client.email // .email // empty)
            end' 2>/dev/null | sort -u
    )

    if ((${#emails[@]} == 0)); then
        log_warn "کلاینتی پیدا نشد"
        return 0
    fi

    local e
    for e in "${emails[@]}"; do
        VLESS_UUID=""
        local info
        info="$(client_info "$e")" || true
        if [[ -n "$info" ]]; then
            VLESS_UUID="$(printf '%s' "$info" | jq -r '.client.id // .id // empty')"
        fi
        [[ -n "$VLESS_UUID" ]] || VLESS_UUID="$(state_get VLESS_UUID)"
        VLESS_PORT="${VLESS_PORT:-$(state_get VLESS_PORT)}"
        VLESS_SNI="${VLESS_SNI:-$(state_get VLESS_SNI)}"
        VLESS_SHORT_ID="${VLESS_SHORT_ID:-$(state_get VLESS_SHORT_ID)}"
        VLESS_PUBLIC_KEY="${VLESS_PUBLIC_KEY:-$(state_get VLESS_PUBLIC_KEY)}"
        VLESS_REMARK="${VLESS_REMARK:-$(state_get VLESS_REMARK)}"
        VLESS_FLOW="${VLESS_FLOW:-$(state_get VLESS_FLOW)}"
        print_client_link "$e" || true
    done
}

action_update_panel() {
    detect_platform
    panel_installed || die "پنل نصب نیست"
    log_step "به‌روزرسانی پنل به آخرین نسخه"
    panel_install "latest"
    panel_restart
    log_ok "پنل به‌روزرسانی شد: $(panel_version)"
}

action_uninstall() {
    state_load || true
    detect_platform
    log_warn "این عملیات پنل، سرویس‌ها و تنظیمات vpn-sanai را حذف می‌کند"
    ask_yesno "مطمئن هستید؟" "n" || { log_info "لغو شد"; return 0; }

    if panel_installed; then
        if has_cmd x-ui; then
            printf 'y\n' | x-ui uninstall || true
        fi
    fi
    panel_service_ctl stop 2>/dev/null || true

    rm -f "$XUI_CLI" "$XUI_SYSTEMD_UNIT" /usr/local/bin/vpn-sanai 2>/dev/null || true
    rm -rf "$XUI_FOLDER" 2>/dev/null || true
    rm -f "$BACKUP_CRON_FILE" 2>/dev/null || true
    rm -f "$SSH_DROPIN" 2>/dev/null || true
    rm -f "$F2B_SSHD" "$F2B_DEFAULTS" 2>/dev/null || true
    rm -f "$SYSCTL_NET" "$SYSCTL_BBR" /etc/modules-load.d/vpn-sanai-bbr.conf 2>/dev/null || true

    if has_cmd systemctl; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    fi

    if ask_yesno "دیتابیس و تنظیمات پنل (/etc/x-ui) هم پاک شود؟" "n"; then
        rm -rf /etc/x-ui
    fi
    if ask_yesno "پشتیبان‌های ${VPN_SANAI_BACKUP_DIR} هم پاک شوند؟" "n"; then
        rm -rf "$VPN_SANAI_BACKUP_DIR"
    fi

    log_ok "حذف انجام شد (فایل‌های state در ${VPN_SANAI_ETC} باقی ماندند)"
}

action_menu() {
    state_load || true
    if ! state_exists; then
        do_full_install
        return 0
    fi
    print_rule "منوی مدیریت vpn-sanai"
    local choice=""
    local -a options=("نمایش وضعیت" "افزودن کلاینت" "نمایش لینک و QR" "پشتیبان‌گیری" \
                      "نهایی‌سازی پورت SSH" "به‌روزرسانی پنل" "اجرای مجدد پیکربندی" \
                      "تنظیم ربات تلگرام" "حذف نصب" "خروج")
    if ((VPN_SANAI_NONINTERACTIVE)) || [[ ! -t 0 ]]; then
        show_status
        return 0
    fi
    local i
    for i in "${!options[@]}"; do
        printf '  %s%d)%s %s\n' "$C_GREEN" "$((i + 1))" "$C_RESET" "${options[$i]}" >&2
    done
    read -r -p "${C_CYAN}انتخاب [1]: ${C_RESET}" choice || true
    case "${choice:-1}" in
        1) show_status ;;
        2) ask email "نام کلاینت" "user$(rand_string 4 '0-9')"; action_add_client "$email" ;;
        3) action_show_clients ;;
        4) state_load; backup_create "manual" ;;
        5) state_load; ssh_finalize ;;
        6) action_update_panel ;;
        7) do_full_install ;;
        8) action_telegram ;;
        9) action_uninstall ;;
        *) log_info "خروج" ;;
    esac
}

# --- Telegram bot -------------------------------------------------------------
action_telegram() {
    local script="${SCRIPT_DIR}/scripts/telegram-bot.sh"
    [[ -f "$script" ]] || script="${VPN_SANAI_LIBEXEC}/scripts/telegram-bot.sh"
    [[ -f "$script" ]] || die "اسکریپت ربات تلگرام پیدا نشد (scripts/telegram-bot.sh)"

    local -a args=(--setup)
    [[ -n "${TG_SETUP_TOKEN:-}" ]] && args+=(--token "$TG_SETUP_TOKEN")
    [[ -n "${TG_SETUP_ADMINS:-}" ]] && args+=(--admins "$TG_SETUP_ADMINS")
    ((VPN_SANAI_NONINTERACTIVE)) && args+=(--yes)

    log_step "راه‌اندازی ربات تلگرام"
    exec bash "$script" "${args[@]}"
}

# --- main --------------------------------------------------------------------
main() {
    # Order matters: load the previous install first, then let CLI flags win
    # over whatever the state file recorded.
    load_existing_state
    parse_args "$@"

    require_root "$@"
    setup_logging "$ACTION"
    install_error_trap
    acquire_lock

    case "$ACTION" in
        install)
            panel_installed && log_info "نصب موجود تشخیص داده شد؛ پیکربندی دوباره اعمال می‌شود"
            do_full_install
            ;;
        add-client)    action_add_client "${CLIENT_EMAILS[0]}" ;;
        show-clients)  action_show_clients ;;
        status)        show_status ;;
        backup)        backup_create "manual"; backup_prune ;;
        restore)       backup_restore "${RESTORE_FILE:-}" ;;
        update-panel)  action_update_panel ;;
        ssh-finalize)  ssh_finalize ;;
        uninstall)     action_uninstall ;;
        menu)          action_menu ;;
        *)             die "عملیات ناشناخته: ${ACTION}" ;;
    esac
}

# Tests source this file to exercise individual functions; running main is
# the default so piping / process substitution / direct execution all work.
if [[ "${VPN_SANAI_NO_MAIN:-0}" != "1" ]]; then
    main "$@"
fi
