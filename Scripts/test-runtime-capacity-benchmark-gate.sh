#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

# Exercises the benchmark wrapper's failure gate with a private fake binary.
# It does not build CellProtocol or execute a capacity workload.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
runner="$script_dir/run-runtime-capacity-benchmark.sh"
temporary_root="$(mktemp -d "${TMPDIR:-/private/tmp}/cellprotocol-runtime-capacity-gate.XXXXXX")"

cleanup() {
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT

mock_bin="$temporary_root/mock-bin"
fake_binary="$temporary_root/fake-benchmark"
mkdir -p "$mock_bin"

for monitor in top iostat vm_stat; do
  print -rl -- '#!/bin/sh' 'while :; do sleep 1; done' > "$mock_bin/$monitor"
  chmod +x "$mock_bin/$monitor"
done

print -rl -- '#!/bin/sh' \
  'set -eu' \
  'workload=""' \
  'concurrency=""' \
  'operations=""' \
  'revision=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in' \
  '    --workload) workload="$2"; shift 2 ;;' \
  '    --concurrency) concurrency="$2"; shift 2 ;;' \
  '    --operations) operations="$2"; shift 2 ;;' \
  '    --revision) revision="$2"; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'case "${BENCHMARK_GATE_TEST_MODE:?}" in' \
  '  child-failure) echo "intentional child failure" >&2; exit 17 ;;' \
  '  missing-json) exit 0 ;;' \
  '  malformed-json) printf "{ malformed\\n"; exit 0 ;;' \
  '  wrong-ack)' \
  '    if [ "$workload" = "flow-overflow" ]; then' \
  '      printf '\''{"formatVersion":1,"revision":"%s","configuration":{"workload":"%s","concurrency":%s,"operations":%s},"summary":{"successfulOperations":1,"queueObservation":{"configuredCapacity":256,"submittedElements":%s,"deliveredElementsAfterSettle":0}}}\n'\'' "$revision" "$workload" "$concurrency" "$operations" "$operations"' \
  '    else' \
  '      printf '\''{"formatVersion":1,"revision":"%s","configuration":{"workload":"%s","concurrency":%s,"operations":%s},"summary":{"successfulOperations":999,"latencyNanoseconds":{"samples":%s}}}\n'\'' "$revision" "$workload" "$concurrency" "$operations" "$operations"' \
  '    fi' \
  '    exit 0 ;;' \
  '  *) echo "unexpected test mode" >&2; exit 64 ;;' \
  'esac' \
  > "$fake_binary"
chmod +x "$fake_binary"

assert_gate_evidence() {
  local output_root="$1"
  local expression="$2"
  shift 2

  if /usr/bin/grep -Eq "$expression" "$@"; then
    return 0
  fi
  echo "Missing expected failure-gate evidence: $expression" >&2
  cat "$output_root/run-configuration.txt" >&2 || true
  find "$output_root" -maxdepth 2 -type f \
    \( -name 'exit-status.txt' -o -name 'failure.txt' -o -name 'validation-errors.txt' -o -name 'stderr.txt' \) \
    -print -exec cat {} \; >&2 || true
  return 1
}

assert_wrapper_fails() {
  local mode="$1"
  local output_root="$temporary_root/$mode-results"
  local exit_status

  set +e
  PATH="$mock_bin:$PATH" \
    CELL_PROTOCOL_BENCHMARK_BINARY_FOR_TESTS="$fake_binary" \
    BENCHMARK_GATE_TEST_MODE="$mode" \
    BENCHMARK_OUTPUT_DIR="$output_root" \
    BENCHMARK_SCRATCH_DIR="$temporary_root/$mode-scratch" \
    BENCHMARK_LOAD_LEVELS="1" \
    BENCHMARK_OPERATIONS="1" \
    BENCHMARK_FLOW_OPERATIONS="1" \
    BENCHMARK_PERSISTENCE_OPERATIONS="1" \
    BENCHMARK_OVERFLOW_OPERATIONS="1" \
    BENCHMARK_IDLE_SECONDS="0" \
    BENCHMARK_MAX_WALL_SECONDS="5" \
    "$runner" > "$temporary_root/$mode.stdout.txt" 2> "$temporary_root/$mode.stderr.txt"
  exit_status=$?
  set -e

  if (( exit_status == 0 )); then
    echo "Expected wrapper failure for $mode" >&2
    exit 1
  fi
  echo "Verified expected wrapper failure: $mode"
  case "$mode" in
    child-failure)
      assert_gate_evidence "$output_root" '^failed_runs=[1-9]' "$output_root/run-configuration.txt"
      assert_gate_evidence "$output_root" 'Benchmark child exited with status 17' "$output_root"/*/failure.txt
      ;;
    missing-json)
      assert_gate_evidence "$output_root" '^invalid_result_runs=[1-9]' "$output_root/run-configuration.txt"
      assert_gate_evidence "$output_root" 'Missing or empty result.json' "$output_root"/*/validation-errors.txt
      ;;
    malformed-json)
      assert_gate_evidence "$output_root" '^invalid_result_runs=[1-9]' "$output_root/run-configuration.txt"
      assert_gate_evidence "$output_root" 'Missing or invalid JSON value' "$output_root"/*/validation-errors.txt
      ;;
    wrong-ack)
      assert_gate_evidence "$output_root" '^invalid_result_runs=[1-9]' "$output_root/run-configuration.txt"
      assert_gate_evidence "$output_root" 'Unexpected summary.successfulOperations|Overflow acknowledgement mismatch' "$output_root"/*/validation-errors.txt
      ;;
  esac
}

assert_wrapper_fails child-failure
assert_wrapper_fails missing-json
assert_wrapper_fails malformed-json
assert_wrapper_fails wrong-ack

echo "Runtime capacity benchmark failure gate verified."
