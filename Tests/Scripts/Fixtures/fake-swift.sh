#!/usr/bin/env bash

set -euo pipefail

log_file="${FAKE_SWIFT_LOG:-/dev/null}"
printf 'BEGIN\n' >> "$log_file"
for argument in "$@"; do
    printf 'ARG:%s\n' "$argument" >> "$log_file"
done
printf 'ENV:CLANG_MODULE_CACHE_PATH=%s\n' "${CLANG_MODULE_CACHE_PATH:-}" >> "$log_file"
printf 'ENV:SWIFTPM_MODULECACHE_OVERRIDE=%s\n' "${SWIFTPM_MODULECACHE_OVERRIDE:-}" >> "$log_file"

if [ -n "${FAKE_SWIFT_STARTED:-}" ]; then
    : > "$FAKE_SWIFT_STARTED"
fi
if [ "${FAKE_SWIFT_SLEEP:-0}" != "0" ]; then
    sleep "$FAKE_SWIFT_SLEEP"
fi

exit "${FAKE_SWIFT_EXIT:-0}"
