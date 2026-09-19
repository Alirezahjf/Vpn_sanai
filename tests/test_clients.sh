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

test_is_uuid_rejects_numeric_row_ids() {
    # Regression: newer panels return a numeric client row-id; it leaked into
    # links as vless://1@… and broke every client.
    _is_uuid "11111111-2222-3333-4444-555555555555" || fail "uuid معتبر رد شد"
    if _is_uuid "1" || _is_uuid "2" || _is_uuid "" || _is_uuid "not-a-uuid"; then
        fail "شناسهٔ عددی باید رد شود"
    fi
}

test_client_uuid_in_inbound_reads_membership() {
    inbound_get_json() {
        printf '%s' '{"settings":{"clients":[{"id":"aaaaaaaa-1111-2222-3333-444444444444","email":"user1"},{"id":"bbbbbbbb-1111-2222-3333-444444444444","email":"user2"}]}}'
    }
    assert_eq "aaaaaaaa-1111-2222-3333-444444444444" "$(client_uuid_in_inbound user1 9)" "uuid عضو" || return 1
    assert_eq "" "$(client_uuid_in_inbound ghost 9)" "ناموجود باید خالی بدهد" || return 1
}

test_client_add_duplicate_member_keeps_panel_uuid() {
    # Regression: rerun hit "email already in use"; the installer then printed a
    # link with its own fresh uuid while xray served the older one.
    api_silent() { API_ERROR="email already in use: user1"; return 1; }
    inbound_get_json() {
        printf '%s' '{"settings":{"clients":[{"id":"eeeeeeee-9999-8888-7777-666666666666","email":"user1"}]}}'
    }
    CLIENT_UUID_ACTUAL=""
    client_add user1 9 0 0 0 "xtls-rprx-vision" "ffffffff-0000-1111-2222-333333333333" || { echo "client_add باید موفق شود"; return 1; }
    assert_eq "eeeeeeee-9999-8888-7777-666666666666" "$CLIENT_UUID_ACTUAL" "UUID باید با پنل هماهنگ شود" || return 1
}

test_client_add_duplicate_recreates_via_delete_ladder() {
    # Regression: panels without the attach endpoint left the client off the
    # inbound entirely while links were still printed.
    local add_calls=0
    api_silent() { # verb path body
        case "$2" in
            */attach*) API_ERROR="404 page not found"; return 1 ;;
            */del/*) return 0 ;;
            */add)
                add_calls=$((add_calls+1))
                if ((add_calls == 1)); then API_ERROR="email already in use: user1"; return 1; fi
                return 0 ;;
            *) return 1 ;;
        esac
    }
    inbound_get_json() { printf '%s' '{"settings":{"clients":[]}}'; }
    CLIENT_UUID_ACTUAL=""
    client_add user1 9 0 0 0 "xtls-rprx-vision" "ffffffff-0000-1111-2222-333333333333" || { echo "client_add ladder باید موفق شود"; return 1; }
    assert_eq "2" "$add_calls" "دو بار تلاش add" || return 1
    assert_eq "ffffffff-0000-1111-2222-333333333333" "$CLIENT_UUID_ACTUAL" "UUID بازسازی" || return 1
}

test_sub_url_uses_panel_subpath_and_tls() {
    # Regression: newer panels serve sub at /{randomised subPath}/{subId} over
    # TLS; the hardcoded http://…/sub/{id} link 404'd on the real server.
    _PANEL_SUB_CACHE='{"subPath":"/82fum5xhiuic2p8x/","subPort":"2096","subDomain":"","subCertFile":"/etc/ssl/panel.crt","subTLS":"true"}'
    _PANEL_SUB_CACHE_AT="$(date +%s)"
    SERVER_IP="203.0.113.9"; SUB_PORT="2096"; SUB_PATH="/sub/"
    assert_eq "https://203.0.113.9:2096/82fum5xhiuic2p8x/ABC123" "$(sub_url ABC123)" "sub با subPath پنل" || return 1
}

test_sub_url_falls_back_to_legacy_path() {
    _PANEL_SUB_CACHE='{}'
    _PANEL_SUB_CACHE_AT="$(date +%s)"
    panel_settings_all() { printf '%s' ''; }
    SERVER_IP="203.0.113.9"; SUB_PORT="2096"; SUB_PATH="/sub/"
    assert_eq "http://203.0.113.9:2096/sub/ABC123" "$(sub_url ABC123)" "fallback قدیمی" || return 1
}
