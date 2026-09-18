#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: lib/telegram.sh
#  Minimal, dependency-free client for the Telegram Bot API.
#
#  Only curl + jq are used, and every endpoint the bot needs is covered:
#  long polling, sendMessage (HTML + inline keyboards, auto-split at 4096),
#  editMessageText, sendPhoto/sendDocument (multipart), answerCallbackQuery,
#  deleteMessage and getMe. TG_API_BASE is overridable so the test-suite can
#  run the whole bot against tests/mock_telegram.py.
#
#  This file is meant to be *sourced*, never executed.
# =============================================================================

: "${TG_API_BASE:=https://api.telegram.org}"
: "${TG_BOT_TOKEN:=}"
: "${TG_CONNECT_TIMEOUT:=10}"
: "${TG_MAX_TIME:=70}"
: "${TG_HTTP_RETRIES:=2}"

# Response plumbing (mirrors the API_* globals of lib/api.sh on purpose).
TG_RESPONSE=""
TG_HTTP_CODE=""
TG_OK=0
TG_ERROR=""
TG_LAST_MESSAGE_ID=""

# --- low level ---------------------------------------------------------------

_tg_url() { printf '%s/bot%s/%s' "${TG_API_BASE%/}" "$TG_BOT_TOKEN" "$1"; }

# tg_call <method> [json-body]
#   -> exports TG_RESPONSE / TG_HTTP_CODE / TG_OK / TG_ERROR; 0 when .ok==true
tg_call() {
    local method="$1" body="${2:-}"
    local url; url="$(_tg_url "$method")"

    local -a args=(-s -X POST --connect-timeout "$TG_CONNECT_TIMEOUT"
                   --max-time "$TG_MAX_TIME" -w '\n%{http_code}')
    [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data-binary "$body")
    args+=("$url")

    local attempt=1 raw code
    while :; do
        raw="$(curl "${args[@]}" 2>/dev/null)" || raw=""
        code="${raw##*$'\n'}"
        TG_RESPONSE="${raw%$'\n'*}"
        [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
        TG_HTTP_CODE="$code"
        log_debug "tg ${method} -> ${code}"

        # 429 Too Many Requests: honour retry_after once, then give up.
        if [[ "$code" == "429" ]] && ((attempt <= TG_HTTP_RETRIES)); then
            local wait
            wait="$(printf '%s' "$TG_RESPONSE" | jq -r '.parameters.retry_after // 3' 2>/dev/null || echo 3)"
            is_uint "$wait" || wait=3
            ((wait > 30)) && wait=30
            log_warn "محدودیت نرخ تلگرام؛ ${wait} ثانیه صبر می‌کنم"
            sleep "$wait"
            attempt=$((attempt + 1))
            continue
        fi
        break
    done

    # NB: jq 1.6 exits 0 on EMPTY input, so an empty response (curl failure)
    # would silently pass the .ok check below. Guard explicitly.
    if [[ -z "$TG_RESPONSE" ]] || \
       ! printf '%s' "$TG_RESPONSE" | jq -e '.ok == true' >/dev/null 2>&1; then
        TG_OK=0
        TG_ERROR="$(printf '%s' "$TG_RESPONSE" | jq -r '.description // empty' 2>/dev/null || true)"
        [[ -n "$TG_ERROR" ]] || TG_ERROR="خطای تلگرام (HTTP ${TG_HTTP_CODE})"
        return 1
    fi
    TG_OK=1
    TG_ERROR=""
    return 0
}

# tg_call_upload <method> <file-field> <file-path> [form k=v ...]
#   (file-path is the PLAIN path; the leading @ for curl -F is added here)
tg_call_upload() {
    local method="$1" field="$2" file="$3"
    shift 3
    local url; url="$(_tg_url "$method")"

    local -a args=(-s --connect-timeout "$TG_CONNECT_TIMEOUT" --max-time 120
                   -w '\n%{http_code}')
    args+=(-F "${field}=@${file}")
    local pair
    for pair in "$@"; do
        args+=(-F "$pair")
    done
    args+=("$url")

    local raw code
    raw="$(curl "${args[@]}" 2>/dev/null)" || raw=""
    code="${raw##*$'\n'}"
    TG_RESPONSE="${raw%$'\n'*}"
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
    TG_HTTP_CODE="$code"
    log_debug "tg ${method} (upload) -> ${code}"

    if [[ -z "$TG_RESPONSE" ]] || \
       ! printf '%s' "$TG_RESPONSE" | jq -e '.ok == true' >/dev/null 2>&1; then
        TG_OK=0
        TG_ERROR="$(printf '%s' "$TG_RESPONSE" | jq -r '.description // empty' 2>/dev/null || true)"
        [[ -n "$TG_ERROR" ]] || TG_ERROR="خطای تلگرام (HTTP ${TG_HTTP_CODE})"
        return 1
    fi
    TG_OK=1
    TG_ERROR=""
    return 0
}

# --- escaping / formatting ---------------------------------------------------

# tg_escape_html <text> -> & < > escaped for parse_mode=HTML
tg_escape_html() {
    local s="$1" had_patsub=0
    # bash >= 5.2 expands '&' in the replacement to the matched text
    # (patsub_replacement, on by default). The escapes below need a literal '&',
    # so the option is disabled for the duration of the substitutions.
    if shopt -q patsub_replacement 2>/dev/null; then
        shopt -u patsub_replacement
        had_patsub=1
    fi
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    ((had_patsub)) && shopt -s patsub_replacement
    printf '%s' "$s"
}

# fa_digits_to_en <text> -> Persian/Arabic digits mapped to ASCII
fa_digits_to_en() {
    local s="$1"
    s="${s//۰/0}"; s="${s//۱/1}"; s="${s//۲/2}"; s="${s//۳/3}"; s="${s//۴/4}"
    s="${s//۵/5}"; s="${s//۶/6}"; s="${s//۷/7}"; s="${s//۸/8}"; s="${s//۹/9}"
    s="${s//٠/0}"; s="${s//١/1}"; s="${s//٢/2}"; s="${s//٣/3}"; s="${s//٤/4}"
    s="${s//٥/5}"; s="${s//٦/6}"; s="${s//٧/7}"; s="${s//٨/8}"; s="${s//٩/9}"
    printf '%s' "$s"
}

# tg_kb <row> [row ...]
#   A row is "text|callback_data;text|url:https://..." — ';' splits buttons,
#   '|' splits label and data. Empty rows are skipped. Prints the JSON array.
tg_kb() {
    local row btn text data first_row=1 first_btn
    local -a btns=()
    printf '['
    for row in "$@"; do
        [[ -n "$row" ]] || continue
        ((first_row)) || printf ','
        first_row=0
        printf '['
        first_btn=1
        btns=()
        while IFS= read -r -d ';' btn; do btns+=("$btn"); done <<< "${row};"
        for btn in "${btns[@]}"; do
            [[ "$btn" == *'|'* ]] || continue
            ((first_btn)) || printf ','
            first_btn=0
            text="${btn%%|*}"
            data="${btn#*|}"
            if [[ "$data" == url:* ]]; then
                printf '{"text":%s,"url":%s}' \
                    "$(jq -Rn --arg t "$text" '$t')" \
                    "$(jq -Rn --arg u "${data#url:}" '$u')"
            else
                printf '{"text":%s,"callback_data":%s}' \
                    "$(jq -Rn --arg t "$text" '$t')" \
                    "$(jq -Rn --arg d "$data" '$d')"
            fi
        done
        printf ']'
    done
    printf ']'
}

# tg_rm_none -> a keyboard that removes any inline keyboard
tg_rm_none() { printf '""'; }

# tg_split_message <text> [max-len] -> chunks of <= max-len on line boundaries,
#   separated by \x1f (unit separator — a character that never appears in a
#   chat message, unlike the newline which is legal inside a chunk).
tg_split_message() {
    local text="$1" max="${2:-3800}" sep=$'\x1f'
    local -a lines=()
    local line len=0 out=""
    # Normalise newlines, then walk the lines accumulating chunks.
    text="${text//$'\r'/}"
    while IFS= read -r line; do
        lines+=("$line")
    done < <(printf '%s\n' "$text")

    for line in "${lines[@]}"; do
        local add=$(( ${#line} + 1 ))
        # A single line longer than the limit is hard-split.
        if (( ${#line} > max )); then
            if [[ -n "$out" ]]; then printf '%s%s' "$out" "$sep"; fi
            out=""; len=0
            local i
            for (( i = 0; i < ${#line}; i += max )); do
                printf '%s%s' "${line:i:max}" "$sep"
            done
            continue
        fi
        if (( len + add > max )); then
            printf '%s%s' "$out" "$sep"
            out=""
            len=0
        fi
        out+="${line}"$'\n'
        len=$((len + add))
    done
    if [[ -n "$out" ]]; then printf '%s%s' "$out" "$sep"; fi
    return 0
}

# --- Bot API endpoints -------------------------------------------------------

tg_get_me() {
    if ! tg_call getMe; then
        return 1
    fi
    printf '%s' "$TG_RESPONSE" | jq -r '.result.username // empty'
}

# tg_get_updates <offset> <timeout-seconds> -> one compact update per line
tg_get_updates() {
    local offset="${1:-0}" timeout="${2:-0}"
    local body
    body="$(jq -nc --argjson offset "$offset" --argjson timeout "$timeout" \
        '{offset: $offset, timeout: $timeout, allowed_updates: ["message","callback_query"]}')" || return 1
    if ! tg_call getUpdates "$body"; then
        return 1
    fi
    printf '%s' "$TG_RESPONSE" | jq -rc '.result[]? // empty' 2>/dev/null || true
}

# tg_markup_json <markup> -> Bot-API reply_markup object
# tg_kb (and tests) work with a bare row-array; the API needs an
# {"inline_keyboard": [...]} object. Pass already-wrapped objects through.
tg_markup_json() {
    local m="${1:-}"
    [[ -n "$m" ]] || return 0
    if [[ "$m" == \[* ]]; then
        printf '{"inline_keyboard":%s}' "$m"
    else
        printf '%s' "$m"
    fi
}

# tg_send_message <chat-id> <text> [reply-markup-json] -> message id of the last part
tg_send_message() {
    local chat="$1" text="$2" markup
    markup="$(tg_markup_json "${3:-}")"
    local -a parts=()
    local part
    while IFS= read -r -d $'\x1f' part || [[ -n "$part" ]]; do
        [[ -n "$part" ]] && parts+=("$part")
    done < <(tg_split_message "$text")

    ((${#parts[@]})) || parts=("$text")
    ((${#parts[@]} == 0)) && parts=("")

    local i last_id=""
    for i in "${!parts[@]}"; do
        local body
        body="$(jq -nc --arg chat "$chat" --arg text "${parts[$i]}" \
            --argjson markup "${markup:-null}" \
            '{chat_id: $chat, text: $text, parse_mode: "HTML",
              disable_web_page_preview: true}
             + (if $markup == null then {} else {reply_markup: $markup} end)')" || return 1
        tg_call sendMessage "$body" || return 1
        last_id="$(printf '%s' "$TG_RESPONSE" | jq -r '.result.message_id // empty')"
    done
    TG_LAST_MESSAGE_ID="$last_id"
    printf '%s' "$last_id"
}

# tg_edit_text <chat-id> <message-id> <text> [reply-markup-json]
tg_edit_text() {
    local chat="$1" msg_id="$2" text="$3" markup
    markup="$(tg_markup_json "${4:-}")"
    local body
    body="$(jq -nc --arg chat "$chat" --argjson mid "$msg_id" --arg text "$text" \
        --argjson markup "${markup:-null}" \
        '{chat_id: $chat, message_id: $mid, text: $text, parse_mode: "HTML",
          disable_web_page_preview: true}
         + (if $markup == null then {} else {reply_markup: $markup} end)')" || return 1
    # "message is not modified" is harmless when re-rendering the same menu.
    if ! tg_call editMessageText "$body"; then
        [[ "$TG_ERROR" == *"not modified"* ]] && return 0
        return 1
    fi
    return 0
}

# tg_answer_cb <callback-id> [text] [show-alert:0|1]
tg_answer_cb() {
    local cb="$1" text="${2:-}" alert="${3:-0}"
    local body
    body="$(jq -nc --arg cb "$cb" --arg text "$text" --argjson alert "$alert" \
        '{callback_query_id: $cb}
         + (if $text == "" then {} else {text: $text, show_alert: ($alert == 1)} end)')" || return 1
    tg_call answerCallbackQuery "$body" || return 1
}

# tg_send_photo <chat-id> <file> [caption] [reply-markup-json]
tg_send_photo() {
    local chat="$1" file="$2" caption="${3:-}" markup="${4:-}"
    [[ -s "$file" ]] || return 1
    tg_call_upload sendPhoto photo "$file" "chat_id=${chat}" "caption=${caption}" \
        "parse_mode=HTML" ${markup:+"reply_markup=$(tg_markup_json "$markup")"} || return 1
    TG_LAST_MESSAGE_ID="$(printf '%s' "$TG_RESPONSE" | jq -r '.result.message_id // empty')"
    printf '%s' "$TG_LAST_MESSAGE_ID"
}

# tg_send_document <chat-id> <file> [caption]
tg_send_document() {
    local chat="$1" file="$2" caption="${3:-}"
    [[ -s "$file" ]] || return 1
    tg_call_upload sendDocument document "$file" "chat_id=${chat}" ${caption:+"caption=${caption}"} \
        "parse_mode=HTML" || return 1
    TG_LAST_MESSAGE_ID="$(printf '%s' "$TG_RESPONSE" | jq -r '.result.message_id // empty')"
    printf '%s' "$TG_LAST_MESSAGE_ID"
}

# tg_delete_message <chat-id> <message-id>
tg_delete_message() {
    local chat="$1" msg_id="$2"
    local body
    body="$(jq -nc --arg chat "$chat" --argjson mid "$msg_id" '{chat_id: $chat, message_id: $mid}')" || return 1
    tg_call deleteMessage "$body" || return 1
}

# tg_chat_action <chat-id> <action>
tg_chat_action() {
    local chat="$1" action="${2:-typing}"
    local body
    body="$(jq -nc --arg chat "$chat" --arg action "$action" '{chat_id: $chat, action: $action}')" || return 1
    tg_call sendChatAction "$body" || return 1
}

# tg_valid_token <token> -> format check only (no network)
tg_valid_token() {
    [[ "$1" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,60}$ ]]
}
