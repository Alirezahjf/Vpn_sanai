#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: lib/preflight.sh
#  Platform detection, dependency installation, network / resource checks.
# =============================================================================

# Populated by detect_platform()
OS_ID=""; OS_LIKE=""; OS_VERSION_ID=""; OS_PRETTY=""
PKG_MGR=""; INIT_SYSTEM=""; ARCH=""; XRAY_ARCH=""

# --- platform ----------------------------------------------------------------
detect_platform() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_LIKE="${ID_LIKE:-}"
        OS_VERSION_ID="${VERSION_ID:-}"
        OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
    else
        OS_ID="$(uname -s | tr '[:upper:]' '[:lower:]')"
        OS_PRETTY="$OS_ID"
    fi

    case "${OS_ID}:${OS_LIKE}" in
        debian:*|ubuntu:*|linuxmint:*|raspbian:*|*:*debian*|*:*ubuntu*) PKG_MGR="apt" ;;
        fedora:*|rhel:*|centos:*|rocky:*|almalinux:*|ol:*|*:*rhel*|*:*fedora*) PKG_MGR="dnf" ;;
        arch:*|manjaro:*|endeavouros:*|*:*arch*) PKG_MGR="pacman" ;;
        opensuse*:*|sles:*|*:*suse*) PKG_MGR="zypper" ;;
        alpine:*) PKG_MGR="apk" ;;
        *) PKG_MGR="" ;;
    esac
    # yum-only CentOS 7 / RHEL 7
    if [[ "$PKG_MGR" == "dnf" ]] && ! has_cmd dnf && has_cmd yum; then
        PKG_MGR="yum"
    fi

    if [[ -d /run/systemd/system ]] && has_cmd systemctl; then
        INIT_SYSTEM="systemd"
    elif has_cmd rc-service; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="other"
    fi

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64)        XRAY_ARCH="amd64" ;;
        aarch64|arm64)       XRAY_ARCH="arm64" ;;
        armv7l|armv6l|armv5*) XRAY_ARCH="arm32" ;;
        i386|i686)           XRAY_ARCH="386" ;;
        s390x)               XRAY_ARCH="s390x" ;;
        *)                   XRAY_ARCH="$ARCH" ;;
    esac
}

print_platform() {
    log_info "سیستم‌عامل: ${OS_PRETTY} | معماری: ${ARCH} (xray: ${XRAY_ARCH}) | مدیر بسته: ${PKG_MGR:-?} | init: ${INIT_SYSTEM}"
}

require_supported_os() {
    if [[ -z "$PKG_MGR" ]]; then
        log_warn "توزیع ${OS_PRETTY} در فهرست توزیع‌های آزمایش‌شده نیست؛ تلاش می‌کنم ادامه دهم"
    fi
    if [[ "$INIT_SYSTEM" == "other" ]]; then
        die "این سیستم init شناخته‌شده‌ای (systemd / openrc) ندارد؛ نصب پنل 3x-ui در این محیط پشتیبانی نمی‌شود"
    fi
    if ! has_cmd bash || ((BASH_VERSINFO[0] < 4)); then
        die "bash نسخهٔ ۴ یا بالاتر لازم است (نسخهٔ فعلی: ${BASH_VERSION:-?})"
    fi
}

# --- package manager ---------------------------------------------------------
# pkg_resolve <label> -> concrete package name for the detected distro family
pkg_resolve() {
    local label="$1"
    case "$PKG_MGR:$label" in
        apt:update)          printf 'update-notifier-common' ;;
        apt:time|dnf:time|yum:time|pacman:time|zypper:time|apk:time) printf 'tzdata' ;;
        apt:sudo)            printf 'sudo' ;;
        apk:sudo)            printf 'doas' ;;
        apk:cron)            printf 'dcron' ;;
        dnf:cron)            printf 'cronie' ;;
        yum:cron)            printf 'cronie' ;;
        pacman:cron)         printf 'cronie' ;;
        zypper:cron)         printf 'cron' ;;
        apt:timesync)        printf 'systemd-timesyncd' ;;
        apk:timesync)        printf 'chrony' ;;
        *:timesync)          printf 'chrony' ;;
        *:qrencode)          printf 'qrencode' ;;
        apt:sqlite)          printf 'sqlite3' ;;
        *:sqlite)            printf 'sqlite' ;;
        apt:firewall)        printf 'ufw' ;;
        *:firewall)          printf 'ufw' ;;
        *:fail2ban)          printf 'fail2ban' ;;
        apk:iptables)        printf 'iptables' ;;
        *:iptables)          printf 'iptables' ;;
        *:nftables)          printf 'nftables' ;;
        apk:unattended)      printf 'unattended-upgrades' ;;
        *:unattended)        printf 'unattended-upgrades' ;;
        apt:tools)           printf 'bc' ;;
        *:tools)             printf 'bc' ;;
        *)                   printf '%s' "$label" ;;
    esac
}

_pkg_update() {
    case "$PKG_MGR" in
        apt)    run_quiet env DEBIAN_FRONTEND=noninteractive apt-get update -y ;;
        dnf|yum) run_quiet "$PKG_MGR" makecache -y ;;
        pacman) run_quiet pacman -Sy --noconfirm ;;
        zypper) run_quiet zypper --non-interactive refresh ;;
        apk)    run_quiet apk update ;;
        *)      return 1 ;;
    esac
}

# pkg_install <pkg...> -> best effort; returns non-zero if *nothing* installed
pkg_install() {
    [[ $# -gt 0 ]] || return 0
    case "$PKG_MGR" in
        apt)                 run_quiet env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" ;;
        dnf|yum)             run_quiet "$PKG_MGR" install -y -q "$@" ;;
        pacman)              run_quiet pacman -S --noconfirm --needed "$@" ;;
        zypper)              run_quiet zypper --non-interactive install -y "$@" ;;
        apk)                 run_quiet apk add "$@" ;;
        *)                   log_warn "مدیر بستهٔ شناخته‌شده‌ای وجود ندارد؛ نصب دستی لازم است: $*"; return 1 ;;
    esac
}

# install_labels <label...> -> resolve + install, warn (but continue) on failure
install_labels() {
    local -a pkgs=() missing=()
    local label p
    for label in "$@"; do
        p="$(pkg_resolve "$label")"
        pkgs+=("$p")
    done
    log_info "نصب بسته‌های لازم: ${pkgs[*]}"
    if ! pkg_install "${pkgs[@]}"; then
        log_warn "نصب برخی بسته‌ها ناموفق بود؛ ادامه می‌دهم"
    fi
    for label in "$@"; do
        case "$label" in
            curl) has_cmd curl || missing+=("curl") ;;
            openssl) has_cmd openssl || missing+=("openssl") ;;
            jq) has_cmd jq || missing+=("jq") ;;
            tar) has_cmd tar || missing+=("tar") ;;
        esac
    done
    if ((${#missing[@]})); then
        die "این ابزارهای پایه نصب نشدند: ${missing[*]} — لطفاً دستی نصب کنید و اسکریپت را دوباره اجرا کنید"
    fi
}

check_and_install_deps() {
    local need_update=0
    local -a wanted=(curl tar openssl jq ca-certificates socat cron time)

    has_cmd curl || need_update=1
    has_cmd jq || need_update=1
    has_cmd openssl || need_update=1
    has_cmd socat || need_update=1

    if ((need_update)); then
        log_step "به‌روزرسانی فهرست بسته‌ها"
        _pkg_update || log_warn "به‌روزرسانی فهرست بسته‌ها ناموفق بود؛ ادامه می‌دهم"
    fi

    install_labels "${wanted[@]}"

    # Optional-but-useful tools. Missing ones only degrade the UX, never abort.
    local -a optional=(qrencode sqlite iproute2 tools)
    install_labels "${optional[@]}" >/dev/null 2>&1 || true

    has_cmd qrencode || log_warn "qrencode نصب نشد — QR کد به‌صورت تصویری نمایش داده نمی‌شود (لینک‌ها ذخیره می‌شوند)"
    has_cmd jq       || die "jq برای گفت‌وگو با API پنل لازم است"
}

# --- resources ---------------------------------------------------------------
check_resources() {
    local mem_mb disk_mb
    mem_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
    disk_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"

    log_info "حافظه: ${mem_mb}MB | فضای آزاد روی /: ${disk_mb}MB"
    ((mem_mb  < 200)) && log_warn "حافظهٔ کمتر از ۲۰۰MB ممکن است برای xray کافی نباشد"
    ((disk_mb < 500)) && log_warn "فضای آزاد کمتر از ۵۰۰MB است؛ نصب ممکن است ناتمام بماند"
    ((disk_mb < 200)) && die "فضای دیسک کافی نیست"
    return 0
}

# --- network -----------------------------------------------------------------
# tcp_probe <host> <port> [timeout]
tcp_probe() {
    local host="$1" port="$2" timeout="${3:-5}"
    if has_cmd timeout; then
        timeout "$timeout" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
    else
        bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
    fi
}

# http_probe <url> [timeout] -> prints HTTP code (000 on failure)
http_probe() {
    local url="$1" timeout="${2:-8}"
    curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout" \
        --retry 1 --retry-delay 1 "$url" 2>/dev/null || echo 000
}

check_network() {
    log_step "بررسی دسترسی شبکه"
    if ! tcp_probe 1.1.1.1 53 4 && ! tcp_probe 8.8.8.8 53 4; then
        log_warn "اتصال به DNS عمومی برقرار نشد — ممکن است شبکه محدود باشد"
    fi

    local code
    code="$(http_probe https://api.github.com 8)"
    if [[ "$code" == "000" ]]; then
        log_warn "دسترسی به api.github.com برقرار نشد. اگر GitHub در شبکهٔ شما محدود است،"
        log_warn "می‌توانید از پروکسی استفاده کنید:  export https_proxy=http://user:pass@host:port"
        log_warn "یا نصب پنل را با --skip-panel-install رد کنید و پنل را دستی نصب نمایید."
    else
        log_ok "دسترسی به GitHub برقرار است (HTTP ${code})"
    fi
}

# get_public_ip [4|6] -> prints the public address or nothing
get_public_ip() {
    local family="${1:-4}" url
    local -a urls
    if [[ "$family" == "6" ]]; then
        urls=("https://api64.ipify.org" "https://ifconfig.co/ip" "https://icanhazip.com")
    else
        urls=("https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.co/ip" "https://ipinfo.io/ip")
    fi
    for url in "${urls[@]}"; do
        local ip
        ip="$(curl -"${family}" -s --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')" || true
        if [[ "$family" == "4" ]] && is_ipv4 "$ip"; then
            printf '%s' "$ip"; return 0
        fi
        if [[ "$family" == "6" && "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
            printf '%s' "$ip"; return 0
        fi
    done
    return 1
}

# --- time / locale -----------------------------------------------------------
setup_timezone() {
    local tz="${TZ_TARGET:-$TZ_DEFAULT}"
    if has_cmd timedatectl; then
        local current
        current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
        if [[ "$current" != "$tz" ]]; then
            log_info "تنظیم منطقهٔ زمانی روی ${tz}"
            run_quiet timedatectl set-timezone "$tz" || log_warn "تنظیم منطقهٔ زمانی ناموفق بود"
        fi
    elif [[ -f "/usr/share/zoneinfo/${tz}" ]]; then
        ln -sfn "/usr/share/zoneinfo/${tz}" /etc/localtime 2>/dev/null || true
        printf '%s\n' "$tz" > /etc/timezone 2>/dev/null || true
    fi
}

# Reality is time sensitive: a skewed clock breaks the handshake for clients.
ensure_time_sync() {
    is_true "$ENABLE_TIMESYNC" || return 0
    log_step "بررسی همگام‌سازی ساعت"

    if has_cmd timedatectl; then
        run_quiet timedatectl set-ntp true || true
    fi

    # systemd-timesyncd is the lightest option on systemd hosts; fall back to
    # chrony when the distro does not ship it (Arch, Alpine, RHEL 7...).
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
            run_quiet systemctl enable --now systemd-timesyncd || true
        elif ! has_cmd chronyd; then
            install_labels timesync >/dev/null 2>&1 || true
            run_quiet systemctl enable --now chronyd || run_quiet systemctl enable --now chrony || true
        fi
    elif ! has_cmd chronyd; then
        install_labels timesync >/dev/null 2>&1 || true
        run_quiet rc-service chronyd restart || true
    fi

    if has_cmd timedatectl; then
        if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi yes; then
            log_warn "ساعت سیستم هنوز با NTP همگام نشده است؛ در صورت بروز خطای دست‌دادن REALITY، سرویس زمان را بررسی کنید"
        else
            log_ok "ساعت سیستم همگام است"
        fi
    fi
}

# --- ports -------------------------------------------------------------------
# choose_free_port <preferred> <min> <max> <label>
choose_free_port() {
    local preferred="$1" min="$2" max="$3" label="${4:-port}"
    if [[ -n "$preferred" ]] && is_port "$preferred" && ! port_in_use "$preferred"; then
        printf '%s' "$preferred"; return 0
    fi
    if [[ -n "$preferred" ]] && port_in_use "$preferred"; then
        log_warn "${label} ${preferred} اشغال است؛ یک پورت آزاد انتخاب می‌کنم"
    fi
    local picked
    picked="$(rand_port "$min" "$max")" || die "پورت آزادی در بازهٔ ${min}-${max} پیدا نشد"
    printf '%s' "$picked"
}

# explain_port_owner <port> -> helps the user free a port
explain_port_owner() {
    local port="$1"
    has_cmd ss || return 0
    local owner
    owner="$(ss -H -lntp 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p {print $6}' | head -1)"
    [[ -n "$owner" ]] && log_info "پورت ${port} در اختیار: ${owner}" || true
}

# --- host facts --------------------------------------------------------------
detect_primary_ip() {
    # The interface address used to reach the internet (not necessarily public
    # when the host sits behind NAT).
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')" || true
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
    printf '%s' "$ip"
}

# detects NAT: local primary IP differs from what the internet reports
is_behind_nat() {
    local local_ip="$1" public_ip="$2"
    [[ -n "$local_ip" && -n "$public_ip" && "$local_ip" != "$public_ip" ]]
}
