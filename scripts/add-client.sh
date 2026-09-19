#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: scripts/add-client.sh
#  افزودن کلاینت به پنل و نمایش لینک/QR
#
#  Usage:
#     vpn-sanai-add-client --email ali [--days 30] [--gb 50] [--ip-limit 2]
#                         [--inbound ID] [--no-qr] [--json]
#
#  بدون آرگومان، نام کاربری از شما پرسیده می‌شود.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/load.sh
source "${SCRIPT_DIR}/../lib/load.sh"

EMAIL=""
DAYS="$DEFAULT_CLIENT_EXPIRY_DAYS"
GB="$DEFAULT_CLIENT_TOTAL_GB"
IP_LIMIT="$DEFAULT_CLIENT_LIMIT_IP"
INBOUND=""
SHOW_QR=1
JSON_OUT=0

usage() {
    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while (($#)); do
    case "$1" in
        --email|-e)   EMAIL="${2:?}"; shift 2 ;;
        --days|-d)    DAYS="${2:?}"; shift 2 ;;
        --gb|-g)      GB="${2:?}"; shift 2 ;;
        --ip-limit)   IP_LIMIT="${2:?}"; shift 2 ;;
        --inbound|-i) INBOUND="${2:?}"; shift 2 ;;
        --no-qr)      SHOW_QR=0; shift ;;
        --json)       JSON_OUT=1; SHOW_QR=0; shift ;;
        --yes|-y)     VPN_SANAI_NONINTERACTIVE=1; export VPN_SANAI_NONINTERACTIVE; shift ;;
        --debug)      VPN_SANAI_DEBUG=1; shift ;;
        -h|--help)    usage 0 ;;
        *)            die "گزینهٔ ناشناخته: $1" ;;
    esac
done

install_error_trap
require_root "$@"
acquire_lock
load_state_runtime

if [[ -z "$EMAIL" ]]; then
    ask EMAIL "نام کلاینت (ایمیل/برچسب یکتا)" "user$(rand_string 4 '0-9')"
fi
[[ -n "$EMAIL" ]] || die "نام کلاینت نمی‌تواند خالی باشد"

if [[ -z "$INBOUND" ]]; then
    INBOUND="$VLESS_INBOUND_ID"
fi
[[ -n "$INBOUND" ]] || die "شناسهٔ Inbound مشخص نیست؛ با --inbound مقدار بدهید"

ensure_panel_reachable

# حجم/مدت از ورودی می‌آید یا از state
[[ "$DAYS" =~ ^[0-9]+$ ]] || DAYS=0
[[ "$GB"   =~ ^[0-9]+$ ]] || GB=0
[[ "$IP_LIMIT" =~ ^[0-9]+$ ]] || IP_LIMIT=0

client_add "$EMAIL" "$INBOUND" "$GB" "$DAYS" "$IP_LIMIT" "$VLESS_FLOW" || exit 1

# UUID همان کلاینت را از پنل می‌خوانیم (هر کلاینت UUID مستقل دارد). منبع
# معتبر عضویتِ Inbound است؛ رکورد سراسری کلاینت در نسخه‌های جدید پنل فقط یک
# id عددی دارد که UUID نیست.
CLIENT_UUID="${CLIENT_UUID_ACTUAL:-}"
if [[ -z "$CLIENT_UUID" ]]; then
    CLIENT_UUID="$(client_uuid_in_inbound "$EMAIL" "$INBOUND" 2>/dev/null || true)"
fi
if [[ -z "$CLIENT_UUID" ]]; then
    info="$(client_info "$EMAIL" || true)"
    CLIENT_UUID="$(printf '%s' "${info:-{\}}" | jq -r '.client.id // .id // empty' 2>/dev/null || true)"
    _is_uuid "${CLIENT_UUID:-}" || CLIENT_UUID=""
fi
[[ -n "$CLIENT_UUID" ]] || CLIENT_UUID="$VLESS_UUID"

# Prefer the panel's own share link (exact uuid/spiderX of the serving
# inbound); build locally only when the API returns nothing.
LINK="$(client_links_api "$EMAIL" 2>/dev/null | grep '^vless://' | head -1 || true)"
[[ -n "$LINK" ]] || LINK="$(build_vless_link "$CLIENT_UUID" "$SERVER_IP" "$VLESS_PORT" "tcp" \
        "$VLESS_SNI" "$VLESS_SHORT_ID" "$VLESS_PUBLIC_KEY" "$VLESS_FLOW" "$EMAIL")"
SUB_ID="$(client_sub_id "$EMAIL" 2>/dev/null || true)"
SUB_URL=""; [[ -n "$SUB_ID" ]] && SUB_URL="$(sub_url "$SUB_ID")"

save_client_link "$EMAIL" "$LINK" "$SUB_URL"

if ((JSON_OUT)); then
    jq -nc --arg email "$EMAIL" --arg uuid "$CLIENT_UUID" --arg link "$LINK" \
           --arg sub "${SUB_URL:-}" --argjson days "$DAYS" --argjson gb "$GB" \
           '{email:$email,uuid:$uuid,link:$link,subscription:$sub,days:$days,totalGB:$gb}'
    exit 0
fi

print_rule "کلاینت ${EMAIL}"
kv "UUID" "$CLIENT_UUID"
kv "لینک" "$LINK"
[[ -n "$SUB_URL" ]] && kv "لینک اشتراک" "$SUB_URL"
kv "حجم" "$([[ "$GB" == "0" ]] && echo 'نامحدود' || echo "${GB} GB")"
kv "اعتبار" "$([[ "$DAYS" == "0" ]] && echo 'نامحدود' || echo "${DAYS} روز")"
printf '\n' >&2
((SHOW_QR)) && { show_qr "$LINK" "${VPN_SANAI_LINKS_DIR}/${EMAIL}.png" || true; }
print_rule ""
kv "فایل لینک" "${VPN_SANAI_LINKS_DIR}/${EMAIL}.txt"
