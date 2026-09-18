#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: scripts/uninstall.sh
#  حذف کامل پنل 3x-ui و تنظیمات vpn-sanai
#
#  Usage:
#     vpn-sanai-uninstall            # تعاملی، با پرسش‌های تأیید
#     vpn-sanai-uninstall --yes-all  # حذف کامل بدون پرسش (خطرناک)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/load.sh
source "${SCRIPT_DIR}/../lib/load.sh"

PURGE_ALL=0
while (($#)); do
    case "$1" in
        --yes-all) PURGE_ALL=1; VPN_SANAI_NONINTERACTIVE=1; export VPN_SANAI_NONINTERACTIVE; shift ;;
        --debug)   VPN_SANAI_DEBUG=1; shift ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "گزینهٔ ناشناخته: $1" ;;
    esac
done

install_error_trap
require_root "$@"
detect_platform

print_rule "حذف vpn-sanai"
log_warn "این عملیات سرویس پنل، فایل‌های اجرایی و قواعد فایروال/SSH افزوده‌شده را حذف می‌کند"

if (( ! PURGE_ALL )); then
    ask_yesno "ادامه می‌دهید؟" "n" || { log_info "لغو شد"; exit 0; }
fi

# پشتیبان امنیتی قبل از حذف
if state_exists || panel_installed; then
    log_info "تهیهٔ پشتیبان امنیتی پیش از حذف"
    state_exists && load_state_runtime
    backup_create "pre-uninstall" >/dev/null 2>&1 || log_warn "پشتیبان‌گیری پیش از حذف ناموفق بود"
fi

if has_cmd x-ui; then
    printf 'y\n' | x-ui uninstall >/dev/null 2>&1 || true
fi
case "$INIT_SYSTEM" in
    systemd) systemctl stop x-ui 2>/dev/null || true; systemctl disable x-ui 2>/dev/null || true ;;
    openrc)  rc-service x-ui stop 2>/dev/null || true ;;
esac

# ربات تلگرام: سرویس پیش از حذف فایل‌هایش متوقف و غیرفعال می‌شود
TG_UNIT="${VPN_SANAI_TG_UNIT_NAME:-vpn-sanai-telegram}"
if has_cmd systemctl; then
    systemctl stop "${TG_UNIT}" 2>/dev/null || true
    systemctl disable "${TG_UNIT}" 2>/dev/null || true
fi

rm -f /usr/bin/x-ui /usr/local/bin/vpn-sanai /usr/local/bin/vpn-sanai-telegram \
      /etc/systemd/system/x-ui.service "/etc/systemd/system/${TG_UNIT}.service" 2>/dev/null || true
rm -rf /usr/local/x-ui 2>/dev/null || true
rm -f /etc/cron.d/vpn-sanai-backup 2>/dev/null || true
rm -f /etc/sysctl.d/99-vpn-sanai-bbr.conf /etc/sysctl.d/98-vpn-sanai-net.conf 2>/dev/null || true
rm -f /etc/modules-load.d/vpn-sanai-bbr.conf /etc/fail2ban/jail.d/99-vpn-sanai-sshd.local \
      /etc/fail2ban/jail.d/00-vpn-sanai-defaults.local 2>/dev/null || true

# SSH: هر پورتی که خودمان اضافه کرده‌ایم برداشته می‌شود
if [[ -f /etc/ssh/sshd_config.d/99-vpn-sanai.conf ]]; then
    rm -f /etc/ssh/sshd_config.d/99-vpn-sanai.conf
    if sshd -t 2>/dev/null; then
        service_restart ssh || service_restart sshd || log_warn "سرویس SSH را دستی راه‌اندازی مجدد کنید"
    else
        log_warn "پیکربندی SSH را دستی بررسی کنید"
    fi
fi

if has_cmd systemctl; then
    systemctl daemon-reload 2>/dev/null || true
fi

if (( PURGE_ALL )) || ask_yesno "دیتابیس و تنظیمات پنل (/etc/x-ui) پاک شود؟" "n"; then
    rm -rf /etc/x-ui
fi
if (( PURGE_ALL )) || ask_yesno "پوشهٔ state و لینک‌ها (${VPN_SANAI_ETC}) پاک شود؟" "n"; then
    rm -rf "$VPN_SANAI_ETC"
fi
if (( PURGE_ALL )) || ask_yesno "پشتیبان‌ها (${VPN_SANAI_BACKUP_DIR}) پاک شوند؟" "n"; then
    rm -rf "$VPN_SANAI_BACKUP_DIR"
fi
TG_STATE_DIR="${VPN_SANAI_BOT_STATE_DIR:-/var/lib/vpn-sanai/telegram}"
if [[ -d "$TG_STATE_DIR" ]] && { (( PURGE_ALL )) || ask_yesno "وضعیت ربات تلگرام (${TG_STATE_DIR}) پاک شود؟" "n"; }; then
    rm -rf "$TG_STATE_DIR"
fi

log_ok "حذف انجام شد. اگر UFW یا fail2ban را دستی نصب کرده‌اید، قواعد آن‌ها را بررسی کنید"
log_info "برای حذف UFW:  ufw disable && apt remove ufw"
