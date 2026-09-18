#!/usr/bin/env bash
# Tests for lib/clients.sh — link construction and link bookkeeping.
# shellcheck source=../lib/load.sh
source "${TEST_DIR}/../lib/load.sh"

UUID="11111111-2222-3333-4444-555555555555"
HOST="203.0.113.9"
PORT="443"
SNI="www.example.org"
SID="aabbccddeeff0011"
PUB="PUBLICKEY=="
FLOW="xtls-rprx-vision"
REMARK="srv-reality"

test_link_for_vless_reality_tcp() {
    local link
    link="$(build_vless_link "$UUID" "$HOST" "$PORT" "tcp" "$SNI" "$SID" "$PUB" "$FLOW" "$REMARK")"

    assert_eq "vless" "${link%%://*}" "اسکیم لینک" || return 1
    assert_contains "$link" "vless://${UUID}@${HOST}:${PORT}?" "بخش آدرس" || return 1
    assert_contains "$link" "type=tcp" "نوع انتقال" || return 1
    assert_contains "$link" "security=reality" "امنیت" || return 1
    assert_contains "$link" "pbk=PUBLICKEY%3D%3D" "کلید عمومی باید URL-encode شود" || return 1
    assert_contains "$link" "fp=chrome" "fingerprint" || return 1
    assert_contains "$link" "sni=${SNI}" "SNI" || return 1
    assert_contains "$link" "sid=${SID}" "shortId" || return 1
    assert_contains "$link" "spx=%2F" "spiderX" || return 1
    assert_contains "$link" "flow=xtls-rprx-vision" "flow" || return 1
    assert_contains "$link" "#${REMARK}" "نام (remark)" || return 1

    # No stray whitespace: strict clients reject such links
    case "$link" in
        *" "*) fail "لینک نباید فاصله داشته باشد" ;;
    esac
}

test_link_encodes_remark_and_host() {
    local link
    link="$(build_vless_link "$UUID" "2001:db8::1" "$PORT" "tcp" "$SNI" "$SID" "$PUB" "" "سرور من")"
    assert_contains "$link" "vless://${UUID}@[2001:db8::1]:${PORT}?" "آدرس IPv6 باید براکت شود" || return 1
    assert_contains "$link" "#%D8%B3%D8%B1%D9%88%D8%B1%20%D9%85%D9%86" "remark فارسی باید encode شود" || return 1
    case "$link" in
        *"flow="*) fail "بدون flow نباید پارامتر flow اضافه شود" ;;
    esac
}

test_link_for_xhttp_transport() {
    local link
    link="$(build_vless_link "$UUID" "$HOST" "8443" "xhttp" "$SNI" "$SID" "$PUB" "" "srv-xhttp" "/abc123" "auto")"
    assert_contains "$link" "type=xhttp" "نوع انتقال" || return 1
    assert_contains "$link" "path=%2Fabc123" "مسیر" || return 1
    assert_contains "$link" "mode=auto" "حالت" || return 1
}

test_subscription_url() {
    SERVER_IP="203.0.113.9"; SUB_PORT="2096"; SUB_PATH="/sub/"
    assert_eq "http://203.0.113.9:2096/sub/sub123" "$(sub_url "sub123")" "آدرس اشتراک" || return 1

    SUB_PATH="/panel/sub/"
    assert_eq "http://203.0.113.9:2096/panel/sub/sub123" "$(sub_url "sub123")" "مسیر دلخواه" || return 1

    SERVER_IP="2001:db8::1"
    assert_eq "http://[2001:db8::1]:2096/panel/sub/sub123" "$(sub_url "sub123")" "سرور IPv6" || return 1
}

test_save_client_link_creates_files() {
    VPN_SANAI_LINKS_DIR="${VPN_SANAI_TEST_ROOT}/links-test"
    rm -rf "$VPN_SANAI_LINKS_DIR"

    save_client_link "ali" "vless://one" "http://sub/one"
    save_client_link "sara" "vless://two" ""

    assert_true test -f "${VPN_SANAI_LINKS_DIR}/ali.txt" || fail "فایل کلاینت ساخته نشد"
    assert_true test -f "${VPN_SANAI_LINKS_DIR}/links.txt" || fail "فایل فهرست ساخته نشد"
    assert_eq "600" "$(stat -c '%a' "${VPN_SANAI_LINKS_DIR}/links.txt")" "سطح دسترسی فهرست" || return 1
    assert_contains "$(cat "${VPN_SANAI_LINKS_DIR}/ali.txt")" "vless://one" "محتوای فایل کلاینت" || return 1
    assert_contains "$(cat "${VPN_SANAI_LINKS_DIR}/ali.txt")" "http://sub/one" "آدرس اشتراک" || return 1

    # updating the same client must not duplicate its index line
    save_client_link "ali" "vless://one-updated" ""
    local count
    count="$(grep -c '^ali[[:space:]]' "${VPN_SANAI_LINKS_DIR}/links.txt")"
    assert_eq "1" "$count" "رکورد تکراری در فهرست" || return 1
    assert_contains "$(cat "${VPN_SANAI_LINKS_DIR}/links.txt")" "vless://one-updated" "به‌روزرسانی لینک" || return 1
}

test_client_link_from_state() {
    VLESS_UUID="$UUID"; SERVER_IP="$HOST"; VLESS_PORT="$PORT"; VLESS_SNI="$SNI"
    VLESS_SHORT_ID="$SID"; VLESS_PUBLIC_KEY="$PUB"; VLESS_FLOW="$FLOW"; VLESS_REMARK="$REMARK"
    DEFAULT_CLIENT_EMAIL="user1"

    local link
    link="$(build_client_link_from_state "user1")" || fail "ساخت لینک از state ناموفق بود"
    assert_contains "$link" "vless://${UUID}@${HOST}:${PORT}" "آدرس" || return 1
    assert_contains "$link" "flow=xtls-rprx-vision" "flow" || return 1

    VLESS_PUBLIC_KEY=""
    assert_false build_client_link_from_state "user1" || fail "بدون کلید عمومی نباید لینک ساخته شود"
}

test_print_client_link_writes_and_returns() {
    VPN_SANAI_LINKS_DIR="${VPN_SANAI_TEST_ROOT}/links-print"
    rm -rf "$VPN_SANAI_LINKS_DIR"
    VLESS_UUID="$UUID"; SERVER_IP="$HOST"; VLESS_PORT="$PORT"; VLESS_SNI="$SNI"
    VLESS_SHORT_ID="$SID"; VLESS_PUBLIC_KEY="$PUB"; VLESS_FLOW="$FLOW"; VLESS_REMARK="$REMARK"

    # the panel API is unreachable here: the local link must still be produced
    PANEL_SCHEME="http" PANEL_PORT="1" PANEL_BASE_PATH="/" PANEL_API_TOKEN="x" \
        print_client_link "user1" >/dev/null 2>&1 || fail "print_client_link شکست خورد"

    assert_true test -s "${VPN_SANAI_LINKS_DIR}/user1.txt" || fail "فایل لینک نوشته نشد"
    assert_contains "$(cat "${VPN_SANAI_LINKS_DIR}/user1.txt")" "vless://" "لینک ذخیره‌شده" || return 1
}
