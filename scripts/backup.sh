#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: scripts/backup.sh
#  پشتیبان‌گیری / بازگردانی / مدیریت پشتیبان‌ها
#
#  Usage:
#     vpn-sanai-backup                # پشتیبان‌گیری دستی
#     vpn-sanai-backup --list         # فهرست پشتیبان‌ها
#     vpn-sanai-backup --restore FILE # بازگردانی
#     vpn-sanai-backup --quiet --prune   # حالت cron
#     vpn-sanai-backup --prune --days 7
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/load.sh
source "${SCRIPT_DIR}/../lib/load.sh"

MODE="create"
FILE=""
QUIET=0
TAG="manual"

while (($#)); do
    case "$1" in
        --list)         MODE="list"; shift ;;
        --restore)      MODE="restore"; FILE="${2:?}"; shift 2 ;;
        --prune)        MODE="prune-or-create"; shift ;;
        --days)         BACKUP_KEEP_DAYS="${2:?}"; shift 2 ;;
        --tag)          TAG="${2:?}"; shift 2 ;;
        --quiet|-q)     QUIET=1; VPN_SANAI_QUIET=1; export VPN_SANAI_QUIET; shift ;;
        --debug)        VPN_SANAI_DEBUG=1; shift ;;
        -h|--help)      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              die "گزینهٔ ناشناخته: $1" ;;
    esac
done

install_error_trap
require_root "$@"

# State may be missing on a half-installed host: fall back to panel defaults.
if state_exists; then
    load_state_runtime
else
    detect_platform
    PANEL_PORT="$(panel_cli setting -show true 2>/dev/null | sed -nE 's/^port:[[:space:]]*//p' | head -1)"
    PANEL_PORT="${PANEL_PORT:-2053}"
    panel_get_api_token >/dev/null 2>&1 || true
fi

case "$MODE" in
    list)    backup_list ;;
    restore) backup_restore "$FILE" ;;
    prune-or-create)
        backup_create "$TAG" >/dev/null || { log_error "پشتیبان‌گیری ناموفق بود"; exit 1; }
        backup_prune "$BACKUP_KEEP_DAYS"
        ((QUIET)) || backup_list
        ;;
    create)  backup_create "$TAG"; backup_prune "$BACKUP_KEEP_DAYS" ;;
esac
