#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

# Bounded, synthetic, process-local CellProtocol capacity measurements.
# This script deliberately builds into /private/tmp instead of the repository's
# .build directory, and it never invokes a network or production endpoint.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_root="${BENCHMARK_OUTPUT_DIR:-/private/tmp/CellProtocol-runtime-capacity-${run_stamp}}"
scratch_root="${BENCHMARK_SCRATCH_DIR:-/private/tmp/CellProtocol-runtime-capacity-build}"
build_jobs="${BENCHMARK_BUILD_JOBS:-2}"
load_levels="${BENCHMARK_LOAD_LEVELS:-1 2 4 8}"
operations="${BENCHMARK_OPERATIONS:-1000}"
flow_operations="${BENCHMARK_FLOW_OPERATIONS:-256}"
persistence_operations="${BENCHMARK_PERSISTENCE_OPERATIONS:-80}"
overflow_operations="${BENCHMARK_OVERFLOW_OPERATIONS:-512}"
idle_seconds="${BENCHMARK_IDLE_SECONDS:-10}"
max_wall_seconds="${BENCHMARK_MAX_WALL_SECONDS:-60}"

mkdir -p "$output_root"
mkdir -p "$scratch_root"

git_revision="$(git -C "$repo_root" rev-parse HEAD)"
runtime_revision="${BENCHMARK_RUNTIME_REVISION:-$git_revision}"
branch="$(git -C "$repo_root" branch --show-current)"
{
  echo "git_revision=$git_revision"
  echo "runtime_revision=$runtime_revision"
  echo "branch=$branch"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "build_jobs=$build_jobs"
  echo "load_levels=$load_levels"
  echo "operations=$operations"
  echo "flow_operations=$flow_operations"
  echo "persistence_operations=$persistence_operations"
  echo "overflow_operations=$overflow_operations"
  echo "idle_seconds=$idle_seconds"
  echo "max_wall_seconds=$max_wall_seconds"
} > "$output_root/run-configuration.txt"

{
  sw_vers
  sysctl -n machdep.cpu.brand_string 2>/dev/null || true
  sysctl -n hw.ncpu 2>/dev/null || true
  sysctl -n hw.physicalcpu 2>/dev/null || true
  sysctl -n hw.memsize 2>/dev/null || true
  xcodebuild -version
  swift --version
} > "$output_root/system.txt"

echo "Building CellRuntimeBenchmarks with --jobs $build_jobs in $scratch_root"
swift build \
  --jobs "$build_jobs" \
  -c release \
  --product CellRuntimeBenchmarks \
  --scratch-path "$scratch_root" \
  --package-path "$repo_root" \
  > "$output_root/build.stdout.txt" \
  2> "$output_root/build.stderr.txt"

benchmark_binary="$(swift build \
  -c release \
  --scratch-path "$scratch_root" \
  --package-path "$repo_root" \
  --show-bin-path)/CellRuntimeBenchmarks"
if [[ ! -x "$benchmark_binary" ]]; then
  echo "Expected benchmark binary is missing: $benchmark_binary" >&2
  exit 1
fi

typeset -i stopped_runs=0

run_one() {
  local workload="$1"
  local concurrency="$2"
  local operation_count="$3"
  local run_name="${workload}-c${concurrency}-n${operation_count}"
  local run_dir="$output_root/$run_name"
  local storage_dir="$run_dir/synthetic-storage"
  local benchmark_pid top_pid iostat_pid vmstat_pid run_exit_status
  local started_seconds=$SECONDS

  mkdir -p "$run_dir"
  local -a arguments=(
    --workload "$workload"
    --concurrency "$concurrency"
    --operations "$operation_count"
    --revision "$runtime_revision"
  )
  if [[ "$workload" == "idle" ]]; then
    arguments+=(--idle-seconds "$idle_seconds")
  fi
  if [[ "$workload" == "persistence" ]]; then
    arguments+=(--storage-dir "$storage_dir")
  fi

  echo "$run_name" >> "$output_root/run-order.txt"
  "$benchmark_binary" "${arguments[@]}" > "$run_dir/result.json" 2> "$run_dir/stderr.txt" &
  benchmark_pid=$!
  echo "$benchmark_pid" > "$run_dir/benchmark.pid"

  # top gives interval CPU and total/running OS threads. iostat and vm_stat are
  # system-wide supplementary context, not process-attributable disk metrics.
  top -l 0 -s 1 -pid "$benchmark_pid" -stats pid,command,cpu,th,rsize,vsize,time \
    > "$run_dir/top.txt" 2> "$run_dir/top.stderr.txt" &
  top_pid=$!
  iostat -d -K -w 1 > "$run_dir/iostat.txt" 2> "$run_dir/iostat.stderr.txt" &
  iostat_pid=$!
  vm_stat 1 > "$run_dir/vm_stat.txt" 2> "$run_dir/vm_stat.stderr.txt" &
  vmstat_pid=$!

  while kill -0 "$benchmark_pid" 2>/dev/null; do
    sleep 1
    if (( SECONDS - started_seconds > max_wall_seconds )); then
      echo "Stopped after ${max_wall_seconds}s safety limit" > "$run_dir/stopped.txt"
      kill -TERM "$benchmark_pid" 2>/dev/null || true
      sleep 2
      if kill -0 "$benchmark_pid" 2>/dev/null; then
        kill -KILL "$benchmark_pid" 2>/dev/null || true
      fi
      stopped_runs=$((stopped_runs + 1))
      break
    fi
  done

  set +e
  wait "$benchmark_pid"
  run_exit_status=$?
  set -e
  echo "$run_exit_status" > "$run_dir/exit-status.txt"
  kill -TERM "$top_pid" "$iostat_pid" "$vmstat_pid" 2>/dev/null || true
  wait "$top_pid" 2>/dev/null || true
  wait "$iostat_pid" 2>/dev/null || true
  wait "$vmstat_pid" 2>/dev/null || true
  echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$run_dir/metadata.txt"
}

# The idle run establishes the configured runtime baseline once. All other
# workloads rise through conservative worker counts; no level exceeds 8 unless
# the operator explicitly changes BENCHMARK_LOAD_LEVELS.
run_one idle 1 1
for concurrency in ${(z)load_levels}; do
  run_one cell "$concurrency" "$operations"
  run_one resolver "$concurrency" "$operations"
  run_one flow "$concurrency" "$flow_operations"
  run_one persistence "$concurrency" "$persistence_operations"
done
run_one flow-overflow 1 "$overflow_operations"

echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$output_root/run-configuration.txt"
echo "stopped_runs=$stopped_runs" >> "$output_root/run-configuration.txt"
echo "Raw results: $output_root"
if (( stopped_runs > 0 )); then
  echo "One or more runs reached their safety timeout; inspect stopped.txt before using results." >&2
  exit 2
fi
