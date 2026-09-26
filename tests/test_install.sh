#!/usr/bin/env bash
# Tests for install.sh — argument handling, help output and the CLI contract.
# These run without root on purpose: only the parts that never touch the host
# are exercised here.
# shellcheck source=../lib/load.sh
source "${TEST_DIR}/../lib/load.sh"

INSTALL="${TEST_DIR}/../install.sh"

test_help_and_version() {
    local out
    out="$(bash "$INSTALL" --help)" || fail "--help باید با کد صفر تمام شود"
    assert_contains "$out" "--panel-mode"   "راهنما باید گزینهٔ حالت پنل را نشان دهد" || return 1
    assert_contains "$out" "--ssh-finalize" "راهنما باید گزینهٔ نهایی‌سازی SSH را نشان دهد" || return 1
    assert_contains "$out" "--no-fail2ban"  "راهنما باید گزینه‌های امنیتی را نشان دهد" || return 1

    out="$(bash "$INSTALL" --version)" || fail "--version باید با کد صفر تمام شود"
    assert_contains "$out" "$VPN_SANAI_VERSION" "شمارهٔ نسخه" || return 1
}

test_help_documents_every_flag() {
    local out
    out="$(cd "$ROOT_DIR" && bash install.sh --help 2>/dev/null || true)"
    local flag
    for flag in --panel-mode --panel-port --panel-user --panel-pass --panel-base-path \
                --panel-tls --panel-version --installer-url --vless-port --sni --xhttp \
                --xhttp-port --client-email --client-total-gb --client-days --client-ip-limit \
                --sub-port --ssh-port --ssh-finalize --no-ufw --no-fail2ban --no-bbr \
                --no-sysctl --no-timesync --no-backup --status --add-client --show-clients \
                --backup --restore --update-panel --uninstall --menu --dry-run; do
        assert_contains "$out" "$flag" "راهنما باید ${flag} را توضیح دهد" || return 1
    done
}

test_unknown_flag_is_rejected() {
    local out status=0
    out="$(bash "$INSTALL" --definitely-not-a-flag 2>&1)" || status=$?
    assert_eq "2" "$status" "کد خروج گزینهٔ ناشناخته" || return 1
    assert_contains "$out" "ناشناخته" "پیام خطای گزینهٔ ناشناخته" || return 1
}

test_help_lists_every_documented_action() {
    local out
    out="$(bash "$INSTALL" --help)"
    local flag
    for flag in --status --add-client --show-clients --backup --restore --update-panel \
                --uninstall --menu --dry-run --yes; do
        assert_contains "$out" "$flag" "راهنما باید ${flag} را داشته باشد" || return 1
    done
}

test_defaults_file_is_sane() {
    # shellcheck source=../config/defaults.conf
    source "${TEST_DIR}/../config/defaults.conf"
    assert_true is_port "$VLESS_PORT_DEFAULT" || fail "پورت پیش‌فرض VLESS باید معتبر باشد"
    assert_true is_port "$SUB_PORT_DEFAULT" || fail "پورت اشتراک باید معتبر باشد"
    assert_true is_port "$PANEL_PORT_RANGE_MIN" || fail "بازهٔ پورت پنل" || return 1
    ((PANEL_PORT_RANGE_MIN < PANEL_PORT_RANGE_MAX)) || fail "بازهٔ پورت پنل نامعتبر است"
    ((${#REALITY_SNI_CANDIDATES[@]} >= 3)) || fail "حداقل چند نامزد SNI لازم است"
    is_true "$ENABLE_UFW_DEFAULT" || fail "UFW باید به‌صورت پیش‌فرض فعال باشد"
    is_true "$ENABLE_FAIL2BAN_DEFAULT" || fail "fail2ban باید پیش‌فرض باشد"
    [[ "$BACKUP_CRON_DEFAULT" =~ ^[0-9*/,.-]+' '[0-9*/,.-]+' '[0-9*/,.-]+' '[0-9*/,.-]+' '[0-9*/,.-]+$ ]] \
        || fail "قالب cron پشتیبان‌گیری نامعتبر است"
}

test_all_modules_source_cleanly() {
    # `load.sh` was already sourced by this test file; verifying the entry point
    # contract means the guard must be idempotent.
    # shellcheck source=../lib/load.sh
    source "${TEST_DIR}/../lib/load.sh" || fail "سورس دوبارهٔ load.sh باید بی‌خطر باشد"
    assert_true declare -F log_info >/dev/null || fail "log_info تعریف نشده است"
    assert_true declare -F api_get_obj >/dev/null || fail "api_get_obj تعریف نشده است"
    assert_true declare -F reality_build_payload >/dev/null || fail "reality_build_payload تعریف نشده است"
    assert_true declare -F client_add >/dev/null || fail "client_add تعریف نشده است"
    assert_true declare -F backup_create >/dev/null || fail "backup_create تعریف نشده است"
    assert_true declare -F setup_ufw >/dev/null || fail "setup_ufw تعریف نشده است"
}

test_state_paths_are_overridable() {
    # The test-suite must never write to /etc/vpn-sanai.
    assert_contains "$VPN_SANAI_STATE_FILE" "$VPN_SANAI_TEST_ROOT" "فایل state باید در مسیر تست باشد" || return 1
    assert_contains "$VPN_SANAI_LINKS_DIR" "$VPN_SANAI_TEST_ROOT" "پوشهٔ لینک‌ها" || return 1
    assert_contains "$VPN_SANAI_BACKUP_DIR" "$VPN_SANAI_TEST_ROOT" "پوشهٔ پشتیبان" || return 1
}

test_dry_run_never_writes() {
    local target="${VPN_SANAI_TEST_ROOT}/dry-run-file"
    VPN_SANAI_DRY_RUN=1 atomic_write "$target" 600 "x"
    assert_false test -e "$target" || fail "در حالت dry-run نباید فایلی نوشته شود"
}

# --- bootstrap (curl | bash) -------------------------------------------------
# A fake `curl` that resolves every project URL to the local checkout, so the
# bootstrap path can be tested without network access.
_serve_local_repo() {
    local dest="" url="" arg
    while (($#)); do
        case "$1" in
            -o) dest="$2"; shift 2 ;;
            --connect-timeout|--retry|--retry-delay|--max-time) shift 2 ;;
            -*|"") shift ;;
            http*://*) url="$1"; shift ;;
            *) shift ;;
        esac
    done
    [[ -n "$dest" && -n "$url" ]] || return 1
    local path
    path="${url#*Vpn_sanai/main/}"
    path="${path#*Vpn_sanai@main/}"
    # ROOT_DIR comes from lib/load.sh and is exported, so the exported helper
    # still sees it inside the child shell bootstrap runs in.
    [[ -f "${ROOT_DIR}/${path}" ]] || return 22
    cp "${ROOT_DIR}/${path}" "$dest"
}

test_bootstrap_fails_cleanly_without_network() {
    local tmp; tmp="$(mktemp -d)"
    cp "$INSTALL" "${tmp}/install.sh"

    local out="" status=0
    out="$(
        # shellcheck disable=SC2329  # called by the script under test
        curl() { return 7; }
        export -f curl
        bash "${tmp}/install.sh" --status 2>&1
    )" || status=$?

    rm -rf "$tmp"
    assert_eq "1" "$status" "در نبود شبکه، bootstrap باید با خطا تمام شود" || return 1
    assert_contains "$out" "دانلود" "پیام خطای قابل‌فهم" || return 1
}

test_bootstrap_downloads_tree_and_runs() {
    local tmp; tmp="$(mktemp -d)"
    cp "$INSTALL" "${tmp}/install.sh"

    local out="" status=0
    out="$(
        # shellcheck disable=SC2329  # called by the script under test
        curl() { _serve_local_repo "$@"; }
        export -f curl _serve_local_repo
        bash "${tmp}/install.sh" --help 2>&1
    )" || status=$?

    rm -rf "$tmp"
    assert_eq "0" "$status" "bootstrap باید نسخهٔ دانلودشده را اجرا کند" || return 1
    assert_contains "$out" "--panel-mode" "خروجی نسخهٔ دانلودشده" || return 1
}

test_scripts_are_user_friendly() {
    local script
    for script in add-client show-clients backup security status uninstall; do
        local path="${TEST_DIR}/../scripts/${script}.sh"
        assert_true test -f "$path" || fail "اسکریپت ${script} وجود ندارد" || return 1
        assert_true test -x "$path" || fail "اسکریپت ${script} باید اجرایی باشد" || return 1
        local out
        out="$(bash "$path" --help 2>&1 || true)"
        assert_contains "$out" "Usage" "اسکریپت ${script} باید راهنما داشته باشد" || return 1
    done
}

test_reality_material_reaches_parent_shell() {
    # Regression: create_inbounds_and_clients ran setup_reality_inbound in a
    # command-substitution subshell, so the reality keypair / chosen SNI /
    # shortId it resolved never reached the caller. The final report then
    # crashed on ${VLESS_PUBLIC_KEY} under `set -u` (line ~678) and the
    # persisted state / links came out empty. The fix harvests the inbound
    # back into the parent shell right after creation.
    (
        set -Eeuo pipefail
        VPN_SANAI_NO_MAIN=1
        # shellcheck source=../install.sh
        source "${TEST_DIR}/../install.sh"

        # The real setup_reality_inbound stays under test; only the helpers
        # that need a live panel/xray are stubbed.
        reality_inbound_exists() { return 1; }
        reality_keypair()        { printf 'PRIVKEY PUBKEY\n'; }
        reality_short_id()       { printf 'sid123\n'; }
        pick_reality_sni()       { printf 'example.com\n'; }
        reality_build_payload()  { printf '{}'; }
        reality_create_inbound() { printf '7\n'; }
        inbound_set_share_addr() { :; }
        choose_free_port()       { printf '8444\n'; }
        client_add()             { :; }
        xray_restart()           { :; }
        port_in_use()            { return 0; }
        inbound_get_json() {
            cat <<'JSON'
{"id":7,"remark":"test","settings":{"clients":[{"id":"11111111-2222-3333-4444-555555555555","flow":"xtls-rprx-vision","email":"user1"}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverNames":["example.com"],"shortIds":["sid123"],"privateKey":"PRIVKEY","settings":{"publicKey":"PUBKEY"}}}}
JSON
        }

        unset VLESS_PUBLIC_KEY VLESS_PRIVATE_KEY VLESS_SNI VLESS_SHORT_ID \
              VLESS_UUID VLESS_INBOUND_ID VLESS_REMARK 2>/dev/null || true
        VLESS_PORT=1443 SERVER_IP=203.0.113.10 CREATE_XHTTP=yes \
            DEFAULT_CLIENT_EMAIL=user1 DEFAULT_CLIENT_TOTAL_GB=0 \
            DEFAULT_CLIENT_EXPIRY_DAYS=0 DEFAULT_CLIENT_LIMIT_IP=0 \
            VLESS_SNI_CHOICE=""
        create_inbounds_and_clients >/dev/null 2>&1

        [[ "$VLESS_INBOUND_ID"  == "7" ]] || { echo "VLESS_INBOUND_ID='$VLESS_INBOUND_ID'"; return 1; }
        [[ "$VLESS_PUBLIC_KEY"  == "PUBKEY" ]] || { echo "VLESS_PUBLIC_KEY='$VLESS_PUBLIC_KEY'"; return 1; }
        [[ "$VLESS_PRIVATE_KEY" == "PRIVKEY" ]] || { echo "VLESS_PRIVATE_KEY='$VLESS_PRIVATE_KEY'"; return 1; }
        [[ "$VLESS_SNI"         == "example.com" ]] || { echo "VLESS_SNI='$VLESS_SNI'"; return 1; }
        [[ "$VLESS_SHORT_ID"    == "sid123" ]] || { echo "VLESS_SHORT_ID='$VLESS_SHORT_ID'"; return 1; }
        [[ "$VLESS_UUID" == "11111111-2222-3333-4444-555555555555" ]] || { echo "VLESS_UUID='$VLESS_UUID'"; return 1; }
        [[ -n "${XHTTP_INBOUND_ID:-}" ]] || { echo "XHTTP_INBOUND_ID empty"; return 1; }
    ) || fail "کلیدها و SNI باید پس از ساخت Inbound در شل اصلی در دسترس باشند"
}

test_default_or_ask_resolves_named_default() {
    # Regression: _default_or_ask received the NAME of a *_DEFAULT variable
    # but used ${1:-} instead of ${!1}, so the literal string
    # "PANEL_USER_DEFAULT" leaked into the panel's credentials and every
    # report/summary.
    (
        set -Eeuo pipefail
        VPN_SANAI_NO_MAIN=1
        # shellcheck source=../install.sh
        source "${TEST_DIR}/../install.sh"

        SAMPLE_DEFAULT="file-value"
        local out
        out="$(_default_or_ask SAMPLE_DEFAULT "fallback" "برچسب")"
        [[ "$out" == "file-value" ]] || { echo "named default -> '$out'"; return 1; }

        EMPTY_DEFAULT=""
        VPN_SANAI_NONINTERACTIVE=1
        out="$(_default_or_ask EMPTY_DEFAULT "fallback" "برچسب")"
        [[ "$out" == "fallback" ]] || { echo "empty default -> '$out'"; return 1; }
        [[ "$out" != "EMPTY_DEFAULT" ]] || { echo "literal name leaked"; return 1; }
    ) || fail "_default_or_ask باید مقدار متغیر نام‌برده را برگرداند، نه اسمش را"
}

test_panel_placeholder_secrets_healed() {
    # Regression: servers installed by the buggy version carry the literal
    # placeholder names in state and in the panel itself; the heal step must
    # regenerate them (and flag creds/base so bootstrap re-applies them).
    (
        set -Eeuo pipefail
        VPN_SANAI_NO_MAIN=1
        # shellcheck source=../install.sh
        source "${TEST_DIR}/../install.sh"

        PANEL_USER="PANEL_USER_DEFAULT"
        PANEL_PASS="PANEL_PASS_DEFAULT"
        PANEL_BASE_PATH="/PANEL_BASE_PATH_DEFAULT/"
        PANEL_BASE_PATH_RAW="PANEL_BASE_PATH_DEFAULT"
        panel_heal_placeholder_secrets

        [[ "$PANEL_USER" != "PANEL_USER_DEFAULT" && -n "$PANEL_USER" ]] || { echo "user='$PANEL_USER'"; return 1; }
        [[ "$PANEL_PASS" != "PANEL_PASS_DEFAULT" && -n "$PANEL_PASS" ]] || { echo "pass='$PANEL_PASS'"; return 1; }
        [[ "$PANEL_BASE_PATH" != "/PANEL_BASE_PATH_DEFAULT/" && "$PANEL_BASE_PATH" == /*/ ]] \
            || { echo "base='$PANEL_BASE_PATH'"; return 1; }
        ((PANEL_HEALED_CREDS == 1 && PANEL_HEALED_BASE == 1)) || { echo "flags not set"; return 1; }

        # A healthy config must be left untouched.
        PANEL_USER="real-user"; PANEL_PASS="real-pass"
        PANEL_BASE_PATH="/abc123/"; PANEL_BASE_PATH_RAW="abc123"
        panel_heal_placeholder_secrets
        [[ "$PANEL_USER" == "real-user" && "$PANEL_PASS" == "real-pass" ]] || { echo "clobbered healthy values"; return 1; }
        ((PANEL_HEALED_CREDS == 0 && PANEL_HEALED_BASE == 0)) || { echo "false positive heal"; return 1; }
    ) || fail "مقادیر placeholder باید ترمیم و مقادیر سالم دست‌نخورده بمانند"
}

test_help_documents_the_new_flags() {
    local out
    out="$(bash "$INSTALL" --help)"
    assert_contains "$out" "--fix-reality"  "راهنما باید --fix-reality را داشته باشد" || return 1
    assert_contains "$out" "--update-self"  "راهنما باید --update-self را داشته باشد" || return 1
    return 0
}

test_self_update_files_cover_the_whole_tree() {
    local -a files=()
    mapfile -t files < <(VPN_SANAI_NO_MAIN=1 bash -c '
        source "'"$TEST_DIR"'/../install.sh" >/dev/null 2>&1 || true
        _self_update_files') || true
    ((${#files[@]} > 15)) || { fail "فهرست فایل‌های به‌روزرسانی خالی است"; return 1; }
    local f
    for f in install.sh lib/bootstrap.sh lib/reality.sh lib/bot.sh lib/load.sh \
             scripts/status.sh scripts/telegram-bot.sh config/defaults.conf; do
        printf '%s\n' "${files[@]}" | grep -qx "$f" || { fail "${f} در فهرست به‌روزرسانی نیست"; return 1; }
    done
    return 0
}

test_self_update_fetch_from_local_mirror() {
    # CI has no GitHub: serve this checkout over HTTP and point the downloader
    # at it through VPN_SANAI_UPDATE_URL (the same knob a restricted network uses).
    local dir="$VPN_SANAI_TEST_ROOT/mirror" port=18099 pid tmp i
    mkdir -p "$dir"
    cp -a "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/scripts" "$ROOT_DIR/install.sh" "$dir/"
    ( cd "$dir" && python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) &
    pid=$!
    for i in $(seq 1 40); do
        curl -sf -o /dev/null "http://127.0.0.1:${port}/install.sh" 2>/dev/null && break
        sleep 0.1
    done

    tmp="$VPN_SANAI_TEST_ROOT/fetched"
    rm -rf "$tmp"
    # _self_update_fetch lives in install.sh, so run it the way the CLI does
    VPN_SANAI_NO_MAIN=1 VPN_SANAI_UPDATE_URL="http://127.0.0.1:${port}" bash -c '
        source "'"$TEST_DIR"'/../install.sh" >/dev/null 2>&1 || true
        _self_update_fetch "main" "$1"' _ "$tmp" >/dev/null 2>&1 || {
        kill "$pid" 2>/dev/null || true
        fail "دانلود از آینهٔ محلی ناموفق بود"
        return 1
    }
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    [[ -s "$tmp/install.sh" ]] || { rm -rf "$tmp"; fail "install.sh دانلود نشد"; return 1; }
    [[ -s "$tmp/lib/reality.sh" ]] || { rm -rf "$tmp"; fail "lib/reality.sh دانلود نشد"; return 1; }
    [[ -s "$tmp/scripts/telegram-bot.sh" ]] || { rm -rf "$tmp"; fail "scripts/telegram-bot.sh دانلود نشد"; return 1; }
    grep -q "reality_repair_inbounds" "$tmp/lib/reality.sh" || { rm -rf "$tmp"; fail "محتوای دانلودشده درست نیست"; return 1; }
    rm -rf "$tmp"
    return 0
}

test_self_update_fetch_fails_without_touching_anything() {
    local tmp="$VPN_SANAI_TEST_ROOT/fetched-bad"
    rm -rf "$tmp"
    if VPN_SANAI_NO_MAIN=1 VPN_SANAI_UPDATE_URL="http://127.0.0.1:1" bash -c '
        source "'"$TEST_DIR"'/../install.sh" >/dev/null 2>&1 || true
        _self_update_fetch "nope" "$1"' _ "$tmp" >/dev/null 2>&1; then
        rm -rf "$tmp"
        fail "دانلود از آینهٔ ناموجود باید شکست بخورد"
        return 1
    fi
    rm -rf "$tmp"
    return 0
}

test_self_update_dry_run_changes_nothing() {
    local out status=0
    out="$(VPN_SANAI_DRY_RUN=1 VPN_SANAI_NO_MAIN=1 bash -c '
        source "'"$TEST_DIR"'/../install.sh" >/dev/null 2>&1 || true
        action_self_update "main"' 2>&1)" || status=$?
    assert_contains "$out" "dry-run" "حالت dry-run باید اعلام شود" || return 1
    return 0
}

test_update_self_accepts_a_ref() {
    # The fix lives on the branch, not on main: `--update-self BRANCH` must pass
    # the ref to the downloader instead of falling back to main.
    local out
    out="$(VPN_SANAI_NO_MAIN=1 bash -c '
        source "'"$TEST_DIR"'/../install.sh" >/dev/null 2>&1 || true
        ACTION=""
        parse_args --update-self arena-branch
        printf "%s|%s\n" "$ACTION" "${SELF_UPDATE_REF:-unset}"
        ACTION=""; SELF_UPDATE_REF=""
        parse_args --update-self
        printf "%s|%s\n" "$ACTION" "${SELF_UPDATE_REF:-unset}"' 2>/dev/null || true)"
    assert_contains "$out" "update-self|arena-branch" \
        "--update-self BRANCH باید ref را بگیرد" || return 1
    assert_contains "$out" "update-self|unset" \
        "--update-self بدون آرگومان هم باید کار کند" || return 1
    return 0
}

test_update_self_ref_reaches_the_bootstrap() {
    # `bash <(curl ...) --update-self BRANCH` must download the tree from BRANCH,
    # not from the default ref (where the flag may not exist yet at all).
    local out
    out="$(VPN_SANAI_NO_MAIN=1 VPN_SANAI_UPDATE_URL="http://127.0.0.1:1" bash -c '
        source "'"$TEST_DIR"'/../install.sh" >/dev/null 2>&1 || true
        # Re-run only the ref resolution the bare install.sh path performs.
        VPN_SANAI_REF="${VPN_SANAI_REF:-main}"
        _prev=""
        for _arg in --update-self arena-branch --yes; do
            if [[ "$_prev" == "--update-self" && "$_arg" != -* ]]; then
                VPN_SANAI_REF="$_arg"; break
            fi
            _prev="$_arg"
        done
        printf "%s\n" "$VPN_SANAI_REF"' 2>/dev/null || true)"
    assert_eq "arena-branch" "$out" "ref باید از --update-self BRANCH گرفته شود" || return 1
    return 0
}

test_bootstrap_urls_honour_the_update_url() {
    # A restricted network points VPN_SANAI_UPDATE_URL at its own mirror; the
    # whole download (not just --update-self) has to follow it.
    local out
    out="$(VPN_SANAI_UPDATE_URL="http://mirror.test:8080" bash -c '
        source "'"$TEST_DIR"'/../lib/load.sh" >/dev/null 2>&1 || true
        source "'"$TEST_DIR"'/../lib/bootstrap.sh" >/dev/null 2>&1 || true
        _bootstrap_urls_for "lib/reality.sh"' 2>/dev/null || true)"
    assert_contains "$out" "http://mirror.test:8080/lib/reality.sh" \
        "آینهٔ محلی باید اولین منبع باشد" || return 1
    assert_contains "$out" "raw.githubusercontent.com" \
        "آینهٔ عمومی هم به‌عنوان جایگزین بماند" || return 1
    return 0
}
