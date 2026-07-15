#!/usr/bin/env bash

set -euo pipefail

readonly MARKER_VALUE="haven-swiftpm-cache-v1"
readonly EX_USAGE=64
readonly EX_TEMPFAIL=75

SWIFT_BIN="${SWIFT_BIN:-swift}"
CACHE_KEY="${HAVEN_SWIFTPM_CACHE_KEY:-}"
MAX_AGE_SECONDS="${HAVEN_SWIFTPM_MAX_AGE_SECONDS:-259200}"
MAX_CACHE_KIB="${HAVEN_SWIFTPM_MAX_CACHE_KIB:-25165824}"
WAIT_SECONDS="${HAVEN_SWIFTPM_WAIT_SECONDS:-1800}"
POLL_SECONDS="${HAVEN_SWIFTPM_POLL_SECONDS:-2}"
EPHEMERAL=0
GC_ONLY=0
DRY_RUN=0

tmp_base="${TMPDIR:-/tmp}"
tmp_base="${tmp_base%/}"
if [ -z "$tmp_base" ]; then
    tmp_base="/tmp"
fi
CACHE_ROOT="${HAVEN_SWIFTPM_CACHE_ROOT:-$tmp_base/haven-swiftpm-bounded}"

CACHES_DIR=""
LEASES_DIR=""
CACHE_HASH=""
CURRENT_CACHE_DIR=""
MAIN_LEASE_TOKEN=""
MAIN_LEASE_HELD=0
CHILD_PID=""
GC_TMP_FILE=""

log() {
    printf '[haven-swiftpm] %s\n' "$*" >&2
}

die() {
    local message="$1"
    local status="${2:-$EX_USAGE}"
    log "ERROR: $message"
    exit "$status"
}

usage() {
    cat <<'EOF'
Usage:
  Scripts/haven-swiftpm.sh [options] -- <build|test|run|package> [arguments]
  Scripts/haven-swiftpm.sh [options] --gc-only

Options:
  --cache-root PATH         Managed cache root.
  --cache-key KEY           Stable cache family key. Derived from git/package if omitted.
  --max-age-seconds N       Remove inactive caches older than N (default: 259200; 0 disables).
  --max-cache-kib N         Total managed cache cap in KiB (default: 25165824; 0 disables).
  --wait-seconds N          Maximum wait for the same cache lease (default: 1800).
  --poll-seconds N          Lease polling interval (default: 2).
  --ephemeral               Remove this invocation's cache after Swift exits.
  --gc-only                 Run managed cache collection without invoking Swift.
  --dry-run                 Report cache deletions without performing them.
  --help                    Show this help.

Environment equivalents use the HAVEN_SWIFTPM_ prefix. SWIFT_BIN selects the
Swift executable. The runner only deletes cache directories carrying its exact
ownership marker beneath the managed cache root.
EOF
}

require_value() {
    local option="$1"
    local count="$2"
    if [ "$count" -lt 2 ]; then
        die "$option requires a value"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --cache-root)
            require_value "$1" "$#"
            CACHE_ROOT="$2"
            shift 2
            ;;
        --cache-key)
            require_value "$1" "$#"
            CACHE_KEY="$2"
            shift 2
            ;;
        --max-age-seconds)
            require_value "$1" "$#"
            MAX_AGE_SECONDS="$2"
            shift 2
            ;;
        --max-cache-kib)
            require_value "$1" "$#"
            MAX_CACHE_KIB="$2"
            shift 2
            ;;
        --wait-seconds)
            require_value "$1" "$#"
            WAIT_SECONDS="$2"
            shift 2
            ;;
        --poll-seconds)
            require_value "$1" "$#"
            POLL_SECONDS="$2"
            shift 2
            ;;
        --ephemeral)
            EPHEMERAL=1
            shift
            ;;
        --gc-only)
            GC_ONLY=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            die "unknown option before --: $1"
            ;;
    esac
done

is_nonnegative_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

for numeric_value in "$MAX_AGE_SECONDS" "$MAX_CACHE_KIB" "$WAIT_SECONDS" "$POLL_SECONDS"; do
    if ! is_nonnegative_integer "$numeric_value"; then
        die "retention and wait values must be non-negative integers"
    fi
done
if [ "$POLL_SECONDS" -eq 0 ]; then
    die "--poll-seconds must be greater than zero"
fi

if [ "$GC_ONLY" -eq 1 ] && [ "$#" -ne 0 ]; then
    die "--gc-only does not accept a Swift subcommand"
fi
if [ "$GC_ONLY" -eq 0 ] && [ "$#" -eq 0 ]; then
    die "missing Swift subcommand after --"
fi

stat_owner_uid() {
    if [ "$(uname -s)" = "Darwin" ]; then
        stat -f '%u' "$1"
    else
        stat -c '%u' "$1"
    fi
}

stat_mtime() {
    if [ "$(uname -s)" = "Darwin" ]; then
        stat -f '%m' "$1"
    else
        stat -c '%Y' "$1"
    fi
}

stat_size() {
    if [ "$(uname -s)" = "Darwin" ]; then
        stat -f '%z' "$1"
    else
        stat -c '%s' "$1"
    fi
}

initialize_cache_root() {
    if [ -z "$CACHE_ROOT" ] || [ "$CACHE_ROOT" = "/" ]; then
        die "refusing unsafe cache root"
    fi
    if [ -L "$CACHE_ROOT" ]; then
        die "cache root must not be a symbolic link: $CACHE_ROOT"
    fi

    mkdir -p "$CACHE_ROOT"
    if [ -L "$CACHE_ROOT" ]; then
        die "cache root became a symbolic link: $CACHE_ROOT"
    fi
    CACHE_ROOT="$(cd "$CACHE_ROOT" && pwd -P)"
    if [ "$CACHE_ROOT" = "/" ]; then
        die "refusing filesystem root as cache root"
    fi
    if [ "$(stat_owner_uid "$CACHE_ROOT")" != "$(id -u)" ]; then
        die "cache root is not owned by the current user: $CACHE_ROOT"
    fi
    chmod 700 "$CACHE_ROOT"

    CACHES_DIR="$CACHE_ROOT/caches"
    LEASES_DIR="$CACHE_ROOT/leases"
    for managed_dir in "$CACHES_DIR" "$LEASES_DIR"; do
        if [ -L "$managed_dir" ]; then
            die "managed directory must not be a symbolic link: $managed_dir"
        fi
        mkdir -p "$managed_dir"
        if [ -L "$managed_dir" ]; then
            die "managed directory became a symbolic link: $managed_dir"
        fi
        if [ "$(stat_owner_uid "$managed_dir")" != "$(id -u)" ]; then
            die "managed directory is not owned by the current user: $managed_dir"
        fi
        chmod 700 "$managed_dir"
    done
}

sha256_text() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    else
        die "shasum or sha256sum is required"
    fi
}

find_package_root() {
    local candidate
    candidate="$(pwd -P)"
    while [ "$candidate" != "/" ]; do
        if [ -f "$candidate/Package.swift" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        candidate="${candidate%/*}"
        if [ -z "$candidate" ]; then
            candidate="/"
        fi
    done
    return 1
}

derive_cache_hash() {
    local identity_material package_root repository_root remote_url package_relative
    if [ -n "$CACHE_KEY" ]; then
        identity_material="v1|explicit=$CACHE_KEY|swift=$SWIFT_BIN"
        sha256_text "$identity_material"
        return
    fi

    package_root="$(find_package_root)" || die "could not find Package.swift; provide --cache-key"
    repository_root="$(git -C "$package_root" rev-parse --show-toplevel 2>/dev/null || true)"
    remote_url="$(git -C "$package_root" remote get-url origin 2>/dev/null || true)"
    if [ -n "$repository_root" ]; then
        if [ "$package_root" = "$repository_root" ]; then
            package_relative="."
        else
            package_relative="${package_root#"$repository_root"/}"
        fi
    else
        repository_root="$package_root"
        package_relative="."
    fi
    if [ -z "$remote_url" ]; then
        remote_url="local:$repository_root"
    fi

    identity_material="v1|remote=$remote_url|package=$package_relative|swift=$SWIFT_BIN"
    sha256_text "$identity_material"
}

process_start_fingerprint() {
    ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

valid_hash() {
    if [ "${#1}" -ne 64 ]; then
        return 1
    fi
    case "$1" in
        *[!0-9a-f]*) return 1 ;;
        *) return 0 ;;
    esac
}

lease_dir_for_hash() {
    printf '%s/%s\n' "$LEASES_DIR" "$1"
}

lease_is_live() {
    local lease_dir="$1"
    local pid stored_start current_start age now modified

    if [ ! -d "$lease_dir" ] || [ -L "$lease_dir" ]; then
        return 1
    fi
    pid="$(sed -n '1p' "$lease_dir/pid" 2>/dev/null || true)"
    case "$pid" in
        ''|*[!0-9]*)
            now="$(date +%s)"
            modified="$(stat_mtime "$lease_dir" 2>/dev/null || printf '0')"
            age=$((now - modified))
            [ "$age" -le 30 ]
            return
            ;;
    esac
    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi

    stored_start="$(sed -n '1p' "$lease_dir/process_start" 2>/dev/null || true)"
    current_start="$(process_start_fingerprint "$pid")"
    if [ -n "$stored_start" ] && [ -n "$current_start" ] && [ "$stored_start" != "$current_start" ]; then
        return 1
    fi
    return 0
}

recover_stale_lease() {
    local hash="$1"
    local lease_dir stale_dir
    lease_dir="$(lease_dir_for_hash "$hash")"
    if lease_is_live "$lease_dir"; then
        return 1
    fi
    stale_dir="$LEASES_DIR/.stale-$hash-$$-$RANDOM"
    if mv "$lease_dir" "$stale_dir" 2>/dev/null; then
        rm -rf "$stale_dir"
        log "recovered stale lease for ${hash:0:12}"
        return 0
    fi
    return 1
}

try_claim_lease() {
    local hash="$1"
    local token="$2"
    local lease_dir attempt
    lease_dir="$(lease_dir_for_hash "$hash")"
    attempt=0

    while [ "$attempt" -lt 3 ]; do
        if mkdir "$lease_dir" 2>/dev/null; then
            chmod 700 "$lease_dir"
            printf '%s\n' "$$" > "$lease_dir/pid"
            process_start_fingerprint "$$" > "$lease_dir/process_start"
            printf '%s\n' "$token" > "$lease_dir/token"
            date +%s > "$lease_dir/created_at"
            return 0
        fi
        if lease_is_live "$lease_dir"; then
            return 1
        fi
        recover_stale_lease "$hash" || true
        attempt=$((attempt + 1))
    done
    return 1
}

release_named_lease() {
    local hash="$1"
    local token="$2"
    local lease_dir stored_token
    lease_dir="$(lease_dir_for_hash "$hash")"
    stored_token="$(sed -n '1p' "$lease_dir/token" 2>/dev/null || true)"
    if [ -n "$token" ] && [ "$stored_token" = "$token" ] && [ -d "$lease_dir" ] && [ ! -L "$lease_dir" ]; then
        rm -rf "$lease_dir"
    fi
}

acquire_main_lease() {
    local deadline now announced
    MAIN_LEASE_TOKEN="run-$$-$(date +%s)-$RANDOM-$RANDOM"
    deadline=$(( $(date +%s) + WAIT_SECONDS ))
    announced=0

    while true; do
        if try_claim_lease "$CACHE_HASH" "$MAIN_LEASE_TOKEN"; then
            if [ -d "$CURRENT_CACHE_DIR" ] && cache_has_open_files "$CURRENT_CACHE_DIR"; then
                release_named_lease "$CACHE_HASH" "$MAIN_LEASE_TOKEN"
            else
                MAIN_LEASE_HELD=1
                return
            fi
        fi
        now="$(date +%s)"
        if [ "$WAIT_SECONDS" -eq 0 ] || [ "$now" -ge "$deadline" ]; then
            die "cache ${CACHE_HASH:0:12} is in use or still has open files; lease wait expired" "$EX_TEMPFAIL"
        fi
        if [ "$announced" -eq 0 ]; then
            log "cache ${CACHE_HASH:0:12} is busy; waiting up to ${WAIT_SECONDS}s"
            announced=1
        fi
        sleep "$POLL_SECONDS"
    done
}

release_main_lease() {
    if [ "$MAIN_LEASE_HELD" -eq 1 ] && [ -n "$CACHE_HASH" ] && [ -n "$MAIN_LEASE_TOKEN" ]; then
        release_named_lease "$CACHE_HASH" "$MAIN_LEASE_TOKEN"
        MAIN_LEASE_HELD=0
    fi
}

is_managed_cache_dir() {
    local cache_dir="$1"
    local hash marker marker_size
    if [ "${cache_dir%/*}" != "$CACHES_DIR" ] || [ ! -d "$cache_dir" ] || [ -L "$cache_dir" ]; then
        return 1
    fi
    hash="${cache_dir##*/}"
    if ! valid_hash "$hash"; then
        return 1
    fi
    marker="$cache_dir/.haven-swiftpm-cache-v1"
    if [ ! -f "$marker" ] || [ -L "$marker" ]; then
        return 1
    fi
    marker_size="$(stat_size "$marker" 2>/dev/null || printf '0')"
    [ "$marker_size" -eq $((${#MARKER_VALUE} + 1)) ] && \
        [ "$(sed -n '1p' "$marker" 2>/dev/null || true)" = "$MARKER_VALUE" ]
}

cache_last_used_epoch() {
    local cache_dir="$1"
    if [ -f "$cache_dir/.last-used" ] && [ ! -L "$cache_dir/.last-used" ]; then
        stat_mtime "$cache_dir/.last-used"
    else
        stat_mtime "$cache_dir"
    fi
}

cache_size_kib() {
    du -sk "$1" 2>/dev/null | awk '{print $1}'
}

cache_has_open_files() {
    if ! command -v lsof >/dev/null 2>&1; then
        return 1
    fi
    lsof +D "$1" >/dev/null 2>&1
}

delete_managed_cache() {
    local cache_dir="$1"
    local reason="$2"
    local hash token lease_dir
    if ! is_managed_cache_dir "$cache_dir"; then
        return 1
    fi
    hash="${cache_dir##*/}"
    lease_dir="$(lease_dir_for_hash "$hash")"

    if [ "$DRY_RUN" -eq 1 ]; then
        if lease_is_live "$lease_dir" || cache_has_open_files "$cache_dir"; then
            return 1
        fi
        log "would remove ${hash:0:12} ($reason)"
        return 0
    fi

    token="gc-$$-$(date +%s)-$RANDOM-$RANDOM"
    if ! try_claim_lease "$hash" "$token"; then
        return 1
    fi
    if ! is_managed_cache_dir "$cache_dir" || cache_has_open_files "$cache_dir"; then
        release_named_lease "$hash" "$token"
        return 1
    fi
    if rm -rf "$cache_dir"; then
        release_named_lease "$hash" "$token"
        log "removed ${hash:0:12} ($reason)"
        return 0
    fi
    release_named_lease "$hash" "$token"
    return 1
}

total_cache_kib() {
    local cache_dir total size
    total=0
    for cache_dir in "$CACHES_DIR"/*; do
        if ! is_managed_cache_dir "$cache_dir"; then
            continue
        fi
        size="$(cache_size_kib "$cache_dir")"
        if is_nonnegative_integer "$size"; then
            total=$((total + size))
        fi
    done
    printf '%s\n' "$total"
}

run_gc() {
    local preserve_hash="${1:-}"
    local cache_dir hash now last_used age total size modified
    now="$(date +%s)"

    if [ "$MAX_AGE_SECONDS" -gt 0 ]; then
        for cache_dir in "$CACHES_DIR"/*; do
            if ! is_managed_cache_dir "$cache_dir"; then
                continue
            fi
            hash="${cache_dir##*/}"
            if [ -n "$preserve_hash" ] && [ "$hash" = "$preserve_hash" ]; then
                continue
            fi
            last_used="$(cache_last_used_epoch "$cache_dir")"
            if ! is_nonnegative_integer "$last_used"; then
                continue
            fi
            age=$((now - last_used))
            if [ "$age" -gt "$MAX_AGE_SECONDS" ]; then
                delete_managed_cache "$cache_dir" "inactive for ${age}s" || true
            fi
        done
    fi

    if [ "$MAX_CACHE_KIB" -eq 0 ]; then
        return
    fi
    total="$(total_cache_kib)"
    if [ "$total" -le "$MAX_CACHE_KIB" ]; then
        return
    fi

    GC_TMP_FILE="$(mktemp "$CACHE_ROOT/.gc-candidates.XXXXXX")"
    for cache_dir in "$CACHES_DIR"/*; do
        if ! is_managed_cache_dir "$cache_dir"; then
            continue
        fi
        hash="${cache_dir##*/}"
        if [ -n "$preserve_hash" ] && [ "$hash" = "$preserve_hash" ]; then
            continue
        fi
        modified="$(cache_last_used_epoch "$cache_dir")"
        size="$(cache_size_kib "$cache_dir")"
        if is_nonnegative_integer "$modified" && is_nonnegative_integer "$size"; then
            printf '%s %s %s\n' "$modified" "$size" "$hash" >> "$GC_TMP_FILE"
        fi
    done
    sort -n -k1,1 "$GC_TMP_FILE" -o "$GC_TMP_FILE"

    while read -r modified size hash; do
        if [ "$total" -le "$MAX_CACHE_KIB" ]; then
            break
        fi
        cache_dir="$CACHES_DIR/$hash"
        if delete_managed_cache "$cache_dir" "cache cap ${MAX_CACHE_KIB} KiB"; then
            if [ "$size" -le "$total" ]; then
                total=$((total - size))
            else
                total=0
            fi
        fi
    done < "$GC_TMP_FILE"

    rm -f "$GC_TMP_FILE"
    GC_TMP_FILE=""
    if [ "$total" -gt "$MAX_CACHE_KIB" ]; then
        log "cache remains above cap because retained or active caches could not be removed"
    fi
}

remove_current_ephemeral_cache() {
    if [ "$EPHEMERAL" -ne 1 ] || [ -z "$CURRENT_CACHE_DIR" ]; then
        return
    fi
    if ! is_managed_cache_dir "$CURRENT_CACHE_DIR"; then
        die "refusing to remove unmarked ephemeral cache"
    fi
    if cache_has_open_files "$CURRENT_CACHE_DIR"; then
        die "ephemeral cache still has open files"
    fi
    rm -rf "$CURRENT_CACHE_DIR"
    log "removed ephemeral cache ${CACHE_HASH:0:12}"
}

prepare_cache_layout() {
    local last_used="$CURRENT_CACHE_DIR/.last-used"
    local managed_child
    if [ -L "$last_used" ] || { [ -e "$last_used" ] && [ ! -f "$last_used" ]; }; then
        die "managed last-used marker has an unsafe file type"
    fi
    for managed_child in "$CURRENT_CACHE_DIR/clang-module-cache" "$CURRENT_CACHE_DIR/swiftpm-cache"; do
        if [ -L "$managed_child" ] || { [ -e "$managed_child" ] && [ ! -d "$managed_child" ]; }; then
            die "managed cache child has an unsafe file type: $managed_child"
        fi
        mkdir -p "$managed_child"
        if [ -L "$managed_child" ]; then
            die "managed cache child became a symbolic link: $managed_child"
        fi
    done
}

cleanup_on_exit() {
    local status="$?"
    trap - EXIT
    if [ -n "$GC_TMP_FILE" ]; then
        case "$GC_TMP_FILE" in
            "$CACHE_ROOT"/.gc-candidates.*) rm -f "$GC_TMP_FILE" ;;
        esac
    fi
    release_main_lease
    exit "$status"
}

handle_signal() {
    local signal_name="$1"
    local status="$2"
    if [ -n "$CHILD_PID" ]; then
        kill -"$signal_name" "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
        CHILD_PID=""
    fi
    exit "$status"
}

umask 077
initialize_cache_root
trap cleanup_on_exit EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

if [ "$GC_ONLY" -eq 1 ]; then
    run_gc ""
    exit 0
fi

subcommand="$1"
shift
case "$subcommand" in
    build|test|run|package) ;;
    *) die "unsupported Swift subcommand: $subcommand" ;;
esac
for swift_argument in "$@"; do
    case "$swift_argument" in
        --scratch-path|--scratch-path=*|--build-path|--build-path=*|--cache-path|--cache-path=*|--package-path|--package-path=*)
            die "scratch/build/cache/package path is managed by this runner"
            ;;
    esac
done

CACHE_HASH="$(derive_cache_hash)"
if ! valid_hash "$CACHE_HASH"; then
    die "failed to derive a valid cache identifier"
fi
CURRENT_CACHE_DIR="$CACHES_DIR/$CACHE_HASH"

run_gc "$CACHE_HASH"
acquire_main_lease

if [ -L "$CURRENT_CACHE_DIR" ]; then
    die "cache path must not be a symbolic link"
fi
if [ -e "$CURRENT_CACHE_DIR" ]; then
    if ! is_managed_cache_dir "$CURRENT_CACHE_DIR"; then
        die "existing cache lacks the required ownership marker: $CURRENT_CACHE_DIR"
    fi
else
    mkdir "$CURRENT_CACHE_DIR"
    chmod 700 "$CURRENT_CACHE_DIR"
    printf '%s\n' "$MARKER_VALUE" > "$CURRENT_CACHE_DIR/.haven-swiftpm-cache-v1"
    printf 'version=1\ncreated_at=%s\n' "$(date +%s)" > "$CURRENT_CACHE_DIR/.haven-swiftpm-metadata"
fi
prepare_cache_layout
touch "$CURRENT_CACHE_DIR/.last-used"

export CLANG_MODULE_CACHE_PATH="$CURRENT_CACHE_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

log "running swift $subcommand with cache ${CACHE_HASH:0:12}"
set +e
"$SWIFT_BIN" "$subcommand" --scratch-path "$CURRENT_CACHE_DIR" --cache-path "$CURRENT_CACHE_DIR/swiftpm-cache" "$@" &
CHILD_PID=$!
wait "$CHILD_PID"
swift_status=$?
CHILD_PID=""
set -e

touch "$CURRENT_CACHE_DIR/.last-used"
remove_current_ephemeral_cache
release_main_lease
run_gc "$CACHE_HASH"
exit "$swift_status"
