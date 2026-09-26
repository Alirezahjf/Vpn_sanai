#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: lib/reality.sh
#  VLESS + REALITY: key material, SNI/target selection and inbound creation.
#
#  Why these defaults:
#    * VLESS + xtls-rprx-vision over TCP still has the best anti-DPI record,
#      and REALITY removes the need for a domain or a server certificate.
#    * The `target`/SNI must be a TLS 1.3 + HTTP/2 host reachable from *the
#      server* that looks unremarkable to censors. Candidates are probed and
#      the fastest healthy one wins (see pick_reality_sni).
#    * realitySettings.settings (publicKey/fingerprint/spiderX) is stripped by
#      the panel before the config reaches xray: it is client-side material and
#      is kept in the payload only so links can be built from the inbound.
# =============================================================================

# --- key material ------------------------------------------------------------
# reality_keypair -> prints "<private> <public>"
# Primary source: the panel API (arch independent). Fallback: bundled xray.
reality_keypair() {
    local obj priv pub

    obj="$(api_get_obj "/panel/api/server/getNewX25519Cert" 2>/dev/null || true)"
    if [[ -n "$obj" ]]; then
        priv="$(printf '%s' "$obj" | jq -r '.privateKey // empty')"
        pub="$(printf '%s' "$obj" | jq -r '.publicKey // empty')"
        if [[ -n "$priv" && -n "$pub" ]]; then
            printf '%s %s' "$priv" "$pub"
            return 0
        fi
    fi

    local xray_bin="" candidate
    for candidate in "${XUI_FOLDER}/bin/xray-linux-${XRAY_ARCH}" "${XUI_FOLDER}/bin/xray"; do
        [[ -x "$candidate" ]] && { xray_bin="$candidate"; break; }
    done
    if [[ -n "$xray_bin" ]]; then
        local out
        out="$("$xray_bin" x25519 2>/dev/null || true)"
        priv="$(printf '%s\n' "$out" | sed -nE 's/^(Private key|PrivateKey|Private):[[:space:]]*//Ip' | head -1 | tr -d '\r')"
        pub="$(printf '%s\n' "$out" | sed -nE 's/^(Public key|Password|PublicKey):[[:space:]]*//Ip' | head -1 | tr -d '\r')"
        if [[ -n "$priv" && -n "$pub" ]]; then
            printf '%s %s' "$priv" "$pub"
            return 0
        fi
    fi
    return 1
}

reality_short_id() {
    # 16 hex chars: the shape the panel UI generates (any even-length hex works).
    rand_hex 8
}

# --- validation --------------------------------------------------------------
# reality_sni_valid <sni> -> 0 when the value can be used as a REALITY SNI.
# Xray refuses to build a REALITY inbound whose serverNames is empty, and the
# panel happily stores it anyway — the server then dies on the next xray start
# with `infra/conf: empty "serverNames"`, taking *every* inbound down with it.
# So the value is validated here, before anything is sent to the panel.
reality_sni_valid() {
    local sni="${1-}"
    [[ -n "$sni" ]] || return 1
    # Values read from files/command substitution can carry a trailing newline
    # or padding, and REALITY matches the SNI byte for byte.
    [[ "$sni" == "${sni//[[:space:]]/}" ]] || return 1
    (( ${#sni} <= 253 )) || return 1
    # A bare hostname: dot separated labels, no scheme, port or path.
    [[ "$sni" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

# --- SNI / target selection --------------------------------------------------
# probe_reality_target <host> [port] [timeout] -> prints RTT in ms
# Requires TLS 1.3, HTTP/2, a certificate this server can validate, and (unless
# REALITY_SNI_IPV6=true) an IPv4 endpoint.
probe_reality_target() {
    local host="$1" port="${2:-$REALITY_TARGET_PORT}" timeout="${3:-6}"
    has_cmd curl || return 1

    local out code verify http_ver tt remote_ip
    out="$(curl -s -o /dev/null --max-time "$timeout" --tlsv1.3 --http2 \
            -w '%{http_code} %{ssl_verify_result} %{http_version} %{time_total} %{remote_ip}' \
            "https://${host}:${port}/" 2>/dev/null || true)"
    [[ -n "$out" ]] || return 1

    read -r code verify http_ver tt remote_ip <<< "$out"
    [[ "$code" =~ ^[23] ]] || return 1
    [[ "$verify" == "0" ]] || return 1
    [[ "$http_ver" == "2" || "$http_ver" == "2.0" ]] || return 1
    if [[ "$REALITY_SNI_IPV6" != "true" && "$remote_ip" == *:* ]]; then
        return 1
    fi

    awk -v t="$tt" 'BEGIN { printf "%d", t * 1000 }'
}

# pick_reality_sni [preferred] -> prints the chosen host
pick_reality_sni() {
    local preferred="${1:-}"
    local host rtt best_host="" best_rtt=999999
    local -a candidates=() unique=()

    [[ -n "$preferred" ]] && candidates+=("$preferred")
    candidates+=("${REALITY_SNI_CANDIDATES[@]+"${REALITY_SNI_CANDIDATES[@]}"}")

    for host in "${candidates[@]}"; do
        [[ -n "$host" ]] || continue
        local dupe=0 existing
        for existing in "${unique[@]+"${unique[@]}"}"; do
            [[ "$existing" == "$host" ]] && dupe=1
        done
        ((dupe)) || unique+=("$host")
    done

    log_step "انتخاب بهترین SNI/Target برای REALITY (${#unique[@]} گزینه)"
    for host in "${unique[@]}"; do
        rtt="$(probe_reality_target "$host" 2>/dev/null || true)"
        if [[ -n "$rtt" && "$rtt" =~ ^[0-9]+$ ]]; then
            log_info "  ${host} → ${rtt}ms ✓"
            if ((rtt < best_rtt)); then
                best_rtt="$rtt"; best_host="$host"
            fi
        else
            log_debug "  ${host}: TLS1.3/HTTP2 معتبر نداشت"
        fi
    done

    if [[ -z "$best_host" ]]; then
        best_host="${unique[0]:-www.microsoft.com}"
        log_warn "هیچ میزبانی معیارها را پاس نکرد؛ ${best_host} استفاده می‌شود (در صورت بروز مشکل SNI را در پنل تغییر دهید)"
    else
        log_ok "SNI انتخاب‌شده: ${best_host} (${best_rtt}ms)"
    fi
    printf '%s' "$best_host"
}

# --- inbound payload ---------------------------------------------------------
# reality_build_payload <uuid> <email> <subid> <flow> <port> <sni> <priv> <sid> <pub>
#                       [remark] [network] [xhttp-path] [share-addr]
# Prints the complete /panel/api/inbounds/add body.
reality_build_payload() {
    local uuid="$1" email="$2" subid="$3" flow="$4" port="$5" sni="$6"
    local priv="$7" sid="$8" pub="$9"
    local remark="${10:-VLESS-Reality}" network="${11:-tcp}" xhttp_path="${12:-}"
    local share_addr="${13:-${SERVER_IP:-}}"

    local settings stream reality_settings

    # Fail before touching the panel: an inbound the panel accepts but xray
    # rejects is worse than no inbound at all, because the whole config then
    # fails to load and every other inbound goes down with it.
    reality_sni_valid "$sni" ||
        die "SNI نامعتبر است: «${sni}» — REALITY بدون serverNames معتبر کار نمی‌کند (خطای xray: empty \"serverNames\"). با --sni HOST یک میزبان معتبر بدهید."
    [[ -n "$priv" ]] || die "کلید خصوصی REALITY خالی است (privateKey)"
    [[ -n "$sid" ]]  || die "shortId خالی است"

    settings="$(jq -nc \
        --arg id "$uuid" --arg email "$email" --arg subid "$subid" --arg flow "$flow" \
        --argjson limit_ip "${DEFAULT_CLIENT_LIMIT_IP:-0}" \
        --argjson total_gb "${DEFAULT_CLIENT_TOTAL_GB:-0}" \
        --argjson expiry_ms "${DEFAULT_CLIENT_EXPIRY_MS:-0}" \
        '{
            clients: [{
                id: $id,
                email: $email,
                subId: $subid,
                flow: $flow,
                limitIp: $limit_ip,
                totalGB: $total_gb,
                expiryTime: $expiry_ms,
                enable: true,
                tgId: 0,
                comment: ""
            }],
            decryption: "none",
            fallbacks: []
        }')" || die "ساخت JSON کلاینت ناموفق بود"

    reality_settings="$(jq -nc \
        --arg target "${sni}:${REALITY_TARGET_PORT}" --arg sni "$sni" \
        --arg priv "$priv" --arg sid "$sid" --arg pub "$pub" \
        --arg fp "$REALITY_FINGERPRINT" --arg spx "$REALITY_SPIDER_X" \
        --argjson maxdiff "${REALITY_MAX_TIME_DIFF:-0}" \
        '{
            show: false,
            xver: 0,
            target: $target,
            serverNames: [$sni],
            privateKey: $priv,
            maxTimediff: $maxdiff,
            shortIds: [$sid],
            settings: {
                publicKey: $pub,
                fingerprint: $fp,
                serverName: "",
                spiderX: $spx
            }
        }')" || die "ساخت JSON تنظیمات REALITY ناموفق بود"

    if [[ "$network" == "xhttp" ]]; then
        stream="$(jq -nc --argjson reality "$reality_settings" \
            --arg path "$xhttp_path" --arg mode "${XHTTP_MODE:-auto}" \
            '{
                network: "xhttp",
                security: "reality",
                realitySettings: $reality,
                xhttpSettings: { path: $path, host: "", mode: $mode, extra: {} }
            }')" || die "ساخت JSON انتقال xhttp ناموفق بود"
    else
        stream="$(jq -nc --argjson reality "$reality_settings" \
            '{
                network: "tcp",
                security: "reality",
                realitySettings: $reality,
                tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } }
            }')" || die "ساخت JSON انتقال tcp ناموفق بود"
    fi

    jq -nc \
        --arg remark "$remark" --arg port "$port" \
        --argjson settings "$settings" --argjson stream "$stream" \
        --arg share "$share_addr" \
        '{
            up: 0, down: 0, total: 0,
            remark: $remark,
            enable: true,
            expiryTime: 0,
            listen: "",
            port: ($port | tonumber),
            protocol: "vless",
            settings: $settings,
            streamSettings: $stream,
            sniffing: {
                enabled: true,
                destOverride: ["http", "tls", "quic", "fakedns"],
                metadataOnly: false,
                routeOnly: false
            },
            allocate: { strategy: "always", refresh: 5, concurrency: 3 },
            shareAddrStrategy: (if $share == "" then "node" else "custom" end),
            shareAddr: $share
        }'
}

# reality_create_inbound <payload> -> prints the new inbound id
reality_create_inbound() {
    local payload="$1" obj id
    obj="$(api_post_obj "/panel/api/inbounds/add" "$payload")" || return 1
    id="$(printf '%s' "$obj" | jq -r '.id // empty')"
    if [[ -z "$id" ]]; then
        log_error "پنل شناسهٔ Inbound را برنگرداند: $(printf '%s' "$obj" | head -c 200)"
        return 1
    fi
    printf '%s' "$id"
}

# reality_inbound_exists <port> [network] -> prints the id of a matching VLESS
# REALITY inbound already listening on that port (keeps re-runs idempotent)
reality_inbound_exists() {
    local port="$1" network="${2:-tcp}" list
    list="$(api_get_obj "/panel/api/inbounds/list" 2>/dev/null || true)"
    [[ -n "$list" ]] || return 1
    printf '%s' "$list" | jq -r --arg p "$port" --arg net "$network" '
        def norm: if type == "string" then (fromjson? // {}) else (. // {}) end;
        .[]?
        | select(.protocol == "vless")
        | select((.port|tostring) == $p)
        | select((.streamSettings | norm | .network) == $net)
        | .id' 2>/dev/null | head -1
}

# inbound_get_json <id> -> normalised inbound (settings/streamSettings parsed)
inbound_get_json() {
    local id="$1"
    api_get_obj "/panel/api/inbounds/get/${id}" | jq -c '
        def norm: if type == "string" then (fromjson? // {}) else (. // {}) end;
        . as $i
        | $i
        + { settings: ($i.settings | norm),
            streamSettings: ($i.streamSettings | norm),
            sniffing: ($i.sniffing | norm) }'
}

# reality_harvest_from_inbound <inbound-json>
# Fills the VLESS_* globals from an inbound that already exists, but never
# overwrites a value that is already known. This is what makes a re-run (or a
# host whose state file was lost) produce links that match what xray serves.
reality_harvest_from_inbound() {
    local json="$1"
    [[ -n "$json" ]] || return 1

    VLESS_SNI="${VLESS_SNI:-$(printf '%s' "$json" | jq -r '.streamSettings.realitySettings.serverNames[0] // empty')}"
    VLESS_SHORT_ID="${VLESS_SHORT_ID:-$(printf '%s' "$json" | jq -r '.streamSettings.realitySettings.shortIds[0] // empty')}"
    VLESS_PRIVATE_KEY="${VLESS_PRIVATE_KEY:-$(printf '%s' "$json" | jq -r '.streamSettings.realitySettings.privateKey // empty')}"
    # realitySettings.settings is an object in current panels, but tolerate
    # builds that return it string-encoded.
    VLESS_PUBLIC_KEY="${VLESS_PUBLIC_KEY:-$(printf '%s' "$json" | jq -r \
        '.streamSettings.realitySettings.settings | if type == "string" then (fromjson? // {}) else (. // {}) end | .publicKey // empty')}"

    local first_uuid first_flow
    first_uuid="$(printf '%s' "$json" | jq -r '.settings.clients[0].id // empty')"
    first_flow="$(printf '%s' "$json" | jq -r '.settings.clients[0].flow // empty')"
    if [[ -n "$first_uuid" && -z "${VLESS_UUID:-}" ]]; then
        VLESS_UUID="$first_uuid"
    fi
    if [[ -n "$first_flow" && -z "${VLESS_FLOW:-}" ]]; then
        VLESS_FLOW="$first_flow"
    fi
    return 0
}

# inbound_set_share_addr <id> <ip> -> make the panel advertise the public IP
# for links/QR it builds itself (the API is reached over loopback).
inbound_set_share_addr() {
    local id="$1" ip="$2"
    [[ -n "$ip" ]] || return 0

    local inbound body
    inbound="$(inbound_get_json "$id" 2>/dev/null || true)"
    [[ -n "$inbound" ]] || return 0

    if [[ "$(printf '%s' "$inbound" | jq -r '.shareAddr // ""')" == "$ip" ]]; then
        return 0
    fi

    body="$(printf '%s' "$inbound" | jq -c \
        --arg ip "$ip" '
        {
            up: (.up // 0), down: (.down // 0), total: (.total // 0),
            remark: (.remark // ""), enable: (.enable // true),
            expiryTime: (.expiryTime // 0), listen: (.listen // ""),
            port: .port, protocol: .protocol,
            settings: .settings, streamSettings: .streamSettings,
            sniffing: .sniffing,
            allocate: (.allocate // {strategy:"always",refresh:5,concurrency:3}),
            shareAddrStrategy: "custom", shareAddr: $ip
        }')" || return 0

    if api_silent POST "/panel/api/inbounds/update/${id}" "$body"; then
        log_debug "shareAddr=${ip} روی inbound ${id} ثبت شد"
    else
        log_debug "ثبت shareAddr ناموفق بود (لینک‌ها به‌صورت محلی ساخته می‌شوند)"
    fi
}

# --- doctor / repair ---------------------------------------------------------
# reality_broken_inbounds <inbounds-json> -> prints "<id>\t<problem>" for every
# REALITY inbound that xray would refuse to load.
#
# Xray validates the *whole* config at start-up, so one inbound with an empty
# serverNames keeps every inbound (and therefore every client) offline. The
# panel does not validate these fields, so the damage is invisible until the
# "Xray خطا" badge shows up in the dashboard.
reality_broken_inbounds() {
    local list="${1:-[]}"
    printf '%s' "$list" | jq -r '
        def norm: if type == "string" then (fromjson? // {}) else (. // {}) end;
        def clean: tostring | gsub("^[[:space:]]+|[[:space:]]+$"; "");
        def names: (.serverNames // []) | (if type == "array" then . else [] end);
        def blank_names: names
            | map(select(. != null and (. | clean) != "")) | length;
        .[]?
        | . as $i
        | ($i.streamSettings | norm) as $s
        | select(($s.security // "") == "reality")
        | ($s.realitySettings // {}) as $r
        | if ($r | blank_names) == 0 then "\($i.id | tostring)\tserverNames"
          elif (($r.target // "") | clean) == "" then "\($i.id | tostring)\ttarget"
          elif (($r.privateKey // "") | clean) == "" then "\($i.id | tostring)\tprivateKey"
          else empty end' 2>/dev/null || true
}

# reality_health_warning -> loud warning when a REALITY inbound would keep xray
# from starting. Never fails: it is called from status output, where a dead
# panel must not turn into a broken status command.
reality_health_warning() {
    panel_installed 2>/dev/null || return 0
    [[ -n "${PANEL_API_TOKEN:-}" ]] || return 0

    local list broken
    list="$(api_get_obj "/panel/api/inbounds/list" 2>/dev/null || true)"
    [[ -n "$list" ]] || return 0
    broken="$(reality_broken_inbounds "$list")"
    [[ -n "$broken" ]] || return 0

    log_warn "Inbound REALITY ناقص — xray استارت نمی‌خورد: $(printf '%s' "$broken" | tr '\t' ' ' | tr '\n' ' ')"
    log_warn "ترمیم سریع:  vpn-sanai --fix-reality"
    return 0
}

# reality_repair_inbounds [sni] -> fix every broken REALITY inbound and restart
# xray. The SNI is taken from the argument, then the state file, then a fresh
# probe. Returns 0 only when the panel no longer holds a broken inbound.
reality_repair_inbounds() {
    local sni="${1:-}"

    local list
    list="$(api_get_obj "/panel/api/inbounds/list" 2>/dev/null || true)"
    if [[ -z "$list" ]]; then
        log_error "فهرست Inboundها از پنل خوانده نشد"
        return 1
    fi

    local -a targets=()
    local id problem
    while IFS=$'\t' read -r id problem; do
        [[ -n "$id" ]] && targets+=("$id")
    done < <(reality_broken_inbounds "$list")

    if ((${#targets[@]} == 0)); then
        log_ok "همهٔ Inboundهای REALITY سالم هستند"
        return 0
    fi

    log_warn "${#targets[@]} Inbound REALITY ناقص پیدا شد (xray بدون serverNames استارت نمی‌خورد)"

    reality_sni_valid "$sni" || sni="${VLESS_SNI:-}"
    reality_sni_valid "$sni" || sni="$(pick_reality_sni "" 2>/dev/null || true)"
    if ! reality_sni_valid "$sni"; then
        log_error "SNI معتبری برای ترمیم پیدا نشد؛ با  --sni HOST  یک میزبان بدهید"
        return 1
    fi
    log_info "SNI مورد استفاده برای ترمیم: ${sni}"

    local fixed=0 failed=0 inbound body
    for id in "${targets[@]}"; do
        inbound="$(inbound_get_json "$id" 2>/dev/null || true)"
        if [[ -z "$inbound" ]]; then
            log_error "Inbound ${id} خوانده نشد"
            failed=$((failed + 1))
            continue
        fi

        # Same shape inbound_set_share_addr uses (the panel replaces the row),
        # with serverNames/target filled in only where they are broken.
        body="$(printf '%s' "$inbound" | jq -c \
            --arg sni "$sni" --arg tport "${REALITY_TARGET_PORT:-443}" '
            def clean: tostring | gsub("^[[:space:]]+|[[:space:]]+$"; "");
            {
                up: (.up // 0), down: (.down // 0), total: (.total // 0),
                remark: (.remark // ""), enable: (.enable // true),
                expiryTime: (.expiryTime // 0), listen: (.listen // ""),
                port: .port, protocol: .protocol,
                settings: .settings, streamSettings: .streamSettings,
                sniffing: .sniffing,
                allocate: (.allocate // {strategy: "always", refresh: 5, concurrency: 3}),
                shareAddrStrategy: (.shareAddrStrategy // "node"),
                shareAddr: (.shareAddr // "")
            }
            | .streamSettings.realitySettings = (
                (.streamSettings.realitySettings // {})
                | (if (((.serverNames // []) | (if type == "array" then . else [] end)
                        | map(select(. != null and (. | clean) != "")) | length) == 0)
                   then .serverNames = [$sni] else . end)
                | (if ((.target // "") | clean) == ""
                   then .target = ($sni + ":" + $tport) else . end)
              )' 2>/dev/null)" || body=""

        if [[ -z "$body" ]]; then
            log_error "ساخت بدنهٔ ترمیم برای Inbound ${id} ناموفق بود"
            failed=$((failed + 1))
            continue
        fi

        if api_silent POST "/panel/api/inbounds/update/${id}" "$body"; then
            log_ok "Inbound ${id} ترمیم شد (serverNames=${sni})"
            fixed=$((fixed + 1))
        else
            log_error "به‌روزرسانی Inbound ${id} ناموفق بود: ${API_ERROR:-نامشخص}"
            failed=$((failed + 1))
        fi
    done

    ((failed == 0)) || log_warn "${failed} Inbound ترمیم نشد"

    log_info "راه‌اندازی مجدد Xray"
    xray_restart

    # The panel keeps serving a broken config until xray accepts it, so verify.
    sleep "${REALITY_REPAIR_WAIT:-2}"
    local after
    after="$(reality_broken_inbounds "$(api_get_obj "/panel/api/inbounds/list" 2>/dev/null || echo '[]')")"
    if [[ -n "$after" ]]; then
        log_error "هنوز Inbound ناقص باقی است: $(printf '%s' "$after" | tr '\t' ' ' | tr '\n' ' ')"
        return 1
    fi
    log_ok "پیکربندی REALITY سالم شد و Xray راه‌اندازی مجدد شد (${fixed} Inbound ترمیم شد)"
    return 0
}
