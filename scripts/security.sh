#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: scripts/security.sh
#  مدیریت امنیت سرور: UFW، fail2ban، SSH، BBR
#
#  Usage:
#     vpn-sanai-security --status            # خلاصهٔ وضعیت امنیتی
#     vpn-sanai-security --ssh-port 2222     # تغییر پورت SSH
#     vpn-sanai-security --ssh-finalize      # بستن پورت(های) قبلی SSH
#     vpn-sanai-security --ufw-allow 8443/tcp
#     vpn-sanai-security --ufw-deny 8443/tcp
#     vpn-sanai-security --fail2ban-unban 1.2.3.4
#     vpn-sanai-security --bbr               # اعمال مجدد BBR + sysctl
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/load.sh
source "${SCRIPT_DIR}/../lib/load.sh"

MODE="status"
ARG=""

while (($#)); do
    case "$1" in
        --status)          MODE="status"; shift ;;
        --ssh-port)        MODE="ssh-port"; ARG="${2:?}"; shift 2 ;;
        --ssh-finalize)    MODE="ssh-finalize"; shift ;;
        --ssh-harden)      MODE="ssh-harden"; shift ;;
        --ufw-allow)       MODE="ufw-allow"; ARG="${2:?}"; shift 2 ;;
        --ufw-deny)        MODE="ufw-deny"; ARG="${2:?}"; shift 2 ;;
        --fail2ban-unban)  MODE="unban"; ARG="${2:?}"; shift 2 ;;
        --bbr)             MODE="bbr"; shift ;;
        --debug)           VPN_SANAI_DEBUG=1; shift ;;
        -h|--help)         sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                 die "گزینهٔ ناشناخته: $1" ;;
    esac
done

install_error_trap
require_root "$@"
detect_platform
state_exists && load_state_runtime
ENABLE_UFW="${ENABLE_UFW:-$(state_get ENABLE_UFW yes)}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-$(state_get ENABLE_FAIL2BAN yes)}"
ENABLE_BBR="${ENABLE_BBR:-$(state_get ENABLE_BBR yes)}"

_split_port_proto() {
    local spec="$1"
    local port="${spec%%/*}" proto="${spec##*/}"
    [[ "$proto" == "$spec" ]] && proto="tcp"
    is_port "$port" || die "پورت نامعتبر: ${spec}"
    printf '%s %s' "$port" "$proto"
}

case "$MODE" in
    status)
        print_rule "وضعیت امنیتی"
        security_summary
        printf '\n' >&2
        ufw_status_summary
        if has_cmd fail2ban-client; then
            print_rule "fail2ban"
            fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' >&2 || log_warn "jail sshd فعال نیست"
        fi
        ;;
    ssh-port)
        read -r -a current <<< "$(ssh_ports_active | paste -sd' ' -)"
        change_ssh_port "$ARG" "${current[@]}" || exit 1
        if has_cmd fail2ban-client && [[ -f "$F2B_SSHD" ]]; then
            setup_fail2ban "${current[@]}" "$ARG"
        fi
        log_warn "اگر اتصال فعلی شما قطع شد، با پورت‌های قبلی (${current[*]}) وصل شوید"
        ;;
    ssh-finalize)
        ssh_finalize
        setup_fail2ban "$(ssh_ports_active | paste -sd, -)"
        ;;
    ssh-harden)
        harden_ssh
        ;;
    ufw-allow|ufw-deny)
        read -r port proto <<< "$(_split_port_proto "$ARG")"
        if [[ "$MODE" == "ufw-allow" ]]; then
            ufw_allow_port "$port" "$proto" "manual"
        else
            ufw_delete_port "$port" "$proto"
        fi
        ufw_status_summary
        ;;
    unban)
        has_cmd fail2ban-client || die "fail2ban نصب نیست"
        fail2ban-client set sshd unbanip "$ARG" && log_ok "${ARG} از لیست بن آزاد شد"
        ;;
    bbr)
        setup_bbr
        setup_sysctl_tuning
        ;;
esac
