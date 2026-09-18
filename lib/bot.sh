#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: lib/bot.sh
#  The Telegram management bot: configuration, authentication, sessions,
#  inline menus, conversation wizards and the update dispatcher.
#
#  Design notes
#   * Auth is a strict allowlist of Telegram user ids stored in
#     /etc/vpn-sanai/telegram.env (mode 600). Strangers are rejected and the
#     admins are notified (throttled). A one-shot pairing code can enrol the
#     first admin from inside the chat.
#   * Conversation state lives in BOT_STATE_DIR/chat-<id>.env so the daemon
#     can be restarted (or crash) mid-wizard without losing context.
#   * Every handler is defensive: a failing panel call produces an error
#     message in the chat, never a dead daemon.
#   * Secrets (panel credentials) are sent with a self-destruct timer.
#
#  This file is meant to be *sourced*, never executed.
# =============================================================================

: "${VPN_SANAI_TG_CONFIG:=${VPN_SANAI_ETC}/telegram.env}"
: "${VPN_SANAI_BOT_STATE_DIR:=/var/lib/vpn-sanai/telegram}"
BOT_STATE_DIR="${VPN_SANAI_BOT_STATE_DIR}"

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_ADMIN_IDS="${TG_ADMIN_IDS:-}"
TG_AUTO_DELETE="${TG_AUTO_DELETE:-$TG_AUTO_DELETE_DEFAULT}"
TG_POLL_TIMEOUT="${TG_POLL_TIMEOUT:-$TG_POLL_TIMEOUT_DEFAULT}"
TG_DAILY_REPORT="${TG_DAILY_REPORT:-$TG_DAILY_REPORT_DEFAULT}"
TG_DAILY_REPORT_HOUR="${TG_DAILY_REPORT_HOUR:-$TG_DAILY_REPORT_HOUR_DEFAULT}"
TG_PAIRING_CODE="${TG_PAIRING_CODE:-}"
TG_PAIRING_EXPIRY="${TG_PAIRING_EXPIRY:-0}"
BOT_ERR=""

# --- configuration -----------------------------------------------------------

# bot_config_load -> source the runtime config, apply defaults, validate
bot_config_load() {
    [[ -r "$VPN_SANAI_TG_CONFIG" ]] || {
        BOT_ERR="پیکربندی ربات پیدا نشد (${VPN_SANAI_TG_CONFIG}). ابتدا «vpn-sanai-telegram --setup» را اجرا کنید."
        return 1
    }
    # shellcheck disable=SC1090
    source "$VPN_SANAI_TG_CONFIG"
    TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
    TG_ADMIN_IDS="${TG_ADMIN_IDS:-}"
    TG_AUTO_DELETE="${TG_AUTO_DELETE:-$TG_AUTO_DELETE_DEFAULT}"
    TG_POLL_TIMEOUT="${TG_POLL_TIMEOUT:-$TG_POLL_TIMEOUT_DEFAULT}"
    TG_DAILY_REPORT="${TG_DAILY_REPORT:-$TG_DAILY_REPORT_DEFAULT}"
    TG_DAILY_REPORT_HOUR="${TG_DAILY_REPORT_HOUR:-$TG_DAILY_REPORT_HOUR_DEFAULT}"
    TG_PAIRING_CODE="${TG_PAIRING_CODE:-}"
    TG_PAIRING_EXPIRY="${TG_PAIRING_EXPIRY:-0}"

    [[ -n "$TG_BOT_TOKEN" ]] || { BOT_ERR="TG_BOT_TOKEN در پیکربندی خالی است"; return 1; }
    return 0
}

bot_configured() { [[ -r "$VPN_SANAI_TG_CONFIG" && -n "$(read_env_value "$VPN_SANAI_TG_CONFIG" TG_BOT_TOKEN 2>/dev/null || true)" ]]; }

# --- admins / authentication --------------------------------------------------

bot_admins_list() {
    # Accept both "1 2 3" and "1,2,3" forms.
    printf '%s' "$TG_ADMIN_IDS" | tr ',;' '  ' | tr -s ' ' '\n' | grep -v '^$' || true
}

bot_is_admin() {
    local uid="$1" a
    [[ -n "$uid" ]] || return 1
    while IFS= read -r a; do
        [[ "$a" == "$uid" ]] && return 0
    done < <(bot_admins_list)
    return 1
}

# bot_add_admin <uid> -> persist into the config file (and the live list)
bot_add_admin() {
    local uid="$1"
    is_uint "$uid" || return 1
    bot_is_admin "$uid" && return 0
    local tmp
    tmp="$(mktemp)"
    {
        grep -v '^TG_ADMIN_IDS=' "$VPN_SANAI_TG_CONFIG" 2>/dev/null || true
        printf 'TG_ADMIN_IDS=%s %s\n' "${TG_ADMIN_IDS}" "$uid"
    } > "$tmp"
    cat "$tmp" > "$VPN_SANAI_TG_CONFIG" && rm -f "$tmp"
    chmod 600 "$VPN_SANAI_TG_CONFIG" 2>/dev/null || true
    TG_ADMIN_IDS="${TG_ADMIN_IDS} ${uid}"
    log_ok "کاربر تلگرام ${uid} به‌عنوان مدیر افزوده شد"
}

# bot_pairing_try <text> <uid> -> 0 when the message completed a pairing
bot_pairing_try() {
    local text="$1" uid="$2"
    [[ -n "$TG_PAIRING_CODE" ]] || return 1
    [[ "$text" == "/start ${TG_PAIRING_CODE}"* ]] || return 1
    local now; now="$(date +%s)"
    (( TG_PAIRING_EXPIRY > now )) || return 1
    bot_add_admin "$uid" || return 1
    # The code is single use.
    sed -i '/^TG_PAIRING_CODE=/d; /^TG_PAIRING_EXPIRY=/d' "$VPN_SANAI_TG_CONFIG" 2>/dev/null || true
    TG_PAIRING_CODE=""
    return 0
}

# tg_normalize_admins <raw> -> space-separated numeric ids
# Numeric tokens pass through; @username tokens resolve to the numeric id via
# getChat (works once that user has dm'd the bot); anything else is dropped
# with a warning. Guards against the classic "@myname stored where a numeric
# id was expected" mistake — the notification would reach no one and every
# /start would be denied.
tg_normalize_admins() {
    local raw="$1" token id out="" uname
    while IFS= read -r token; do
        [[ -n "$token" ]] || continue
        if is_uint "$token"; then
            out+=" $token"
            continue
        fi
        uname="${token#@}"
        if [[ "$uname" =~ ^[A-Za-z][A-Za-z0-9_]{3,31}$ ]]; then
            if tg_call getChat "$(jq -nc --arg c "@${uname}" '{chat_id:$c}')" >/dev/null 2>&1; then
                id="$(printf '%s' "$TG_RESPONSE" | jq -r '.result.id // empty')"
                if [[ "$id" =~ ^-?[0-9]+$ ]]; then
                    out+=" $id"
                    log_info "«${token}» به شناسهٔ عددی ${id} تبدیل شد"
                    continue
                fi
            fi
            log_warn "تشخیص آیدی «${token}» ناموفق بود؛ کاربر ابتدا باید به ربات Start بزند (یا آیدی عددی او را بدهید) — رد شد"
        else
            log_warn "شناسهٔ مدیر «${token}» نامعتبر است — رد شد (آیدی عددی یا @username وارد کنید)"
        fi
    done < <(printf '%s\n' "$raw" | tr ',;' '  ' | tr -s ' ' '\n')
    printf '%s' "${out# }"
}

# --- sessions -----------------------------------------------------------------

bot_sess_file() { printf '%s/chat-%s.env' "$BOT_STATE_DIR" "$1"; }

bot_sess_set() {
    local chat="$1" key="$2" value="${3-}"
    local file; file="$(bot_sess_file "$chat")"
    mkdir -p "$BOT_STATE_DIR" 2>/dev/null || true
    local tmp
    tmp="$(grep -v "^${key}=" "$file" 2>/dev/null || true)"
    printf '%s\n%s=%q\n' "$tmp" "$key" "$value" > "${file}.tmp" && mv -f "${file}.tmp" "$file"
    chmod 600 "$file" 2>/dev/null || true
}

bot_sess_get() {
    local chat="$1" key="$2" default="${3:-}"
    local file; file="$(bot_sess_file "$chat")"
    [[ -f "$file" ]] || { printf '%s' "$default"; return 0; }
    local line val
    line="$(grep -m1 "^${key}=" "$file" 2>/dev/null || true)"
    [[ -n "$line" ]] || { printf '%s' "$default"; return 0; }
    val="${line#*=}"
    eval "printf '%s' ${val}" 2>/dev/null || printf '%s' "$default"
}

bot_sess_clear() {
    local chat="$1"
    rm -f "$(bot_sess_file "$chat")" 2>/dev/null || true
}

# Selection lists: choosing a long name (email / backup file) from a callback
# button would exceed Telegram's 64-byte callback_data limit, so menus store
# the list in the session and pass the index instead.
bot_sel_save() {
    local chat="$1" type="$2"; shift 2
    bot_sess_set "$chat" sel_type "$type"
    bot_sess_set "$chat" sel_count "$#"
    local i=0
    local item
    for item in "$@"; do
        i=$((i + 1))
        bot_sess_set "$chat" "sel_${i}" "$item"
    done
}

bot_sel_get() {
    local chat="$1" idx="$2"
    [[ "$idx" =~ ^[0-9]+$ ]] || return 1
    bot_sess_get "$chat" "sel_${idx}" ""
}

# --- offset --------------------------------------------------------------------

bot_offset_file() { printf '%s/offset' "$BOT_STATE_DIR"; }

bot_offset_read() {
    local file; file="$(bot_offset_file)"
    if [[ -r "$file" ]]; then
        cat "$file" 2>/dev/null || true
    fi
}

bot_offset_write() { printf '%s' "$1" > "$(bot_offset_file)" 2>/dev/null || true; }

# --- reply helpers --------------------------------------------------------------

BOT_HOME_KB_ROW='⬅️ منوی اصلی|m:main'

# bot_reply <chat> <html> [kb-json] -> sends, prints message id
bot_reply() {
    local chat="$1" text="$2" kb="${3:-}"
    tg_send_message "$chat" "$text" "$kb"
}

# bot_edit <chat> <message-id> <html> [kb-json]
bot_edit() {
    local chat="$1" mid="$2" text="$3" kb="${4:-}"
    [[ -n "$mid" ]] || { bot_reply "$chat" "$text" "$kb"; return $?; }
    tg_edit_text "$chat" "$mid" "$text" "$kb"
}

# bot_send_secret <chat> <html> [kb-json] -> sends a self-destructing message
bot_send_secret() {
    local chat="$1" text="$2" kb="${3:-}"
    local secs="${TG_AUTO_DELETE:-90}"
    is_uint "$secs" || secs=90
    if ((secs > 0)); then
        text+=$'\n'"<i>⏱ این پیام تا ${secs} ثانیهٔ دیگر خودکار حذف می‌شود.</i>"
    fi
    local mid
    mid="$(tg_send_message "$chat" "$text" "$kb")" || return 1
    if ((secs > 0)); then
        bot_schedule_delete "$chat" "$mid" "$secs"
    fi
    printf '%s' "$mid"
}

# bot_schedule_delete <chat> <message-id> <seconds>
bot_schedule_delete() {
    local chat="$1" mid="$2" secs="$3"
    if [[ "${VPN_SANAI_BOT_TEST:-0}" == "1" ]]; then
        tg_delete_message "$chat" "$mid" >/dev/null 2>&1 || true
        return 0
    fi
    # shellcheck disable=SC2026
    ( sleep "$secs"; tg_delete_message "$chat" "$mid" >/dev/null 2>&1 ) >/dev/null 2>&1 &
}

# bot_notify_admins <html> -> message to every configured admin
bot_notify_admins() {
    local text="$1" uid sent=0
    [[ -n "$TG_BOT_TOKEN" ]] || return 1
    while IFS= read -r uid; do
        [[ -n "$uid" ]] || continue
        if tg_send_message "$uid" "$text" >/dev/null 2>&1; then
            sent=$((sent + 1))
        else
            log_warn "ارسال پیام به مدیر ${uid} ناموفق بود"
        fi
    done < <(bot_admins_list)
    ((sent > 0))
}

# --- formatting ------------------------------------------------------------------

fmt_bytes() {
    local b="${1:-0}" out
    if ! is_uint "$b"; then printf '0'; return 0; fi
    if   ((b >= 1073741824)); then out="$(awk -v x="$b" 'BEGIN{printf "%.2f", x/1073741824}') GB"
    elif ((b >= 1048576));    then out="$(awk -v x="$b" 'BEGIN{printf "%.1f", x/1048576}') MB"
    elif ((b >= 1024));       then out="$((b / 1024)) KB"
    else                            out="${b} B"; fi
    printf '%s' "$out"
}

# fmt_when <epoch-seconds> -> "۲ ساعت پیش" / "—" (Persian-friendly, digits ASCII)
fmt_when() {
    local ts="${1:-0}" now diff
    is_uint "$ts" || { printf '—'; return 0; }
    ((ts > 0)) || { printf '—'; return 0; }
    now="$(date +%s)"
    diff=$((now - ts))
    if   ((diff < 0));     then printf 'لحظاتی پیش'
    elif ((diff < 60));    then printf 'همین الان'
    elif ((diff < 3600));  then printf '%d دقیقه پیش' $((diff / 60))
    elif ((diff < 86400)); then printf '%d ساعت پیش' $((diff / 3600))
    else                        printf '%d روز پیش' $((diff / 86400)); fi
}

# fmt_expiry <epoch-ms> -> remaining time or "نامحدود"
fmt_expiry() {
    local ms="${1:-0}" now end
    is_uint "$ms" || { printf '?'; return 0; }
    ((ms > 0)) || { printf 'نامحدود'; return 0; }
    end=$((ms / 1000)); now="$(date +%s)"
    if ((end <= now)); then printf 'منقضی ⚠️'; return 0; fi
    local diff=$((end - now))
    if   ((diff < 3600));      then printf '%d دقیقه' $((diff / 60))
    elif ((diff < 86400));     then printf '%d ساعت' $((diff / 3600))
    elif ((diff < 2592000));   then printf '%d روز' $((diff / 86400))
    else                            printf '%d ماه' $((diff / 2592000)); fi
}

fmt_onoff() { is_true "$1" && printf '✅ فعال' || printf '⛔️ غیرفعال'; }

# fmt_duration <seconds> -> "3d 4h"
fmt_duration() {
    local s="${1:-0}" d h
    is_uint "$s" || { printf '?'; return 0; }
    d=$((s / 86400)); h=$(((s % 86400) / 3600))
    printf '%dd %dh' "$d" "$h"
}

# --- panel guard -------------------------------------------------------------------

# bot_server_ip -> the public IP from state (safe when globals are empty)
bot_server_ip() {
    printf '%s' "${SERVER_IP:-$(state_get SERVER_IP "?")}"
}

# bot_panel_ready -> 0 when state + panel API are usable; BOT_ERR explains why not
bot_panel_ready() {
    BOT_ERR=""
    if ! state_exists; then
        BOT_ERR="نصب vpn-sanai روی این سرور پیدا نشد. ابتدا نصب را کامل کنید."
        return 1
    fi
    # Validate the state in a subshell first: load_state_runtime dies on a broken
    # state file and a daemon must never exit because of that.
    if ! ( load_state_runtime ) >/dev/null 2>&1; then
        BOT_ERR="خواندن وضعیت نصب ناموفق بود (${VPN_SANAI_STATE_FILE})"
        return 1
    fi
    state_load 2>/dev/null || true
    # Defaults for keys an older state file may not carry.
    PANEL_SCHEME="${PANEL_SCHEME:-http}"
    PANEL_BASE_PATH="${PANEL_BASE_PATH:-/}"
    PANEL_ACCESS_MODE="${PANEL_ACCESS_MODE:-tunnel}"
    VLESS_FLOW="${VLESS_FLOW:-xtls-rprx-vision}"
    detect_platform >/dev/null 2>&1 || true
    panel_detect_scheme 2>/dev/null || true
    if ! api_is_authenticated 2>/dev/null; then
        if [[ -n "$PANEL_USER" && -n "$PANEL_PASS" ]]; then
            panel_login "$PANEL_USER" "$PANEL_PASS" 2>/dev/null || {
                BOT_ERR="اتصال به پنل برقرار نشد (سرویس x-ui بالا است؟)"
                return 1
            }
        else
            BOT_ERR="مشخصات ورود پنل در state ثبت نشده است"
            return 1
        fi
    fi
    return 0
}

# bot_err_reply <chat> -> send the last BOT_ERR as a friendly message
bot_err_reply() {
    local chat="$1"
    bot_reply "$chat" "❌ <b>خطا</b>

$(tg_escape_html "${BOT_ERR:-خطای نامشخص}")" "$(tg_kb "$BOT_HOME_KB_ROW")" >/dev/null
}

# --- update dispatch ----------------------------------------------------------------

# bot_handle_update <compact-json> -> 0 on success (errors are logged, not fatal)
bot_handle_update() {
    local upd="$1"
    local kind
    kind="$(printf '%s' "$upd" | jq -r 'if .callback_query then "cb" elif .message then "msg" else "" end' 2>/dev/null || true)"
    case "$kind" in
        msg) bot_handle_message "$upd" ;;
        cb)  bot_handle_callback "$upd" ;;
        *)   log_debug "به‌روزرسانی ناشناخته نادیده گرفته شد" ;;
    esac
}

# --- access gate ---------------------------------------------------------------------

# bot_refresh_admins_from_disk -> re-read TG_ADMIN_IDS from the config file.
# The service caches the env it started with; manual edits of telegram.env
# (the obvious way to fix a mistyped admin id) otherwise require a restart
# before they take effect.
bot_refresh_admins_from_disk() {
    [[ -r "$VPN_SANAI_TG_CONFIG" ]] || return 0
    local v
    v="$(read_env_value "$VPN_SANAI_TG_CONFIG" TG_ADMIN_IDS 2>/dev/null || true)"
    [[ -n "$v" ]] && TG_ADMIN_IDS="$v"
    return 0
}

# bot_gate <chat> <uid> <display-name> <text> -> 0 when the user may continue
bot_gate() {
    local chat="$1" uid="$2" name="$3" text="${4:-}"
    bot_refresh_admins_from_disk
    if bot_is_admin "$uid"; then
        return 0
    fi
    # Unknown user. Either this is the very first admin pairing …
    if bot_pairing_try "$text" "$uid"; then
        bot_reply "$chat" "✅ <b>اتصال انجام شد</b>

شما به‌عنوان مدیر این ربات ثبت شدید.
برای شروع /start را بفرستید." >/dev/null
        local others="${TG_ADMIN_IDS// /, }"
        bot_notify_admins "👤 کاربر تلگرام <b>${uid}</b> با کد جفت‌سازی به ربات اضافه شد." >/dev/null 2>&1 || true
        return 1
    fi
    # … or an intruder: reject, log, notify the admins (throttled to 1/hour/uid).
    log_warn "پیام از کاربر ناشناس ${uid} (${name}): رد شد"
    bot_reply "$chat" "⛔️ <b>دسترسی ندارید</b>

این ربات فقط برای مدیران سرور تنظیم شده است.
🆔 شناسهٔ عددی شما: <code>${uid}</code>" >/dev/null 2>&1 || true
    local marker="${BOT_STATE_DIR}/intruder-${uid}"
    if [[ ! -f "$marker" || -n "$(find "$marker" -mmin +60 2>/dev/null)" ]]; then
        mkdir -p "$BOT_STATE_DIR" 2>/dev/null || true
        touch "$marker" 2>/dev/null || true
        bot_notify_admins "🚸 تلاش برای دسترسی به ربات:
👤 $(tg_escape_html "$name") — id: <code>${uid}</code>
💬 $(tg_escape_html "${text:0:120}")" >/dev/null 2>&1 || true
    fi
    return 1
}

# --- message (command) handling ---------------------------------------------------------

bot_handle_message() {
    local upd="$1"
    local chat uid name type text
    chat="$(printf '%s' "$upd" | jq -r '.message.chat.id // empty')"
    uid="$(printf '%s' "$upd" | jq -r '.message.from.id // empty')"
    name="$(printf '%s' "$upd" | jq -r '.message.from.first_name // .message.from.username // "?"')"
    type="$(printf '%s' "$upd" | jq -r '.message.chat.type // "private"')"
    text="$(printf '%s' "$upd" | jq -r '.message.text // ""')"

    [[ -n "$chat" && -n "$uid" ]] || return 0
    [[ -n "$text" ]] || {
        bot_reply "$chat" "💬 فقط پیام متنی پشتیبانی می‌شود." >/dev/null 2>&1 || true
        return 0
    }

    # Gate first — pairing is handled inside.
    bot_gate "$chat" "$uid" "$name" "$text" || return 0

    local mode; mode="$(bot_sess_get "$chat" mode "")"

    # A running wizard swallows every plain message; /cancel escapes it.
    if [[ -n "$mode" && "$text" != /* ]]; then
        bot_wizard_step "$chat" "$uid" "$text" "$mode"
        return 0
    fi

    local cmd rest
    cmd="${text%% *}"; rest="${text#* }"
    [[ "$text" == *" "* ]] || rest=""
    cmd="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"
    cmd="$(printf '%s' "$cmd" | cut -d@ -f1)"   # /cmd@thisbot

    case "$cmd" in
        /start)    bot_menu_main "$chat" "" ;;
        /panel)    bot_menu_panel "$chat" "" ;;
        /status)   bot_send_status "$chat" ;;
        /clients)  bot_menu_clients "$chat" "" ;;
        /security) bot_menu_security "$chat" "" ;;
        /backup)   bot_menu_backup "$chat" "" ;;
        /settings) bot_menu_settings "$chat" "" ;;
        /help)     bot_send_help "$chat" ;;
        /id)       bot_reply "$chat" "🪪 شناسهٔ کاربری شما: <code>${uid}</code>
💬 شناسهٔ این چت: <code>${chat}</code>" >/dev/null ;;
        /add)      bot_cmd_add "$chat" "$rest" ;;
        /link)     bot_cmd_link "$chat" "$rest" ;;
        /del)      bot_cmd_del "$chat" "$rest" ;;
        /cancel)   bot_sess_clear "$chat"; bot_menu_main "$chat" "" ;;
        *)         bot_reply "$chat" "🤖 این دستور را نمی‌شناسم. /help را ببینید یا از دکمه‌ها استفاده کنید." >/dev/null ;;
    esac
    return 0
}

# --- callback handling -------------------------------------------------------------------

bot_handle_callback() {
    local upd="$1"
    local cb chat mid uid data
    cb="$(printf '%s' "$upd" | jq -r '.callback_query.id // empty')"
    chat="$(printf '%s' "$upd" | jq -r '.callback_query.message.chat.id // empty')"
    mid="$(printf '%s' "$upd" | jq -r '.callback_query.message.message_id // empty')"
    uid="$(printf '%s' "$upd" | jq -r '.callback_query.from.id // empty')"
    data="$(printf '%s' "$upd" | jq -r '.callback_query.data // empty')"

    # Always answer, otherwise the client shows a spinner until timeout.
    local answer_after=""

    if ! bot_is_admin "$uid"; then
        [[ -n "$cb" ]] && tg_answer_cb "$cb" "⛔️ دسترسی ندارید" 1 >/dev/null 2>&1 || true
        return 0
    fi

    [[ -n "$data" ]] || { [[ -n "$cb" ]] && tg_answer_cb "$cb" >/dev/null 2>&1 || true; return 0; }

    local -a parts=()
    IFS=':' read -r -a parts <<< "$data"
    local area="${parts[0]}" action="${parts[1]:-}" arg="${parts[2]:-}"

    case "$area" in
        m)
            case "$action" in
                main)    bot_menu_main "$chat" "$mid" ;;
                panel)   bot_menu_panel "$chat" "$mid" ;;
                cli)     bot_menu_clients "$chat" "$mid" ;;
                sec)     bot_menu_security "$chat" "$mid" ;;
                bkp)     bot_menu_backup "$chat" "$mid" ;;
                set)     bot_menu_settings "$chat" "$mid" ;;
                help)    bot_send_help "$chat" ;;
                *)       answer_after="?" ;;
            esac ;;
        st)
            bot_render_status_edit "$chat" "$mid" ;;
        pn)
            case "$action" in
                info) bot_action_panel_info "$chat" "$mid" ;;
                rst)  bot_confirm "$chat" "$mid" "🔁 <b>راه‌اندازی مجدد پنل سنایی</b>

سرویس x-ui حدود ۵ تا ۱۰ ثانیه قطع می‌شود. ادامه می‌دهید؟" "pn:rstY" ;;
                rstY) bot_action_panel_restart "$chat" ;;
                rxr)  bot_action_xray_restart "$chat" ;;
                pass) bot_confirm "$chat" "$mid" "🔑 <b>تغییر رمز عبور پنل</b>

رمز جدید تصادفی و قوی ساخته می‌شود و برایتان ارسال خواهد شد. ادامه می‌دهید؟" "pn:passY" ;;
                passY) bot_action_panel_newpass "$chat" ;;
                *)    answer_after="?" ;;
            esac ;;
        cl)
            case "$action" in
                list) bot_action_clients_list "$chat" "$mid" "${arg:-1}" ;;
                v)    bot_action_client_view "$chat" "$mid" "$arg" ;;
                qr)   bot_action_client_qr "$chat" "$arg" ;;
                sub)  bot_action_client_sub "$chat" "$arg" ;;
                rst)  bot_confirm_sel "$chat" "$mid" "$arg" "cl:rstY" "♻️ ریست ترافیک" ;;
                rstY) bot_action_client_reset "$chat" "$arg" ;;
                tgl)  bot_action_client_toggle "$chat" "$arg" ;;
                edq)  bot_wizard_start_edit "$chat" "$arg" "quota" ;;
                edd)  bot_wizard_start_edit "$chat" "$arg" "days" ;;
                del)  bot_confirm_sel "$chat" "$mid" "$arg" "cl:delY" "🗑 حذف کلاینت" ;;
                delY) bot_action_client_delete "$chat" "$arg" ;;
                add)  bot_wizard_start_add "$chat" ;;
                addY) bot_action_client_create_from_session "$chat" ;;
                onl)  bot_action_clients_online "$chat" "$mid" ;;
                rstAll)  bot_confirm "$chat" "$mid" "♻️ <b>ریست ترافیک همهٔ کلاینت‌ها</b>

شمارندهٔ مصرف همه صفر می‌شود (سهمیه‌ها دست‌نخورده می‌مانند). ادامه می‌دهید؟" "cl:rstAllY" ;;
                rstAllY) bot_action_clients_reset_all "$chat" ;;
                delDep)  bot_confirm "$chat" "$mid" "🧹 <b>حذف کلاینت‌های تمام‌شده</b>

کلاینت‌هایی که سهمیه یا اعتبارشان تمام شده حذف می‌شوند. ادامه می‌دهید؟" "cl:delDepY" ;;
                delDepY) bot_action_clients_delete_depleted "$chat" ;;
                *)       answer_after="?" ;;
            esac ;;
        sec)
            case "$action" in
                st)    bot_render_security "$chat" "$mid" ;;
                open)  bot_wizard_start "$chat" "ufw_open" "🔓 <b>باز کردن پورت فایروال</b>

پورت را بفرستید (مثال: <code>8443</code> یا <code>53/udp</code>):" ;;
                close) bot_wizard_start "$chat" "ufw_close" "🔒 <b>بستن پورت فایروال</b>

پورت را بفرستید (مثال: <code>8443</code> یا <code>53/udp</code>):" ;;
                unban) bot_wizard_start "$chat" "unban" "⛔ <b>آزادسازی IP از fail2ban</b>

آدرس IP را بفرستید:" ;;
                sshp)  bot_wizard_start "$chat" "ssh_port" "🌐 <b>تغییر پورت SSH</b>

⚠️ پس از تغییر، پورت قبلی تا نهایی‌سازی باز می‌ماند.
شمارهٔ پورت جدید را بفرستید:" ;;
                sshpY) bot_action_ssh_confirm "$chat" ;;
                *)     answer_after="?" ;;
            esac ;;
        bkp)
            case "$action" in
                list)  bot_action_backups_list "$chat" "$mid" ;;
                new)   bot_action_backup_create "$chat" ;;
                send)  bot_action_backup_send "$chat" ;;
                rst)   bot_confirm_sel "$chat" "$mid" "$arg" "bkp:rstY" "♻️ بازگردانی پشتیبان" ;;
                rstY)  bot_action_backup_restore "$chat" "$arg" ;;
                prune) bot_confirm "$chat" "$mid" "🧹 <b>پاک‌سازی پشتیبان‌های قدیمی</b>

پشتیبان‌های قدیمی‌تر از ${BACKUP_KEEP_DAYS} روز حذف می‌شوند. ادامه می‌دهید؟" "bkp:pruneY" ;;
                pruneY) bot_action_backup_prune "$chat" ;;
                *)      answer_after="?" ;;
            esac ;;
        set)
            case "$action" in
                show) bot_render_settings "$chat" "$mid" ;;
                port) bot_wizard_start "$chat" "set_port" "🔧 <b>تغییر پورت پنل</b>

شمارهٔ پورت جدید را بفرستید (۱ تا ۶۵۵۳۵):" ;;
                path) bot_wizard_start "$chat" "set_path" "🛣 <b>تغییر مسیر مخفی پنل</b>

مسیر جدید را بفرستید (حروف/عدد/خط تیره، ۴ تا ۳۲ نویسه) یا <code>rand</code> برای تولید تصادفی:" ;;
                user) bot_wizard_start "$chat" "set_user" "👤 <b>تغییر نام کاربری پنل</b>

نام کاربری جدید را بفرستید:" ;;
                pass) bot_wizard_start "$chat" "set_pass" "🔑 <b>تغییر رمز عبور پنل</b>

رمز جدید را بفرستید (حداقل ۸ نویسه) یا <code>rand</code> برای تولید تصادفی:" ;;
                mode) bot_confirm "$chat" "$mid" "$(bot_mode_toggle_text)" "set:modeY" ;;
                modeY) bot_action_mode_toggle "$chat" ;;
                notif) bot_action_toggle_daily "$chat" "$mid" ;;
                *)     answer_after="?" ;;
            esac ;;
        x)
            case "$action" in
                cancel) bot_sess_clear "$chat"; bot_menu_main "$chat" "$mid" ;;
                *)      answer_after="?" ;;
            esac ;;
        noop) : ;;
        *)    answer_after="?" ;;
    esac

    [[ -n "$cb" ]] && tg_answer_cb "$cb" "$answer_after" 0 >/dev/null 2>&1 || true
    return 0
}

# --- menus -----------------------------------------------------------------------------------

bot_menu_main() {
    local chat="$1" mid="$2"
    local kb; kb="$(tg_kb \
        '📊 وضعیت سرور|st:full' \
        '🖥 پنل سنایی|m:panel;👥 کلاینت‌ها|m:cli' \
        '🔒 امنیت|m:sec;💾 پشتیبان|m:bkp' \
        '⚙️ تنظیمات پنل|m:set;📖 راهنما|m:help')"
    local text
    text="🛡 <b>vpn-sanai</b> — مدیریت سرور

از منوی زیر انتخاب کنید:
🖥 <b>پنل سنایی</b> — لینک ورود، مشخصات، ری‌استارت
👥 <b>کلاینت‌ها</b> — ساخت/حذف/لینک و QR
🔒 <b>امنیت</b> — فایروال، fail2ban، SSH
💾 <b>پشتیبان</b> — تهیه، ارسال و بازگردانی
⚙️ <b>تنظیمات</b> — پورت و مسیر پنل، رمز، اعلان‌ها"
    bot_edit "$chat" "$mid" "$text" "$kb" >/dev/null
}

bot_menu_panel() {
    local chat="$1" mid="$2"
    local kb; kb="$(tg_kb \
        '🔗 اطلاعات ورود به پنل|pn:info' \
        '📋 تنظیمات فعلی پنل|m:set' \
        '🔁 ری‌استارت پنل|pn:rst;♻️ ری‌استارت Xray|pn:rxr' \
        '🔑 تغییر رمز عبور|pn:pass' \
        "$BOT_HOME_KB_ROW")"
    bot_edit "$chat" "$mid" "🖥 <b>مدیریت پنل سنایی</b>

چه کاری انجام دهیم؟" "$kb" >/dev/null
}

bot_menu_clients() {
    local chat="$1" mid="$2"
    local kb; kb="$(tg_kb \
        '📋 فهرست کلاینت‌ها|cl:list' \
        '➕ کلاینت جدید|cl:add' \
        '🟢 کاربران آنلاین|cl:onl' \
        '♻️ ریست ترافیک همه|cl:rstAll;🧹 حذف تمام‌شده‌ها|cl:delDep' \
        "$BOT_HOME_KB_ROW")"
    bot_edit "$chat" "$mid" "👥 <b>مدیریت کلاینت‌ها</b>" "$kb" >/dev/null
}

bot_menu_security() {
    local chat="$1" mid="$2"
    local kb; kb="$(tg_kb \
        '📋 وضعیت امنیت|sec:st' \
        '🔓 باز کردن پورت|sec:open;🔒 بستن پورت|sec:close' \
        '⛔ آزادسازی IP (fail2ban)|sec:unban' \
        '🌐 تغییر پورت SSH|sec:sshp' \
        "$BOT_HOME_KB_ROW")"
    bot_edit "$chat" "$mid" "🔒 <b>امنیت سرور</b>" "$kb" >/dev/null
}

bot_menu_backup() {
    local chat="$1" mid="$2"
    local kb; kb="$(tg_kb \
        '📋 فهرست پشتیبان‌ها|bkp:list' \
        '💾 پشتیبان‌گیری فوری|bkp:new' \
        '📤 ارسال آخرین پشتیبان|bkp:send' \
        '🧹 پاک‌سازی قدیمی‌ها|bkp:prune' \
        "$BOT_HOME_KB_ROW")"
    bot_edit "$chat" "$mid" "💾 <b>پشتیبان‌گیری</b>" "$kb" >/dev/null
}

bot_menu_settings() {
    local chat="$1" mid="$2"
    local daily_state="خاموش"
    is_true "$TG_DAILY_REPORT" && daily_state="روشن (ساعت ${TG_DAILY_REPORT_HOUR})"
    local kb; kb="$(tg_kb \
        '📋 نمایش تنظیمات فعلی|set:show' \
        '🔧 پورت پنل|set:port;🛣 مسیر مخفی پنل|set:path' \
        '👤 نام کاربری|set:user;🔑 رمز عبور|set:pass' \
        "🔔 گزارش روزانه: ${daily_state}|set:notif" \
        "$BOT_HOME_KB_ROW")"
    bot_edit "$chat" "$mid" "⚙️ <b>تنظیمات پنل سنایی</b>" "$kb" >/dev/null
}

# --- generic confirmation ----------------------------------------------------------------------

# bot_confirm <chat> <mid> <html> <yes-callback>
bot_confirm() {
    local chat="$1" mid="$2" text="$3" yes="$4"
    local kb; kb="$(tg_kb '✅ بله، انجام بده|'"${yes}"';❌ انصراف|x:cancel')"
    bot_edit "$chat" "$mid" "$text" "$kb" >/dev/null
}

# bot_confirm_sel <chat> <mid> <index> <yes-callback-prefix> <title>
#   Confirmation for an action on a selected item; shows the item name.
bot_confirm_sel() {
    local chat="$1" mid="$2" idx="$3" yes="$4" title="$5"
    local target; target="$(bot_sel_get "$chat" "$idx")"
    if [[ -z "$target" ]]; then
        bot_reply "$chat" "⌛ فهرست منقضی شده است؛ دوباره از منو انتخاب کنید." >/dev/null
        return 0
    fi
    bot_confirm "$chat" "$mid" "${title}: <b>$(tg_escape_html "$target")</b>

⚠️ این عمل قابل بازگشت نیست. ادامه می‌دهید؟" "${yes}:${idx}"
}

# --- wizards (conversation flows) -----------------------------------------------------------------

bot_wizard_start() {
    local chat="$1" mode="$2" prompt="$3"
    bot_sess_set "$chat" mode "$mode"
    local kb; kb="$(tg_kb '❌ انصراف|x:cancel')"
    bot_reply "$chat" "$prompt" "$kb" >/dev/null
}

bot_wizard_start_add() {
    local chat="$1"
    bot_sess_set "$chat" mode "add_email"
    bot_sess_set "$chat" w_email ""
    bot_sess_set "$chat" w_days "${DEFAULT_CLIENT_EXPIRY_DAYS:-0}"
    bot_sess_set "$chat" w_gb "${DEFAULT_CLIENT_TOTAL_GB:-0}"
    bot_sess_set "$chat" w_ip "${DEFAULT_CLIENT_LIMIT_IP:-0}"
    local kb; kb="$(tg_kb '❌ انصراف|x:cancel')"
    bot_reply "$chat" "➕ <b>ساخت کلاینت جدید</b> (۱ از ۴)

نام کلاینت را بفرستید (حروف انگلیسی/عدد/نقطه/خط تیره):" "$kb" >/dev/null
}

bot_wizard_start_edit() {
    local chat="$1" idx="$2" what="$3"
    local target; target="$(bot_sel_get "$chat" "$idx")"
    if [[ -z "$target" ]]; then
        bot_reply "$chat" "⌛ فهرست منقضی شده است؛ دوباره از منو انتخاب کنید." >/dev/null
        return 0
    fi
    bot_sess_set "$chat" mode "edit_${what}"
    bot_sess_set "$chat" w_target "$target"
    local prompt
    if [[ "$what" == "quota" ]]; then
        prompt="📦 <b>تغییر سهمیهٔ حجم</b> — کلاینت: <b>$(tg_escape_html "$target")</b>

حجم جدید به گیگابایت را بفرستید (۰ = نامحدود):"
    else
        prompt="📅 <b>تغییر اعتبار</b> — کلاینت: <b>$(tg_escape_html "$target")</b>

تعداد روز اعتبار را بفرستید (۰ = نامحدود):"
    fi
    local kb; kb="$(tg_kb '❌ انصراف|x:cancel')"
    bot_reply "$chat" "$prompt" "$kb" >/dev/null
}

# bot_wizard_step <chat> <uid> <text> <mode>
bot_wizard_step() {
    local chat="$1" uid="$2" raw="$3" mode="$4"
    local text; text="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    local num; num="$(fa_digits_to_en "$text")"

    case "$mode" in
        add_email)
            if ! [[ "$text" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
                bot_reply "$chat" "❌ نام کلاینت فقط می‌تواند شامل حروف انگلیسی، عدد، نقطه، زیرخط و خط تیره باشد. دوباره بفرستید:" >/dev/null
                return 0
            fi
            if bot_client_exists "$text"; then
                bot_reply "$chat" "⚠️ کلاینت «$(tg_escape_html "$text")» از قبل وجود دارد. نام دیگری بفرستید:" >/dev/null
                return 0
            fi
            bot_sess_set "$chat" w_email "$text"
            bot_sess_set "$chat" mode "add_days"
            bot_reply "$chat" "📅 <b>ساخت کلاینت جدید</b> (۲ از ۴) — نام: <code>$(tg_escape_html "$text")</code>

تعداد روز اعتبار را بفرستید (۰ = نامحدود):" >/dev/null
            ;;
        add_days|add_gb|add_ip)
            if ! is_uint "$num"; then
                bot_reply "$chat" "❌ فقط عدد بفرستید (۰ = نامحدود):" >/dev/null
                return 0
            fi
            case "$mode" in
                add_days)
                    bot_sess_set "$chat" w_days "$num"; bot_sess_set "$chat" mode "add_gb"
                    bot_reply "$chat" "📦 <b>ساخت کلاینت جدید</b> (۳ از ۴)

حجم مجاز به گیگابایت را بفرستید (۰ = نامحدود):" >/dev/null ;;
                add_gb)
                    bot_sess_set "$chat" w_gb "$num"; bot_sess_set "$chat" mode "add_ip"
                    bot_reply "$chat" "🔢 <b>ساخت کلاینت جدید</b> (۴ از ۴)

محدودیت IP همزمان را بفرستید (۰ = نامحدود):" >/dev/null ;;
                add_ip)
                    bot_sess_set "$chat" w_ip "$num"
                    bot_sess_clear_mode "$chat"
                    bot_wizard_add_summary "$chat"
                    ;;
            esac ;;
        edit_quota|edit_days)
            if ! is_uint "$num"; then
                bot_reply "$chat" "❌ فقط عدد بفرستید (۰ = نامحدود):" >/dev/null
                return 0
            fi
            local target; target="$(bot_sess_get "$chat" w_target "")"
            bot_sess_clear_mode "$chat"
            bot_action_client_edit_limit "$chat" "$target" "$mode" "$num"
            ;;
        ufw_open|ufw_close)
            local port proto="tcp"
            if [[ "$num" == */udp ]]; then proto="udp"; num="${num%/udp}"; fi
            num="${num%/tcp}"
            if ! is_port "$num"; then
                bot_reply "$chat" "❌ پورت نامعتبر است. مثال درست: <code>8443</code> یا <code>53/udp</code>" >/dev/null
                return 0
            fi
            bot_sess_clear_mode "$chat"
            bot_action_ufw_port "$chat" "$mode" "$num" "$proto"
            ;;
        unban)
            if ! is_ipv4 "$text"; then
                bot_reply "$chat" "❌ آدرس IP معتبر نیست. مثال: <code>1.2.3.4</code>" >/dev/null
                return 0
            fi
            bot_sess_clear_mode "$chat"
            bot_action_unban "$chat" "$text"
            ;;
        ssh_port)
            if ! is_port "$num"; then
                bot_reply "$chat" "❌ پورت نامعتبر است (۱ تا ۶۵۵۳۵):" >/dev/null
                return 0
            fi
            bot_sess_set "$chat" w_ssh_port "$num"
            bot_sess_clear_mode "$chat"
            bot_confirm "$chat" "" "🌐 <b>تغییر پورت SSH به ${num}</b>

⚠️ پورت‌های قبلی موقتاً باز می‌مانند تا اتصال مطمئن شوید، سپس با دستور نهایی‌سازی بسته می‌شوند.
پورت جدید: <code>${num}</code> — ادامه می‌دهید؟" "sec:sshpY"
            ;;
        set_port)
            if ! is_port "$num"; then
                bot_reply "$chat" "❌ پورت نامعتبر است (۱ تا ۶۵۵۳۵):" >/dev/null
                return 0
            fi
            bot_sess_clear_mode "$chat"
            bot_action_set_port "$chat" "$num"
            ;;
        set_path)
            local raw="$text"
            [[ "$raw" == "rand" ]] && raw="$(rand_string 12 'a-z0-9')"
            if ! [[ "$raw" =~ ^[A-Za-z0-9_-]{4,32}$ ]]; then
                bot_reply "$chat" "❌ مسیر فقط می‌تواند ۴ تا ۳۲ نویسه از حروف/عدد/خط تیره/زیرخط باشد (یا <code>rand</code>):" >/dev/null
                return 0
            fi
            bot_sess_clear_mode "$chat"
            bot_action_set_path "$chat" "$raw"
            ;;
        set_user)
            if ! [[ "$text" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; then
                bot_reply "$chat" "❌ نام کاربری باید ۳ تا ۳۲ نویسه از حروف/عدد/نقطه/خط تیره باشد:" >/dev/null
                return 0
            fi
            bot_sess_clear_mode "$chat"
            bot_action_set_user "$chat" "$text"
            ;;
        set_pass)
            local pass="$text"
            [[ "$pass" == "rand" ]] && pass="$(rand_password 24)"
            if (( ${#pass} < 8 )); then
                bot_reply "$chat" "❌ رمز عبور باید حداقل ۸ نویسه باشد (یا <code>rand</code>):" >/dev/null
                return 0
            fi
            bot_sess_clear_mode "$chat"
            bot_action_set_pass "$chat" "$pass"
            ;;
        *)
            bot_sess_clear_mode "$chat"
            bot_reply "$chat" "⌛ عملیات قبلی منقضی شد. دوباره تلاش کنید." >/dev/null
            ;;
    esac
    return 0
}

# leave every other key (selections, wizard data) in place
bot_sess_clear_mode() {
    local chat="$1"
    local f; f="$(bot_sess_file "$chat")"
    [[ -f "$f" ]] || return 0
    grep -v '^mode=' "$f" > "${f}.tmp" 2>/dev/null && mv -f "${f}.tmp" "$f" || true
}

bot_wizard_add_summary() {
    local chat="$1"
    local email days gb ips
    email="$(bot_sess_get "$chat" w_email "")"
    days="$(bot_sess_get "$chat" w_days 0)"
    gb="$(bot_sess_get "$chat" w_gb 0)"
    ips="$(bot_sess_get "$chat" w_ip 0)"
    local kb; kb="$(tg_kb '✅ بساز|cl:addY;❌ انصراف|x:cancel')"
    bot_reply "$chat" "🧾 <b>خلاصهٔ کلاینت جدید</b>

👤 نام: <code>$(tg_escape_html "$email")</code>
📅 اعتبار: $( [[ "$days" == "0" ]] && echo 'نامحدود' || echo "${days} روز" )
📦 حجم: $( [[ "$gb" == "0" ]] && echo 'نامحدود' || echo "${gb} گیگابایت" )
🔢 محدودیت IP: $( [[ "$ips" == "0" ]] && echo 'نامحدود' || echo "${ips}" )" "$kb" >/dev/null
}

# --- panel actions -------------------------------------------------------------------------------

bot_panel_url_public() {
    printf '%s://%s:%s%s' "${PANEL_SCHEME:-https}" "$(bot_server_ip)" "${PANEL_PORT:-?}" "${PANEL_BASE_PATH:-/}"
}

# bot_panel_info_html -> the credentials block (caller must be admin + private chat)
bot_panel_info_html() {
    local mode_label url_line ssh_port
    if [[ "${PANEL_ACCESS_MODE:-tunnel}" == "public" ]]; then
        mode_label="عمومی (روی همهٔ اینترفیس‌ها)"
        url_line="🔗 آدرس پنل:
<code>$(bot_panel_url_public)</code>"
    else
        mode_label="تونل (فقط 127.0.0.1)"
        ssh_port="$(state_get SSH_PORT 22)"
        url_line="🔗 آدرس از سیستم شما (تونل SSH):
<code>ssh -N -L 8443:127.0.0.1:${PANEL_PORT:-?} root@${SERVER_IP:-SERVER_IP} -p ${ssh_port}</code>

سپس در مرورگر:
<code>https://127.0.0.1:8443${PANEL_BASE_PATH:-/}</code>"
    fi
    cat <<EOF
🖥 <b>پنل سنایی (3x-ui)</b>

حالت دسترسی: ${mode_label}

${url_line}

👤 نام کاربری: <code>$(tg_escape_html "${PANEL_USER:-?}")</code>
🔑 رمز عبور: <code>$(tg_escape_html "${PANEL_PASS:-?}")</code>

ℹ️ گواهی پنل self-signed است؛ هشدار مرورگر را بپذیرید.
EOF
}

bot_action_panel_info() {
    local chat="$1" mid="$2"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    bot_send_secret "$chat" "$(bot_panel_info_html)" >/dev/null
}

bot_action_panel_restart() {
    local chat="$1"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    tg_chat_action "$chat" typing >/dev/null 2>&1 || true
    if ! panel_restart_api 2>/dev/null; then
        # Restart kills the connection mid-answer — treat network errors as ok.
        log_debug "restartPanel پاسخ قطع‌شده داد (طبیعی است)"
    fi
    if panel_wait_port "${PANEL_PORT}" 45; then
        bot_reply "$chat" "✅ پنل با موفقیت راه‌اندازی مجدد شد.

🔗 $(bot_panel_url_public)" >/dev/null
    else
        bot_reply "$chat" "⚠️ پنل پس از ۴۵ ثانیه پاسخ نداد. وضعیت: $(panel_service_status 2>/dev/null || echo '?')
لاگ: <code>journalctl -u x-ui -n 50</code>" >/dev/null
    fi
}

bot_action_xray_restart() {
    local chat="$1"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    if xray_restart 2>/dev/null; then
        bot_reply "$chat" "✅ هستهٔ Xray راه‌اندازی مجدد شد." >/dev/null
    else
        bot_reply "$chat" "❌ راه‌اندازی مجدد Xray ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null
    fi
}

bot_action_panel_newpass() {
    local chat="$1"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    local new; new="$(rand_password 24)"
    if ! panel_update_user "$PANEL_USER" "$PANEL_PASS" "$PANEL_USER" "$new" 2>/dev/null; then
        bot_reply "$chat" "❌ تغییر رمز ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null
        return 0
    fi
    state_set PANEL_PASS "$new"
    PANEL_PASS="$new"
    bot_send_secret "$chat" "✅ رمز عبور پنل تغییر کرد.

👤 نام کاربری: <code>$(tg_escape_html "$PANEL_USER")</code>
🔑 رمز عبور جدید: <code>$(tg_escape_html "$new")</code>" >/dev/null
}

# --- panel settings actions -----------------------------------------------------------------------

bot_render_settings() {
    local chat="$1" mid="$2"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    local s
    s="$(panel_settings_all 2>/dev/null)" || {
        bot_edit "$chat" "$mid" "❌ خواندن تنظیمات پنل ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" "$(tg_kb "$BOT_HOME_KB_ROW")" >/dev/null
        return 0
    }
    local webport webpath weblisten suben subport subpath sessionmax
    webport="$(printf '%s' "$s" | jq -r '.webPort // "?"')"
    webpath="$(printf '%s' "$s" | jq -r '.webPath // "?"')"
    weblisten="$(printf '%s' "$s" | jq -r '.webListen // ""')"; [[ -z "$weblisten" ]] && weblisten="همهٔ اینترفیس‌ها"
    suben="$(printf '%s' "$s" | jq -r '.subEnable // false')"
    subport="$(printf '%s' "$s" | jq -r '.subPort // "?"')"
    subpath="$(printf '%s' "$s" | jq -r '.subPath // "?"')"
    sessionmax="$(printf '%s' "$s" | jq -r '.sessionMaxAge // "?"')"

    local text
    text="⚙️ <b>تنظیمات فعلی پنل سنایی</b>

🖥 <b>وب پنل</b>
• پورت: <code>${webport}</code>
• مسیر مخفی: <code>${webpath}</code>
• گوش‌دادن: <code>$(tg_escape_html "$weblisten")</code>
• عمر نشست: <code>${sessionmax} دقیقه</code>

📎 <b>اشتراک (Subscription)</b>
• وضعیت: $(fmt_onoff "$suben")
• پورت: <code>${subport}</code> — مسیر: <code>${subpath}</code>

📡 <b>کانفیگ VLESS</b>
• پورت: <code>${VLESS_PORT:-?}</code> — SNI: <code>${VLESS_SNI:-?}</code>
• ShortId: <code>${VLESS_SHORT_ID:-?}</code>

🔐 <b>امنیت</b>
• پورت SSH: <code>$(ssh_ports_active 2>/dev/null | paste -sd, -)</code>
• توکن API: $( [[ -n "$PANEL_API_TOKEN" ]] && echo '✅ موجود' || echo '❌ ندارد' )"

    local kb; kb="$(tg_kb \
        '🔧 تغییر پورت|set:port;🛣 تغییر مسیر|set:path' \
        '👤 نام کاربری|set:user;🔑 رمز عبور|set:pass' \
        '🌐 تغییر حالت دسترسی|set:mode' \
        "$BOT_HOME_KB_ROW")"
    bot_edit "$chat" "$mid" "$text" "$kb" >/dev/null
}

bot_action_set_port() {
    local chat="$1" port="$2"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    if [[ "$port" == "${PANEL_PORT}" ]]; then
        bot_reply "$chat" "ℹ️ پنل از قبل روی پورت ${port} است." >/dev/null; return 0
    fi
    if port_in_use "$port"; then
        bot_reply "$chat" "❌ پورت ${port} در حال حاضر اشغال است؛ پورت دیگری انتخاب کنید." >/dev/null; return 0
    fi
    local old_port="$PANEL_PORT"
    # shellcheck disable=SC2016  # the jq filter is passed verbatim on purpose
    if ! panel_settings_patch '.webPort = $p' --argjson p "$port" >/dev/null 2>&1; then
        bot_reply "$chat" "❌ ثبت پورت جدید ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null; return 0
    fi
    panel_restart_api 2>/dev/null || true
    if ! panel_wait_port "$port" 45; then
        bot_reply "$chat" "⚠️ پنل روی پورت جدید پاسخ نداد؛ به پورت قبلی برمی‌گردم…" >/dev/null
        # shellcheck disable=SC2016
        panel_settings_patch '.webPort = $p' --argjson p "$old_port" >/dev/null 2>&1 || true
        panel_restart_api 2>/dev/null || true
        panel_wait_port "$old_port" 30 || true
        return 0
    fi
    state_set PANEL_PORT "$port"
    PANEL_PORT="$port"
    if [[ "${PANEL_ACCESS_MODE:-tunnel}" == "public" ]] && ufw_is_active; then
        ufw_allow_port "$port" tcp "panel" 2>/dev/null || true
        ufw_delete_port "$old_port" tcp 2>/dev/null || true
    fi
    bot_reply "$chat" "✅ پورت پنل به <code>${port}</code> تغییر کرد.

🔗 $(bot_panel_url_public)" >/dev/null
}

bot_action_set_path() {
    local chat="$1" raw="$2"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    # shellcheck disable=SC2016  # the jq filter is passed verbatim on purpose
    if ! panel_settings_patch '.webPath = $p' --arg p "/${raw}/" >/dev/null 2>&1; then
        bot_reply "$chat" "❌ ثبت مسیر جدید ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null; return 0
    fi
    panel_restart_api 2>/dev/null || true
    if panel_probe_base_path "${PANEL_PORT}" "$raw"; then
        state_set PANEL_BASE_PATH "$PANEL_BASE_PATH"
        bot_reply "$chat" "✅ مسیر مخفی پنل تغییر کرد.

🔗 $(bot_panel_url_public)" >/dev/null
    else
        bot_reply "$chat" "⚠️ مسیر جدید ثبت شد اما تأیید نشد. پنل را بررسی کنید:
<code>x-ui setting -show true</code>" >/dev/null
    fi
}

bot_action_set_user() {
    local chat="$1" user="$2"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    if ! panel_update_user "$PANEL_USER" "$PANEL_PASS" "$user" "$PANEL_PASS" 2>/dev/null; then
        bot_reply "$chat" "❌ تغییر نام کاربری ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null; return 0
    fi
    state_set PANEL_USER "$user"
    PANEL_USER="$user"
    bot_reply "$chat" "✅ نام کاربری پنل به <code>$(tg_escape_html "$user")</code> تغییر کرد." >/dev/null
}

bot_action_set_pass() {
    local chat="$1" pass="$2"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    if ! panel_update_user "$PANEL_USER" "$PANEL_PASS" "$PANEL_USER" "$pass" 2>/dev/null; then
        bot_reply "$chat" "❌ تغییر رمز ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null; return 0
    fi
    state_set PANEL_PASS "$pass"
    PANEL_PASS="$pass"
    bot_send_secret "$chat" "✅ رمز عبور پنل تغییر کرد.

👤 نام کاربری: <code>$(tg_escape_html "$PANEL_USER")</code>
🔑 رمز عبور جدید: <code>$(tg_escape_html "$pass")</code>" >/dev/null
}

bot_mode_toggle_text() {
    if [[ "${PANEL_ACCESS_MODE:-tunnel}" == "tunnel" ]]; then
        printf '🌐 <b>عمومی کردن پنل</b>

پنل از 127.0.0.1 روی همهٔ اینترفیس‌ها گوش می‌دهد و پورت آن در فایروال باز می‌شود:
<code>%s</code>

⚠️ توصیهٔ امنیتی: حالت تونل امن‌تر است. ادامه می‌دهید؟' "$(bot_panel_url_public)"
    else
        printf '🔒 <b>تونل کردن پنل</b>

پنل فقط روی 127.0.0.1 گوش می‌دهد، پورت آن از فایروال بسته می‌شود و دسترسی تنها از طریق تونل SSH ممکن است.

⚠️ مطمئن شوید پیش از این تغییر، راه تونل را می‌دانید. ادامه می‌دهید؟'
    fi
}

bot_action_mode_toggle() {
    local chat="$1"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    local listen new_mode
    if [[ "${PANEL_ACCESS_MODE:-tunnel}" == "tunnel" ]]; then
        listen=""; new_mode="public"
    else
        listen="127.0.0.1"; new_mode="tunnel"
    fi
    # shellcheck disable=SC2016  # the jq filter is passed verbatim on purpose
    if ! panel_settings_patch '.webListen = $l' --arg l "$listen" >/dev/null 2>&1; then
        bot_reply "$chat" "❌ تغییر حالت دسترسی ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null; return 0
    fi
    panel_restart_api 2>/dev/null || true
    panel_wait_port "${PANEL_PORT}" 45 || true
    state_set PANEL_ACCESS_MODE "$new_mode"
    PANEL_ACCESS_MODE="$new_mode"
    if [[ "$new_mode" == "public" ]]; then
        ufw_is_active && ufw_allow_port "${PANEL_PORT}" tcp "panel" 2>/dev/null || true
        bot_reply "$chat" "✅ پنل عمومی شد.

🔗 $(bot_panel_url_public)" >/dev/null
    else
        ufw_is_active && ufw_delete_port "${PANEL_PORT}" tcp 2>/dev/null || true
        bot_reply "$chat" "✅ پنل به حالت تونل رفت (فقط 127.0.0.1).

🔗 تونل: <code>ssh -N -L 8443:127.0.0.1:${PANEL_PORT} root@$(bot_server_ip)</code>" >/dev/null
    fi
}

bot_action_toggle_daily() {
    local chat="$1" mid="$2"
    if is_true "$TG_DAILY_REPORT"; then
        TG_DAILY_REPORT="no"
    else
        TG_DAILY_REPORT="yes"
    fi
    bot_config_set TG_DAILY_REPORT "$TG_DAILY_REPORT"
    bot_menu_settings "$chat" "$mid"
}

# bot_config_set <key> <value> -> rewrite one key of the runtime config
bot_config_set() {
    local key="$1" value="$2"
    [[ -w "$VPN_SANAI_TG_CONFIG" ]] || return 1
    local tmp
    tmp="$(mktemp)"
    {
        grep -v "^${key}=" "$VPN_SANAI_TG_CONFIG" 2>/dev/null || true
        printf '%s=%q\n' "$key" "$value"
    } > "$tmp"
    cat "$tmp" > "$VPN_SANAI_TG_CONFIG" && rm -f "$tmp"
    return 0
}

# --- status ---------------------------------------------------------------------------------------

bot_build_status_html() {
    # Requires bot_panel_ready to have run; falls back to /proc when the panel
    # does not expose a field.
    local text="" s inbounds
    s="$(api_get_obj "/panel/api/server/status" 2>/dev/null || echo '{}')"
    inbounds="$(api_get_obj "/panel/api/inbounds/list" 2>/dev/null || echo '[]')"

    local xstate xver cpu upt loads memc memt diskc diskt users
    xstate="$(printf '%s' "$s" | jq -r '.xray.state // "?"')"
    xver="$(printf '%s' "$s" | jq -r '.xray.version // "?"')"
    cpu="$(printf '%s' "$s" | jq -r '.cpu // empty')"
    [[ -z "$cpu" ]] && cpu="$(awk '{u=$2+$4; t=$2+$4+$5; if (t==0) print 0; else printf "%.0f", u/t*100}' /proc/stat 2>/dev/null || echo '?')"
    upt="$(printf '%s' "$s" | jq -r '.uptime // empty')"
    [[ -z "$upt" ]] && upt="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"
    loads="$(printf '%s' "$s" | jq -rc '.loads // empty')"
    [[ -z "$loads" ]] && loads="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?')"
    loads="${loads//[\[\]\"]/}"
    memc="$(printf '%s' "$s" | jq -r '.mem.current // empty')"
    memt="$(printf '%s' "$s" | jq -r '.mem.total // empty')"
    if [[ -z "$memc" || -z "$memt" ]]; then
        read -r memc memt < <(awk '/MemTotal|MemAvailable/{ if ($1=="MemTotal:") t=$2; else a=$2 } END{print t-a, t}' /proc/meminfo 2>/dev/null || echo "0 0")
    fi
    diskc="$(printf '%s' "$s" | jq -r '.disk.current // empty')"
    diskt="$(printf '%s' "$s" | jq -r '.disk.total // empty')"
    if [[ -z "$diskc" || -z "$diskt" ]]; then
        read -r diskc diskt < <(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $3*1024, $2*1024}' || echo "0 0")
    fi
    users="$(printf '%s' "$s" | jq -r '.appStats.users // empty')"
    if [[ -z "$users" ]]; then
        users="$(bot_client_emails | wc -l | tr -d '[:space:]')"
        is_uint "$users" || users=0
    fi

    text="📊 <b>وضعیت سرور</b>

🖥 پنل: $(panel_service_status 2>/dev/null || echo '?') — Xray: <b>${xstate}</b> (${xver})
⏱ Uptime: $(fmt_duration "$upt") — Load: ${loads}
🧠 CPU: ${cpu}% — RAM: $(fmt_bytes "$memc") / $(fmt_bytes "$memt")
💾 Disk: $(fmt_bytes "$diskc") / $(fmt_bytes "$diskt")
👥 کلاینت‌ها: ${users}"

    local rows count
    rows="$(printf '%s' "$inbounds" | jq -r '
        .[]? | [.remark // .tag // (.id|tostring), (.port|tostring), .protocol,
              (((.up // 0) + (.down // 0))), ((.settings|fromjson?).clients // [] | length)]
            | @tsv' 2>/dev/null || true)"
    if [[ -n "$rows" ]]; then
        text+=$'\n'"📡 <b>Inboundها</b>"
        while IFS=$'\t' read -r remark port proto traffic nclients; do
            [[ -n "$remark" ]] || continue
            text+=$'\n'"• $(tg_escape_html "$remark") (:${port}) — ${nclients} کلاینت — $(fmt_bytes "$traffic")"
        done <<< "$rows"
    fi

    local online
    online="$(client_onlines 2>/dev/null | grep -vc '^$' || true)"
    is_uint "$online" || online=0
    ((online > 0)) && text+=$'\n'"🟢 آنلاین: ${online}"

    local last_backup
    last_backup="$(backup_list 2>/dev/null | head -1 | awk '{print $1, $2}')"
    text+=$'\n'"💾 آخرین پشتیبان: ${last_backup:-ندارد}"
    text+=$'\n'"🔒 UFW: $(ufw_is_active 2>/dev/null && echo 'فعال' || echo 'غیرفعال') — BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    printf '%s' "$text"
}

bot_send_status() {
    local chat="$1"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    tg_chat_action "$chat" typing >/dev/null 2>&1 || true
    bot_reply "$chat" "$(bot_build_status_html)" "$(tg_kb '🔄 refresh|st:refresh' "$BOT_HOME_KB_ROW")" >/dev/null
}

bot_render_status_edit() {
    local chat="$1" mid="$2"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    bot_edit "$chat" "$mid" "$(bot_build_status_html)" "$(tg_kb '🔄 refresh|st:refresh' "$BOT_HOME_KB_ROW")" >/dev/null
}

# --- clients ----------------------------------------------------------------------------------------

# bot_client_emails -> one email per line (from clients/list, inbounds fallback)
bot_client_emails() {
    {
        client_list 2>/dev/null | jq -r '
            if type=="array" and ((.[0]? // {}) | has("settings")) then
                .[] | (.settings|fromjson?) | .clients[]? | .email
            else
                .[]? | (.email // .client.email // empty)
            end' 2>/dev/null || true
        api_get_obj "/panel/api/inbounds/list" 2>/dev/null | jq -r '
            .[]? | (.settings|fromjson?) | .clients[]? | .email' 2>/dev/null || true
    } | grep -v '^$' | sort -u
}

bot_client_exists() {
    local email="$1" all
    all="$(bot_client_emails)"
    grep -qxF "$email" <<< "$all"
}

# bot_client_row <email> -> normalized one-line TSV: email uuid enable total up down expiry subId limitIp lastOnline
bot_client_row() {
    local email="$1" info
    info="$(client_info "$email" 2>/dev/null)" || return 1
    [[ -n "$info" ]] || return 1
    printf '%s' "$info" | jq -r '
        . as $o | ($o.client // $o) as $c |
        [$c.email // $o.email // "",
         ($c.id // $c.uuid // $o.uuid // ""),
         ($c.enable // $o.enable // true),
         (($o.total // $c.total // $c.totalGB // 0) | tonumber? // 0),
         (($o.up // $c.up // 0) | tonumber? // 0),
         (($o.down // $c.down // 0) | tonumber? // 0),
         (($o.expiryTime // $c.expiryTime // 0) | tonumber? // 0),
         ($o.subId // $c.subId // ""),
         (($c.limitIp // $o.limitIp // 0) | tonumber? // 0),
         (($o.lastOnline // $c.lastOnline // 0) | tonumber? // 0)]
        | @tsv'
}

bot_action_clients_list() {
    local chat="$1" mid="$2" page="${3:-1}"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    local -a emails=()
    local e
    while IFS= read -r e; do [[ -n "$e" ]] && emails+=("$e"); done < <(bot_client_emails)

    if ((${#emails[@]} == 0)); then
        bot_edit "$chat" "$mid" "👥 کلاینتی وجود ندارد.

با «➕ کلاینت جدید» اولین را بسازید." "$(tg_kb '➕ کلاینت جدید|cl:add' "$BOT_HOME_KB_ROW")" >/dev/null
        return 0
    fi

    local per_page=10
    local total_pages=$(( (${#emails[@]} + per_page - 1) / per_page ))
    is_uint "$page" || page=1
    ((page >= 1 && page <= total_pages)) || page=1
    local first=$(( (page - 1) * per_page ))
    local last=$(( first + per_page - 1 ))
    ((last < ${#emails[@]} - 1)) || last=$(( ${#emails[@]} - 1 ))

    # Selection map: index is global (page-aware) so pagination stays stable.
    local -a shown=()
    local i
    for ((i = first; i <= last; i++)); do shown+=("${emails[$i]}"); done
    bot_sel_save "$chat" "client" "${emails[@]}"

    local text="👥 <b>کلاینت‌ها</b> (${#emails[@]} مورد — صفحهٔ ${page}/${total_pages})

برای جزئیات روی یکی بزنید:"
    local kb_rows=() row
    local global_idx=$first
    for e in "${shown[@]}"; do
        ((global_idx++))
        local row_line
        row_line="$(printf '%d. %s|cl:v:%d' "$global_idx" "$(tg_escape_html "$e")" "$global_idx")"
        kb_rows+=("$row_line")
    done
    local nav=""
    ((page > 1)) && nav+="◀️|cl:list:$((page - 1));"
    ((page < total_pages)) && nav+="▶️|cl:list:$((page + 1))"
    kb_rows+=("${nav%;}")
    kb_rows+=("➕ کلاینت جدید|cl:add;🟢 آنلاین‌ها|cl:onl")
    kb_rows+=("$BOT_HOME_KB_ROW")
    local kb; kb="$(tg_kb "${kb_rows[@]}")"
    bot_edit "$chat" "$mid" "$text" "$kb" >/dev/null
}

bot_action_client_view() {
    local chat="$1" mid="$2" idx="$3"
    local email; email="$(bot_sel_get "$chat" "$idx")"
    if [[ -z "$email" ]]; then
        bot_reply "$chat" "⌛ فهرست منقضی شده است؛ از «فهرست کلاینت‌ها» دوباره انتخاب کنید." >/dev/null
        return 0
    fi
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    local row
    row="$(bot_client_row "$email")" || {
        bot_edit "$chat" "$mid" "❌ اطلاعات «$(tg_escape_html "$email")» خوانده نشد." "$(tg_kb "$BOT_HOME_KB_ROW")" >/dev/null
        return 0
    }
    local -a f=()
    IFS=$'\t' read -r -a f <<< "$row"
    local enable="${f[2]}" total="${f[3]}" up="${f[4]}" down="${f[5]}" expiry="${f[6]}" limitip="${f[8]}" laston="${f[9]}"
    laston=$((laston / 1000))

    local used=$((up + down))
    local quota="نامحدود"; ((total > 0)) && quota="$(fmt_bytes "$total")"
    local status="✅ فعال"; is_true "$enable" || status="⛔️ غیرفعال"
    ((total > 0 && used >= total)) && status="پر شده ⚠️"

    local text
    text="👤 <b>$(tg_escape_html "$email")</b>

وضعیت: ${status}
📦 مصرف: ↓ $(fmt_bytes "$down") + ↑ $(fmt_bytes "$up") = $(fmt_bytes "$used") از ${quota}
📅 اعتبار: $(fmt_expiry "$expiry")
🔢 محدودیت IP: $( ((limitip > 0)) && echo "${limitip}" || echo 'نامحدود' )
🕐 آخرین اتصال: $(fmt_when "$laston")"

    local toggle_label="⛔️ غیرفعال کردن"; is_true "$enable" || toggle_label="▶️ فعال کردن"
    local kb; kb="$(tg_kb \
        '🔗 لینک و QR|cl:qr:'"${idx}"';📎 لینک اشتراک|cl:sub:'"${idx}" \
        '♻️ ریست ترافیک|cl:rst:'"${idx}" \
        '📦 تغییر حجم|cl:edq:'"${idx}"';📅 تغییر اعتبار|cl:edd:'"${idx}" \
        "${toggle_label}|cl:tgl:${idx}" \
        "🗑 حذف|cl:del:${idx}" \
        "⬅️ فهرست کلاینت‌ها|cl:list;$BOT_HOME_KB_ROW")"
    bot_edit "$chat" "$mid" "$text" "$kb" >/dev/null
}

bot_action_client_qr() {
    local chat="$1" idx="$2"
    local email; email="$(bot_sel_get "$chat" "$idx")"
    [[ -n "$email" ]] || { bot_reply "$chat" "⌛ فهرست منقضی شده است." >/dev/null; return 0; }
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    bot_send_client_link "$chat" "$email"
}

# bot_send_client_link <chat> <email> -> link + QR photo + subscription
bot_send_client_link() {
    local chat="$1" email="$2"
    local info uuid link sub sub_id
    info="$(client_info "$email" 2>/dev/null)" || true
    if [[ -n "$info" ]]; then
        uuid="$(printf '%s' "$info" | jq -r '(.client.id // .id // empty)' 2>/dev/null || true)"
    fi
    link="$(build_client_link_from_state "$email" "${uuid:-}" 2>/dev/null || true)"
    [[ -n "$link" ]] || link="$(client_links_api "$email" 2>/dev/null | head -1 || true)"
    if [[ -z "$link" ]]; then
        bot_reply "$chat" "❌ لینک «$(tg_escape_html "$email")» ساخته نشد." >/dev/null
        return 0
    fi
    sub_id="$(client_sub_id "$email" 2>/dev/null || true)"
    sub=""
    [[ -n "$sub_id" ]] && sub="$(sub_url "$sub_id" 2>/dev/null || true)"

    local text
    text="🔗 <b>کانفیگ $(tg_escape_html "$email")</b>

<code>$(tg_escape_html "$link")</code>"
    [[ -n "$sub" ]] && text+=$'\n\n'"📎 <b>لینک اشتراک</b> (آپدیت خودکار):
<code>$(tg_escape_html "$sub")</code>"

    # QR as a photo when qrencode is available
    local png="${BOT_STATE_DIR}/qr-${email//[^A-Za-z0-9._-]/_}-$$.png"
    mkdir -p "$BOT_STATE_DIR" 2>/dev/null || true
    if show_qr "$link" "$png" >/dev/null 2>&1 && [[ -s "$png" ]]; then
        if ! tg_send_photo "$chat" "$png" "کانفیگ $(tg_escape_html "$email")" >/dev/null 2>&1; then
            bot_reply "$chat" "$text" >/dev/null
        else
            bot_reply "$chat" "$text" >/dev/null
        fi
        rm -f "$png" 2>/dev/null || true
    else
        rm -f "$png" 2>/dev/null || true
        bot_reply "$chat" "$text

💡 برای QR، بستهٔ qrencode را نصب کنید: <code>apt install qrencode</code>" >/dev/null
    fi
    save_client_link "$email" "$link" "$sub" 2>/dev/null || true
}

bot_action_client_sub() {
    local chat="$1" idx="$2"
    local email; email="$(bot_sel_get "$chat" "$idx")"
    [[ -n "$email" ]] || { bot_reply "$chat" "⌛ فهرست منقضی شده است." >/dev/null; return 0; }
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    local sub_id sub
    sub_id="$(client_sub_id "$email" 2>/dev/null || true)"
    sub="$(sub_url "${sub_id:-}" 2>/dev/null || true)"
    if [[ -z "$sub" ]]; then
        bot_reply "$chat" "❌ لینک اشتراک برای «$(tg_escape_html "$email")» پیدا نشد (اشتراک فعال است؟)." >/dev/null
        return 0
    fi
    bot_reply "$chat" "📎 <b>لینک اشتراک $(tg_escape_html "$email")</b>

<code>$(tg_escape_html "$sub")</code>

این لینک را در کلاینت‌های پشتیبان از VLESS (مثل v2rayNG/Streisand) به‌عنوان Subscription وارد کنید." >/dev/null
}

bot_action_client_reset() {
    local chat="$1" idx="$2"
    local email; email="$(bot_sel_get "$chat" "$idx")"
    [[ -n "$email" ]] || { bot_reply "$chat" "⌛ فهرست منقضی شده است." >/dev/null; return 0; }
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    if client_reset_traffic "$email" 2>/dev/null; then
        bot_reply "$chat" "✅ ترافیک «$(tg_escape_html "$email")» صفر شد و کلاینت دوباره قابل اتصال است." >/dev/null
    else
        bot_reply "$chat" "❌ ریست ترافیک ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null
    fi
}

bot_action_client_toggle() {
    local chat="$1" idx="$2"
    local email; email="$(bot_sel_get "$chat" "$idx")"
    [[ -n "$email" ]] || { bot_reply "$chat" "⌛ فهرست منقضی شده است." >/dev/null; return 0; }
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    local row; row="$(bot_client_row "$email")" || { bot_reply "$chat" "❌ اطلاعات کلاینت خوانده نشد." >/dev/null; return 0; }
    local enable; enable="$(printf '%s' "$row" | cut -f3)"
    if is_true "$enable"; then
        if client_set_enabled "$email" false 2>/dev/null; then
            bot_reply "$chat" "⛔️ کلاینت «$(tg_escape_html "$email")» غیرفعال شد." >/dev/null
        else
            bot_reply "$chat" "❌ غیرفعال‌سازی ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null
        fi
    else
        if client_set_enabled "$email" true 2>/dev/null; then
            bot_reply "$chat" "▶️ کلاینت «$(tg_escape_html "$email")» فعال شد." >/dev/null
        else
            bot_reply "$chat" "❌ فعال‌سازی ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null
        fi
    fi
}

bot_action_client_edit_limit() {
    local chat="$1" email="$2" what="$3" value="$4"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    local ok=0
    if [[ "$what" == "edit_quota" ]]; then
        local bytes=$(( value * 1073741824 ))
        client_set_limits "$email" "$bytes" "" "" 2>/dev/null && ok=1
    else
        local expiry_ms=0
        ((value > 0)) && expiry_ms=$(( ( $(date +%s) + value * 86400 ) * 1000 ))
        client_set_limits "$email" "" "$expiry_ms" "" 2>/dev/null && ok=1
    fi
    if ((ok)); then
        bot_reply "$chat" "✅ تغییرات «$(tg_escape_html "$email")» ذخیره شد." >/dev/null
    else
        bot_reply "$chat" "❌ ذخیرهٔ تغییرات ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null
    fi
}

bot_action_client_delete() {
    local chat="$1" idx="$2"
    local email; email="$(bot_sel_get "$chat" "$idx")"
    [[ -n "$email" ]] || { bot_reply "$chat" "⌛ فهرست منقضی شده است." >/dev/null; return 0; }
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    if client_delete "$email" 2>/dev/null; then
        bot_reply "$chat" "🗑 کلاینت «$(tg_escape_html "$email")» حذف شد." >/dev/null
    else
        bot_reply "$chat" "❌ حذف ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null
    fi
}

bot_action_clients_online() {
    local chat="$1" mid="$2"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    local out
    out="$(client_onlines 2>/dev/null | grep -v '^$' || true)"
    local count; count="$(printf '%s' "$out" | grep -c . || true)"
    local text
    if [[ -z "$out" ]]; then
        text="🟢 <b>کاربران آنلاین</b>

هیچ کلاینتی در حال حاضر متصل نیست."
    else
        text="🟢 <b>کاربران آنلاین (${count})</b>

$(printf '%s' "$out" | sed 's/^/• /' | tg_escape_html_stream)"
    fi
    bot_edit "$chat" "$mid" "$text" "$(tg_kb '🔄 refresh|cl:onl' '⬅️ فهرست کلاینت‌ها|cl:list' "$BOT_HOME_KB_ROW")" >/dev/null
}

# tg_escape_html_stream -> escape stdin (for piped lists)
tg_escape_html_stream() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        tg_escape_html "$line"
        printf '\n'
    done
}

bot_action_clients_reset_all() {
    local chat="$1"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    if client_reset_all_traffic 2>/dev/null; then
        bot_reply "$chat" "✅ ترافیک همهٔ کلاینت‌ها صفر شد." >/dev/null
    else
        bot_reply "$chat" "❌ عملیات ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null
    fi
}

bot_action_clients_delete_depleted() {
    local chat="$1"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    if client_delete_depleted 2>/dev/null; then
        bot_reply "$chat" "🧹 کلاینت‌های تمام‌شده حذف شدند." >/dev/null
    else
        bot_reply "$chat" "❌ عملیات ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null
    fi
}

# --- client creation (wizard finish) ---------------------------------------------------------

# bot_sess_del_keys <chat> <key>... -> drop specific keys from a session file
bot_sess_del_keys() {
    local chat="$1"; shift
    local f; f="$(bot_sess_file "$chat")"
    [[ -f "$f" ]] || return 0
    local pat="" k
    for k in "$@"; do pat+="${pat:+|}${k}"; done
    grep -vE "^(${pat})=" "$f" > "${f}.tmp" 2>/dev/null && mv -f "${f}.tmp" "$f" || true
}

# bot_action_client_create_from_session <chat> -> the wizard's "✅ بساز" button
bot_action_client_create_from_session() {
    local chat="$1"
    local email days gb ips
    email="$(bot_sess_get "$chat" w_email "")"
    days="$(bot_sess_get "$chat" w_days 0)"
    gb="$(bot_sess_get "$chat" w_gb 0)"
    ips="$(bot_sess_get "$chat" w_ip 0)"
    if [[ -z "$email" ]]; then
        bot_reply "$chat" "⌛ نشست ساخت کلاینت منقضی شده؛ دوباره از منو شروع کنید." >/dev/null
        return 0
    fi
    bot_action_client_create "$chat" "$email" "$days" "$gb" "$ips"
    # wizard answers are consumed either way
    bot_sess_del_keys "$chat" w_email w_days w_gb w_ip
}

bot_action_client_create() {
    local chat="$1" email="$2" days="$3" gb="$4" ips="$5"
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    local inbound="${VLESS_INBOUND_ID:-$(state_get VLESS_INBOUND_ID)}"
    if [[ -z "$inbound" ]]; then
        bot_reply "$chat" "❌ شناسهٔ Inbound در state ثبت نشده؛ از CLI بررسی کنید." >/dev/null
        return 0
    fi
    # The panel stores the quota in bytes (the UI converts GB -> bytes too).
    local total_bytes=$(( ${gb:-0} * 1073741824 ))
    local flow="${VLESS_FLOW:-xtls-rprx-vision}"
    if ! client_add "$email" "$inbound" "$total_bytes" "$days" "$ips" "$flow" 2>/dev/null; then
        bot_reply "$chat" "❌ ساخت کلاینت ناموفق بود: $(tg_escape_html "${API_ERROR:-}")" >/dev/null
        return 0
    fi
    bot_send_client_link "$chat" "$email"
}

# --- quick commands -----------------------------------------------------------------------------

bot_cmd_add() {
    local chat="$1" rest="$2"
    # /add name [days] [gb] [ip-limit]
    local -a a=()
    read -r -a a <<< "$(printf '%s' "$rest" | tr -s ' ')"
    local email="${a[0]:-}" days="${a[1]:-0}" gb="${a[2]:-0}" ips="${a[3]:-0}"
    days="$(fa_digits_to_en "$days")"; gb="$(fa_digits_to_en "$gb")"; ips="$(fa_digits_to_en "$ips")"
    if [[ -z "$email" || ! "$email" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        bot_wizard_start_add "$chat"
        return 0
    fi
    if ! is_uint "$days" || ! is_uint "$gb" || ! is_uint "$ips"; then
        bot_reply "$chat" "❌ الگو: <code>/add name [روز] [گیگابایت] [محدودیت-ip]</code> — اعداد باید صحیح باشند." >/dev/null
        return 0
    fi
    bot_action_client_create "$chat" "$email" "$days" "$gb" "$ips"
}

bot_cmd_link() {
    local chat="$1" rest="$2"
    local email="${rest%% *}"
    email="$(printf '%s' "$email" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "$email" ]]; then
        bot_reply "$chat" "❌ الگو: <code>/link نام‌کلاینت</code>" >/dev/null
        return 0
    fi
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    if ! bot_client_exists "$email"; then
        bot_reply "$chat" "❌ کلاینت «$(tg_escape_html "$email")» پیدا نشد." >/dev/null
        return 0
    fi
    bot_send_client_link "$chat" "$email"
}

bot_cmd_del() {
    local chat="$1" rest="$2"
    local email="${rest%% *}"
    email="$(printf '%s' "$email" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "$email" ]]; then
        bot_reply "$chat" "❌ الگو: <code>/del نام‌کلاینت</code>" >/dev/null
        return 0
    fi
    if ! bot_panel_ready; then bot_err_reply "$chat"; return 0; fi
    if ! bot_client_exists "$email"; then
        bot_reply "$chat" "❌ کلاینت «$(tg_escape_html "$email")» پیدا نشد." >/dev/null
        return 0
    fi
    bot_sel_save "$chat" "client" "$email"
    bot_confirm "$chat" "" "🗑 <b>حذف کلاینت</b>: <b>$(tg_escape_html "$email")</b>

⚠️ این عمل قابل بازگشت نیست. ادامه می‌دهید؟" "cl:delY:1"
}

# --- security actions -----------------------------------------------------------------------------

bot_render_security() {
    local chat="$1" mid="$2"
    local f2b="نصب نیست"
    if has_cmd fail2ban-client; then
        f2b="فعال ($(fail2ban-client status sshd 2>/dev/null | sed -nE 's/.*Currently banned:[[:space:]]*([0-9]+).*/\1/p' | head -1) بن‌شده)"
    fi
    local text
    text="🔒 <b>وضعیت امنیت</b>

• UFW: $(ufw_is_active 2>/dev/null && echo '✅ فعال' || echo '⛔️ غیرفعال')
• fail2ban: ${f2b}
• BBR: <code>$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')</code>
• پورت‌های SSH: <code>$(ssh_ports_active 2>/dev/null | paste -sd, -)</code>"
    if ufw_is_active 2>/dev/null; then
        local rules
        rules="$(ufw status 2>/dev/null | sed -n '4,$p' | head -12)"
        [[ -n "$rules" ]] && text+=$'\n\n<b>قواعد UFW:</b>
<pre>$(tg_escape_html "$rules")</pre>'
    fi
    local kb; kb="$(tg_kb \
        '🔓 باز کردن پورت|sec:open;🔒 بستن پورت|sec:close' \
        '⛔ آزادسازی IP|sec:unban;🌐 پورت SSH|sec:sshp' \
        "$BOT_HOME_KB_ROW")"
    bot_edit "$chat" "$mid" "$text" "$kb" >/dev/null
}

bot_action_ufw_port() {
    local chat="$1" mode="$2" port="$3" proto="$4"
    if ! has_cmd ufw; then
        bot_reply "$chat" "❌ ufw روی این سرور نصب نیست." >/dev/null; return 0
    fi
    if ! ufw_is_active; then
        bot_reply "$chat" "⚠️ فایروال UFW فعال نیست؛ قاعده ثبت شد اما اثری ندارد. ابتدا آن را فعال کنید." >/dev/null
    fi
    if [[ "$mode" == "ufw_open" ]]; then
        if ufw_allow_port "$port" "$proto" "telegram-bot" 2>/dev/null; then
            bot_reply "$chat" "✅ پورت <code>${port}/${proto}</code> در فایروال باز شد." >/dev/null
        else
            bot_reply "$chat" "❌ باز کردن پورت ناموفق بود." >/dev/null
        fi
    else
        if ufw_delete_port "$port" "$proto" 2>/dev/null; then
            bot_reply "$chat" "✅ قاعدهٔ پورت <code>${port}/${proto}</code> بسته شد." >/dev/null
        else
            bot_reply "$chat" "❌ بستن پورت ناموفق بود." >/dev/null
        fi
    fi
}

bot_action_unban() {
    local chat="$1" ip="$2"
    if ! has_cmd fail2ban-client; then
        bot_reply "$chat" "❌ fail2ban روی این سرور نصب نیست." >/dev/null; return 0
    fi
    if fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1; then
        bot_reply "$chat" "✅ IP <code>${ip}</code> از fail2ban آزاد شد." >/dev/null
    else
        bot_reply "$chat" "❌ آزادسازی ناموفق بود (IP در لیست بن نبود؟)." >/dev/null
    fi
}

# bot_action_ssh_confirm <chat> -> "✅ بله" button of the SSH port confirmation
bot_action_ssh_confirm() {
    local chat="$1" port
    port="$(bot_sess_get "$chat" w_ssh_port "")"
    bot_sess_clear_mode "$chat"
    if ! is_port "$port"; then
        bot_reply "$chat" "⌛ پورت دریافتی نامعتبر است؛ دوباره تلاش کنید." >/dev/null
        return 0
    fi
    bot_action_ssh_change "$chat" "$port"
}

bot_action_ssh_change() {
    local chat="$1" port="$2"
    local -a old_ports=()
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && old_ports+=("$p")
    done < <(ssh_ports_active 2>/dev/null)
    # change_ssh_port dies on error -> run it in a subshell and capture output.
    local out rc
    out="$( change_ssh_port "$port" ${old_ports[@]+"${old_ports[@]}"} 2>&1 )" && rc=0 || rc=$?
    if ((rc == 0)); then
        bot_reply "$chat" "✅ پورت SSH به <code>${port}</code> تغییر کرد.

⚠️ پورت(های) قبلی هنوز باز هستند. پس از اطمینان از اتصال با پورت جدید، نهایی‌سازی کنید:
<code>vpn-sanai-security --ssh-finalize</code>" >/dev/null
    else
        bot_reply "$chat" "❌ تغییر پورت SSH ناموفق بود:

<pre>$(tg_escape_html "$(printf '%s' "$out" | tail -3)")</pre>" >/dev/null
    fi
}

# --- backup actions --------------------------------------------------------------------------------

bot_action_backups_list() {
    local chat="$1" mid="$2"
    local list
    list="$(backup_list 2>/dev/null || true)"
    if [[ -z "$list" ]]; then
        bot_edit "$chat" "$mid" "💾 هنوز پشتیبانی ساخته نشده است.

«💾 پشتیبان‌گیری فوری» اولین را می‌سازد." "$(tg_kb '💾 پشتیبان‌گیری فوری|bkp:new' "$BOT_HOME_KB_ROW")" >/dev/null
        return 0
    fi
    local -a files=() shown=()
    local line f
    while IFS= read -r line; do
        f="${line##* }"
        [[ -f "$f" ]] && files+=("$f")
    done <<< "$list"

    local -a kb_rows=()
    local i=0 text=""
    text="💾 <b>پشتیبان‌ها</b>"
    for f in "${files[@]:0:15}"; do
        i=$((i + 1))
        local base sz
        base="$(basename "$f")"
        sz="$(du -h "$f" 2>/dev/null | awk '{print $1}')"
        text+=$'\n'"${i}. <code>$(tg_escape_html "${base#vpn-sanai-backup-}")</code> (${sz})"
        kb_rows+=("${i}. ${base##*-} (${sz})|bkp:rst:${i}")
    done
    ((${#files[@]} > 15)) && text+=$'\n'"… و $(( ${#files[@]} - 15 )) مورد دیگر"
    bot_sel_save "$chat" "backup" "${files[@]:0:15}"

    kb_rows+=("💾 پشتیبان‌گیری فوری|bkp:new;📤 ارسال آخرین|bkp:send")
    kb_rows+=("$BOT_HOME_KB_ROW")
    local kb; kb="$(tg_kb "${kb_rows[@]}")"
    bot_edit "$chat" "$mid" "$text

برای بازگردانی روی یکی بزنید:" "$kb" >/dev/null
}

bot_action_backup_create() {
    local chat="$1"
    if ! state_exists; then bot_err_reply "$chat"; return 0; fi
    load_state_runtime >/dev/null 2>&1 || true
    detect_platform >/dev/null 2>&1 || true
    tg_chat_action "$chat" upload_document >/dev/null 2>&1 || true
    bot_reply "$chat" "⏳ در حال تهیهٔ پشتیبان…" >/dev/null
    local archive
    archive="$(backup_create telegram 2>/dev/null)" || {
        bot_reply "$chat" "❌ پشتیبان‌گیری ناموفق بود (لاگ: /var/log/vpn-sanai/)." >/dev/null
        return 0
    }
    if ! tg_send_document "$chat" "$archive" "💾 پشتیبان $(date '+%Y-%m-%d %H:%M')" >/dev/null 2>&1; then
        bot_reply "$chat" "✅ پشتیبان ساخته شد: <code>$(tg_escape_html "$archive")</code>

⚠️ ارسال فایل به تلگرام ناموفق بود (حجم زیاد؟)." >/dev/null
        return 0
    fi
    bot_reply "$chat" "✅ پشتیبان ساخته و ارسال شد." >/dev/null
}

bot_action_backup_send() {
    local chat="$1"
    local latest
    # backup_list sorts newest-first, so the first line carries the newest archive
    latest="$(backup_list 2>/dev/null | head -1 | awk '{print $NF}')"
    if [[ -z "$latest" || ! -f "$latest" ]]; then
        bot_reply "$chat" "💾 پشتیبانی برای ارسال وجود ندارد؛ ابتدا یکی بسازید." >/dev/null
        return 0
    fi
    tg_chat_action "$chat" upload_document >/dev/null 2>&1 || true
    if tg_send_document "$chat" "$latest" "💾 آخرین پشتیبان" >/dev/null 2>&1; then
        bot_reply "$chat" "📤 ارسال شد: <code>$(tg_escape_html "$(basename "$latest")")</code>" >/dev/null
    else
        bot_reply "$chat" "❌ ارسال فایل ناموفق بود." >/dev/null
    fi
}

bot_action_backup_restore() {
    local chat="$1" idx="$2"
    local archive; archive="$(bot_sel_get "$chat" "$idx")"
    [[ -n "$archive" ]] || { bot_reply "$chat" "⌛ فهرست منقضی شده است." >/dev/null; return 0; }
    if ! state_exists; then bot_err_reply "$chat"; return 0; fi
    load_state_runtime >/dev/null 2>&1 || true
    detect_platform >/dev/null 2>&1 || true
    bot_reply "$chat" "⏳ در حال بازگردانی… (پنل موقتاً قطع می‌شود)" >/dev/null
    local out rc
    out="$( backup_restore "$archive" 2>&1 )" && rc=0 || rc=$?
    # Refresh every cached global from the (possibly replaced) state file.
    state_load >/dev/null 2>&1 || true
    load_state_runtime >/dev/null 2>&1 || true
    if ((rc == 0)); then
        bot_reply "$chat" "✅ بازگردانی کامل شد.

🔗 پنل: $(bot_panel_url_public)" >/dev/null
    else
        bot_reply "$chat" "❌ بازگردانی ناموفق بود:

<pre>$(tg_escape_html "$(printf '%s' "$out" | tail -3)")</pre>" >/dev/null
    fi
}

bot_action_backup_prune() {
    local chat="$1"
    if ! state_exists; then bot_err_reply "$chat"; return 0; fi
    load_state_runtime >/dev/null 2>&1 || true
    if backup_prune 2>/dev/null; then
        bot_reply "$chat" "🧹 پشتیبان‌های قدیمی حذف شدند (نگهداری ${BACKUP_KEEP_DAYS} روز)." >/dev/null
    else
        bot_reply "$chat" "❌ پاک‌سازی ناموفق بود." >/dev/null
    fi
}

# --- help --------------------------------------------------------------------------------------------

bot_send_help() {
    local chat="$1"
    local text
    text="📖 <b>راهنمای ربات vpn-sanai</b>

<b>دستورها</b>
/start — منوی اصلی
/panel — مدیریت پنل سنایی (لینک ورود، ری‌استارت، رمز)
/status — وضعیت سرور و پنل
/clients — مدیریت کلاینت‌ها
/add [نام] [روز] [گیگ] [ip] — ساخت سریع کلاینت
/link نام — ارسال لینک و QR کلاینت
/del نام — حذف کلاینت
/security — فایروال و fail2ban
/backup — پشتیبان‌گیری
/settings — تنظیمات پنل سنایی
/id — نمایش شناسهٔ تلگرام شما
/cancel — لغو عملیات جاری

<b>نکته‌ها</b>
• پیام‌های حاوی رمز، خودکار حذف می‌شوند.
• اعداد فارسی هم پذیرفته می‌شوند (۳۰ = 30).
• گزارش روزانهٔ وضعیت هر روز صبح ارسال می‌شود."
    bot_reply "$chat" "$text" "$(tg_kb "$BOT_HOME_KB_ROW")" >/dev/null
}

# --- daily digest --------------------------------------------------------------------------------------

bot_daily_tick() {
    is_true "$TG_DAILY_REPORT" || return 0
    local hour; hour="$(date +%H)"
    [[ "$hour" == "${TG_DAILY_REPORT_HOUR}" ]] || return 0
    local today; today="$(date +%F)"
    local marker="${BOT_STATE_DIR}/last-daily-report"
    [[ -r "$marker" && "$(cat "$marker" 2>/dev/null)" == "$today" ]] && return 0
    mkdir -p "$BOT_STATE_DIR" 2>/dev/null || true
    printf '%s' "$today" > "$marker" 2>/dev/null || true

    local text
    if bot_panel_ready 2>/dev/null; then
        text="☀️ <b>گزارش روزانهٔ vpn-sanai</b> — ${today}

$(bot_build_status_html)"
    else
        text="☀️ <b>گزارش روزانهٔ vpn-sanai</b> — ${today}

⚠️ اتصال به پنل برقرار نشد: ${BOT_ERR}
وضعیت سرویس: $(panel_service_status 2>/dev/null || echo '?')"
    fi
    bot_notify_admins "$text" >/dev/null 2>&1 || true
}
