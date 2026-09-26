#!/usr/bin/env bash
# diagnose-reality.sh — read-only check for REALITY inbounds xray refuses to load.
#
# x-ui does not validate realitySettings when an inbound is saved, so an inbound
# can end up with an empty serverNames (or no target / no privateKey). xray then
# rejects the *whole* config file and every inbound goes offline, with:
#
#   infra/conf: Failed to build REALITY config. > infra/conf: empty "serverNames"
#
# This script only reads the panel API and prints what is broken; it changes
# nothing. Fix it with `vpn-sanai --fix-reality`, the Telegram bot's /fix, or
# `install.sh --update-self`.
#
# Standalone on purpose (jq + curl only): it works even when the installed copy
# of vpn-sanai is too old to know about this problem.

set -uo pipefail

STATE="${VPN_SANAI_STATE_FILE:-/etc/vpn-sanai/state.env}"
CURL="${CURL:-curl}"

if [[ ! -r "$STATE" ]]; then
    echo "فایل تنظیمات پیدا نشد: $STATE" >&2
    echo "اگر vpn-sanai نصب نیست، از install.sh --fix-reality استفاده کنید." >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$STATE"

for tool in jq curl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool نصب نیست" >&2; exit 1; }
done

base="${PANEL_BASE_PATH:-/}"
case "$base" in
    */) ;;
    *) base="${base}/" ;;
esac
scheme="${PANEL_SCHEME:-https}"
port="${PANEL_PORT:-}"
[[ -n "$port" ]] || { echo "PANEL_PORT در $STATE خالی است" >&2; exit 1; }

args=(-k -s --max-time 15 -H "Accept: application/json")
[[ -n "${PANEL_API_TOKEN:-}" ]] && args+=(-H "Authorization: Bearer ${PANEL_API_TOKEN}")

list="$("$CURL" "${args[@]}" "${scheme}://127.0.0.1:${port}${base}panel/api/inbounds/list" || true)"
if ! printf '%s' "$list" | jq -e . >/dev/null 2>&1; then
    echo "پاسخ پنل خوانده نشد: $(printf '%s' "$list" | head -c 200)" >&2
    exit 1
fi

# A disabled inbound is never handed to xray, so it cannot break the config.
total="$(printf '%s' "$list" | jq '(.obj // .) | length')"
echo "پنل: ${scheme}://127.0.0.1:${port}${base}panel/api — ${total} Inbound"
echo
echo "--- Inboundهای REALITY ناقص (Xray را استارت‌نشدنی می‌کنند) ---"
broken="$(printf '%s' "$list" | jq -r '
    def norm: if type == "string" then (fromjson? // {}) else (. // {}) end;
    def clean: tostring | gsub("^[[:space:]]+|[[:space:]]+$"; "");
    [ (.obj // .)[]?
      | select(.enable != false)
      | (.streamSettings | norm) as $s
      | select(($s.security // "") == "reality")
      | . as $i
      | $s.realitySettings as $r
      | (if ((($r.serverNames // []) | (if type == "array" then . else [] end)
              | map(select(. != null and (. | clean) != "")) | length) == 0)
         then "serverNames خالی"
         elif (($r.target // "") | clean) == "" then "target خالی"
         elif (($r.privateKey // "") | clean) == "" then "privateKey خالی"
         else empty end) as $why
      | select($why != null)
      | "• Inbound \($i.id) [\($i.remark // "-")] port \($i.port): \($why)" ]
    | if length == 0 then "" else .[] end')"
if [[ -z "$broken" ]]; then
    echo "هیچ‌کدام — همهٔ Inboundهای REALITY سالم هستند ✅"
else
    printf '%s\n' "$broken"
fi

echo
echo "--- وضعیت سرویس ---"
systemctl is-active x-ui 2>/dev/null || echo "x-ui فعال نیست"
journalctl -u x-ui -n 3 --no-pager 2>/dev/null \
    | grep -o 'tag in-[^ >]*\|empty "serverNames"\|Failed to build REALITY' | sort -u || true
