#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: lib/common.sh
#  Shared primitives: logging, prompts, validation, state file, misc helpers.
#
#  This file is meant to be *sourced*, never executed:
#      # shellcheck source=lib/common.sh
#      source "${LIB_DIR}/common.sh"
#
#  Layout of a working install (all paths overridable for tests):
#      /etc/vpn-sanai/state.env      install state, secrets -> mode 0600
#      /etc/vpn-sanai/links/         exported client links
#      /etc/vpn-sanai/report.txt     human readable summary of the last run
#      /var/log/vpn-sanai/*.log      install / helper logs
#      /var/backups/vpn-sanai/       timestamped backups
# =============================================================================

# --- version / paths ---------------------------------------------------------
VPN_SANAI_NAME="vpn-sanai"
VPN_SANAI_VERSION="1.0.0"

: "${VPN_SANAI_ETC:=/etc/vpn-sanai}"
: "${VPN_SANAI_LOG_DIR:=/var/log/vpn-sanai}"
: "${VPN_SANAI_BACKUP_DIR:=/var/backups/vpn-sanai}"
: "${VPN_SANAI_STATE_FILE:=${VPN_SANAI_ETC}/state.env}"
: "${VPN_SANAI_LINKS_DIR:=${VPN_SANAI_ETC}/links}"
: "${VPN_SANAI_REPORT_FILE:=${VPN_SANAI_ETC}/report.txt}"
: "${VPN_SANAI_LOCK_FILE:=${VPN_SANAI_ETC}/.lock}"
: "${VPN_SANAI_ETC_DEFAULT:=/etc/vpn-sanai}"   # used by uninstall

# Where the tool itself is kept after installation (stable across reboots and
# independent of wherever the user cloned the repository).
: "${VPN_SANAI_LIBEXEC:=/usr/local/lib/vpn-sanai}"

XUI_MAIN_FOLDER_DEFAULT="/usr/local/x-ui"
: "${XUI_DB_DEFAULT:=/etc/x-ui/x-ui.db}"
XUI_INSTALL_RESULT="/etc/x-ui/install-result.env"
XUI_SYSTEMD_UNIT="/etc/systemd/system/x-ui.service"
XUI_CLI="/usr/bin/x-ui"

# --- behaviour switches ------------------------------------------------------
: "${VPN_SANAI_DRY_RUN:=0}"     # 1 => print commands instead of running them
: "${VPN_SANAI_NONINTERACTIVE:=0}" # 1 => never prompt, use defaults
: "${VPN_SANAI_QUIET:=0}"
: "${VPN_SANAI_DEBUG:=0}"

# --- colors ------------------------------------------------------------------
# Colors are disabled automatically when stdout is not a TTY, when NO_COLOR is
# set (https://no-color.org), or for dumb terminals.
_setup_colors() {
    local use_color=1
    if [[ -n "${NO_COLOR:-}" || "${TERM:-dumb}" == "dumb" || "${VPN_SANAI_NO_COLOR:-0}" == "1" ]]; then
        use_color=0
    fi
    if [[ ! -t 1 ]]; then
        use_color=0
    fi

    if ((use_color)); then
        C_RESET=$'\033[0m';   C_BOLD=$'\033[1m';  C_DIM=$'\033[2m'
        C_RED=$'\033[31m';    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m';   C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
    else
        C_RESET=''; C_BOLD=''; C_DIM=''
        C_RED=''; C_GREEN=''; C_YELLOW=''
        C_BLUE=''; C_MAGENTA=''; C_CYAN=''
    fi
}
_setup_colors

# --- logging -----------------------------------------------------------------
# Every message goes to stderr, so `script.sh | jq` style piping stays clean.
_log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# _log <color> <tag> <message...>
_log() {
    local color="$1" tag="$2"
    shift 2
    ((VPN_SANAI_QUIET)) && [[ "$tag" != "ERROR" ]] && return 0
    printf '%s[%s]%s %s%-7s%s %s\n' "$C_DIM" "$(_log_ts)" "$C_RESET" \
        "$color" "$tag" "$C_RESET" "$*" >&2
}

log_info()  { _log "$C_BLUE"    "INFO"  "$@"; }
log_ok()    { _log "$C_GREEN"   "OK"    "$@"; }
log_warn()  { _log "$C_YELLOW"  "WARN"  "$@"; }
log_error() { _log "$C_RED"     "ERROR" "$@"; }
log_step()  { _log "$C_MAGENTA" "STEP"  "$@"; }
log_debug() { ((VPN_SANAI_DEBUG)) && _log "$C_DIM" "DEBUG" "$@" || true; }

# Persist everything that reaches stdin of the script into a log file.
# Called once from the entry point; safe to skip (e.g. in unit tests).
setup_logging() {
    local tag="${1:-main}"
    local file
    file="${VPN_SANAI_LOG_DIR}/${tag}-$(date '+%Y%m%d-%H%M%S').log"
    local link="${VPN_SANAI_LOG_DIR}/last-${tag}.log"

    if ! mkdir -p "$VPN_SANAI_LOG_DIR" 2>/dev/null; then
        log_debug "cannot create ${VPN_SANAI_LOG_DIR}, logging to terminal only"
        return 0
    fi
    # Re-execute the whole script with both streams tee'd into the log file.
    if [[ "${VPN_SANAI_LOGGING:-0}" != "1" ]]; then
        export VPN_SANAI_LOGGING=1 VPN_SANAI_LOG_FILE="$file"
        # shellcheck disable=SC2093,SC2094
        exec > >(tee -a "$file") 2>&1
        ln -sfn "$file" "$link" 2>/dev/null || true
    fi
}

# --- error handling ----------------------------------------------------------
# die <message...>  -> error + usage hint + exit 1
die() {
    log_error "$@"
    exit 1
}

# _on_error <line> <command> <exit code> -- used by the ERR trap
_on_error() {
    local line="$1" cmd="$2" code="$3"
    log_error "خط در خط ${line} با کد ${code} متوقف شد: ${cmd}"
    log_error "برای گزارش مشکل، فایل لاگ را ببینید: ${VPN_SANAI_LOG_FILE:-$VPN_SANAI_LOG_DIR/last-*.log}"
    exit "$code"
}

# install_error_trap -> call from the entry point after sourcing libs
install_error_trap() {
    set -Eeuo pipefail
    trap '_on_error "${LINENO}" "${BASH_COMMAND}" "$?"' ERR
    trap 'log_warn "اجرای اسکریپت توسط کاربر متوقف شد" ; exit 130' INT TERM
}

# --- command helpers ---------------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# run <cmd...>  -> honour dry-run, log the command line in debug mode
run() {
    log_debug "run: $*"
    if ((VPN_SANAI_DRY_RUN)); then
        printf '%s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
        return 0
    fi
    "$@"
}

# run_quiet <cmd...> -> suppress stdout unless debug mode is on
run_quiet() {
    log_debug "run(quiet): $*"
    if ((VPN_SANAI_DRY_RUN)); then
        printf '%s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
        return 0
    fi
    if ((VPN_SANAI_DEBUG)); then
        "$@"
    else
        "$@" >/dev/null 2>&1
    fi
}

# retry <attempts> <delay-seconds> <cmd...>
retry() {
    local attempts="$1" delay="$2"
    shift 2
    local i=1 rc=0
    while :; do
        if "$@"; then
            return 0
        else
            rc=$?
        fi
        if ((i >= attempts)); then
            log_debug "retry: gave up after ${attempts} attempts: $*"
            return "$rc"
        fi
        log_debug "retry ${i}/${attempts} failed, sleeping ${delay}s: $*"
        sleep "$delay"
        ((i++))
    done
}

# --- validation --------------------------------------------------------------
is_true() {
    case "${1,,}" in
        1|true|yes|y|on|enable|enabled|فعال|بله|آره) return 0 ;;
        *) return 1 ;;
    esac
}

is_false() {
    case "${1,,}" in
        0|false|no|n|off|disable|disabled|غیرفعال|خیر|نه) return 0 ;;
        *) return 1 ;;
    esac
}

is_uint()  { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_ipv4()  { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
             local IFS=. p; # shellcheck disable=SC2206
             read -r -a _oct <<< "$1"
             for p in "${_oct[@]}"; do ((p <= 255)) || return 1; done; return 0; }
is_port()  { is_uint "${1:-}" && (( $1 >= 1 && $1 <= 65535 )); }

# valid_base_path <raw> -> echoes a normalised base path ("/abc/" or "/")
normalise_base_path() {
    local raw="${1:-}"
    raw="${raw#/}"; raw="${raw%/}"
    # The panel base path is a single URL segment. Keep it to characters that
    # are safe in every shell/URL context: letters, digits, dash, underscore.
    # Everything else (slashes, dots, percent escapes) is dropped, so a value
    # like "../../etc/passwd" can never produce a path with separators.
    raw="${raw//[^A-Za-z0-9_-]/}"
    if [[ -z "$raw" ]]; then
        printf '/'
    else
        printf '/%s/' "$raw"
    fi
}

# base_path_raw <normalised_base_path> -> the value the panel CLI expects
# ("/secret/" -> "secret", "/" -> "")
base_path_raw() {
    local path="${1#/}"
    printf '%s' "${path%/}"
}

# base_path_join <normalised_base_path> <suffix> -> URL path without double slashes
base_path_join() {
    local base="$1" suffix="$2"
    base="${base%/}"
    suffix="${suffix#/}"
    if [[ -z "$base" ]]; then
        printf '/%s' "$suffix"
    else
        printf '%s/%s' "$base" "$suffix"
    fi
}

# --- randomness --------------------------------------------------------------
# rand_string <length> [charset]
rand_string() {
    local len="${1:-16}" charset="${2:-A-Za-z0-9}"
    local out=""
    # Prefer openssl: /dev/urandom based, available nearly everywhere.
    if has_cmd openssl; then
        out="$(openssl rand -base64 $(( len * 2 )) 2>/dev/null | tr -dc "$charset" | head -c "$len")" || true
    fi
    if [[ "${#out}" -lt "$len" ]]; then
        out="$(LC_ALL=C tr -dc "$charset" < /dev/urandom 2>/dev/null | head -c "$len")" || true
    fi
    printf '%s' "$out"
}

# rand_password [length] -> URL/JSON-safe high-entropy password
rand_password() { rand_string "${1:-24}" 'A-Za-z0-9._-'; }

# rand_hex <bytes> -> hex string of 2*bytes chars
rand_hex() { local n="${1:-8}"; rand_string "$((n * 2))" 'a-f0-9'; }

# rand_port <min> <max> -> TCP port not currently in LISTEN state
rand_port() {
    local min="${1:-20000}" max="${2:-45000}" try port
    for (( try = 0; try < 40; try++ )); do
        port=$(( RANDOM % (max - min + 1) + min ))
        if ! port_in_use "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done
    # Deterministic fallback: first free port in range
    for (( port = min; port <= max; port++ )); do
        if ! port_in_use "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done
    return 1
}

# port_in_use <port> [proto] -> 0 when something is listening
port_in_use() {
    local port="$1" proto="${2:-tcp}"
    if has_cmd ss; then
        # `ss -lntu`: Netid State Recv-Q Send-Q Local:Port Peer:Port
        ss -H -lntu 2>/dev/null | awk -v p=":${port}" \
            '$5 ~ (p "$") {found=1} END{exit !found}'
        return $?
    fi
    if has_cmd lsof; then
        lsof -nP -i"${proto}:${port}" >/dev/null 2>&1
        return $?
    fi
    # Last resort: is anything in /proc/net holding the port?
    awk -v p="$(printf '%04X' "$port")" \
        'NR>1 { split($2,a,":"); if (toupper(a[2])==p) {found=1} } END{exit !found}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# --- prompting ---------------------------------------------------------------
# In non-interactive mode every prompt returns its default value.
# ask <var-name> <prompt> <default>
ask() {
    local __var="$1" prompt="$2" default="${3:-}" answer=""
    if ((VPN_SANAI_NONINTERACTIVE)) || [[ ! -t 0 && ! -t 2 ]]; then
        printf -v "$__var" '%s' "$default"
        log_info "${prompt} [غیرتعاملی: ${default:-خالی}]"
        return 0
    fi
    if [[ -n "$default" ]]; then
        read -r -p "${C_CYAN}${prompt}${C_RESET} [${default}]: " answer || true
        answer="${answer:-$default}"
    else
        read -r -p "${C_CYAN}${prompt}${C_RESET}: " answer || true
    fi
    printf -v "$__var" '%s' "$answer"
}

# ask_secret <var-name> <prompt> <default> -> hidden input when possible
ask_secret() {
    local __var="$1" prompt="$2" default="${3:-}" answer=""
    if ((VPN_SANAI_NONINTERACTIVE)) || [[ ! -t 0 ]]; then
        printf -v "$__var" '%s' "$default"
        return 0
    fi
    read -r -s -p "${C_CYAN}${prompt}${C_RESET} [$([[ -n $default ]] && echo 'پیش‌فرض تولیدشده')]: " answer || true
    echo >&2
    answer="${answer:-$default}"
    printf -v "$__var" '%s' "$answer"
}

# ask_yesno <prompt> <default:y|n> -> returns 0 for yes
ask_yesno() {
    local prompt="$1" default="${2:-n}" answer=""
    if ((VPN_SANAI_NONINTERACTIVE)) || [[ ! -t 0 ]]; then
        [[ "${default,,}" == "y" || "${default,,}" == "yes" ]]
        return $?
    fi
    local hint="y/N"; [[ "${default,,}" == "y" ]] && hint="Y/n"
    read -r -p "${C_CYAN}${prompt}${C_RESET} [${hint}]: " answer || true
    answer="${answer:-$default}"
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" || "${answer,,}" == "بله" ]]
}

# ask_menu <var-name> <prompt> <default> <option1> <option2> ...
# Options are printed as a numbered list; the variable receives the chosen
# *value* (not the number).
ask_menu() {
    local __var="$1" prompt="$2" default="$3"
    shift 3
    local -a options=("$@")
    local i choice=""

    if ((VPN_SANAI_NONINTERACTIVE)) || [[ ! -t 0 ]]; then
        printf -v "$__var" '%s' "$default"
        log_info "${prompt} [غیرتعاملی: ${default}]"
        return 0
    fi

    printf '%s%s%s\n' "$C_BOLD" "$prompt" "$C_RESET" >&2
    for i in "${!options[@]}"; do
        printf '  %s%d)%s %s\n' "$C_GREEN" "$((i + 1))" "$C_RESET" "${options[$i]}" >&2
    done
    read -r -p "${C_CYAN}انتخاب [${default}]: ${C_RESET}" choice || true
    choice="${choice:-$default}"
    if is_uint "$choice" && ((choice >= 1 && choice <= ${#options[@]})); then
        choice="${options[$((choice - 1))]}"
    fi
    printf -v "$__var" '%s' "$choice"
}

# --- state file --------------------------------------------------------------
# The state file is a source-able shell fragment written with printf %q, so
# values survive round trips regardless of quotes/spaces in passwords.

state_load() {
    [[ -f "$VPN_SANAI_STATE_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$VPN_SANAI_STATE_FILE"
    return 0
}

state_exists() { [[ -s "$VPN_SANAI_STATE_FILE" ]]; }

# state_set KEY VALUE -> update the file atomically, mode 0600
state_set() {
    local key="$1" value="${2-}"
    declare -A state_map=()

    if [[ -f "$VPN_SANAI_STATE_FILE" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
            state_map["${BASH_REMATCH[1]}"]="${line#*=}"
        done < "$VPN_SANAI_STATE_FILE"
    fi
    # shellcheck disable=SC2059
    state_map["$key"]="$(printf '%q' "$value")"

    atomic_write "$VPN_SANAI_STATE_FILE" 600 "$(
        for k in "${!state_map[@]}"; do printf '%s=%s\n' "$k" "${state_map[$k]}"; done | sort
    )"
}

state_get() {
    local key="$1" default="${2:-}"
    local line
    line="$(grep -m1 "^${key}=" "$VPN_SANAI_STATE_FILE" 2>/dev/null || true)"
    if [[ -z "$line" ]]; then
        printf '%s' "$default"
        return 0
    fi
    # Evaluate the %q-escaped value safely: it is our own file, mode 0600.
    local __value=""
    eval "__value=${line#*=}"
    printf '%s' "$__value"
}

# --- file helpers ------------------------------------------------------------
# atomic_write <path> <mode> <content>  (content can be piped in as $3)
atomic_write() {
    local path="$1" mode="${2:-600}" content="${3-}"
    local dir tmp
    dir="$(dirname "$path")"
    mkdir -p "$dir" 2>/dev/null || true

    if ((VPN_SANAI_DRY_RUN)); then
        printf '%s[dry-run]%s write %s (%s)\n' "$C_YELLOW" "$C_RESET" "$path" "$mode" >&2
        return 0
    fi

    tmp="$(mktemp "${dir}/.$(basename "$path").XXXXXX")" || return 1
    printf '%s' "$content" > "$tmp"
    chmod "$mode" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$path"
}

# Read one `KEY=value` out of a file written with printf %q, without sourcing
# it. Handles plain values, "double quoted", 'single quoted' and $'...' forms.
read_env_value() {
    local file="$1" key="$2" line val
    [[ -f "$file" ]] || return 1
    line="$(grep -m1 "^${key}=" "$file" 2>/dev/null || true)"
    [[ -n "$line" ]] || return 1
    val="${line#*=}"
    case "$val" in
        \$\'*\')  # $'...'
            val="${val#\$}"
            val="${val#\'}"; val="${val%\'}"
            val="${val//\\\'/\'}"
            val="${val//\\\\/\\}"
            ;;
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    printf '%s' "$val"
}

# ensure_dir <path> [mode]
ensure_dir() {
    local path="$1" mode="${2:-755}"
    if [[ -d "$path" ]]; then
        return 0
    fi
    run mkdir -p "$path"
    chmod "$mode" "$path" 2>/dev/null || true
}

# --- misc --------------------------------------------------------------------
# url_encode <string> -> percent-encoded (used for link remarks)
url_encode() {
    local string="$1" out="" i c
    for (( i = 0; i < ${#string}; i++ )); do
        c="${string:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+="$(printf '%%%02X' "'$c")" ;;
        esac
    done
    printf '%s' "$out"
}

# shell_quote <string> -> single-quoted shell literal
shell_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# require_root -> re-exec through sudo when not root (interactive only)
require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
    if ((VPN_SANAI_NONINTERACTIVE)); then
        die "این اسکریپت باید با کاربر root اجرا شود (sudo bash $0 ...)"
    fi
    if has_cmd sudo; then
        log_warn "دسترسی root لازم است؛ اسکریپت با sudo دوباره اجرا می‌شود"
        exec sudo --preserve-env=VPN_SANAI_NONINTERACTIVE,VPN_SANAI_DRY_RUN,VPN_SANAI_DEBUG \
            bash "${VPN_SANAI_SELF:-$0}" "$@"
    fi
    die "برای اجرا به دسترسی root نیاز است (sudo نصب نیست)"
}

# acquire_lock -> prevents two concurrent runs (uses flock when available)
acquire_lock() {
    ensure_dir "$VPN_SANAI_ETC" 700
    if has_cmd flock; then
        exec 9>"$VPN_SANAI_LOCK_FILE"
        if ! flock -n 9; then
            die "یک نمونهٔ دیگر از $VPN_SANAI_NAME در حال اجراست (${VPN_SANAI_LOCK_FILE})"
        fi
    else
        if [[ -f "$VPN_SANAI_LOCK_FILE" ]]; then
            local pid
            pid="$(cat "$VPN_SANAI_LOCK_FILE" 2>/dev/null || true)"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                die "یک نمونهٔ دیگر از $VPN_SANAI_NAME در حال اجراست (PID ${pid})"
            fi
        fi
        printf '%s\n' "$$" > "$VPN_SANAI_LOCK_FILE"
        trap 'rm -f "$VPN_SANAI_LOCK_FILE"' EXIT
    fi
}

# print_rule -> section separator for readable output
print_rule() {
    local title="${1:-}"
    local width=72 line
    line="$(printf '─%.0s' $(seq 1 "$width"))"
    if [[ -n "$title" ]]; then
        printf '\n%s%s%s\n%s%s%s\n' "$C_BOLD" "$title" "$C_RESET" "$C_DIM" "$line" "$C_RESET" >&2
    else
        printf '%s%s%s\n' "$C_DIM" "$line" "$C_RESET" >&2
    fi
}

# kv <key> <value> -> aligned key/value line for reports
kv() { printf '  %s%-22s%s %s\n' "$C_BOLD" "$1" "$C_RESET" "$2" >&2; }
