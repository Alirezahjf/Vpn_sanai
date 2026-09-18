#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: scripts/telegram-bot.sh
#  مدیریت ربات تلگرام vpn-sanai — نصب، راه‌اندازی و کنترل سرویس.
#
#  Usage:
#     vpn-sanai-telegram --setup [--token TOKEN] [--admins 1,2] [--yes]
#     vpn-sanai-telegram --start | --stop | --restart | --status | --log
#     vpn-sanai-telegram --run [--once]      # اجرای مستقیم (foreground)
#     vpn-sanai-telegram --check             # بررسی سلامت پیکربندی
#     vpn-sanai-telegram --notify "متن"      # ارسال پیام به مدیران (برای cron)
#     vpn-sanai-telegram --uninstall
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/load.sh
source "${SCRIPT_DIR}/../lib/load.sh"
# shellcheck source=../lib/telegram.sh
source "${LOAD_DIR}/telegram.sh"
# shellcheck source=../lib/bot.sh
source "${LOAD_DIR}/bot.sh"

ACTION="setup"
SETUP_TOKEN=""
SETUP_ADMINS=""
ASSUME_YES=0
ONCE=0
NOTIFY_TEXT=""
NO_SERVICE=0

usage() {
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while (($#)); do
    case "$1" in
        --setup)       ACTION="setup"; shift ;;
        --run)         ACTION="run"; shift ;;
        --once)        ONCE=1; shift ;;
        --start)       ACTION="start"; shift ;;
        --stop)        ACTION="stop"; shift ;;
        --restart)     ACTION="restart"; shift ;;
        --status)      ACTION="status"; shift ;;
        --log)         ACTION="log"; shift ;;
        --check)       ACTION="check"; shift ;;
        --notify)      ACTION="notify"; NOTIFY_TEXT="${2:?}"; shift 2 ;;
        --uninstall)   ACTION="uninstall"; shift ;;
        --token)       SETUP_TOKEN="${2:?}"; shift 2 ;;
        --admins)      SETUP_ADMINS="${2:?}"; shift 2 ;;
        --no-service)  NO_SERVICE=1; shift ;;
        -y|--yes)      ASSUME_YES=1; shift ;;
        --debug)       VPN_SANAI_DEBUG=1; shift ;;
        -h|--help)     usage 0 ;;
        *)             die "گزینهٔ ناشناخته: $1" ;;
    esac
done

((ASSUME_YES)) && VPN_SANAI_NONINTERACTIVE=1
export VPN_SANAI_NONINTERACTIVE

SERVICE_NAME="${VPN_SANAI_TG_UNIT_NAME:-vpn-sanai-telegram}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BOT_BIN="/usr/local/bin/vpn-sanai-telegram"

has_systemd() { has_cmd systemctl && [[ -d /run/systemd/system ]]; }

# --- setup --------------------------------------------------------------------

tg_setup_validate_token() {
    # tg_setup_validate_token <token> -> prints "@username" on success
    local token="$1" saved_base="$TG_API_BASE" saved_token="$TG_BOT_TOKEN" user
    TG_BOT_TOKEN="$token"
    user="$(tg_get_me 2>/dev/null)" || {
        TG_API_BASE="$saved_base"; TG_BOT_TOKEN="$saved_token"
        return 1
    }
    TG_API_BASE="$saved_base"; TG_BOT_TOKEN="$saved_token"
    [[ -n "$user" ]] && printf '@%s' "$user"
}

tg_setup_write_config() {
    # tg_setup_write_config <token> <admins> <autodelete> <daily> <hour> [pair-code] [pair-expiry]
    local token="$1" admins="$2" autodel="$3" daily="$4" hour="$5"
    local pair="${6:-}" pair_exp="${7:-}"
    ensure_dir "$VPN_SANAI_ETC" 700
    local content="# Managed by ${VPN_SANAI_NAME} (telegram bot) — mode 600
TG_BOT_TOKEN=${token}
TG_ADMIN_IDS=${admins}
TG_AUTO_DELETE=${autodel}
TG_DAILY_REPORT=${daily}
TG_DAILY_REPORT_HOUR=${hour}"
    [[ -n "$pair" ]] && content+=$'\n'"TG_PAIRING_CODE=${pair}"$'\n'"TG_PAIRING_EXPIRY=${pair_exp}"
    atomic_write "$VPN_SANAI_TG_CONFIG" 600 "$content"
    chmod 600 "$VPN_SANAI_TG_CONFIG" 2>/dev/null || true
}

tg_setup_install_unit() {
    if ! has_systemd; then
        log_warn "systemd در دسترس نیست؛ سرویس نصب نشد. ربات را دستی اجرا کنید: ${BOT_BIN} --run"
        return 1
    fi
    local template="${ROOT_DIR}/config/vpn-sanai-telegram.service"
    [[ -f "$template" ]] || template="${VPN_SANAI_LIBEXEC}/config/vpn-sanai-telegram.service"
    if [[ -f "$template" ]]; then
        install -m 644 "$template" "$SERVICE_FILE" 2>/dev/null || \
            cp -f "$template" "$SERVICE_FILE" 2>/dev/null || true
    else
        # Self-contained fallback when the template is not shipped.
        atomic_write "$SERVICE_FILE" 644 "[Unit]
Description=vpn-sanai Telegram management bot
After=network-online.target x-ui.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BOT_BIN} --run
Restart=on-failure
RestartSec=5s
PrivateTmp=true
ProtectHome=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
"
    fi
    systemctl daemon-reload 2>/dev/null || true
    log_ok "سرویس ${SERVICE_NAME} نصب شد"
}

action_setup() {
    require_root "${ORIGINAL_ARGS[@]}"
    state_exists || log_warn "نصب vpn-sanai پیدا نشد؛ ربات فقط دستورهای عمومی کار می‌کند تا نصب کامل شود."

    local token="$SETUP_TOKEN"
    while :; do
        if [[ -z "$token" ]]; then
            ((VPN_SANAI_NONINTERACTIVE)) && die "برای نصب غیرتعاملی --token لازم است"
            ask_secret token "توکن ربات (از @BotFather)" ""
            [[ -n "$token" ]] || die "توکن خالی است؛ نصب لغو شد"
        fi
        if tg_valid_token "$token"; then
            local who; who="$(tg_setup_validate_token "$token")" && {
                log_ok "توکن معتبر است — ربات: ${who}"
                break
            }
            log_error "تلگرام این توکن را نپذیرفت ($TG_ERROR). دوباره تلاش کنید."
        else
            log_error "قالب توکن درست نیست (الگوی صحیح: 123456789:AA...)"
        fi
        ((VPN_SANAI_NONINTERACTIVE)) && die "توکن نامعتبر است؛ نصب لغو شد"
        token=""
    done

    local admins="$SETUP_ADMINS" pair="" pair_exp=""
    if [[ -z "$admins" ]]; then
        if ((VPN_SANAI_NONINTERACTIVE)); then
            pair="$(rand_string 8 'A-HJ-NP-Za-km-z2-9')"
            pair_exp=$(( $(date +%s) + 900 ))
            log_info "حالت جفت‌سازی: به ربات پیام «/start ${pair}» بفرستید (۱۰ دقیقه اعتبار)"
        else
            ask admins "شناسهٔ عددی مدیران (با کاما جدا کنید؛ خالی = جفت‌سازی از داخل چت)" ""
            admins="$(printf '%s' "$admins" | tr ',;' '  ' | tr -s ' ')"
            if [[ -z "$admins" ]]; then
                pair="$(rand_string 8 'A-HJ-NP-Za-km-z2-9')"
                pair_exp=$(( $(date +%s) + 900 ))
            fi
        fi
    else
        admins="$(printf '%s' "$admins" | tr ',;' '  ' | tr -s ' ')"
    fi
    # Validate/resolve before persisting: a non-numeric or unresolved admin id
    # leaves the bot installed but unusable for its owner.
    admins="$(tg_normalize_admins "$admins")"
    if [[ -z "$admins" && -z "$pair" ]]; then
        die "هیچ شناسهٔ مدیر معتبری باقی نماند. دوباره اجرا کنید و آیدی عددی (عددِ @userinfobot) یا @username کاربری که به ربات Start زده وارد کنید"
    fi

    local autodel="$TG_AUTO_DELETE_DEFAULT" daily="yes" hour="$TG_DAILY_REPORT_HOUR_DEFAULT"
    if ((!VPN_SANAI_NONINTERACTIVE)); then
        ask autodel "حذف خودکار پیام‌های محرمانه پس از چند ثانیه" "$TG_AUTO_DELETE_DEFAULT"
        if ask_yesno "گزارش روزانهٔ وضعیت ارسال شود؟" "y"; then daily="yes"; else daily="no"; fi
        if [[ "$daily" == "yes" ]]; then
            ask hour "ساعت ارسال گزارش روزانه (۰-۲۳)" "$TG_DAILY_REPORT_HOUR_DEFAULT"
        fi
    fi
    is_uint "$autodel" || autodel="$TG_AUTO_DELETE_DEFAULT"
    is_uint "$hour" || hour="$TG_DAILY_REPORT_HOUR_DEFAULT"

    tg_setup_write_config "$token" "$admins" "$autodel" "$daily" "$hour" "$pair" "$pair_exp"
    log_ok "پیکربندی ذخیره شد: ${VPN_SANAI_TG_CONFIG} (mode 600)"

    if ((NO_SERVICE)); then
        log_info "نصب سرویس رد شد (--no-service)"
        return 0
    fi
    tg_setup_install_unit
    systemctl enable --now "$SERVICE_NAME" 2>/dev/null || {
        log_warn "فعال‌سازی سرویس ناموفق بود؛ اجرای دستی: ${BOT_BIN} --run"
        return 0
    }
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_ok "ربات در حال اجراست"
    else
        log_warn "سرویس فعال نشد؛ لاگ: journalctl -u ${SERVICE_NAME} -n 30"
    fi

    # Deliver a first message so the admin immediately sees it works.
    TG_BOT_TOKEN="$token"; TG_ADMIN_IDS="$admins"; TG_AUTO_DELETE="$autodel"
    TG_DAILY_REPORT="$daily"; TG_DAILY_REPORT_HOUR="$hour"
    TG_PAIRING_CODE="$pair"; TG_PAIRING_EXPIRY="$pair_exp"
    if [[ -n "$admins" ]]; then
        if bot_notify_admins "✅ ربات مدیریت vpn-sanai راه‌اندازی شد.

🆔 سرور: $(hostname) ($(state_get SERVER_IP '?'))
برای شروع /start را بفرستید."; then
            log_ok "پیام تست برای مدیران ارسال شد"
        else
            log_warn "ارسال پیام تست ناموفق بود (کاربران ابتدا به ربات Start زده‌اند؟)"
        fi
    fi
    if [[ -n "$pair" ]]; then
        print_rule "جفت‌سازی"
        log_info "۱) در تلگرام ربات خود را باز کنید و Start بزنید"
        log_info "۲) این پیام را بفرستید:  /start ${pair}"
        log_info "۳) از آن پس به‌عنوان مدیر شناخته می‌شوید"
    fi
}

# --- service control ------------------------------------------------------------

svc() {
    has_systemd || die "systemd در دسترس نیست؛ ربات را دستی اجرا کنید: ${BOT_BIN} --run"
    [[ -f "$SERVICE_FILE" ]] || die "سرویس نصب نیست؛ ابتدا: ${BOT_BIN} --setup"
    run systemctl "$1" "$SERVICE_NAME"
}

action_status() {
    if ! has_systemd; then
        kv "سرویس" "systemd موجود نیست"
        return 0
    fi
    if [[ -f "$SERVICE_FILE" ]]; then
        kv "سرویس" "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
        kv "فعال‌سازی" "$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo unknown)"
    else
        kv "سرویس" "نصب نیست (vpn-sanai-telegram --setup)"
    fi
    if bot_configured; then
        kv "پیکربندی" "$VPN_SANAI_TG_CONFIG ✓"
        kv "مدیران" "$(read_env_value "$VPN_SANAI_TG_CONFIG" TG_ADMIN_IDS 2>/dev/null | tr -s ' ' ',' || echo '—')"
        kv "توکن" "موجود"
    else
        kv "پیکربندی" "نصب نیست"
    fi
    [[ -d "$BOT_STATE_DIR" ]] && kv "offset" "$(cat "${BOT_STATE_DIR}/offset" 2>/dev/null || echo 0)"
}

action_log() {
    if has_systemd && [[ -f "$SERVICE_FILE" ]]; then
        journalctl -u "$SERVICE_NAME" -n "${1:-50}" --no-pager 2>/dev/null || true
    fi
    local f
    f="$(find "${VPN_SANAI_LOG_DIR}" -maxdepth 1 -name 'telegram-*.log' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)"
    [[ -n "$f" ]] && { print_rule "فایل لاگ: $f"; tail -n "${1:-50}" "$f"; }
    return 0
}

# --- health check ------------------------------------------------------------------

action_check() {
    print_rule "بررسی ربات تلگرام"
    if bot_config_load; then
        log_ok "پیکربندی خوانده شد (${VPN_SANAI_TG_CONFIG})"
    else
        log_error "${BOT_ERR}"
        return 1
    fi
    local admins; admins="$(bot_admins_list | paste -sd, -)"
    if [[ -n "$admins" ]]; then
        log_ok "مدیران: ${admins}"
    else
        log_warn "هیچ مدیری ثبت نشده — از کد جفت‌سازی استفاده کنید"
    fi
    local who
    if who="$(tg_get_me 2>/dev/null)"; then
        log_ok "اتصال به تلگرام برقرار است — ربات: @${who}"
    else
        log_error "اتصال به تلگرام برقرار نشد (${TG_ERROR})"
    fi
    if state_exists; then
        if ( load_state_runtime ) >/dev/null 2>&1; then
            log_ok "state نصب خوانده شد"
            if ( api_is_authenticated ) >/dev/null 2>&1; then
                log_ok "API پنل پاسخ می‌دهد"
            else
                log_warn "API پنل پاسخ نداد (سرویس x-ui بالا است؟)"
            fi
        else
            log_error "state نصب ناقص است"
        fi
    else
        log_warn "نصب vpn-sanai پیدا نشد"
    fi
    has_systemd && kv "سرویس" "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo 'نصب نیست')"
}

# --- one-shot notification ------------------------------------------------------------

action_notify() {
    [[ -n "$NOTIFY_TEXT" ]] || die "متن پیام خالی است"
    bot_config_load || exit 0      # unconfigured => cron stays silent
    if [[ -z "$(bot_admins_list)" ]]; then
        exit 0
    fi
    bot_notify_admins "$NOTIFY_TEXT" || die "ارسال پیام ناموفق بود (${TG_ERROR})"
    log_ok "پیام به مدیران ارسال شد"
}

# --- daemon ---------------------------------------------------------------------------

bot_loop() {
    local offset upd rc updates uid
    offset="$(bot_offset_read)"
    is_uint "$offset" || offset=0

    local errors=0
    while :; do
        updates="$(tg_get_updates "$offset" "$TG_POLL_TIMEOUT")"; rc=$?

        if ((rc == 0)) && [[ -n "$updates" ]]; then
            while IFS= read -r upd; do
                [[ -n "$upd" ]] || continue
                if ! bot_handle_update "$upd"; then
                    log_warn "پردازش یک به‌روزرسانی ناموفق بود"
                fi
                uid="$(printf '%s' "$upd" | jq -r '.update_id // empty' 2>/dev/null || true)"
                if is_uint "$uid"; then
                    offset=$((uid + 1))
                    bot_offset_write "$offset"
                fi
            done <<< "$updates"
        fi

        bot_daily_tick 2>/dev/null || true

        ((ONCE)) && break
        if ((rc != 0)); then
            errors=$((errors + 1))
            log_warn "getUpdates ناموفق بود (${TG_ERROR}) — تلاش ${errors}"
            # 409 Conflict: another instance is polling with the same token.
            [[ "$TG_ERROR" == *"Conflict"* ]] && die "نمونهٔ دیگری از ربات در حال اجراست (409)"
            sleep $(( errors > 5 ? 30 : 5 ))
        else
            errors=0
        fi
    done
    log_info "پردازش کامل شد (حالت --once)"
}

action_run() {
    bot_config_load || die "$BOT_ERR"
    [[ "$EUID" -eq 0 ]] || log_warn "ربات به‌صورت root اجرا نشده؛ عملیات مدیریتی ممکن است شکست بخورند"

    # The bot keeps its own lock: it must not collide with vpn-sanai helpers.
    ensure_dir "$BOT_STATE_DIR" 700
    if has_cmd flock; then
        exec 8>"${BOT_STATE_DIR}/bot.lock"
        if ! flock -n 8; then
            die "ربات از قبل در حال اجراست (${BOT_STATE_DIR}/bot.lock)"
        fi
    fi

    if state_exists; then
        state_load 2>/dev/null || true
        # Non-fatal defaults, same spirit as load_state_runtime.
        PANEL_PORT="${PANEL_PORT:-$(state_get PANEL_PORT)}"
        PANEL_BASE_PATH="${PANEL_BASE_PATH:-$(state_get PANEL_BASE_PATH '/')}"
        PANEL_USER="${PANEL_USER:-$(state_get PANEL_USER)}"
        PANEL_PASS="${PANEL_PASS:-$(state_get PANEL_PASS)}"
        PANEL_API_TOKEN="${PANEL_API_TOKEN:-$(state_get PANEL_API_TOKEN)}"
        PANEL_SCHEME="${PANEL_SCHEME:-$(state_get PANEL_SCHEME http)}"
        export PANEL_PORT PANEL_BASE_PATH PANEL_USER PANEL_PASS PANEL_API_TOKEN PANEL_SCHEME
    else
        log_warn "state نصب پیدا نشد؛ دستورهای وابسته به پنل کار نمی‌کنند تا نصب کامل شود"
    fi
    detect_platform >/dev/null 2>&1 || true

    trap 'log_info "ربات متوقف شد"; exit 0' INT TERM
    log_ok "ربات تلگرام @$(tg_get_me 2>/dev/null || echo '?') راه‌اندازی شد (poll=${TG_POLL_TIMEOUT}s)"
    bot_loop
}

# --- removal -------------------------------------------------------------------------

action_uninstall() {
    require_root "${ORIGINAL_ARGS[@]}"
    log_warn "ربات تلگرام حذف می‌شود (پنل و نصب vpn-sanai دست‌نخورده می‌ماند)"
    ask_yesno "ادامه می‌دهید؟" "n" || { log_info "لغو شد"; return 0; }
    if has_systemd; then
        systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    fi
    rm -f "$SERVICE_FILE" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$VPN_SANAI_TG_CONFIG" 2>/dev/null || true
    rm -rf "$BOT_STATE_DIR" 2>/dev/null || true
    log_ok "ربات حذف شد"
}

# --- main ------------------------------------------------------------------------------

case "$ACTION" in
    setup)     setup_logging telegram; install_error_trap; action_setup ;;
    run)       setup_logging telegram; action_run ;;
    start)     svc start ;;
    stop)      svc stop ;;
    restart)   svc restart ;;
    status)    action_status ;;
    log)       action_log 50 ;;
    check)     action_check ;;
    notify)    action_notify ;;
    uninstall) setup_logging telegram; install_error_trap; action_uninstall "${ORIGINAL_ARGS[@]}" ;;
    *)         die "عملیات ناشناخته: $ACTION" ;;
esac
