#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: scripts/status.sh
#  خلاصهٔ وضعیت نصب: پنل، Xray، Inboundها، ترافیک، امنیت و پشتیبان‌ها
#
#  Usage:
#     vpn-sanai-status [--json] [--no-security]
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/load.sh
source "${SCRIPT_DIR}/../lib/load.sh"

JSON_OUT=0
WITH_SECURITY=1
while (($#)); do
    case "$1" in
        --json)          JSON_OUT=1; shift ;;
        --no-security)   WITH_SECURITY=0; shift ;;
        --debug)         VPN_SANAI_DEBUG=1; shift ;;
        -h|--help)       sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               die "گزینهٔ ناشناخته: $1" ;;
    esac
done

install_error_trap
require_root "$@"
load_state_runtime
detect_platform
ensure_panel_reachable

status_obj="$(api_get_obj "/panel/api/server/status" 2>/dev/null || echo '{}')"
inbounds="$(api_get_obj "/panel/api/inbounds/list" 2>/dev/null || echo '[]')"

if ((JSON_OUT)); then
    jq -nc \
        --argjson status "$status_obj" \
        --argjson inbounds "$inbounds" \
        --arg panel_url "${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}" \
        --arg server_ip "$SERVER_IP" \
        --arg vless_port "$VLESS_PORT" \
        --arg sni "$VLESS_SNI" \
        --arg version "$(panel_version 2>/dev/null || echo unknown)" \
        '{
            panel: {url: $panel_url, version: $version},
            xray: ($status.xray // {}),
            server: {ip: $server_ip, vless_port: ($vless_port|tonumber? // 0), sni: $sni},
            inbounds: [ $inbounds[] | {
                id, remark, port, protocol, enable,
                clients: ((.settings|fromjson?).clients // [] | length),
                up, down
            } ]
        }'
    exit 0
fi

print_rule "vpn-sanai — وضعیت"
kv "پنل" "${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH}"
kv "نسخهٔ پنل" "$(panel_version 2>/dev/null || echo unknown)"
kv "سرویس x-ui" "$(panel_service_status)"
kv "Xray" "$(printf '%s' "$status_obj" | jq -r '"\(.xray.state // "?")  نسخه \(.xray.version // "?")"')"
kv "آدرس سرور" "$SERVER_IP"
kv "پورت VLESS" "${VLESS_PORT:-?}"
kv "SNI" "${VLESS_SNI:-?}"

print_rule "Inboundها"
printf '  %s%-5s %-22s %-7s %-9s %-8s %s%s\n' \
    "$C_BOLD" "ID" "نام" "پورت" "پروتکل" "کلاینت" "حجم (GB)" "$C_RESET" >&2
printf '%s' "$inbounds" | jq -r '
    .[]? | [
        (.id|tostring),
        (.remark // "-"),
        (.port|tostring),
        .protocol,
        ((.settings|fromjson?).clients // [] | length | tostring),
        ((((.up // 0) + (.down // 0)) / 1073741824 * 100 | floor) / 100 | tostring)
    ] | @tsv' 2>/dev/null | while IFS=$'\t' read -r id remark port proto clients traffic; do
    printf '  %-5s %-22s %-7s %-9s %-8s %s\n' "$id" "$remark" "$port" "$proto" "$clients" "$traffic" >&2
done

if ((WITH_SECURITY)); then
    print_rule "امنیت"
    security_summary
    print_rule "پشتیبان‌گیری"
    backup_status
fi
print_rule ""
