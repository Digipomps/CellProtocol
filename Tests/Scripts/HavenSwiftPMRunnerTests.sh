#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
RUNNER="$REPO_ROOT/Scripts/haven-swiftpm.sh"
FAKE_SWIFT="$SCRIPT_DIR/Fixtures/fake-swift.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/haven-swiftpm-tests.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if [ "$expected" != "$actual" ]; then
        fail "$message (expected '$expected', got '$actual')"
    fi
}

assert_exists() {
    [ -e "$1" ] || fail "$2"
}

assert_absent() {
    [ ! -e "$1" ] || fail "$2"
}

cache_count() {
    find "$1/caches" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

only_cache_dir() {
    local root="$1"
    local count cache_dir
    count="$(cache_count "$root")"
    assert_equal "1" "$count" "expected exactly one managed cache"
    cache_dir="$(find "$root/caches" -mindepth 1 -maxdepth 1 -type d -print | head -n 1)"
    printf '%s\n' "$cache_dir"
}

initialize_root() {
    local root="$1"
    "$RUNNER" --cache-root "$root" --max-age-seconds 0 --max-cache-kib 0 --gc-only
}

make_marked_cache() {
    local root="$1"
    local hash="$2"
    local cache_dir="$root/caches/$hash"
    mkdir -p "$cache_dir"
    printf 'haven-swiftpm-cache-v1\n' > "$cache_dir/.haven-swiftpm-cache-v1"
    : > "$cache_dir/.last-used"
    printf '%s\n' "$cache_dir"
}

wait_for_file() {
    local path="$1"
    local attempts=0
    while [ ! -e "$path" ] && [ "$attempts" -lt 100 ]; do
        sleep 0.05
        attempts=$((attempts + 1))
    done
    assert_exists "$path" "timed out waiting for fake Swift to start"
}

test_basic_run() {
    local root="$TEST_ROOT/basic"
    local log="$root.log"
    local cache_dir scratch_arg cache_arg
    FAKE_SWIFT_LOG="$log" SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key basic --max-age-seconds 0 --max-cache-kib 0 -- test --filter ExampleTests

    cache_dir="$(only_cache_dir "$root")"
    assert_exists "$cache_dir/.haven-swiftpm-cache-v1" "runner did not create ownership marker"
    assert_equal "0" "$(find "$root/leases" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "lease was not released"
    scratch_arg="$(awk '/^ARG:--scratch-path$/{getline; sub(/^ARG:/, ""); print; exit}' "$log")"
    assert_equal "$cache_dir" "$scratch_arg" "runner did not inject the managed scratch path"
    cache_arg="$(awk '/^ARG:--cache-path$/{getline; sub(/^ARG:/, ""); print; exit}' "$log")"
    assert_equal "$cache_dir/swiftpm-cache" "$cache_arg" "runner did not inject the managed SwiftPM cache path"
    assert_exists "$cache_dir/clang-module-cache" "runner did not create a bounded module cache"
    grep -q "^ENV:CLANG_MODULE_CACHE_PATH=$cache_dir/clang-module-cache$" "$log" || fail "module cache environment escaped the managed cache"
    grep -q "^ENV:SWIFTPM_MODULECACHE_OVERRIDE=$cache_dir/clang-module-cache$" "$log" || fail "SwiftPM module cache override escaped the managed cache"
    grep -q '^ARG:--filter$' "$log" || fail "Swift arguments were not forwarded"
}

test_stable_cache_reuse() {
    local root="$TEST_ROOT/reuse"
    local log="$root.log"
    FAKE_SWIFT_LOG="$log" SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key stable --max-age-seconds 0 --max-cache-kib 0 -- test
    FAKE_SWIFT_LOG="$log" SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key stable --max-age-seconds 0 --max-cache-kib 0 -- build
    assert_equal "1" "$(cache_count "$root")" "same key created more than one cache"
    assert_equal "2" "$(grep -c '^BEGIN$' "$log")" "fake Swift did not run twice"
}

test_concurrent_lease_denial() {
    local root="$TEST_ROOT/concurrent"
    local log="$root.log"
    local started="$root.started"
    local first_pid second_status

    FAKE_SWIFT_LOG="$log" FAKE_SWIFT_STARTED="$started" FAKE_SWIFT_SLEEP=2 SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key shared --wait-seconds 5 --max-age-seconds 0 --max-cache-kib 0 -- test &
    first_pid=$!
    wait_for_file "$started"

    set +e
    FAKE_SWIFT_LOG="$log" SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key shared --wait-seconds 0 --max-age-seconds 0 --max-cache-kib 0 -- test
    second_status=$?
    set -e
    assert_equal "75" "$second_status" "busy cache did not return EX_TEMPFAIL"
    wait "$first_pid"
    assert_equal "1" "$(grep -c '^BEGIN$' "$log")" "second Swift process ran despite the active lease"
}

test_stale_lease_recovery() {
    local root="$TEST_ROOT/stale"
    local cache_dir hash lease_dir log="$root.log"
    FAKE_SWIFT_LOG="$log" SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key stale --max-age-seconds 0 --max-cache-kib 0 -- test
    cache_dir="$(only_cache_dir "$root")"
    hash="${cache_dir##*/}"
    lease_dir="$root/leases/$hash"
    mkdir "$lease_dir"
    printf '999999\n' > "$lease_dir/pid"
    printf 'not-this-process\n' > "$lease_dir/process_start"
    printf 'stale-token\n' > "$lease_dir/token"

    FAKE_SWIFT_LOG="$log" SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key stale --wait-seconds 1 --max-age-seconds 0 --max-cache-kib 0 -- build
    assert_absent "$lease_dir" "stale lease was not recovered and released"
}

test_orphan_open_files_block_reentry() {
    local root="$TEST_ROOT/orphan-open"
    local cache_dir hash lease_dir log="$root.log"
    local status
    FAKE_SWIFT_LOG="$log" SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key orphan-open --max-age-seconds 0 --max-cache-kib 0 -- test
    cache_dir="$(only_cache_dir "$root")"
    hash="${cache_dir##*/}"
    lease_dir="$root/leases/$hash"
    mkdir "$lease_dir"
    printf '999999\n' > "$lease_dir/pid"
    printf 'not-this-process\n' > "$lease_dir/process_start"
    printf 'stale-token\n' > "$lease_dir/token"

    set +e
    PATH="$SCRIPT_DIR/Fixtures:$PATH" FAKE_LSOF_OPEN_PATH="$cache_dir" FAKE_SWIFT_LOG="$log" SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key orphan-open --wait-seconds 0 --max-age-seconds 0 --max-cache-kib 0 -- build
    status=$?
    set -e
    assert_equal "75" "$status" "runner reused a cache with orphaned open files"
    assert_equal "1" "$(grep -c '^BEGIN$' "$log")" "Swift ran while orphaned files were reported open"
    assert_absent "$lease_dir" "open-file rejection left a replacement lease"
}

test_package_path_override_is_rejected() {
    local root="$TEST_ROOT/package-path"
    local log="$root.log"
    local status
    set +e
    FAKE_SWIFT_LOG="$log" SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key package-path --max-age-seconds 0 --max-cache-kib 0 -- test --package-path /private/tmp/other-package
    status=$?
    set -e
    assert_equal "64" "$status" "runner accepted a package path outside its cache identity"
    assert_absent "$log" "Swift ran after a rejected package path override"
}

test_managed_layout_rejects_symlink_escape() {
    local root="$TEST_ROOT/layout-symlink"
    local log="$root.log"
    local cache_dir outside status
    FAKE_SWIFT_LOG="$log" SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key layout-symlink --max-age-seconds 0 --max-cache-kib 0 -- test
    cache_dir="$(only_cache_dir "$root")"
    outside="$TEST_ROOT/outside-module-cache"
    mkdir "$outside"
    rm -rf "$cache_dir/clang-module-cache"
    ln -s "$outside" "$cache_dir/clang-module-cache"

    set +e
    FAKE_SWIFT_LOG="$log" SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key layout-symlink --max-age-seconds 0 --max-cache-kib 0 -- build
    status=$?
    set -e
    assert_equal "64" "$status" "runner followed a managed cache symlink"
    assert_equal "1" "$(grep -c '^BEGIN$' "$log")" "Swift ran after a cache symlink was detected"
    assert_equal "0" "$(find "$outside" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "data escaped through the cache symlink"
    assert_equal "0" "$(find "$root/leases" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "symlink rejection left a lease"
}

test_age_gc_preserves_unmarked_data() {
    local root="$TEST_ROOT/age-gc"
    local hash cache_dir unmarked
    initialize_root "$root"
    hash="$(printf 'a%.0s' {1..64})"
    cache_dir="$(make_marked_cache "$root" "$hash")"
    touch -t 202001010000 "$cache_dir/.last-used"
    unmarked="$root/caches/do-not-delete"
    mkdir "$unmarked"
    printf 'private\n' > "$unmarked/data"

    "$RUNNER" --cache-root "$root" --max-age-seconds 1 --max-cache-kib 0 --gc-only
    assert_absent "$cache_dir" "age GC did not remove an inactive marked cache"
    assert_exists "$unmarked/data" "GC touched an unmarked directory"
}

test_gc_skips_live_lease() {
    local root="$TEST_ROOT/live-lease"
    local hash cache_dir lease_dir
    initialize_root "$root"
    hash="$(printf 'b%.0s' {1..64})"
    cache_dir="$(make_marked_cache "$root" "$hash")"
    touch -t 202001010000 "$cache_dir/.last-used"
    lease_dir="$root/leases/$hash"
    mkdir "$lease_dir"
    printf '%s\n' "$$" > "$lease_dir/pid"
    printf '\n' > "$lease_dir/process_start"
    printf 'live-test-token\n' > "$lease_dir/token"

    "$RUNNER" --cache-root "$root" --max-age-seconds 1 --max-cache-kib 0 --gc-only
    assert_exists "$cache_dir/.haven-swiftpm-cache-v1" "GC removed a live leased cache"
    rm -rf "$lease_dir"
}

test_ephemeral_cache() {
    local root="$TEST_ROOT/ephemeral"
    local log="$root.log"
    FAKE_SWIFT_LOG="$log" SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key ephemeral --ephemeral --max-age-seconds 0 --max-cache-kib 0 -- test
    assert_equal "0" "$(cache_count "$root")" "ephemeral cache was retained"
}

test_size_cap_removes_oldest() {
    local root="$TEST_ROOT/size-cap"
    local old_hash new_hash old_cache new_cache new_size
    initialize_root "$root"
    old_hash="$(printf 'c%.0s' {1..64})"
    new_hash="$(printf 'd%.0s' {1..64})"
    old_cache="$(make_marked_cache "$root" "$old_hash")"
    new_cache="$(make_marked_cache "$root" "$new_hash")"
    dd if=/dev/zero of="$old_cache/payload" bs=1024 count=16 >/dev/null 2>&1
    dd if=/dev/zero of="$new_cache/payload" bs=1024 count=16 >/dev/null 2>&1
    touch -t 202001010000 "$old_cache/.last-used"
    touch -t 202101010000 "$new_cache/.last-used"
    new_size="$(du -sk "$new_cache" | awk '{print $1}')"

    "$RUNNER" --cache-root "$root" --max-age-seconds 0 --max-cache-kib "$new_size" --gc-only
    assert_absent "$old_cache" "size GC did not remove the oldest cache"
    assert_exists "$new_cache/.haven-swiftpm-cache-v1" "size GC removed the newer cache"
}

test_exit_status_and_lease_cleanup() {
    local root="$TEST_ROOT/exit-status"
    local log="$root.log"
    local status
    set +e
    FAKE_SWIFT_LOG="$log" FAKE_SWIFT_EXIT=7 SWIFT_BIN="$FAKE_SWIFT" \
        "$RUNNER" --cache-root "$root" --cache-key exit-status --max-age-seconds 0 --max-cache-kib 0 -- test
    status=$?
    set -e
    assert_equal "7" "$status" "runner did not preserve Swift exit status"
    assert_equal "0" "$(find "$root/leases" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "failed Swift run left a lease"
}

test_basic_run
pass "managed scratch/module/cache paths and lease cleanup"
test_stable_cache_reuse
pass "stable cache reuse"
test_concurrent_lease_denial
pass "concurrent lease denial"
test_stale_lease_recovery
pass "stale lease recovery"
test_orphan_open_files_block_reentry
pass "orphaned open-file reentry protection"
test_package_path_override_is_rejected
pass "package path identity protection"
test_managed_layout_rejects_symlink_escape
pass "managed cache symlink protection"
test_age_gc_preserves_unmarked_data
pass "age GC and marker boundary"
test_gc_skips_live_lease
pass "live lease protection"
test_ephemeral_cache
pass "ephemeral cleanup"
test_size_cap_removes_oldest
pass "bounded size GC"
test_exit_status_and_lease_cleanup
pass "exit status and failure cleanup"

printf 'All Haven SwiftPM runner tests passed.\n'
