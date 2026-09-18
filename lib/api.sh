#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: lib/api.sh
#  Thin, explicit client for the 3x-ui panel HTTP API.
#
#  Uses `Authorization: Bearer <token>` which the panel accepts for every
#  /panel/api/* endpoint and which bypasses its CSRF check. When no token is
#  available the cookie + CSRF-token flow is used instead (see panel_login).
#
#  Response envelope is always {"success":bool,"msg":string,"obj":...}.
#  Callers should use api_get_obj / api_post_obj which fail loudly on
#  success:false, and print the panel's own message.
# =============================================================================

: "${API_CONNECT_TIMEOUT:=5}"
: "${API_MAX_TIME:=25}"
: "${API_RETRIES:=2}"

# Response plumbing. These are globals on purpose: callers read API_ERROR after
# a helper returned non-zero. Defaults exist so `set -u` never trips on them.
API_RESPONSE=""
API_HTTP_CODE=""
API_OBJ=""
API_ERROR=""

PANEL_SCHEME="${PANEL_SCHEME:-http}"
PANEL_PORT="${PANEL_PORT:-2053}"
PANEL_BASE_PATH="${PANEL_BASE_PATH:-/}"
PANEL_API_TOKEN="${PANEL_API_TOKEN:-}"
PANEL_SESSION_COOKIE=""

# --- URL helpers -------------------------------------------------------------
api_base_url() {
    # 127.0.0.1 always: the panel is reached over loopback (through an SSH
    # tunnel in `tunnel` mode) so no firewall rule or public hostname is needed.
    printf '%s://127.0.0.1:%s%s' "$PANEL_SCHEME" "$PANEL_PORT" "${PANEL_BASE_PATH%/}"
}

api_url() {
    local path="$1"
    printf '%s%s' "$(api_base_url)" "$(base_path_join '' "$path")"
}

_curl_tls_flags() {
    if [[ "$PANEL_SCHEME" == "https" ]]; then
        # The panel certificate is either self-signed or issued for the public
        # IP; both are meaningless for a loopback request, so skip verification
        # but keep the transport encrypted.
        printf '%s' "-k"
    fi
}

# --- core request ------------------------------------------------------------
# api_request <GET|POST> <path> [json-body|-] [extra curl args...]
#   -> exports API_RESPONSE (body) and API_HTTP_CODE; returns 0 on HTTP 2xx
api_request() {
    local method="$1" path="$2" body="${3:-}"
    shift 3 || true

    local url; url="$(api_url "$path")"
    local -a args=(-s -X "$method" --connect-timeout "$API_CONNECT_TIMEOUT"
                   --max-time "$API_MAX_TIME" -w '\n%{http_code}')
    local tls; tls="$(_curl_tls_flags)"
    [[ -n "$tls" ]] && args+=(-k)
    [[ -n "$PANEL_API_TOKEN" ]] && args+=(-H "Authorization: Bearer ${PANEL_API_TOKEN}")
    [[ -n "$PANEL_SESSION_COOKIE" ]] && args+=(-H "Cookie: ${PANEL_SESSION_COOKIE}")

    if [[ "$method" != "GET" && -n "$PANEL_SESSION_COOKIE" && -z "$PANEL_API_TOKEN" ]]; then
        args+=(-H "X-CSRF-Token: ${PANEL_CSRF_TOKEN:-}")
    fi

    if [[ -n "$body" && "$body" != "-" ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary "$body")
    fi
    args+=("$@")
    args+=("$url")

    local raw code
    raw="$(curl "${args[@]}" 2>/dev/null)" || raw=""
    code="${raw##*$'\n'}"
    API_RESPONSE="${raw%$'\n'*}"
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
    API_HTTP_CODE="$code"
    log_debug "api ${method} ${url} -> ${code}"

    [[ "$code" =~ ^2 ]]
}

api_retry_request() {
    local method="$1" path="$2" body="${3:-}"
    shift 3 || true
    local attempt=1
    while :; do
        if api_request "$method" "$path" "$body" "$@"; then
            return 0
        fi
        if ((attempt >= API_RETRIES)); then
            return 1
        fi
        log_debug "تلاش مجدد ${attempt}/${API_RETRIES} برای ${method} ${path}"
        sleep 1
        ((attempt++))
    done
}

# _api_validate_envelope -> sets API_OBJ / returns 1 with the panel message
_api_validate_envelope() {
    if ! has_cmd jq; then
        die "jq برای تحلیل پاسخ پنل لازم است"
    fi
    if [[ -z "$API_RESPONSE" ]]; then
        API_ERROR="پاسخی از پنل دریافت نشد (HTTP ${API_HTTP_CODE})"
        return 1
    fi
    if ! printf '%s' "$API_RESPONSE" | jq -e . >/dev/null 2>&1; then
        API_ERROR="پاسخ پنل JSON معتبر نبود (HTTP ${API_HTTP_CODE}): $(printf '%s' "$API_RESPONSE" | head -c 200)"
        return 1
    fi
    local success
    success="$(printf '%s' "$API_RESPONSE" | jq -r '.success // false')"
    if [[ "$success" != "true" ]]; then
        local msg
        msg="$(printf '%s' "$API_RESPONSE" | jq -r '.msg // "خطای نامشخص"')"
        # Validation failures come back as HTTP 200 with details in obj.issues
        local issues=""
        if printf '%s' "$API_RESPONSE" | jq -e '.obj.issues? // empty' >/dev/null 2>&1; then
            issues="$(printf '%s' "$API_RESPONSE" | jq -c '.obj.issues' 2>/dev/null)"
        fi
        API_ERROR="${msg}${issues:+ | ${issues}} (HTTP ${API_HTTP_CODE})"
        return 1
    fi
    API_OBJ="$(printf '%s' "$API_RESPONSE" | jq -c '.obj')"
    return 0
}

# api_get_obj <path> -> prints .obj as compact JSON; non-zero on failure
api_get_obj() {
    local path="$1"
    if ! api_retry_request GET "$path"; then
        API_ERROR="خطای شبکه در GET ${path} (HTTP ${API_HTTP_CODE})"
        log_error "$API_ERROR"
        return 1
    fi
    if ! _api_validate_envelope; then
        log_error "GET ${path}: ${API_ERROR}"
        return 1
    fi
    printf '%s' "$API_OBJ"
}

# api_post_obj <path> <json-body>
api_post_obj() {
    local path="$1" body="${2:-{\}}"
    if ! api_retry_request POST "$path" "$body"; then
        API_ERROR="خطای شبکه در POST ${path} (HTTP ${API_HTTP_CODE})"
        log_error "$API_ERROR"
        return 1
    fi
    if ! _api_validate_envelope; then
        log_error "POST ${path}: ${API_ERROR}"
        return 1
    fi
    printf '%s' "$API_OBJ"
}

# api_post_form <path> k=v [k=v ...] -> form encoded POST (xray template, scans)
api_post_form() {
    local path="$1"; shift
    local -a form=()
    local pair
    for pair in "$@"; do
        form+=(--data-urlencode "$pair")
    done
    if ! api_request POST "$path" "" -H 'Content-Type: application/x-www-form-urlencoded' "${form[@]}"; then
        API_ERROR="خطای شبکه در POST ${path} (HTTP ${API_HTTP_CODE})"
        log_error "$API_ERROR"
        return 1
    fi
    if ! _api_validate_envelope; then
        log_error "POST ${path}: ${API_ERROR}"
        return 1
    fi
    printf '%s' "$API_OBJ"
}

# api_silent <GET|POST> <path> [body] -> 0/1 without printing errors
api_silent() {
    local method="$1" path="$2" body="${3:-}"
    api_retry_request "$method" "$path" "$body" || return 1
    _api_validate_envelope
}

# --- authentication ----------------------------------------------------------
api_is_authenticated() {
    local obj
    obj="$(api_get_obj "/panel/api/server/status" 2>/dev/null)" || return 1
    [[ -n "$obj" ]]
}

# panel_login <user> <pass> -> cookie based session (used when no API token)
# Flow: GET /csrf-token (sets the session cookie) -> POST /login with X-CSRF-Token
panel_login() {
    local user="$1" pass="$2"
    local url; url="$(api_url "/csrf-token")"
    local -a tls_args=(); [[ "$PANEL_SCHEME" == "https" ]] && tls_args=(-k)

    local headers_file; headers_file="$(mktemp)"
    local body
    body="$(curl -s -D "$headers_file" "${tls_args[@]}" --max-time "$API_MAX_TIME" "$url" 2>/dev/null)" || body=""
    PANEL_SESSION_COOKIE="$(grep -i '^set-cookie:' "$headers_file" | sed -E 's/^[Ss]et-[Cc]ookie: *([^;]+).*/\1/' | paste -sd'; ' -)"
    rm -f "$headers_file"

    PANEL_CSRF_TOKEN="$(printf '%s' "$body" | jq -r '.obj // empty' 2>/dev/null)"
    if [[ -z "$PANEL_CSRF_TOKEN" ]]; then
        log_error "دریافت CSRF توکن ناموفق بود (${url})"
        return 1
    fi
    if [[ -z "$PANEL_SESSION_COOKIE" ]]; then
        log_warn "پنل کوکی نشست برنگرداند؛ ادامه می‌دهم (ممکن است پروکسی Set-Cookie را حذف کرده باشد)"
    fi

    local payload
    payload="$(jq -nc --arg u "$user" --arg p "$pass" '{username:$u,password:$p}')"
    if ! api_request POST "/login" "$payload"; then
        log_error "ورود به پنل ناموفق بود (HTTP ${API_HTTP_CODE})"
        return 1
    fi
    if ! _api_validate_envelope; then
        log_error "ورود به پنل: ${API_ERROR}"
        return 1
    fi
    log_ok "ورود با نام کاربری/رمز عبور موفق بود"
    return 0
}

# panel_detect_scheme -> probes loopback and sets PANEL_SCHEME
panel_detect_scheme() {
    local scheme
    for scheme in https http; do
        local code
        code="$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 6 \
                "${scheme}://127.0.0.1:${PANEL_PORT}${PANEL_BASE_PATH%/}/" 2>/dev/null || echo 000)"
        if [[ "$code" != "000" && -n "$code" ]]; then
            PANEL_SCHEME="$scheme"
            log_debug "پنل روی ${scheme} پاسخ می‌دهد (HTTP ${code})"
            return 0
        fi
    done
    return 1
}
