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
