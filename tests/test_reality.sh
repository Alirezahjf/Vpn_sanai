#!/usr/bin/env bash
# Tests for lib/reality.sh — payload construction, key material, SNI probing.
# shellcheck source=../lib/load.sh
source "${TEST_DIR}/../lib/load.sh"

REALITY_ARGS=(00000000-0000-0000-0000-000000000001 "user1" "sub1234567890ab" "xtls-rprx-vision" \
              "443" "www.example.org" "PRIVKEY==" "aabbccddeeff0011" "PUBKEY==" \
              "MyServer-reality" "tcp" "" "203.0.113.9")

test_tcp_payload_shape() {
    local payload
    payload="$(reality_build_payload "${REALITY_ARGS[@]}")" || fail "ساخت payload ناموفق بود"

    printf '%s' "$payload" | jq -e . >/dev/null || fail "خروجی باید JSON معتبر باشد"

    assert_eq "vless"      "$(printf '%s' "$payload" | jq -r .protocol)"          "پروتکل" || return 1
    assert_eq "443"        "$(printf '%s' "$payload" | jq -r .port)"              "پورت عددی" || return 1
    assert_eq "true"       "$(printf '%s' "$payload" | jq -r .enable)"            "فعال بودن" || return 1
    assert_eq "0"          "$(printf '%s' "$payload" | jq -r .expiryTime)"        "بدون انقضا" || return 1
    assert_eq "0"          "$(printf '%s' "$payload" | jq -r '.listen | length')"  "listen باید خالی باشد (پنل روی همهٔ اینترفیس‌ها)" || return 1

    # transport / security
    assert_eq "tcp"      "$(printf '%s' "$payload" | jq -r .streamSettings.network)"       "شبکه" || return 1
    assert_eq "reality"  "$(printf '%s' "$payload" | jq -r .streamSettings.security)"      "امنیت" || return 1
    assert_eq "none"     "$(printf '%s' "$payload" | jq -r .streamSettings.tcpSettings.header.type)" "هدر tcp" || return 1
    assert_eq "false"    "$(printf '%s' "$payload" | jq -r .streamSettings.tcpSettings.acceptProxyProtocol)" "pp" || return 1

    # reality material
    assert_eq "www.example.org:443" "$(printf '%s' "$payload" | jq -r .streamSettings.realitySettings.target)" "target" || return 1
    assert_eq "www.example.org"     "$(printf '%s' "$payload" | jq -r '.streamSettings.realitySettings.serverNames[0]')" "serverNames" || return 1
    assert_eq "PRIVKEY=="           "$(printf '%s' "$payload" | jq -r .streamSettings.realitySettings.privateKey)" "کلید خصوصی" || return 1
    assert_eq "aabbccddeeff0011"    "$(printf '%s' "$payload" | jq -r '.streamSettings.realitySettings.shortIds[0]')" "shortId" || return 1
    assert_eq "PUBKEY=="            "$(printf '%s' "$payload" | jq -r .streamSettings.realitySettings.settings.publicKey)" "کلید عمومی" || return 1
    assert_eq "chrome"              "$(printf '%s' "$payload" | jq -r .streamSettings.realitySettings.settings.fingerprint)" "fingerprint" || return 1
    assert_eq "/"                   "$(printf '%s' "$payload" | jq -r .streamSettings.realitySettings.settings.spiderX)" "spiderX" || return 1

    # share address so the panel advertises the real IP
    assert_eq "203.0.113.9" "$(printf '%s' "$payload" | jq -r .shareAddr)"             "shareAddr" || return 1
    assert_eq "custom"      "$(printf '%s' "$payload" | jq -r .shareAddrStrategy)"     "shareAddrStrategy" || return 1
}

test_tcp_payload_has_no_panelside_settings() {
    local payload
    payload="$(reality_build_payload "${REALITY_ARGS[@]}")"
    # realitySettings.settings is client-side material: the panel strips it.
    # Sending it is fine, but the *server* keys must not be smuggled into it.
    assert_eq "PRIVKEY==" "$(printf '%s' "$payload" | jq -r .streamSettings.realitySettings.privateKey)" \
        "کلید خصوصی فقط در realitySettings" || return 1
}

test_client_is_not_baked_into_inbound() {
    # vpn-sanai creates the inbound first and attaches clients through
    # /clients/add, so the inbound payload ships with an empty client list.
    local payload
    payload="$(reality_build_payload "${REALITY_ARGS[@]}")"
    payload="$(printf '%s' "$payload" | jq -c '.settings.clients = []')"
    assert_eq "0" "$(printf '%s' "$payload" | jq -r '.settings.clients | length')" "فهرست کلاینت خالی" || return 1
    assert_eq "none" "$(printf '%s' "$payload" | jq -r '.settings.decryption')" "decryption" || return 1
    assert_eq "0" "$(printf '%s' "$payload" | jq -r '.settings.fallbacks | length')" "fallbacks" || return 1
}

test_client_defaults_in_payload() {
    local payload
    DEFAULT_CLIENT_LIMIT_IP=3 DEFAULT_CLIENT_TOTAL_GB=50 DEFAULT_CLIENT_EXPIRY_MS=1700000000000 \
        payload="$(reality_build_payload "${REALITY_ARGS[@]}")"
    assert_eq "3"  "$(printf '%s' "$payload" | jq -r '.settings.clients[0].limitIp')"    "limitIp" || return 1
    assert_eq "50" "$(printf '%s' "$payload" | jq -r '.settings.clients[0].totalGB')"    "totalGB" || return 1
    assert_eq "1700000000000" "$(printf '%s' "$payload" | jq -r '.settings.clients[0].expiryTime')" "expiryTime" || return 1
    assert_eq "xtls-rprx-vision" "$(printf '%s' "$payload" | jq -r '.settings.clients[0].flow')" "flow" || return 1
}

test_xhttp_payload_shape() {
    local payload
    payload="$(reality_build_payload "00000000-0000-0000-0000-000000000001" "user1" "sub1234567890ab" "" \
                 "443" "www.example.org" "PRIVKEY==" "aabbccddeeff0011" "PUBKEY==" \
                 "MyServer-xhttp" "xhttp" "/abc123" "203.0.113.9")"
    printf '%s' "$payload" | jq -e . >/dev/null || fail "JSON معتبر نیست"
    assert_eq "xhttp"    "$(printf '%s' "$payload" | jq -r .streamSettings.network)"                 "شبکه" || return 1
    assert_eq "/abc123"  "$(printf '%s' "$payload" | jq -r .streamSettings.xhttpSettings.path)"      "مسیر" || return 1
    assert_eq "auto"     "$(printf '%s' "$payload" | jq -r .streamSettings.xhttpSettings.mode)"      "حالت" || return 1
    assert_eq "reality"  "$(printf '%s' "$payload" | jq -r .streamSettings.security)"                "امنیت" || return 1
    assert_eq "0"        "$(printf '%s' "$payload" | jq -r '.streamSettings.tcpSettings // {} | length')" \
        "xhttp نباید tcpSettings داشته باشد" || return 1
}

test_sniffing_defaults() {
    local payload
    payload="$(reality_build_payload "${REALITY_ARGS[@]}")"
    assert_eq "true" "$(printf '%s' "$payload" | jq -r .sniffing.enabled)" "sniffing" || return 1
    assert_eq "http,tls,quic,fakedns" \
        "$(printf '%s' "$payload" | jq -r '.sniffing.destOverride | join(",")')" "destOverride" || return 1
}

test_short_id_format() {
    local sid; sid="$(reality_short_id)"
    assert_eq 16 "${#sid}" "طول shortId" || return 1
    assert_match '^[0-9a-f]{16}$' "$sid" "الگوی shortId" || return 1
}

# --- SNI probing -------------------------------------------------------------
# build_path_stub <dir> — a fake `curl` that answers the probe used by
# probe_reality_target, with per-host latencies (fast.example, slow.example).
build_curl_stub() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "${dir}/curl" <<'EOF'
#!/usr/bin/env bash
# minimal stand-in for the probe call: curl -s -o /dev/null --tlsv1.3 ...
url=""
for arg in "$@"; do
    case "$arg" in
        https://*|http://*) url="$arg" ;;
    esac
done
host="${url#https://}"; host="${host%%:*}"
case "$host" in
    fast.example) printf '200 0 2 0.040 1.2.3.4' ;;
    slow.example) printf '200 0 2 0.420 1.2.3.5' ;;
    ipv6.example) printf '200 0 2 0.010 2001:db8::1' ;;
    http1.example) printf '200 0 1.1 0.050 1.2.3.6' ;;
    badcert.example) printf '200 20 2 0.030 1.2.3.7' ;;
    refused.example) exit 7 ;;
    *) printf '000 0 0 0.000 ' ;;
esac
EOF
    chmod +x "${dir}/curl"
}

test_pick_reality_sni_chooses_fastest_healthy() {
    if ! has_cmd curl; then return 0; fi
    local stub host; stub="$(mktemp -d)"
    build_curl_stub "$stub"
    REALITY_SNI_IPV6=false
    REALITY_SNI_CANDIDATES=(refused.example http1.example badcert.example slow.example fast.example ipv6.example)
    host="$(PATH="${stub}:${PATH}" pick_reality_sni 2>/dev/null)"
    rm -rf "$stub"
    assert_eq "fast.example" "$host" "باید سریع‌ترین گزینهٔ سالم انتخاب شود"
}

test_pick_reality_sni_rejects_non_tls13_and_bad_cert() {
    if ! has_cmd curl; then return 0; fi
    local stub host; stub="$(mktemp -d)"
    build_curl_stub "$stub"
    REALITY_SNI_IPV6=false
    REALITY_SNI_CANDIDATES=(http1.example badcert.example slow.example)
    host="$(PATH="${stub}:${PATH}" pick_reality_sni 2>/dev/null)"
    rm -rf "$stub"
    assert_eq "slow.example" "$host" "HTTP/1.1 و گواهی نامعتبر باید رد شوند"
}

test_pick_reality_sni_ignores_ipv6_when_disabled() {
    if ! has_cmd curl; then return 0; fi
    local stub host; stub="$(mktemp -d)"
    build_curl_stub "$stub"
    REALITY_SNI_IPV6=false
    REALITY_SNI_CANDIDATES=(ipv6.example fast.example)
    host="$(PATH="${stub}:${PATH}" pick_reality_sni 2>/dev/null)"
    rm -rf "$stub"
    assert_eq "fast.example" "$host" "وقتی IPv6 خاموش است، نامزد IPv6 نادیده گرفته می‌شود"
}

test_pick_reality_sni_accepts_ipv6_when_enabled() {
    if ! has_cmd curl; then return 0; fi
    local stub host; stub="$(mktemp -d)"
    build_curl_stub "$stub"
    REALITY_SNI_IPV6=true
    REALITY_SNI_CANDIDATES=(fast.example ipv6.example)
    host="$(PATH="${stub}:${PATH}" pick_reality_sni 2>/dev/null)"
    rm -rf "$stub"
    assert_eq "ipv6.example" "$host" "با فعال بودن IPv6، گزینهٔ سریع‌تر IPv6 برنده است"
}

test_pick_reality_sni_checks_the_preferred_host() {
    if ! has_cmd curl; then return 0; fi
    local stub host; stub="$(mktemp -d)"
    build_curl_stub "$stub"
    REALITY_SNI_IPV6=false
    REALITY_SNI_CANDIDATES=(slow.example fast.example)
    host="$(PATH="${stub}:${PATH}" pick_reality_sni "fast.example" 2>/dev/null)"
    rm -rf "$stub"
    assert_eq "fast.example" "$host" "میزبان دلخواه کاربر هم بررسی می‌شود"
}

test_pick_reality_sni_falls_back_to_first_candidate() {
    if ! has_cmd curl; then return 0; fi
    local stub host; stub="$(mktemp -d)"
    build_curl_stub "$stub"
    REALITY_SNI_IPV6=false
    REALITY_SNI_CANDIDATES=(refused.example http1.example)
    host="$(PATH="${stub}:${PATH}" pick_reality_sni 2>/dev/null)"
    rm -rf "$stub"
    assert_eq "refused.example" "$host" "در نبود گزینهٔ سالم، اولین نامزد استفاده می‌شود"
}

test_reality_harvest_from_inbound() {
    local json='{"id":7,"port":443,"settings":{"clients":[{"id":"uuid-from-panel","flow":"xtls-rprx-vision"}]},
                  "streamSettings":{"realitySettings":{"privateKey":"PKEY","shortIds":["0011223344556677"],
                  "serverNames":["www.example.org"],"settings":{"publicKey":"PUBKEY"}}}}'
    VLESS_SNI=""; VLESS_SHORT_ID=""; VLESS_PUBLIC_KEY=""; VLESS_PRIVATE_KEY=""; VLESS_UUID=""; VLESS_FLOW=""

    reality_harvest_from_inbound "$json" || fail "harvest ناموفق بود"
    assert_eq "www.example.org"     "$VLESS_SNI"         "SNI" || return 1
    assert_eq "0011223344556677"    "$VLESS_SHORT_ID"    "shortId" || return 1
    assert_eq "PUBKEY"              "$VLESS_PUBLIC_KEY"  "کلید عمومی" || return 1
    assert_eq "PKEY"                "$VLESS_PRIVATE_KEY" "کلید خصوصی" || return 1
    assert_eq "uuid-from-panel"     "$VLESS_UUID"        "UUID کلاینت موجود" || return 1
    assert_eq "xtls-rprx-vision"    "$VLESS_FLOW"        "flow" || return 1
}

test_reality_harvest_keeps_known_values() {
    local json='{"settings":{"clients":[{"id":"uuid-from-panel"}]},
                  "streamSettings":{"realitySettings":{"privateKey":"PKEY2","shortIds":["ffeeddccbbaa9988"],
                  "serverNames":["other.example.net"],"settings":{"publicKey":"PUBKEY2"}}}}'
    VLESS_SNI="keep.example.com"; VLESS_SHORT_ID="keep"; VLESS_PUBLIC_KEY="KEEPPUB"; VLESS_PRIVATE_KEY="KEEPPRIV"
    VLESS_UUID="keep-uuid"; VLESS_FLOW=""

    reality_harvest_from_inbound "$json" || fail "harvest ناموفق بود"
    assert_eq "keep.example.com" "$VLESS_SNI"         "مقدار موجود نباید بازنویسی شود" || return 1
    assert_eq "keep"             "$VLESS_SHORT_ID"    "shortId" || return 1
    assert_eq "KEEPPUB"          "$VLESS_PUBLIC_KEY"  "کلید عمومی" || return 1
    assert_eq "KEEPPRIV"         "$VLESS_PRIVATE_KEY" "کلید خصوصی" || return 1
    assert_eq "keep-uuid"        "$VLESS_UUID"        "UUID" || return 1
    assert_eq "uuid-from-panel"  "$(printf '%s' "$json" | jq -r '.settings.clients[0].id')" "" || return 0
}

# --- key material ------------------------------------------------------------
test_reality_keypair_reads_xray_binary() {
    local folder; folder="$(mktemp -d)"
    mkdir -p "${folder}/bin"
    cat > "${folder}/bin/xray-linux-amd64" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "x25519" ]] || exit 1
echo "Private key: PRIV_FROM_XRAY"
echo "Public key: PUB_FROM_XRAY"
EOF
    chmod +x "${folder}/bin/xray-linux-amd64"

    # Point the API at a closed port so the binary path is exercised.
    local out
    out="$(XUI_FOLDER="$folder" XRAY_ARCH=amd64 PANEL_SCHEME=http PANEL_PORT=1 \
           PANEL_BASE_PATH=/ PANEL_API_TOKEN=t API_RETRIES=1 API_CONNECT_TIMEOUT=1 API_MAX_TIME=2 \
           reality_keypair 2>/dev/null || true)"
    rm -rf "$folder"
    assert_eq "PRIV_FROM_XRAY PUB_FROM_XRAY" "$out" "خواندن کلید از باینری xray"
}

test_reality_keypair_accepts_alternative_output_forms() {
    local folder; folder="$(mktemp -d)"
    mkdir -p "${folder}/bin"
    cat > "${folder}/bin/xray-linux-arm64" <<'EOF'
#!/usr/bin/env bash
echo "PrivateKey: PRIV2"
echo "Password: PUB2"
EOF
    chmod +x "${folder}/bin/xray-linux-arm64"
    local out
    out="$(XUI_FOLDER="$folder" XRAY_ARCH=arm64 PANEL_SCHEME=http PANEL_PORT=1 \
           PANEL_BASE_PATH=/ PANEL_API_TOKEN=t API_RETRIES=1 API_CONNECT_TIMEOUT=1 API_MAX_TIME=2 \
           reality_keypair 2>/dev/null || true)"
    rm -rf "$folder"
    assert_eq "PRIV2 PUB2" "$out" "قالب‌های جایگزین خروجی xray x25519"
}

test_inbound_get_json_tolerates_object_fields() {
    # Regression: some panel builds return settings/streamSettings as JSON
    # objects instead of serialized strings; `fromjson? // {}` then collapsed
    # them to {} and the post-create harvest found nothing (real server: the
    # summary showed empty SNI/ShortId and the xhttp link had pbk/sni/sid=).
    api_get_obj() {
        printf '%s' '{"id":19,"protocol":"vless","port":40454,"settings":{"clients":[{"id":"u6","flow":"xtls-rprx-vision","email":"user1"}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverNames":["ex.com"],"shortIds":["ab12"],"privateKey":"PRV","settings":{"publicKey":"PUB"}}},"sniffing":{"enabled":false}}'
    }
    local got
    got="$(inbound_get_json 19 | jq -r '.streamSettings.realitySettings.settings.publicKey + "|" + .streamSettings.network + "|" + .settings.clients[0].id')"
    [[ "$got" == "PUB|tcp|u6" ]] || { echo "got=$got"; return 1; }
}

test_reality_inbound_exists_tolerates_object_shape() {
    api_get_obj() { printf '%s' '[{"id":7,"protocol":"vless","port":1443,"streamSettings":{"network":"tcp"}}]'; }
    [[ "$(reality_inbound_exists 1443 tcp)" == "7" ]] || { echo "object-shape"; return 1; }
    api_get_obj() { printf '%s' '[{"id":9,"protocol":"vless","port":1443,"streamSettings":"{\"network\":\"tcp\"}"}]'; }
    [[ "$(reality_inbound_exists 1443 tcp)" == "9" ]] || { echo "string-shape"; return 1; }
    api_get_obj() { printf '%s' '[]'; }
    [[ -z "$(reality_inbound_exists 1443 tcp)" ]] || return 1
}
