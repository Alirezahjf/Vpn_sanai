#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: lib/clients.sh
#  Client lifecycle (create / list / delete), link building and QR output.
#
#  Link building is done locally on purpose: the panel's own link endpoint is
#  called over loopback, and without a domain + public listen address the panel
#  would fall back to the request host (127.0.0.1). The `shareAddr` we store on
#  the inbound covers the panel UI; this covers everything vpn-sanai prints.
# =============================================================================

# --- link helpers ------------------------------------------------------------
# link_host <host> -> IPv6 hosts need brackets inside vless:// URLs
link_host() {
    local host="$1"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

# build_vless_link <uuid> <host> <port> <network> <sni> <sid> <pubkey> <flow> <remark> [path] [mode]
build_vless_link() {
    local uuid="$1" host="$2" port="$3" network="$4" sni="$5" sid="$6" pub="$7"
    local flow="$8" remark="$9" path="${10:-}" mode="${11:-}"

    local query
    query="type=${network}&security=reality&pbk=$(url_encode "$pub")"
    query+="&fp=$(url_encode "${REALITY_FINGERPRINT:-chrome}")"
    query+="&sni=$(url_encode "$sni")&sid=$(url_encode "$sid")"
    query+="&spx=$(url_encode "${REALITY_SPIDER_X:-/}")"
    [[ -n "$flow" ]] && query+="&flow=$(url_encode "$flow")"
    if [[ "$network" == "xhttp" ]]; then
        query+="&path=$(url_encode "${path:-/}")"
        query+="&mode=$(url_encode "${mode:-auto}")&host=$(url_encode "$sni")"
    fi

    printf 'vless://%s@%s:%s?%s#%s' \
        "$uuid" "$(link_host "$host")" "$port" "$query" "$(url_encode "$remark")"
}

# build_client_link_from_state <email> -> uses the state file (single inbound)
build_client_link_from_state() {
    local email="${1:-$DEFAULT_CLIENT_EMAIL}"
    local uuid_override="${2:-}"
    local uuid host port network sni sid pub flow remark path mode
    uuid="${uuid_override:-${VLESS_UUID:-$(state_get VLESS_UUID)}}"
    host="${SERVER_IP:-$(state_get SERVER_IP)}"
    port="${VLESS_PORT:-$(state_get VLESS_PORT)}"
    sni="${VLESS_SNI:-$(state_get VLESS_SNI)}"
    sid="${VLESS_SHORT_ID:-$(state_get VLESS_SHORT_ID)}"
    pub="${VLESS_PUBLIC_KEY:-$(state_get VLESS_PUBLIC_KEY)}"
    flow="${VLESS_FLOW:-$(state_get VLESS_FLOW)}"
    remark="${VLESS_REMARK:-$(state_get VLESS_REMARK)}"
    network="tcp"; path=""; mode=""

    [[ -n "$uuid" && -n "$host" && -n "$port" && -n "$pub" ]] || return 1
    printf '%s' "$(build_vless_link "$uuid" "$host" "$port" "$network" "$sni" "$sid" "$pub" "$flow" "$remark")"
}

# --- panel API wrappers ------------------------------------------------------
client_list() {
    api_get_obj "/panel/api/clients/list"
}

# client_add <email> <inbound-id> [totalGB] [expiryDays] [limitIp] [flow] [uuid]
# A caller-supplied uuid is honoured by the panel; that keeps the LINK we print
# in sync with the identity stored server-side.
client_add() {
    local email="$1" inbound_id="$2"
    local total_gb="${3:-${DEFAULT_CLIENT_TOTAL_GB:-0}}"
    local expiry_days="${4:-${DEFAULT_CLIENT_EXPIRY_DAYS:-0}}"
    local limit_ip="${5:-${DEFAULT_CLIENT_LIMIT_IP:-0}}"
    local flow="${6:-}"
    local uuid="${7:-}"

    local expiry_ms=0
    if [[ "$expiry_days" =~ ^[0-9]+$ ]] && ((expiry_days > 0)); then
        expiry_ms=$(( ( $(date +%s) + expiry_days * 86400 ) * 1000 ))
    fi

    local body
    body="$(jq -nc \
        --arg email "$email" --arg flow "$flow" --arg uuid "$uuid" \
        --argjson total_gb "$total_gb" --argjson expiry "$expiry_ms" \
        --argjson limit_ip "$limit_ip" --argjson inbound_id "$inbound_id" \
        '{
            client: ({
                email: $email,
                flow: $flow,
                totalGB: $total_gb,
                expiryTime: $expiry,
                limitIp: $limit_ip,
                enable: true,
                tgId: 0,
                comment: ""
            } + (if $uuid == "" then {} else {id: $uuid} end)),
            inboundIds: [$inbound_id]
        }')" || return 1

    if api_silent POST "/panel/api/clients/add" "$body"; then
        log_ok "کلاینت «${email}» ساخته و به Inbound ${inbound_id} متصل شد"
        return 0
    fi

    # Already present? attach it to the inbound instead of failing.
    if printf '%s' "${API_ERROR:-}" | grep -qiE 'exist|duplicate|تکراری'; then
        log_warn "کلاینت «${email}» از قبل وجود دارد؛ به Inbound ${inbound_id} متصل می‌شود"
        local attach
        attach="$(jq -nc --argjson id "$inbound_id" '{inboundIds:[$id]}')"
        if api_silent POST "/panel/api/clients/$(url_encode "$email")/attach" "$attach"; then
            log_ok "کلاینت «${email}» به Inbound ${inbound_id} متصل شد"
            return 0
        fi
    fi

    log_error "ساخت کلاینت «${email}» ناموفق بود: ${API_ERROR:-خطای نامشخص}"
    return 1
}

client_delete() {
    local email="$1"
    if api_silent POST "/panel/api/clients/del/$(url_encode "$email")"; then
        log_ok "کلاینت «${email}» حذف شد"
    else
        log_error "حذف کلاینت ناموفق بود: ${API_ERROR:-خطای نامشخص}"
        return 1
    fi
}

# client_links_api <email> -> one URL per line (panel side view)
client_links_api() {
    local email="$1" obj
    obj="$(api_get_obj "/panel/api/clients/links/$(url_encode "$email")" 2>/dev/null || true)"
    [[ -n "$obj" ]] || return 1
    printf '%s' "$obj" | jq -r '.[]?' 2>/dev/null
}

# client_info <email> -> jq object with traffic/expiry, empty when unknown
client_info() {
    local email="$1"
    api_get_obj "/panel/api/clients/get/$(url_encode "$email")" 2>/dev/null || true
}

client_sub_id() {
    local email="$1"
    local info
    info="$(client_info "$email")" || return 1
    [[ -n "$info" ]] || return 1
    printf '%s' "$info" | jq -r '.client.subId // .subId // empty'
}

# --- presentation ------------------------------------------------------------
sub_url() {
    local sub_id="$1"
    local host="${SERVER_IP:-$(state_get SERVER_IP)}"
    local port="${SUB_PORT:-$(state_get SUB_PORT)}"
    local path="${SUB_PATH:-$(state_get SUB_PATH)}"
    [[ -n "$sub_id" && -n "$host" ]] || return 1
    printf 'http://%s:%s%s%s' "$(link_host "$host")" "$port" "${path%/}" "/${sub_id}"
}

# show_qr <text> [file.png] -> terminal QR plus an optional PNG copy
show_qr() {
    local text="$1" png_file="${2:-}"
    if has_cmd qrencode; then
        if [[ -n "$png_file" ]]; then
            qrencode -o "$png_file" -s 6 -m 2 "$text" 2>/dev/null || true
        fi
        if [[ -t 1 ]]; then
            qrencode -t ANSIUTF8 -m 1 "$text" 2>/dev/null || qrencode -t UTF8 "$text" 2>/dev/null || true
        fi
        return 0
    fi
    log_debug "qrencode موجود نیست؛ QR نمایش داده نمی‌شود"
    return 1
}

# save_client_link <email> <link> [sub-url]
save_client_link() {
    local email="$1" link="$2" sub="${3:-}"
    ensure_dir "$VPN_SANAI_LINKS_DIR" 700

    atomic_write "${VPN_SANAI_LINKS_DIR}/${email}.txt" 600 "# ${email}
# generated by ${VPN_SANAI_NAME} $(date '+%Y-%m-%d %H:%M:%S')

${link}
${sub:+
Subscription:
${sub}
}"
    # Central index, handy for the admin
    local index="${VPN_SANAI_LINKS_DIR}/links.txt"
    {
        [[ -f "$index" ]] && { grep -v "^${email}[[:space:]]" "$index" 2>/dev/null || true; }
        printf '%s\t%s\n' "$email" "$link"
    } > "${index}.tmp" && mv -f "${index}.tmp" "$index" && chmod 600 "$index"
}

# print_client_link <email> -> link + QR + subscription URL
print_client_link() {
    local email="$1"
    local link sub uuid info
    # Every client carries its own UUID; read it back so the QR we print can
    # never point at a stale identity.
    info="$(client_info "$email" 2>/dev/null || true)"
    if [[ -n "$info" ]]; then
        uuid="$(printf '%s' "$info" | jq -r '.client.id // .id // empty' 2>/dev/null || true)"
    fi
    link="$(build_client_link_from_state "$email" "${uuid:-}" || true)"
    sub="$(client_sub_id "$email" 2>/dev/null || true)"

    if [[ -z "$link" ]]; then
        log_warn "لینک محلی ساخته نشد؛ سراغ API پنل می‌روم"
        link="$(client_links_api "$email" | head -1 || true)"
    fi
    [[ -n "$link" ]] || { log_error "لینکی برای ${email} پیدا نشد"; return 1; }

    printf '\n' >&2
    kv "نام کلاینت" "$email"
    kv "لینک" "$link"
    if [[ -n "$sub" ]]; then
        kv "لینک اشتراک" "$(sub_url "$sub")"
    fi
    printf '\n' >&2
    show_qr "$link" "${VPN_SANAI_LINKS_DIR}/${email}.png" || true
    save_client_link "$email" "$link" "${sub:+$(sub_url "$sub")}"
    printf '\n' >&2
}
