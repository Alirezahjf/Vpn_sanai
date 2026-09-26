#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: lib/bootstrap.sh
#  Self-installing front end.
#
#  vpn-sanai is a multi-file project, so the documented one-liner
#
#      bash <(curl -Ls https://raw.githubusercontent.com/<repo>/main/install.sh)
#
#  arrives with only install.sh on disk. This module detects that case,
#  downloads the rest of the tree (trying several mirrors), and re-executes the
#  freshly downloaded copy. When run from a checkout nothing happens here.
#
#  NOTE: this file must not depend on any other module — it runs before them.
# =============================================================================

# shellcheck disable=SC2034
VPN_SANAI_REPO="${VPN_SANAI_REPO:-Alirezahjf/Vpn_sanai}"
VPN_SANAI_REF="${VPN_SANAI_REF:-main}"

_bootstrap_files=(
    "install.sh"
    # bootstrap.sh itself: the one-liner path fetches it separately, but the
    # tree this list produces must be complete, otherwise --update-self cannot
    # resolve the module (and the downloader aborts) when run from curl|bash.
    "lib/bootstrap.sh"
    "lib/common.sh"
    "lib/preflight.sh"
    "lib/api.sh"
    "lib/panel.sh"
    "lib/reality.sh"
    "lib/clients.sh"
    "lib/security.sh"
    "lib/backup.sh"
    "lib/telegram.sh"
    "lib/bot.sh"
    "lib/load.sh"
    "config/defaults.conf"
    "config/vpn-sanai-telegram.service"
    "scripts/add-client.sh"
    "scripts/show-clients.sh"
    "scripts/backup.sh"
    "scripts/security.sh"
    "scripts/status.sh"
    "scripts/diagnose-reality.sh"
    "scripts/uninstall.sh"
    "scripts/telegram-bot.sh"
)

_bootstrap_urls_for() { # <relative-path> -> mirrors, one per line
    local path="$1"
    # A restricted network can point the whole download at its own mirror.
    if [[ -n "${VPN_SANAI_UPDATE_URL:-}" ]]; then
        printf '%s\n' "${VPN_SANAI_UPDATE_URL%/}/${path}"
    fi
    printf '%s\n' \
        "https://raw.githubusercontent.com/${VPN_SANAI_REPO}/${VPN_SANAI_REF}/${path}" \
        "https://cdn.jsdelivr.net/gh/${VPN_SANAI_REPO}@${VPN_SANAI_REF}/${path}" \
        "https://gcore.jsdelivr.net/gh/${VPN_SANAI_REPO}@${VPN_SANAI_REF}/${path}" \
        "https://ghproxy.net/https://raw.githubusercontent.com/${VPN_SANAI_REPO}/${VPN_SANAI_REF}/${path}"
}

# bootstrap_needed -> 0 when we must download the tree first
bootstrap_needed() {
    [[ -f "${SCRIPT_DIR}/lib/common.sh" && -f "${SCRIPT_DIR}/lib/api.sh" ]] && return 1
    return 0
}

# bootstrap_self <original-args...> -> downloads the tree and exec's the copy
bootstrap_self() {
    printf '\033[36m[vpn-sanai]\033[0m فایل‌های پروژه روی این سیستم نیست؛ از GitHub دانلود می‌شوند...\n' >&2
    printf '           repo=%s ref=%s\n' "$VPN_SANAI_REPO" "$VPN_SANAI_REF" >&2

    command -v curl >/dev/null 2>&1 || {
        printf '\033[31m[vpn-sanai]\033[0m curl نصب نیست؛ ابتدا آن را نصب کنید (apt install curl)\n' >&2
        exit 1
    }

    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/vpn-sanai-bootstrap.XXXXXX)" || exit 1

    local file url ok
    for file in "${_bootstrap_files[@]}"; do
        ok=0
        while IFS= read -r url; do
            mkdir -p "${tmp_dir}/$(dirname "$file")"
            if curl -fsSL --connect-timeout 15 --retry 2 --retry-delay 2 --max-time 60 \
                    -o "${tmp_dir}/${file}" "$url" 2>/dev/null && [[ -s "${tmp_dir}/${file}" ]]; then
                ok=1
                break
            fi
        done < <(_bootstrap_urls_for "$file")

        if ((!ok)); then
            printf '\033[31m[vpn-sanai]\033[0m دانلود %s ناموفق بود.\n' "$file" >&2
            printf '           شبکهٔ شما دسترسی به GitHub را محدود کرده است. راه‌حل‌ها:\n' >&2
            printf '             ۱) استفاده از پروکسی:  export https_proxy=http://user:pass@host:port\n' >&2
            printf '             ۲) کل ریپو را دانلود و از داخل پوشه اجرا کنید:  bash install.sh\n' >&2
            rm -rf "$tmp_dir"
            exit 1
        fi
        printf '  ✓ %s\n' "$file" >&2
    done

    chmod +x "${tmp_dir}/install.sh" "${tmp_dir}"/scripts/*.sh 2>/dev/null || true

    # Asking for a flag the downloaded copy does not have means we pulled the
    # wrong ref — the default `main` may simply not carry that feature yet. Say
    # so plainly: a bare usage screen reads like a typo and sends people in
    # circles (it looks like the flag is misspelled).
    if _bootstrap_ref_mismatch "${tmp_dir}/install.sh" "$@"; then
        printf '\033[31m[vpn-sanai]\033[0m این دستور در ref «%s» وجود ندارد.\n' \
            "$VPN_SANAI_REF" >&2
        printf '           ref درست را با VPN_SANAI_REF بدهید، مثلاً:\n' >&2
        printf '           VPN_SANAI_REF=<branch> bash <(curl -Ls https://raw.githubusercontent.com/%s/<branch>/install.sh) %s\n' \
            "$VPN_SANAI_REPO" "$1" >&2
        rm -rf "$tmp_dir"
        exit 2
    fi

    printf '\033[32m[vpn-sanai]\033[0m دانلود کامل شد؛ اجرای نسخهٔ دانلودشده...\n\n' >&2

    exec bash "${tmp_dir}/install.sh" "$@"
}

# _bootstrap_ref_mismatch <install.sh> <args...> -> 0 when an argument names a
# feature the downloaded copy does not implement (wrong ref).
_bootstrap_ref_mismatch() {
    local script="$1"; shift
    [[ -s "$script" ]] || return 1
    local arg
    for arg in "$@"; do
        case "$arg" in
            --update-self|--fix-reality)
                grep -q -- "$arg" "$script" || return 0 ;;
        esac
    done
    return 1
}
