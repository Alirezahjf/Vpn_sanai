#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: tests/run.sh
#  Zero-dependency test runner.
#
#     bash tests/run.sh            # all suites
#     bash tests/run.sh common     # only tests/test_common.sh
#     bash tests/run.sh -v         # verbose (show assertion values)
#
#  Every tests/test_*.sh defines test_* functions; each one runs in its own
#  subshell so a failure cannot leak state into the next test.
# =============================================================================
set -uo pipefail

TEST_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT_DIR="$(cd "${TEST_DIR}/.." && pwd)"

VERBOSE=0
FILTER=""
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=1 ;;
        *)            FILTER="$arg" ;;
    esac
done

PASS=0
FAIL=0
FAILED_TESTS=()
CURRENT_FILE=""

# --- assertion helpers available to every test -------------------------------
assert_eq() { # <expected> <actual> <message>
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    printf '    ✗ %s\n      expected: %s\n      actual  : %s\n' "$3" "$1" "$2" >&2
    return 1
}

assert_match() { # <regex> <value> <message>
    if [[ "$2" =~ $1 ]]; then
        return 0
    fi
    printf '    ✗ %s\n      regex   : %s\n      value   : %s\n' "$3" "$1" "$2" >&2
    return 1
}

assert_contains() { # <haystack> <needle> <message>
    if [[ "$1" == *"$2"* ]]; then
        return 0
    fi
    printf '    ✗ %s\n      missing : %s\n      in      : %.200s\n' "$3" "$2" "$1" >&2
    return 1
}

assert_true() { # <command...>
    local msg="شرط برقرار نشد: $*"
    if "$@"; then
        return 0
    fi
    printf '    ✗ %s\n' "$msg" >&2
    return 1
}

assert_false() {
    local msg="شرط باید برقرار نباشد: $*"
    if "$@"; then
        printf '    ✗ %s\n' "$msg" >&2
        return 1
    fi
    return 0
}

fail() { printf '    ✗ %s\n' "$1" >&2; return 1; }

# run_test <function>
run_test() {
    local fn="$1"
    local name="${fn#test_}"
    printf '  → %s ... ' "$name"

    local output status
    output="$( ( set -Eeuo pipefail; "$fn" ) 2>&1 )"
    status=$?

    if ((status == 0)); then
        printf 'ok\n'
        ((PASS++))
    else
        printf 'FAIL\n'
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        ((FAIL++))
        FAILED_TESTS+=("${CURRENT_FILE##*/}::${name}")
    fi
    ((VERBOSE)) && [[ -n "$output" ]] && printf '%s\n' "$output" | sed 's/^/    | /'
    return 0
}

# --- discover and run --------------------------------------------------------
declare -a FILES=()
while IFS= read -r f; do
    [[ -n "$FILTER" && "$f" != *"$FILTER"* ]] && continue
    FILES+=("$f")
done < <(find "$TEST_DIR" -maxdepth 1 -name 'test_*.sh' -type f | sort)

if ((${#FILES[@]} == 0)); then
    printf 'هیچ تستی پیدا نشد\n' >&2
    exit 1
fi

# Common environment for every test: keep the tests away from the real host.
export VPN_SANAI_TEST_ROOT="${VPN_SANAI_TEST_ROOT:-$(mktemp -d)}"
export VPN_SANAI_NONINTERACTIVE=1
export VPN_SANAI_QUIET=0
# Never touch /etc/vpn-sanai, /var/log or /var/backups from a test run.
export VPN_SANAI_ETC="${VPN_SANAI_TEST_ROOT}/etc"
export VPN_SANAI_STATE_FILE="${VPN_SANAI_ETC}/state.env"
export VPN_SANAI_LINKS_DIR="${VPN_SANAI_ETC}/links"
export VPN_SANAI_REPORT_FILE="${VPN_SANAI_ETC}/report.txt"
export VPN_SANAI_LOG_DIR="${VPN_SANAI_TEST_ROOT}/log"
export VPN_SANAI_BACKUP_DIR="${VPN_SANAI_TEST_ROOT}/backups"
mkdir -p "$VPN_SANAI_ETC" "$VPN_SANAI_LOG_DIR" "$VPN_SANAI_BACKUP_DIR"

printf '\n%s\n' "vpn-sanai test-suite"
for file in "${FILES[@]}"; do
    CURRENT_FILE="$file"
    printf '\n%s\n' "${file#"$ROOT_DIR"/}"
    # shellcheck source=/dev/null
    source "$file"

    mapfile -t FUNCS < <(declare -F | awk '{print $3}' | grep '^test_' | sort)
    if ((${#FUNCS[@]} == 0)); then
        printf '  (بدون تست)\n'
        continue
    fi
    for fn in "${FUNCS[@]}"; do
        run_test "$fn"
    done
    unset -f "${FUNCS[@]}" 2>/dev/null || true
done

printf '\n──────────────────────────────────────────────\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if ((FAIL > 0)); then
    printf 'failing tests:\n'
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
printf 'همهٔ تست‌ها موفق بودند ✓\n'
