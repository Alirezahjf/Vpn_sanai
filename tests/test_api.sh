#!/usr/bin/env bash
# End-to-end tests of the API layer against tests/mock_panel.py, which mirrors
# the real panel's envelope, authentication and validation behaviour.
# shellcheck source=../lib/load.sh
source "${TEST_DIR}/../lib/load.sh"

MOCK_LOG="${VPN_SANAI_TEST_ROOT}/mock-requests.jsonl"
MOCK_TOKEN="test-token"
MOCK_BASE_PATH="/secret/"

# with_mock <function> — start the mock panel, call the function in this shell
# (so all library functions stay available), stop the mock, return its status.
with_mock() {
    local fn="$1" port_file pid port rc i

    : > "$MOCK_LOG"
    port_file="$(mktemp)"
    python3 "${TEST_DIR}/mock_panel.py" --port 0 --base-path "${MOCK_BASE_PATH}" \
        --token "${MOCK_TOKEN}" --log "${MOCK_LOG}" >"$port_file" 2>/dev/null &
    pid=$!

    port=""
    for i in $(seq 1 60); do
        port="$(awk '/LISTENING/{print $2}' "$port_file" 2>/dev/null || true)"
        [[ -n "$port" ]] && break
        sleep 0.1
    done
    if [[ -z "$port" ]]; then
        kill "$pid" 2>/dev/null || true
        printf '    (mock panel did not start)\n' >&2
        return 1
    fi

    PANEL_SCHEME="http"
    PANEL_PORT="$port"
    PANEL_BASE_PATH="$MOCK_BASE_PATH"
    PANEL_API_TOKEN="$MOCK_TOKEN"
    PANEL_SESSION_COOKIE=""
    API_RETRIES=1
    API_CONNECT_TIMEOUT=2
    API_MAX_TIME=5
    export PANEL_SCHEME PANEL_PORT PANEL_BASE_PATH PANEL_API_TOKEN

    "$fn"
    rc=$?

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$port_file"
    return $rc
}

mock_reqs() { # <path-suffix> -> the request bodies for that route, one per line
    jq -rc --arg p "$1" 'select(.path | endswith($p)) | .body' "$MOCK_LOG" 2>/dev/null
}

_make_tcp_payload() { # <port> [uuid]
    reality_build_payload "${2:-00000000-0000-0000-0000-000000000001}" "user1" "sub1" \
        "xtls-rprx-vision" "$1" "www.example.org" "PRIV==" "0011223344556677" "PUB==" \
        "srv-reality" "tcp" "" "203.0.113.9" | jq -c '.settings.clients = []'
}

_make_xhttp_payload() { # <port> [uuid]
    reality_build_payload "${2:-00000000-0000-0000-0000-000000000001}" "user1" "sub1" \
        "" "$1" "www.example.org" "PRIV==" "0011223344556677" "PUB==" \
        "srv-xhttp" "xhttp" "/x1y2z3" "203.0.113.9" | jq -c '.settings.clients = []'
}

# --- cases (run by with_mock in the current shell) ---------------------------
case_status() {
    local obj
    obj="$(api_get_obj "/panel/api/server/status")" || return 1
    [[ "$(printf '%s' "$obj" | jq -r .xray.state)" == "running" ]]
}

case_bad_token() {
    local saved="$PANEL_API_TOKEN"
    PANEL_API_TOKEN="wrong-token"
    if api_is_authenticated; then
        PANEL_API_TOKEN="$saved"
        return 1
    fi
    PANEL_API_TOKEN="$saved"
    return 0
}

case_missing_route() {
    api_silent GET "/panel/api/does/not/exist" && return 1
    [[ -n "${API_ERROR:-}" ]]
}

case_create_inbound() {
    local id
    id="$(reality_create_inbound "$(_make_tcp_payload 443)")" || return 1
    [[ "$id" == "1" ]]
}

case_reject_bad_reality() {
    local bad
    bad="$(jq -nc '{protocol:"vless",port:8443,settings:{clients:[],decryption:"none"},
                    streamSettings:{network:"tcp",security:"reality",realitySettings:{},
                                    tcpSettings:{header:{type:"none"}}},
                    sniffing:{enabled:true}}')"
    if api_silent POST "/panel/api/inbounds/add" "$bad"; then
        return 1
    fi
    [[ "${API_ERROR}" == *validation* || "${API_ERROR}" == *required* ]]
}

case_duplicate_port() {
    # call the API directly (not through $()) so API_ERROR stays in this shell
    api_silent POST "/panel/api/inbounds/add" "$(_make_tcp_payload 443)" || return 1
    if api_silent POST "/panel/api/inbounds/add" "$(_make_tcp_payload 443)"; then
        return 1
    fi
    [[ "${API_ERROR:-}" == *"already in use"* ]]
}

case_idempotent_detection() {
    reality_create_inbound "$(_make_tcp_payload 8443)" >/dev/null || return 1
    local found missing
    found="$(reality_inbound_exists 8443 tcp)"
    [[ "$found" == "1" ]] || { log_error "found=[$found]"; return 1; }
    missing="$(reality_inbound_exists 9999 tcp || true)"
    [[ -z "$missing" ]]
}

case_client_with_explicit_uuid() {
    reality_create_inbound "$(_make_tcp_payload 443)" >/dev/null || return 1
    client_add "sara" 1 0 0 0 "xtls-rprx-vision" "11111111-2222-3333-4444-555555555555" || return 1
    local id
    id="$(client_info "sara" | jq -r '.client.id // .id')"
    [[ "$id" == "11111111-2222-3333-4444-555555555555" ]]
}

case_multiple_inbounds_and_attach() {
    reality_create_inbound "$(_make_tcp_payload 443)" >/dev/null || return 1
    reality_create_inbound "$(_make_xhttp_payload 8443)" >/dev/null || return 1

    client_add "ali" 1 0 0 0 "xtls-rprx-vision" || return 1
    client_add "ali" 2 0 0 0 "" || return 1     # duplicate email -> attach path

    local sub
    sub="$(client_sub_id ali)"
    [[ -n "$sub" ]]
}

case_unknown_inbound_client() {
    client_add "ghost" 99 0 0 0 "" 2>/dev/null && return 1
    [[ "${API_ERROR:-}" == *"inbound 99"* ]]
}

case_share_addr() {
    local id addr
    id="$(reality_create_inbound "$(_make_tcp_payload 443)")" || return 1
    inbound_set_share_addr "$id" "203.0.113.9"
    addr="$(inbound_get_json "$id" | jq -r .shareAddr)"
    [[ "$addr" == "203.0.113.9" ]]
}

case_cookie_login() {
    PANEL_API_TOKEN=""
    panel_login "admin" "secret" || return 1
    [[ -n "$PANEL_SESSION_COOKIE" ]] || return 1
    api_silent GET "/panel/api/server/status"
}

case_inbound_get_normalises_json_strings() {
    local id settings network
    id="$(reality_create_inbound "$(_make_tcp_payload 443)")" || return 1
    settings="$(inbound_get_json "$id" | jq -r '.settings.decryption')"
    network="$(inbound_get_json "$id" | jq -r '.streamSettings.network')"
    [[ "$settings" == "none" && "$network" == "tcp" ]]
}

# --- tests -------------------------------------------------------------------
test_api_url_building() {
    local saved_scheme="$PANEL_SCHEME" saved_port="$PANEL_PORT" saved_base="$PANEL_BASE_PATH"
    PANEL_SCHEME="https"; PANEL_PORT="2053"; PANEL_BASE_PATH="/AbC123/"
    assert_eq "https://127.0.0.1:2053/AbC123" "$(api_base_url)" "آدرس پایه" || return 1
    assert_eq "https://127.0.0.1:2053/AbC123/panel/api/server/status" \
        "$(api_url '/panel/api/server/status')" "آدرس endpoint" || return 1

    PANEL_BASE_PATH="/"
    assert_eq "https://127.0.0.1:2053/panel/api/server/status" \
        "$(api_url '/panel/api/server/status')" "بدون مسیر مخفی" || return 1

    PANEL_SCHEME="$saved_scheme"; PANEL_PORT="$saved_port"; PANEL_BASE_PATH="$saved_base"
    return 0
}

test_api_status_round_trip() {
    with_mock case_status || fail "خواندن وضعیت پنل ناموفق بود"
}

test_api_rejects_wrong_token() {
    with_mock case_bad_token || fail "توکن نامعتبر نباید پذیرفته شود"
}

test_api_surfaces_panel_error_messages() {
    with_mock case_missing_route || fail "پیام خطای پنل باید منتقل شود"
}

test_inbound_creation_round_trip() {
    with_mock case_create_inbound || fail "ساخت Inbound از طریق API ناموفق بود"

    local body auth
    body="$(mock_reqs "/inbounds/add" | tail -1)"
    auth="$(jq -r 'select(.path|endswith("/inbounds/add")) | .auth' "$MOCK_LOG" | tail -1)"
    assert_eq "vless"  "$(printf '%s' "$body" | jq -r .protocol)" "پروتکل ارسالی" || return 1
    assert_eq "443"    "$(printf '%s' "$body" | jq -r .port)"     "پورت ارسالی" || return 1
    assert_eq "PRIV==" "$(printf '%s' "$body" | jq -r .streamSettings.realitySettings.privateKey)" \
        "کلید خصوصی ارسالی" || return 1
    assert_eq "203.0.113.9" "$(printf '%s' "$body" | jq -r .shareAddr)" "shareAddr ارسالی" || return 1
    assert_eq "Bearer test-token" "$auth" "هدر احراز هویت" || return 1
}

test_inbound_rejects_incomplete_reality_payload() {
    with_mock case_reject_bad_reality || fail "پنل باید payload ناقص REALITY را رد کند"
}

test_inbound_duplicate_port_is_reported() {
    with_mock case_duplicate_port || fail "پورت تکراری باید خطای پنل را برگرداند"
}

test_reality_inbound_exists_detects_existing() {
    with_mock case_idempotent_detection || fail "تشخیص Inbound موجود (اجرای دوبارهٔ اسکریپت) کار نکرد"
}

test_inbound_get_normalises_json_strings() {
    with_mock case_inbound_get_normalises_json_strings || fail "تبدیل settings/streamSettings از رشته به JSON"
}

test_client_add_with_explicit_uuid() {
    with_mock case_client_with_explicit_uuid || fail "UUID صریح کلاینت باید در پنل ثبت شود"
}

test_client_add_and_duplicate_attach() {
    with_mock case_multiple_inbounds_and_attach || fail "افزودن کلاینت و اتصال به Inbound دوم ناموفق بود"

    local flow
    flow="$(jq -rc 'select(.path|endswith("/clients/add")) | .body.client.flow' "$MOCK_LOG" | head -1)"
    assert_eq "xtls-rprx-vision" "$flow" "flow کلاینت VLESS" || return 1

    local attach
    attach="$(mock_reqs "/attach" | tail -1)"
    assert_eq "2" "$(printf '%s' "$attach" | jq -r '.inboundIds[0]')" "اتصال کلاینت تکراری به Inbound دوم" || return 1
}

test_client_add_reports_unknown_inbound() {
    with_mock case_unknown_inbound_client || fail "پیام خطای inbound ناموجود باید منتقل شود"
}

test_share_addr_update_keeps_panel_links_correct() {
    with_mock case_share_addr || fail "ثبت shareAddr روی Inbound ناموفق بود"
}

test_cookie_login_fallback() {
    with_mock case_cookie_login || fail "ورود با کوکی/CSRF ناموفق بود"
}
