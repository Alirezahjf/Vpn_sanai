#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: lib/load.sh
#  Single entry point used by the helper scripts to source every module and to
#  load the runtime configuration (state file + live panel reachability).
# =============================================================================

[[ -n "${VPN_SANAI_LOADED:-}" ]] && return 0
VPN_SANAI_LOADED=1

LOAD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${LOAD_DIR}/.." && pwd)"
: "${VPN_SANAI_SELF:=${ROOT_DIR}/install.sh}"
export VPN_SANAI_SELF ROOT_DIR

# shellcheck source=common.sh
source "${LOAD_DIR}/common.sh"
# shellcheck source=../config/defaults.conf
source "${ROOT_DIR}/config/defaults.conf"
# shellcheck source=preflight.sh
source "${LOAD_DIR}/preflight.sh"
# shellcheck source=api.sh
source "${LOAD_DIR}/api.sh"
# shellcheck source=panel.sh
source "${LOAD_DIR}/panel.sh"
# shellcheck source=reality.sh
source "${LOAD_DIR}/reality.sh"
# shellcheck source=clients.sh
source "${LOAD_DIR}/clients.sh"
# shellcheck source=security.sh
source "${LOAD_DIR}/security.sh"
# shellcheck source=backup.sh
source "${LOAD_DIR}/backup.sh"

# load_state_runtime -> state + panel globals, no platform detection
load_state_runtime() {
    state_exists || die "نصبی پیدا نشد (${VPN_SANAI_STATE_FILE}). ابتدا 'bash install.sh' را اجرا کنید."
    state_load || die "خواندن ${VPN_SANAI_STATE_FILE} ناموفق بود"

    PANEL_PORT="${PANEL_PORT:-$(state_get PANEL_PORT)}"
    PANEL_BASE_PATH="${PANEL_BASE_PATH:-$(state_get PANEL_BASE_PATH '/')}"
    PANEL_USER="${PANEL_USER:-$(state_get PANEL_USER)}"
    PANEL_PASS="${PANEL_PASS:-$(state_get PANEL_PASS)}"
    PANEL_API_TOKEN="${PANEL_API_TOKEN:-$(state_get PANEL_API_TOKEN)}"
    PANEL_SCHEME="${PANEL_SCHEME:-$(state_get PANEL_SCHEME http)}"
    PANEL_ACCESS_MODE="${PANEL_ACCESS_MODE:-$(state_get PANEL_ACCESS_MODE tunnel)}"
    SERVER_IP="${SERVER_IP:-$(state_get SERVER_IP)}"
    VLESS_PORT="${VLESS_PORT:-$(state_get VLESS_PORT)}"
    VLESS_SNI="${VLESS_SNI:-$(state_get VLESS_SNI)}"
    VLESS_UUID="${VLESS_UUID:-$(state_get VLESS_UUID)}"
    VLESS_SHORT_ID="${VLESS_SHORT_ID:-$(state_get VLESS_SHORT_ID)}"
    VLESS_PUBLIC_KEY="${VLESS_PUBLIC_KEY:-$(state_get VLESS_PUBLIC_KEY)}"
    VLESS_PRIVATE_KEY="${VLESS_PRIVATE_KEY:-$(state_get VLESS_PRIVATE_KEY)}"
    VLESS_FLOW="${VLESS_FLOW:-$(state_get VLESS_FLOW xtls-rprx-vision)}"
    VLESS_REMARK="${VLESS_REMARK:-$(state_get VLESS_REMARK)}"
    VLESS_INBOUND_ID="${VLESS_INBOUND_ID:-$(state_get VLESS_INBOUND_ID)}"
    SUB_PORT="${SUB_PORT:-$(state_get SUB_PORT "$SUB_PORT_DEFAULT")}"
    SUB_PATH="${SUB_PATH:-$(state_get SUB_PATH "$SUB_PATH_DEFAULT")}"
    DEFAULT_CLIENT_EMAIL="${DEFAULT_CLIENT_EMAIL:-$(state_get DEFAULT_CLIENT_EMAIL "$DEFAULT_CLIENT_EMAIL")}"
    XHTTP_INBOUND_ID="${XHTTP_INBOUND_ID:-$(state_get XHTTP_INBOUND_ID)}"
    XHTTP_PATH="${XHTTP_PATH:-$(state_get XHTTP_PATH)}"
    XHTTP_PORT="${XHTTP_PORT:-$(state_get XHTTP_PORT)}"
    export PANEL_PORT PANEL_BASE_PATH PANEL_USER PANEL_PASS PANEL_API_TOKEN PANEL_SCHEME \
           PANEL_ACCESS_MODE SERVER_IP VLESS_PORT VLESS_SNI VLESS_UUID VLESS_SHORT_ID \
           VLESS_PUBLIC_KEY VLESS_PRIVATE_KEY VLESS_FLOW VLESS_REMARK VLESS_INBOUND_ID \
           SUB_PORT SUB_PATH DEFAULT_CLIENT_EMAIL XHTTP_INBOUND_ID XHTTP_PATH XHTTP_PORT
}

# ensure_panel_reachable -> detect the scheme and fail with a helpful message
ensure_panel_reachable() {
    if ! panel_detect_scheme; then
        log_debug "پنل روی ${PANEL_SCHEME} پاسخ نداد؛ با API تلاش می‌کنم"
    fi
    if ! api_is_authenticated; then
        if [[ -n "$PANEL_API_TOKEN" ]]; then
            log_warn "توکن API نامعتبر است؛ تلاش برای ورود با نام کاربری/رمز"
        fi
        panel_login "$PANEL_USER" "$PANEL_PASS" || die "اتصال به پنل برقرار نشد. وضعیت سرویس: $(panel_service_status)"
    fi
}
