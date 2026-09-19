#!/usr/bin/env bash
# Tests for lib/common.sh — pure helpers, state file round-trips, file writing.
# shellcheck source=../lib/load.sh
source "${TEST_DIR}/../lib/load.sh"

test_port_and_ip_validation() {
    assert_true  is_port 443 || fail "443 باید پورت معتبر باشد"
    assert_true  is_port 65535 || fail "65535 باید معتبر باشد"
    assert_false is_port 0 || fail "0 پورت نیست"
    assert_false is_port 65536 || fail "65536 پورت نیست"
    assert_false is_port abc || fail "abc پورت نیست"
    assert_false is_port "" || fail "رشتهٔ خالی پورت نیست"

    assert_true  is_ipv4 1.2.3.4 || fail "1.2.3.4 معتبر است"
    assert_true  is_ipv4 255.255.255.255 || fail "255.255.255.255 معتبر است"
    assert_false is_ipv4 1.2.3.256 || fail "256 در هر اکتت مجاز نیست"
    assert_false is_ipv4 1.2.3 || fail "آدرس ناقص معتبر نیست"
    assert_false is_ipv4 example.com || fail "دامنه IPv4 نیست"
}

test_boolean_parsing() {
    assert_true  is_true yes || fail "yes"
    assert_true  is_true TRUE || fail "TRUE"
    assert_true  is_true 1 || fail "1"
    assert_true  is_true بله || fail "بله"
    assert_false is_true no || fail "no"
    assert_true  is_false off || fail "off"
    assert_true  is_false غیرفعال || fail "غیرفعال"
}

test_base_path_raw() {
    assert_eq ""      "$(base_path_raw '/')"            "مسیر ریشه" || return 1
    assert_eq "abc"   "$(base_path_raw '/abc/')"        "حذف اسلش‌ها" || return 1
    assert_eq "a/b"   "$(base_path_raw '/a/b/')"        "حذف فقط اسلش ابتدا/انتها" || return 1
}

test_base_path_normalisation() {
    assert_eq "/"      "$(normalise_base_path '')"          "مسیر خالی باید ریشه شود" || return 1
    assert_eq "/"      "$(normalise_base_path '/')"         "اسلش تنها باید ریشه شود" || return 1
    assert_eq "/abc/"  "$(normalise_base_path 'abc')"       "مسیر بدون اسلش" || return 1
    assert_eq "/abc/"  "$(normalise_base_path '/abc/')"     "مسیر با اسلش دو طرف" || return 1
    assert_eq "/sec12/" "$(normalise_base_path 'sec12')"    "کاراکترهای مجاز" || return 1
    # characters that could break a URL path are stripped, never escaped
    assert_eq "/etcpasswd/" "$(normalise_base_path '../../etc/passwd')" \
        "کاراکترهای خطرناک حذف می‌شوند" || return 1
    assert_eq "/"      "$(normalise_base_path '%$#@')"      "ورودی کاملاً غیرمجاز" || return 1
}

test_base_path_join() {
    assert_eq "/panel/api/x" "$(base_path_join '/' '/panel/api/x')"        "ریشه" || return 1
    assert_eq "/sec/panel/api/x" "$(base_path_join '/sec/' 'panel/api/x')" "با مسیر مخفی" || return 1
    assert_eq "/sec/panel" "$(base_path_join '/sec/' '/panel')"            "بدون اسلش دوگانه" || return 1
}

test_url_encode() {
    assert_eq "abc-123_x.y~z" "$(url_encode 'abc-123_x.y~z')" "کاراکترهای امن تغییر نمی‌کنند" || return 1
    assert_eq "a%20b"  "$(url_encode 'a b')"   "فاصله" || return 1
    assert_eq "a%2Fb"  "$(url_encode 'a/b')"   "اسلش" || return 1
    assert_eq "%40name" "$(url_encode '@name')" "ات‌ساین" || return 1
    assert_eq ""       "$(url_encode '')"      "رشتهٔ خالی" || return 1
}

test_random_helpers() {
    local hex pass
    hex="$(rand_hex 8)"
    assert_eq 16 "${#hex}" "rand_hex 8 باید ۱۶ کاراکتر بدهد" || return 1
    assert_match '^[0-9a-f]{16}$' "$hex" "خروجی rand_hex باید hex باشد" || return 1

    pass="$(rand_password 24)"
    assert_eq 24 "${#pass}" "طول رمز" || return 1

    assert_true assert_match '^[A-Za-z0-9]{10}$' "$(rand_string 10)" "rand_string پیش‌فرض" || return 1
}

test_shell_quote_round_trip() {
    # shellcheck disable=SC2016  # the test feeds a literal $ through quoting
    local value='a b"c'\''d$e\f'
    local quoted; quoted="$(shell_quote "$value")"
    local round; round="$(eval "printf '%s' ${quoted}")"
    assert_eq "$value" "$round" "shell_quote باید دور رفت و برگشت امن باشد"
}

test_state_file_round_trip() {
    local value=$'hi "there" \\ \'quoted\' $HOME / مسیر جدید\nخط دوم'
    state_set TRICKY "$value"
    local got; got="$(state_get TRICKY)"
    assert_eq "$value" "$got" "مقدار پیچیده باید سالم برگردد" || return 1

    state_set SIMPLE "hello"
    assert_eq "hello" "$(state_get SIMPLE)" "مقدار ساده" || return 1
    assert_eq "fallback" "$(state_get MISSING_KEY fallback)" "مقدار پیش‌فرض" || return 1

    # updating an existing key must not duplicate it
    state_set SIMPLE "changed"
    assert_eq "changed" "$(state_get SIMPLE)" "به‌روزرسانی کلید" || return 1
    assert_eq 1 "$(grep -c '^SIMPLE=' "$VPN_SANAI_STATE_FILE")" "کلید نباید تکرار شود" || return 1

    local mode
    mode="$(stat -c '%a' "$VPN_SANAI_STATE_FILE")"
    assert_eq "600" "$mode" "دسترسی‌های فایل state" || return 1
}

test_read_env_value_formats() {
    local file="${VPN_SANAI_TEST_ROOT}/install-result.env"
    cat > "$file" <<'EOF'
XUI_USERNAME=admin
XUI_PASSWORD='p@ss word'
XUI_PANEL_PORT="2053"
XUI_WEB_BASE_PATH=/SecretPath/
XUI_API_TOKEN=$'tok\'en\\value'
XUI_DB_TYPE=sqlite
EOF

    assert_eq "admin"        "$(read_env_value "$file" XUI_USERNAME)"     "مقدار بدون کوتیشن" || return 1
    assert_eq 'p@ss word'    "$(read_env_value "$file" XUI_PASSWORD)"     "کوتیشن تک" || return 1
    assert_eq "2053"         "$(read_env_value "$file" XUI_PANEL_PORT)"   "کوتیشن دوگانه" || return 1
    assert_eq "/SecretPath/" "$(read_env_value "$file" XUI_WEB_BASE_PATH)" "مسیر" || return 1
    assert_eq "tok'en\\value" "$(read_env_value "$file" XUI_API_TOKEN)"   "قالب $'...'" || return 1
    assert_false read_env_value "$file" XUI_DOES_NOT_EXIST || fail "کلید ناموجود باید ناموفق باشد"
}

test_atomic_write_modes() {
    local target="${VPN_SANAI_TEST_ROOT}/nested/dir/file.txt"
    atomic_write "$target" 640 "payload"
    assert_eq "payload" "$(cat "$target")" "محتوا" || return 1
    assert_eq "640" "$(stat -c '%a' "$target")" "سطح دسترسی" || return 1

    atomic_write "$target" 640 "replaced"
    assert_eq "replaced" "$(cat "$target")" "جایگزینی اتمیک" || return 1
    assert_eq 0 "$(find "$(dirname "$target")" -name '.file.txt.*' | wc -l)" \
        "فایل موقت نباید باقی بماند" || return 1
}

test_retry_helper() {
    COUNTER_FILE="$(mktemp)"; echo 0 > "$COUNTER_FILE"
    # shellcheck disable=SC2329  # invoked indirectly by retry()
    flaky() {
        local n; n="$(cat "$COUNTER_FILE")"; n=$((n + 1)); echo "$n" > "$COUNTER_FILE"
        ((n >= 3))
    }
    retry 5 0 flaky || fail "retry باید بعد از سه تلاش موفق شود"
    assert_eq "3" "$(cat "$COUNTER_FILE")" "تعداد تلاش‌ها" || return 1
    rm -f "$COUNTER_FILE"
}

test_port_in_use_detection() {
    has_cmd python3 || return 0
    local port_file; port_file="$(mktemp)"
    python3 - "$port_file" <<'PY' &
import socket, sys, time
sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 0))
sock.listen(1)
with open(sys.argv[1], "w") as fh:
    fh.write(str(sock.getsockname()[1]))
time.sleep(10)
PY
    local pid=$! port="" i
    for i in $(seq 1 40); do
        port="$(cat "$port_file" 2>/dev/null || true)"
        [[ -n "$port" ]] && break
        sleep 0.1
    done
    [[ -n "$port" ]] || { kill "$pid" 2>/dev/null || true; return 0; }

    assert_true port_in_use "$port" || { kill "$pid" 2>/dev/null; return 1; }

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    # CI sandboxes may mirror local listeners on another interface with
    # SO_REUSEADDR and release them with ~1s delay — poll instead of a fixed
    # sleep so the assertion stays meaningful everywhere.
    for i in $(seq 1 50); do
        port_in_use "$port" || break
        sleep 0.1
    done
    assert_false port_in_use "$port" || fail "پورت آزادشده نباید اشغال گزارش شود"
    rm -f "$port_file"
}

test_random_port_is_free() {
    local port
    port="$(rand_port 20000 45000)"
    assert_true is_port "$port" || fail "rand_port باید پورت معتبر بدهد"
    assert_false port_in_use "$port" || fail "rand_port نباید پورت اشغال بدهد"
}

test_atomic_write_guarantees_trailing_newline() {
    # Regression: atomic_write saved content verbatim, and the caller passed
    # "$(...)" output whose trailing newline is always stripped — so later
    # `>>` appends glued onto the last key=value line and corrupted state.env.
    local f; f="$(mktemp)"
    atomic_write "$f" 600 "A=1"
    echo "B=2" >> "$f"
    local last; last="$(tail -1 "$f")"
    rm -f "$f"
    [[ "$last" == "B=2" ]] || fail "خط آخر نباید چسبیده باشد: ${last}"
}
