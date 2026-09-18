#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: scripts/show-clients.sh
#  نمایش لینک و QR همهٔ کلاینت‌های پنل
#
#  Usage:
#     vpn-sanai-clients [--email NAME] [--no-qr] [--json] [--usage]
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/load.sh
source "${SCRIPT_DIR}/../lib/load.sh"

FILTER=""
SHOW_QR=1
JSON_OUT=0
SHOW_USAGE=0

while (($#)); do
    case "$1" in
        --email|-e)  FILTER="${2:?}"; shift 2 ;;
        --no-qr)     SHOW_QR=0; shift ;;
        --json)      JSON_OUT=1; SHOW_QR=0; shift ;;
        --usage)     SHOW_USAGE=1; shift ;;
        --debug)     VPN_SANAI_DEBUG=1; shift ;;
        -h|--help)   sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           die "گزینهٔ ناشناخته: $1" ;;
    esac
done

install_error_trap
require_root "$@"
load_state_runtime
ensure_panel_reachable

# Gather every client email present in the panel. `/clients/list` returns the
# client rows; older builds only expose the inbounds, so both are supported.
emails="$(
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
)"

[[ -n "$emails" ]] || die "هیچ کلاینتی در پنل پیدا نشد"

((JSON_OUT)) && printf '[\n'
first=1
while read -r email; do
    [[ -n "$email" ]] || continue
    [[ -n "$FILTER" && "$email" != "$FILTER" ]] && continue

    info="$(client_info "$email" 2>/dev/null || true)"
    uuid="$(printf '%s' "${info:-{\}}" | jq -r '.client.id // .id // empty' 2>/dev/null || true)"
    [[ -n "$uuid" ]] || uuid="$VLESS_UUID"
    sub_id="$(printf '%s' "${info:-{\}}" | jq -r '.client.subId // .subId // empty' 2>/dev/null || true)"
    [[ -n "$sub_id" ]] || sub_id="$(client_sub_id "$email" 2>/dev/null || true)"

    link="$(build_vless_link "$uuid" "$SERVER_IP" "$VLESS_PORT" "tcp" \
            "$VLESS_SNI" "$VLESS_SHORT_ID" "$VLESS_PUBLIC_KEY" "$VLESS_FLOW" "$email")"
    sub=""; [[ -n "$sub_id" ]] && sub="$(sub_url "$sub_id")"

    save_client_link "$email" "$link" "$sub"

    if ((JSON_OUT)); then
        ((first)) || printf ',\n'
        first=0
        jq -nc --arg email "$email" --arg uuid "$uuid" --arg link "$link" --arg sub "$sub" \
           '{email:$email,uuid:$uuid,link:$link,subscription:$sub}'
        continue
    fi

    print_rule "کلاینت ${email}"
    kv "لینک" "$link"
    [[ -n "$sub" ]] && kv "لینک اشتراک" "$sub"
    if ((SHOW_USAGE)) && [[ -n "$info" ]]; then
        printf '%s' "$info" | jq -r '
            "  حجم مصرفی  : \(((.up // .client.up // 0) + (.down // .client.down // 0)) / 1073741824 * 100 | floor / 100) GB
  حجم کل     : \((.total // .client.totalGB // 0) as $t | if $t == 0 then "نامحدود" else (($t/1073741824*100|floor)/100|tostring) + " GB" end)
  انقضا      : \((.expiryTime // .client.expiryTime // 0) as $e | if $e == 0 then "نامحدود" else ($e/1000 | strftime("%Y-%m-%d")) end)"' 2>/dev/null || true
    fi
    ((SHOW_QR)) && show_qr "$link" "${VPN_SANAI_LINKS_DIR}/${email}.png" || true
done <<< "$emails"
((JSON_OUT)) && printf '\n]\n'

if ((!JSON_OUT)); then
    print_rule ""
    kv "فایل لینک‌ها" "${VPN_SANAI_LINKS_DIR}/links.txt"
fi
