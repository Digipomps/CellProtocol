#!/usr/bin/env bash
# Source from registered job wrappers. Optional collection cannot change a job's
# exit status. Configuration is enrolled by the owner, never inferred from argv.
HAVEN_ARTIFACT_ATTEMPT=""
HAVEN_ARTIFACT_COLLECTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/haven_artifacts.py"
HAVEN_ARTIFACT_PYTHON="${HAVEN_ARTIFACT_PYTHON:-/usr/bin/python3}"

haven_artifact_start() {
    [ -n "${HAVEN_ARTIFACT_CONFIG:-}" ] || return 0
    if ! HAVEN_ARTIFACT_ATTEMPT="$("$HAVEN_ARTIFACT_PYTHON" "$HAVEN_ARTIFACT_COLLECTOR" --config "$HAVEN_ARTIFACT_CONFIG" start \
        --job "$1" --project "$2" --path "$3")"; then
        HAVEN_ARTIFACT_ATTEMPT=""
        printf '[haven-artifacts] degraded: start was not recorded; cleanup classification unavailable\n' >&2
    fi
    return 0
}

haven_artifact_created() {
    [ -n "$HAVEN_ARTIFACT_ATTEMPT" ] || return 0
    "$HAVEN_ARTIFACT_PYTHON" "$HAVEN_ARTIFACT_COLLECTOR" --config "$HAVEN_ARTIFACT_CONFIG" created \
        --attempt "$HAVEN_ARTIFACT_ATTEMPT" --path "$1" >/dev/null || \
        printf '[haven-artifacts] degraded: writer event was not recorded\n' >&2
    return 0
}

haven_artifact_finish() {
    [ -n "$HAVEN_ARTIFACT_ATTEMPT" ] || return 0
    local artifact_result=failed
    case "$1" in
        0) artifact_result=succeeded ;;
        129|130|143) artifact_result=cancelled ;;
    esac
    "$HAVEN_ARTIFACT_PYTHON" "$HAVEN_ARTIFACT_COLLECTOR" --config "$HAVEN_ARTIFACT_CONFIG" finish \
        --attempt "$HAVEN_ARTIFACT_ATTEMPT" --result "$artifact_result" >/dev/null || \
        printf '[haven-artifacts] degraded: terminal receipt missing; attempt remains active\n' >&2
    HAVEN_ARTIFACT_ATTEMPT=""
    return 0
}
