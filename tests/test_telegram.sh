#!/usr/bin/env bash
# Unit + integration tests for the Telegram bot:
#   * lib/telegram.sh — escaping, keyboards, message splitting, token format
#   * lib/bot.sh      — config/auth/sessions, formatting helpers
#   * new panel API helpers against tests/mock_panel.py
#   * the whole bot end-to-end against tests/mock_telegram.py + mock panel:
#     updates are queued as JSON lines, `telegram-bot.sh --run --once` polls
#     them, and assertions run against what the bot actually sent.
# shellcheck source=../lib/load.sh
source "${TEST_DIR}/../lib/load.sh"
# shellcheck source=../lib/telegram.sh
source "${TEST_DIR}/../lib/telegram.sh"
# shellcheck source=../lib/bot.sh
source "${TEST_DIR}/../lib/bot.sh"

TG_TOKEN="123456789:AAHtest-mock-token-for-vpn-sanai"
ADMIN_ID="424242"
STRANGER_ID="111111"
MOCK_PANEL_TOKEN="test-token"

# --- unit: lib/telegram.sh -----------------------------------------------------

test_tg_escape_html() {
    [[ "$(tg_escape_html 'a<b>&c"d')" == 'a&lt;b&gt;&amp;c"d' ]]
}

test_tg_kb_build() {
    local kb
    kb="$(tg_kb 'یکی|cb:one;دو|url:https://x.example')"
    jq -e '.[0][0].text=="یکی" and .[0][0].callback_data=="cb:one"
           and .[0][1].text=="دو" and .[0][1].url=="https://x.example"' <<<"$kb" >/dev/null
}

test_tg_kb_skips_empty_rows() {
    local kb
    kb="$(tg_kb '' 'A|cb:x' '' 'B|cb:y')"
    jq -e 'length == 2' <<<"$kb" >/dev/null
}

test_fa_digits_to_en() {
    [[ "$(fa_digits_to_en '۱۲۳۴۵۰۶۷۸۹')" == "1234506789" ]]
    [[ "$(fa_digits_to_en '٣٠')" == "30" ]]
}

test_tg_valid_token() {
    tg_valid_token "$TG_TOKEN"
    ! tg_valid_token "not-a-token"
    ! tg_valid_token "12345:short"
}

test_tg_split_message() {
    local long
    long="$(head -c 9000 /dev/zero | tr '\0' 'a')"   # one huge line
    local -a parts=()
    local part
    while IFS= read -r -d $'\x1f' part || [[ -n "$part" ]]; do
        parts+=("$part")
    done < <(tg_split_message "$long" 3800)
    (( ${#parts[@]} == 3 )) || return 1
    (( ${#parts[0]} == 3800 && ${#parts[1]} == 3800 && ${#parts[2]} == 1400 ))
}

test_tg_split_message_lines() {
    local text
    text="$(for i in $(seq 1 300); do printf 'line-%03d text\n' "$i"; done)"
    local -a parts=()
    local part
    while IFS= read -r -d $'\x1f' part || [[ -n "$part" ]]; do
        parts+=("$part")
    done < <(tg_split_message "$text" 1000)
    (( ${#parts[@]} >= 4 )) || return 1
    local p
    for p in "${parts[@]}"; do (( ${#p} <= 1000 )) || return 1; done
    [[ "${parts[0]}" == line-001* ]]
}

# --- unit: lib/bot.sh ------------------------------------------------------------

test_bot_admin_allowlist() {
    TG_ADMIN_IDS="1 2,3"
    bot_is_admin 2 && bot_is_admin 3 || return 1
    ! bot_is_admin 4
    ! bot_is_admin ""
}

test_bot_config_load() {
    local dir; dir="$(mktemp -d)"
    printf 'TG_BOT_TOKEN=%s\nTG_ADMIN_IDS=%s\n' "$TG_TOKEN" "$ADMIN_ID" > "${dir}/telegram.env"
    VPN_SANAI_TG_CONFIG="${dir}/telegram.env" bot_config_load
    [[ "$TG_BOT_TOKEN" == "$TG_TOKEN" ]]
    [[ "$(read_env_value "${dir}/telegram.env" TG_ADMIN_IDS)" == "$ADMIN_ID" ]]
    rm -rf "$dir"
}

test_bot_sessions() {
    BOT_STATE_DIR="$(mktemp -d)"
    bot_sess_set "42" mode "add_email"
    bot_sess_set "42" w_email "ali"
    [[ "$(bot_sess_get 42 mode)" == "add_email" ]]
    [[ "$(bot_sess_get 42 w_email)" == "ali" ]]
    [[ "$(bot_sess_get 42 missing default-x)" == "default-x" ]]
    bot_sess_clear_mode "42"
    [[ "$(bot_sess_get 42 mode)" == "" ]]
    [[ "$(bot_sess_get 42 w_email)" == "ali" ]]
    bot_sel_save "42" "client" "one" "two words" "three"
    [[ "$(bot_sel_get 42 2)" == "two words" ]]
    ! bot_sel_get "42" "abc"
    bot_sess_clear "42"
    [[ "$(bot_sess_get 42 w_email)" == "" ]]
    rm -rf "$BOT_STATE_DIR"
}

test_bot_add_admin() {
    local dir; dir="$(mktemp -d)"
    printf 'TG_BOT_TOKEN=%s\nTG_ADMIN_IDS=%s\n' "$TG_TOKEN" "$ADMIN_ID" > "${dir}/telegram.env"
    VPN_SANAI_TG_CONFIG="${dir}/telegram.env"
    TG_ADMIN_IDS="$ADMIN_ID"
    bot_add_admin 777
    bot_is_admin 777 || return 1
    grep -q '^TG_ADMIN_IDS=424242 777$' "${dir}/telegram.env"
    # idempotent
    bot_add_admin 777
    ! grep -q '777 777' "${dir}/telegram.env"
    rm -rf "$dir"
}

test_fmt_helpers() {
    [[ "$(fmt_bytes 0)" == "0 B" ]]
    [[ "$(fmt_bytes 2048)" == "2 KB" ]]
    [[ "$(fmt_bytes 1073741824)" == "1.00 GB" ]]
    [[ "$(fmt_expiry 0)" == "نامحدود" ]]
    [[ "$(fmt_expiry 1)" == "منقضی ⚠️" ]]
    local future=$(( ( $(date +%s) + 3*86400 ) * 1000 ))
    [[ "$(fmt_expiry "$future")" == "3 روز" ]]
    [[ "$(fmt_when 0)" == "—" ]]
    [[ "$(fmt_when $(( $(date +%s) - 7200 )))" == "2 ساعت پیش" ]]
    [[ "$(fmt_duration 90000)" == "1d 1h" ]]
}

# --- panel API helpers against the mock panel --------------------------------------

with_mock() {
    local fn="$1" port_file pid port rc i
    : > "${VPN_SANAI_TEST_ROOT}/mock-requests.jsonl"
    port_file="$(mktemp)"
    python3 "${TEST_DIR}/mock_panel.py" --port 0 --base-path "/secret/" \
        --token "$MOCK_PANEL_TOKEN" --log "${VPN_SANAI_TEST_ROOT}/mock-requests.jsonl" >"$port_file" 2>/dev/null &
    pid=$!
    port=""
    for i in $(seq 1 60); do
        port="$(awk '/LISTENING/{print $2}' "$port_file" 2>/dev/null || true)"
        [[ -n "$port" ]] && break
        sleep 0.1
    done
    [[ -n "$port" ]] || { kill "$pid" 2>/dev/null || true; return 1; }
    PANEL_SCHEME="http"; PANEL_PORT="$port"; PANEL_BASE_PATH="/secret/"
    PANEL_API_TOKEN="$MOCK_PANEL_TOKEN"; PANEL_SESSION_COOKIE=""
    API_RETRIES=1; API_CONNECT_TIMEOUT=2; API_MAX_TIME=5
    "$fn"; rc=$?
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    rm -f "$port_file"
    return "$rc"
}

_seed_inbound() {
    local payload
    payload="$(reality_build_payload "00000000-0000-0000-0000-000000000001" "user1" "sub1" \
        "xtls-rprx-vision" 443 "www.example.org" "PRIV==" "0011223344556677" "PUB==" \
        "srv-reality" "tcp" "" "203.0.113.9" | jq -c '.settings.clients = []')"
    api_silent POST "/panel/api/inbounds/add" "$payload"
}

case_panel_settings_read() {
    local s
    s="$(panel_settings_all)" || return 1
    [[ "$(printf '%s' "$s" | jq -r .webPort)" == "2053" ]]
    [[ "$(printf '%s' "$s" | jq -r .subPort)" == "2096" ]]
}

case_panel_settings_patch() {
    # shellcheck disable=SC2016  # the jq filter is passed verbatim on purpose
    panel_settings_patch '.webPort = $p' --argjson p 9443 >/dev/null || return 1
    local s; s="$(panel_settings_all)" || return 1
    [[ "$(printf '%s' "$s" | jq -r .webPort)" == "9443" ]]
    # invalid port is rejected like the real panel
    # shellcheck disable=SC2016
    panel_settings_patch '.webPort = $p' --argjson p 99999 >/dev/null 2>&1 && return 1
    return 0
}

case_panel_update_user() {
    panel_update_user admin admin newadmin newpass || return 1
    local s; s="$(panel_settings_all)"
    [[ "$(printf '%s' "$s" | jq -r .username)" == "newadmin" ]]
    panel_update_user wrong wrong x y 2>/dev/null && return 1
    return 0
}

case_client_lifecycle() {
    _seed_inbound || return 1
    client_add "ali" 1 10737418240 30 2 "xtls-rprx-vision" || return 1
    client_set_limits "ali" 21474836480 "" "" || return 1
    local info; info="$(client_info ali)"
    [[ "$(printf '%s' "$info" | jq -r '.client.totalGB // .totalGB')" == "21474836480" ]] || return 1
    client_set_enabled "ali" false || return 1
    [[ "$(client_info ali | jq -r '.client.enable // .enable')" == "false" ]] || return 1
    client_set_enabled "ali" true || return 1
    client_reset_traffic "ali" || return 1
    local onlines; onlines="$(client_onlines)"
    [[ "$onlines" == "ali" ]]
    client_reset_all_traffic || return 1
    client_delete_depleted || return 1
    client_delete "ali" || return 1
    [[ -z "$(client_info ali 2>/dev/null)" ]] || return 1
    return 0
}

test_panel_settings_api() { with_mock case_panel_settings_read; }
test_panel_settings_patch_api() { with_mock case_panel_settings_patch; }
test_panel_update_user_api() { with_mock case_panel_update_user; }
test_client_lifecycle_api() { with_mock case_client_lifecycle; }

# --- end-to-end: bot against mock telegram + mock panel -------------------------------

IT_ROOT="" IT_PANEL_PID="" IT_TG_PID=""
IT_PANEL_PORT="" IT_TG_PORT=""
TGQ="" TGLOG="" PANELLOG="" IT_TG_CONFIG="" IT_BOTSTATE=""
NEXT_UPDATE_ID=100

it_start() {
    IT_ROOT="$(mktemp -d)"
    TGQ="${IT_ROOT}/queue.jsonl"; TGLOG="${IT_ROOT}/sent.jsonl"
    PANELLOG="${IT_ROOT}/panel.jsonl"
    : > "$TGQ"
    # the suite shares VPN_SANAI_BACKUP_DIR across tests; do not let archives
    # created by one test leak into another test's listing/sending
    rm -f "${VPN_SANAI_BACKUP_DIR}"/vpn-sanai-backup-*.tar.gz 2>/dev/null || true

    # mock panel — credentials mirror the state file below
    local pf; pf="$(mktemp)"
    MOCK_PANEL_USER=admin MOCK_PANEL_PASS=panelpass123 \
        python3 "${TEST_DIR}/mock_panel.py" --port 0 --base-path "/secret/" \
            --token "$MOCK_PANEL_TOKEN" --log "$PANELLOG" >"$pf" 2>/dev/null &
    IT_PANEL_PID=$!
    IT_PANEL_PORT=""
    local i
    for i in $(seq 1 60); do
        IT_PANEL_PORT="$(awk '/LISTENING/{print $2}' "$pf" 2>/dev/null || true)"
        [[ -n "$IT_PANEL_PORT" ]] && break
        sleep 0.1
    done
    rm -f "$pf"
    [[ -n "$IT_PANEL_PORT" ]] || { it_stop; return 1; }

    # mock telegram
    local tf; tf="$(mktemp)"
    python3 "${TEST_DIR}/mock_telegram.py" --port 0 --token "$TG_TOKEN" \
        --queue "$TGQ" --log "$TGLOG" >"$tf" 2>/dev/null &
    IT_TG_PID=$!
    IT_TG_PORT=""
    for i in $(seq 1 60); do
        IT_TG_PORT="$(awk '/LISTENING/{print $2}' "$tf" 2>/dev/null || true)"
        [[ -n "$IT_TG_PORT" ]] && break
        sleep 0.1
    done
    rm -f "$tf"
    [[ -n "$IT_TG_PORT" ]] || { it_stop; return 1; }

    # install state (what install.sh would have written)
    cat > "$VPN_SANAI_STATE_FILE" <<EOF
STATE_VERSION=1
OS_ID='debian'
ARCH='amd64'
PANEL_PORT='${IT_PANEL_PORT}'
PANEL_BASE_PATH='/secret/'
PANEL_USER='admin'
PANEL_PASS='panelpass123'
PANEL_SCHEME='http'
PANEL_ACCESS_MODE='tunnel'
PANEL_API_TOKEN='${MOCK_PANEL_TOKEN}'
SERVER_IP='203.0.113.9'
VLESS_PORT='443'
VLESS_INBOUND_ID='1'
VLESS_UUID='00000000-0000-0000-0000-000000000001'
VLESS_FLOW='xtls-rprx-vision'
VLESS_SNI='www.microsoft.com'
VLESS_SHORT_ID='0011223344556677'
VLESS_PUBLIC_KEY='PUBKEYTEST=='
VLESS_PRIVATE_KEY='PRIVKEYTEST=='
VLESS_REMARK='srv-reality'
SUB_PORT='2096'
SUB_PATH='/sub/'
DEFAULT_CLIENT_EMAIL='user1'
INSTALLED_AT='2026-01-01'
EOF
    chmod 600 "$VPN_SANAI_STATE_FILE"

    # bot config
    IT_TG_CONFIG="${IT_ROOT}/telegram.env"
    cat > "$IT_TG_CONFIG" <<EOF
TG_BOT_TOKEN='${TG_TOKEN}'
TG_ADMIN_IDS='${ADMIN_ID}'
TG_AUTO_DELETE='90'
TG_DAILY_REPORT='no'
TG_DAILY_REPORT_HOUR='8'
EOF
    IT_BOTSTATE="${IT_ROOT}/botstate"
    mkdir -p "$IT_BOTSTATE"
    NEXT_UPDATE_ID=100

    # seed one inbound so clients can attach to it
    (
        PANEL_SCHEME="http"; PANEL_PORT="$IT_PANEL_PORT"; PANEL_BASE_PATH="/secret/"
        PANEL_API_TOKEN="$MOCK_PANEL_TOKEN"; PANEL_SESSION_COOKIE=""
        API_RETRIES=1; API_CONNECT_TIMEOUT=2; API_MAX_TIME=5
        _seed_inbound
    ) >/dev/null 2>&1 || { it_stop; return 1; }
    return 0
}

it_stop() {
    [[ -n "$IT_PANEL_PID" ]] && kill "$IT_PANEL_PID" 2>/dev/null || true
    [[ -n "$IT_TG_PID" ]] && kill "$IT_TG_PID" 2>/dev/null || true
    [[ -n "$IT_PANEL_PID" ]] && wait "$IT_PANEL_PID" 2>/dev/null || true
    [[ -n "$IT_TG_PID" ]] && wait "$IT_TG_PID" 2>/dev/null || true
    [[ -n "$IT_ROOT" ]] && rm -rf "$IT_ROOT"
    IT_PANEL_PID=""; IT_TG_PID=""
    return 0
}

# it_feed_message <uid> <text>
it_feed_message() {
    jq -nc --argjson u "$((NEXT_UPDATE_ID++))" --argjson uid "$1" --arg t "$2" \
        '{update_id:$u, message:{message_id:1, from:{id:$uid, first_name:"Test"},
          chat:{id:$uid, type:"private"}, date:1700000000, text:$t}}' >> "$TGQ"
}

# it_feed_callback <uid> <data>
it_feed_callback() {
    jq -nc --argjson u "$((NEXT_UPDATE_ID++))" --argjson uid "$1" --arg d "$2" \
        '{update_id:$u, callback_query:{id:"cb1", from:{id:$uid},
          message:{message_id:50, chat:{id:$uid}}, data:$d}}' >> "$TGQ"
}

it_bot_run() {
    # The bot must exit 0; its stderr is surfaced only when a test fails.
    env VPN_SANAI_TG_CONFIG="$IT_TG_CONFIG" \
        VPN_SANAI_BOT_STATE_DIR="$IT_BOTSTATE" \
        TG_API_BASE="http://127.0.0.1:${IT_TG_PORT}" \
        TG_POLL_TIMEOUT=0 VPN_SANAI_BOT_TEST=1 VPN_SANAI_QUIET=1 \
        bash "${TEST_DIR}/../scripts/telegram-bot.sh" --run --once \
        >"${IT_ROOT}/bot.out" 2>&1 || {
            printf '    bot failed:\n' >&2
            tail -20 "${IT_ROOT}/bot.out" | sed 's/^/      /' >&2
            return 1
        }
}

it_sent_texts() {   # all texts the bot sent
    jq -r 'select(.method=="sendMessage") | .params.text // empty' "$TGLOG" 2>/dev/null
}

it_sent_edit_texts() {
    jq -r 'select(.method=="editMessageText") | .params.text // empty' "$TGLOG" 2>/dev/null
}

it_buttons() {      # every callback_data the bot attached
    jq -r 'select(.params.reply_markup != null)
           | .params.reply_markup.inline_keyboard[]?[]?.callback_data // empty' "$TGLOG" 2>/dev/null
}

it_methods() { jq -r '.method' "$TGLOG" 2>/dev/null; }

it_panel_requests() {  # <path-suffix>
    jq -rc --arg p "$1" 'select(.path | endswith($p))' "$PANELLOG" 2>/dev/null
}

it_panel_bodies() {    # <path-suffix>
    jq -rc --arg p "$1" 'select(.path | endswith($p)) | .body' "$PANELLOG" 2>/dev/null
}

it_reset_log() { : > "$TGLOG"; }

test_it_denies_stranger() {
    it_start || return 1
    it_feed_message "$STRANGER_ID" "/start"
    it_bot_run
    it_sent_texts | grep -q "دسترسی ندارید" || { it_stop; return 1; }
    ! it_buttons | grep -q "m:panel"
    # admins were notified about the intrusion attempt
    it_sent_texts | grep -q "تلاش برای دسترسی"
    it_stop
}

test_it_start_menu() {
    it_start || return 1
    it_feed_message "$ADMIN_ID" "/start"
    it_bot_run
    it_sent_texts | grep -q "vpn-sanai" || { it_stop; return 1; }
    it_buttons | grep -q "m:panel" || { it_stop; return 1; }
    it_buttons | grep -q "m:cli"
    it_buttons | grep -q "m:set"
    it_stop
}

test_it_panel_info_link() {
    it_start || return 1
    it_feed_message "$ADMIN_ID" "/panel"
    it_bot_run
    # menu shown; now request the credential block via its button
    it_feed_callback "$ADMIN_ID" "pn:info"
    it_bot_run
    local texts; texts="$(it_sent_texts)"
    printf '%s' "$texts" | grep -q "پنل سنایی" || { it_stop; return 1; }
    printf '%s' "$texts" | grep -q "ssh -N -L 8443:127.0.0.1:${IT_PANEL_PORT}" || { it_stop; return 1; }
    printf '%s' "$texts" | grep -q "admin" || { it_stop; return 1; }
    printf '%s' "$texts" | grep -q "panelpass123"
    # secrets are self-destructing: a deleteMessage must follow
    it_methods | grep -q "deleteMessage"
    it_stop
}

test_it_status() {
    it_start || return 1
    it_feed_message "$ADMIN_ID" "/status"
    it_bot_run
    local texts; texts="$(it_sent_texts)"
    printf '%s' "$texts" | grep -q "وضعیت سرور" || { it_stop; return 1; }
    printf '%s' "$texts" | grep -q "running"
    it_stop
}

test_it_add_client_quick() {
    it_start || return 1
    it_feed_message "$ADMIN_ID" "/add ali 30 50 2"
    it_bot_run
    # quota was sent as bytes (50 GB = 53687091200)
    it_panel_bodies "/panel/api/clients/add" | grep -q '"totalGB":53687091200' || { it_stop; return 1; }
    it_panel_bodies "/panel/api/clients/add" | grep -q '"email":"ali"' || { it_stop; return 1; }
    it_panel_bodies "/panel/api/clients/add" | grep -q '"limitIp":2' || { it_stop; return 1; }
    # the bot answered with the link
    it_sent_texts | grep -q "vless://" || { it_stop; return 1; }
    it_sent_texts | grep -q "ali"
    it_stop
}

test_it_add_client_wizard() {
    it_start || return 1
    it_feed_callback "$ADMIN_ID" "cl:add"
    it_bot_run
    it_sent_texts | grep -q "۱ از ۴" || { it_stop; return 1; }
    it_reset_log
    it_feed_message "$ADMIN_ID" "reza"
    it_bot_run
    it_sent_texts | grep -q "۲ از ۴" || { it_stop; return 1; }
    it_reset_log
    it_feed_message "$ADMIN_ID" "۳۰"            # Persian digits must work
    it_bot_run
    it_sent_texts | grep -q "۳ از ۴" || { it_stop; return 1; }
    it_reset_log
    it_feed_message "$ADMIN_ID" "100"
    it_bot_run
    it_reset_log
    it_feed_message "$ADMIN_ID" "0"
    it_bot_run
    it_sent_texts | grep -q "خلاصهٔ کلاینت" || { it_stop; return 1; }
    it_buttons | grep -q "cl:addY" || { it_stop; return 1; }
    it_reset_log
    it_feed_callback "$ADMIN_ID" "cl:addY"
    it_bot_run
    it_panel_bodies "/panel/api/clients/add" | grep -q '"email":"reza"' || { it_stop; return 1; }
    it_panel_bodies "/panel/api/clients/add" | grep -q '"totalGB":107374182400'
    it_sent_texts | grep -q "vless://"
    it_stop
}

test_it_clients_list_view_delete() {
    it_start || return 1
    # create two clients directly through the panel API
    (
        PANEL_SCHEME="http"; PANEL_PORT="$IT_PANEL_PORT"; PANEL_BASE_PATH="/secret/"
        PANEL_API_TOKEN="$MOCK_PANEL_TOKEN"; PANEL_SESSION_COOKIE=""
        API_RETRIES=1; API_CONNECT_TIMEOUT=2; API_MAX_TIME=5
        client_add "ali" 1 10737418240 0 0 "xtls-rprx-vision" >/dev/null
        client_add "sara" 1 0 0 0 "xtls-rprx-vision" >/dev/null
    ) >/dev/null 2>&1
    it_feed_callback "$ADMIN_ID" "cl:list"
    it_bot_run
    it_buttons | grep -q "cl:v:1" || { it_stop; return 1; }
    it_buttons | grep -q "cl:v:2" || { it_stop; return 1; }
    it_reset_log
    it_feed_callback "$ADMIN_ID" "cl:v:1"
    it_bot_run
    it_sent_edit_texts | grep -q "ali" || { it_stop; return 1; }
    it_buttons | grep -q "cl:qr:1" || { it_stop; return 1; }
    it_buttons | grep -q "cl:del:1" || { it_stop; return 1; }
    it_buttons | grep -q "cl:tgl:1" || { it_stop; return 1; }
    it_reset_log
    it_feed_callback "$ADMIN_ID" "cl:del:1"
    it_bot_run
    it_sent_edit_texts | grep -q "حذف کلاینت" || { it_stop; return 1; }
    it_buttons | grep -q "cl:delY:1" || { it_stop; return 1; }
    it_reset_log
    it_feed_callback "$ADMIN_ID" "cl:delY:1"
    it_bot_run
    it_panel_requests "/panel/api/clients/del/ali" | grep -q . || { it_stop; return 1; }
    it_sent_texts | grep -q "حذف شد"
    it_stop
}

test_it_client_toggle_and_reset() {
    it_start || return 1
    (
        PANEL_SCHEME="http"; PANEL_PORT="$IT_PANEL_PORT"; PANEL_BASE_PATH="/secret/"
        PANEL_API_TOKEN="$MOCK_PANEL_TOKEN"; PANEL_SESSION_COOKIE=""
        API_RETRIES=1; API_CONNECT_TIMEOUT=2; API_MAX_TIME=5
        client_add "ali" 1 10737418240 0 0 "xtls-rprx-vision" >/dev/null
    ) >/dev/null 2>&1
    it_feed_callback "$ADMIN_ID" "cl:list"; it_bot_run; it_reset_log
    it_feed_callback "$ADMIN_ID" "cl:v:1"; it_bot_run; it_reset_log
    it_feed_callback "$ADMIN_ID" "cl:tgl:1"
    it_bot_run
    it_panel_bodies "/panel/api/clients/update/ali" | grep -q '"enable":false' || { it_stop; return 1; }
    it_sent_texts | grep -q "غیرفعال شد" || { it_stop; return 1; }
    it_reset_log
    it_feed_callback "$ADMIN_ID" "cl:rst:1"; it_bot_run; it_reset_log
    it_feed_callback "$ADMIN_ID" "cl:rstY:1"
    it_bot_run
    it_panel_requests "/panel/api/clients/resetTraffic/ali" | grep -q . || { it_stop; return 1; }
    it_sent_texts | grep -q "صفر شد"
    it_stop
}

test_it_settings_show_and_port_change() {
    it_start || return 1
    it_feed_callback "$ADMIN_ID" "set:show"
    it_bot_run
    it_sent_edit_texts | grep -q "تنظیمات فعلی پنل" || { it_stop; return 1; }
    it_sent_edit_texts | grep -q "2053" || { it_stop; return 1; }
    it_sent_edit_texts | grep -q "2096"
    it_reset_log
    # change the panel port through the wizard
    it_feed_callback "$ADMIN_ID" "set:port"
    it_bot_run
    it_sent_texts | grep -q "تغییر پورت پنل" || { it_stop; return 1; }
    it_reset_log
    local new_port=39443
    it_feed_message "$ADMIN_ID" "$new_port"
    it_bot_run
    it_panel_bodies "/panel/api/setting/update" | grep -q "\"webPort\":${new_port}" || { it_stop; return 1; }
    it_panel_requests "/panel/api/setting/restartPanel" | grep -q . || { it_stop; return 1; }
    it_sent_texts | grep -q "${new_port}" || { it_stop; return 1; }
    # state was updated so subsequent runs talk to the new port
    [[ "$(state_get PANEL_PORT)" == "$new_port" ]]
    it_stop
}

test_it_settings_path_change() {
    it_start || return 1
    it_feed_callback "$ADMIN_ID" "set:path"
    it_bot_run
    it_reset_log
    it_feed_message "$ADMIN_ID" "newsecret"
    it_bot_run
    it_panel_bodies "/panel/api/setting/update" | grep -q '"webPath":"/newsecret/"' || { it_stop; return 1; }
    it_sent_texts | grep -q "تغییر کرد" || { it_stop; return 1; }
    [[ "$(state_get PANEL_BASE_PATH)" == "/newsecret/" ]]
    it_stop
}

test_it_backup_list_send() {
    it_start || return 1
    # fabricate two archives where backup_list() looks for them
    printf 'SQLite format 3 mock' > "${IT_ROOT}/fake.db"
    export XUI_DB_DEFAULT="${IT_ROOT}/fake.db"
    mkdir -p "$VPN_SANAI_BACKUP_DIR"
    local stamp1="20260101-030000" stamp2="20260102-030000"
    printf 'fake-archive-1' > "${VPN_SANAI_BACKUP_DIR}/vpn-sanai-backup-${stamp1}-manual.tar.gz"
    printf 'fake-archive-2' > "${VPN_SANAI_BACKUP_DIR}/vpn-sanai-backup-${stamp2}-manual.tar.gz"
    it_feed_callback "$ADMIN_ID" "bkp:list"
    it_bot_run
    it_sent_edit_texts | grep -q "پشتیبان‌ها" || { it_stop; return 1; }
    it_buttons | grep -q "bkp:send" || { it_stop; return 1; }
    it_reset_log
    it_feed_callback "$ADMIN_ID" "bkp:send"
    it_bot_run
    it_methods | grep -q "sendDocument" || { it_stop; return 1; }
    it_sent_texts | grep -q "20260102-030000"
    it_stop
}

test_it_backup_create() {
    it_start || return 1
    printf 'SQLite format 3 mock' > "${IT_ROOT}/fake.db"
    export XUI_DB_DEFAULT="${IT_ROOT}/fake.db"
    it_feed_callback "$ADMIN_ID" "bkp:new"
    it_bot_run
    it_methods | grep -q "sendDocument" || { it_stop; return 1; }
    ls "${VPN_SANAI_BACKUP_DIR}"/vpn-sanai-backup-*-telegram.tar.gz >/dev/null 2>&1 || { it_stop; return 1; }
    it_sent_texts | grep -q "پشتیبان ساخته و ارسال شد"
    it_stop
}

test_it_pairing_first_admin() {
    it_start || return 1
    # a fresh config without admins and with a pairing code
    printf 'TG_BOT_TOKEN=%q\nTG_ADMIN_IDS=\nTG_AUTO_DELETE=90\nTG_DAILY_REPORT=no\nTG_PAIRING_CODE=Ab12Cd9x\nTG_PAIRING_EXPIRY=%s\n' \
        "$TG_TOKEN" "$(( $(date +%s) + 600 ))" > "$IT_TG_CONFIG"
    it_feed_message "$STRANGER_ID" "/start Ab12Cd9x"
    it_bot_run
    it_sent_texts | grep -q "اتصال انجام شد" || { it_stop; return 1; }
    grep -q "TG_ADMIN_IDS=.*${STRANGER_ID}" "$IT_TG_CONFIG" || { it_stop; return 1; }
    # the pairing code is single use
    ! grep -q "TG_PAIRING_CODE" "$IT_TG_CONFIG"
    it_stop
}

test_it_id_and_help_and_cancel() {
    it_start || return 1
    it_feed_message "$ADMIN_ID" "/id"
    it_bot_run
    it_sent_texts | grep -q "شناسهٔ کاربری شما: <code>${ADMIN_ID}</code>" || { it_stop; return 1; }
    it_reset_log
    it_feed_message "$ADMIN_ID" "/help"
    it_bot_run
    it_sent_texts | grep -q "راهنمای ربات" || { it_stop; return 1; }
    it_reset_log
    # an unknown command suggests /help
    it_feed_message "$ADMIN_ID" "/frobnicate"
    it_bot_run
    it_sent_texts | grep -q "نمی‌شناسم" || { it_stop; return 1; }
    it_reset_log
    # cancel during a wizard returns to the main menu
    it_feed_callback "$ADMIN_ID" "cl:add"; it_bot_run; it_reset_log
    it_feed_callback "$ADMIN_ID" "x:cancel"
    it_bot_run
    it_buttons | grep -q "m:panel"
    it_stop
}

test_it_offset_persists() {
    it_start || return 1
    it_feed_message "$ADMIN_ID" "/start"
    it_bot_run
    [[ "$(cat "${IT_BOTSTATE}/offset")" == "101" ]] || { it_stop; return 1; }
    # the same update is never processed twice
    local before; before="$(it_methods | grep -c sendMessage)"
    it_bot_run
    local after; after="$(it_methods | grep -c sendMessage)"
    (( after == before ))
    it_stop
}

test_it_online_users() {
    it_start || return 1
    (
        PANEL_SCHEME="http"; PANEL_PORT="$IT_PANEL_PORT"; PANEL_BASE_PATH="/secret/"
        PANEL_API_TOKEN="$MOCK_PANEL_TOKEN"; PANEL_SESSION_COOKIE=""
        API_RETRIES=1; API_CONNECT_TIMEOUT=2; API_MAX_TIME=5
        client_add "ali" 1 0 0 0 "xtls-rprx-vision" >/dev/null
        client_add "sara" 1 0 0 0 "xtls-rprx-vision" >/dev/null
    ) >/dev/null 2>&1
    it_feed_callback "$ADMIN_ID" "cl:onl"
    it_bot_run
    it_sent_edit_texts | grep -q "کاربران آنلاین (1)" || { it_stop; return 1; }
    it_sent_edit_texts | grep -q "ali"
    it_stop
}

test_it_link_command() {
    it_start || return 1
    (
        PANEL_SCHEME="http"; PANEL_PORT="$IT_PANEL_PORT"; PANEL_BASE_PATH="/secret/"
        PANEL_API_TOKEN="$MOCK_PANEL_TOKEN"; PANEL_SESSION_COOKIE=""
        API_RETRIES=1; API_CONNECT_TIMEOUT=2; API_MAX_TIME=5
        client_add "ali" 1 0 0 0 "xtls-rprx-vision" >/dev/null
    ) >/dev/null 2>&1
    it_feed_message "$ADMIN_ID" "/link ali"
    it_bot_run
    it_sent_texts | grep -q "vless://" || { it_stop; return 1; }
    it_sent_texts | grep -q "203.0.113.9:443" || { it_stop; return 1; }
    # subscription link is included when the panel returns a subId
    it_sent_texts | grep -q "sub/"
    it_stop
}

test_it_security_menu() {
    it_start || return 1
    it_feed_callback "$ADMIN_ID" "sec:st"
    it_bot_run
    it_sent_edit_texts | grep -q "وضعیت امنیت" || { it_stop; return 1; }
    it_buttons | grep -q "sec:open" || { it_stop; return 1; }
    it_buttons | grep -q "sec:sshp"
    it_stop
}

test_it_no_install_reports_error() {
    it_start || return 1
    mv "$VPN_SANAI_STATE_FILE" "${IT_ROOT}/state.env.bak"
    it_feed_message "$ADMIN_ID" "/status"
    it_bot_run
    it_sent_texts | grep -q "پیدا نشد" || { it_stop; mv "${IT_ROOT}/state.env.bak" "$VPN_SANAI_STATE_FILE"; return 1; }
    mv "${IT_ROOT}/state.env.bak" "$VPN_SANAI_STATE_FILE"
    # /id still works without an install
    it_reset_log
    it_feed_message "$ADMIN_ID" "/id"
    it_bot_run
    it_sent_texts | grep -q "${ADMIN_ID}"
    it_stop
}

test_tg_normalize_admins() {
    # Regression: a non-numeric admin id (e.g. "@username") used to be stored
    # verbatim — notifications silently failed and every /start was denied.
    local out
    out="$(tg_normalize_admins "111, 222 333" 2>/dev/null)"
    [[ "$out" == "111 222 333" ]] || { echo "numeric list -> '$out'"; return 1; }
    out="$(tg_normalize_admins "111 abc 222" 2>/dev/null)"
    [[ "$out" == "111 222" ]] || { echo "garbage not dropped -> '$out'"; return 1; }
    out="$(tg_normalize_admins " , ; " 2>/dev/null)"
    [[ -z "$out" ]] || { echo "empty expected, got '$out'"; return 1; }
}

test_bot_gate_denial_shows_uid() {
    # Regression aid: the denial message must echo the sender's numeric id so
    # a mistyped TG_ADMIN_IDS can be fixed without guesswork.
    BOT_STATE_DIR="$(mktemp -d)"
    local sent=""
    # shellcheck disable=SC2329
    bot_reply() { sent="$2"; return 0; }
    # shellcheck disable=SC2329
    bot_pairing_try() { return 1; }
    # shellcheck disable=SC2329
    bot_notify_admins() { return 0; }
    TG_ADMIN_IDS="999" TG_PAIRING_CODE="" bot_gate "111" "12345678" "نام" "/start" || true
    rm -rf "$BOT_STATE_DIR"
    [[ "$sent" == *"دسترسی ندارید"* && "$sent" == *"12345678"* ]] || { echo "reply='$sent'"; return 1; }
}
