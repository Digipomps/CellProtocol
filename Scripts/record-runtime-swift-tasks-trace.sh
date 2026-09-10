#!/bin/zsh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright (c) 2026 Stiftelsen Digipomps and HAVEN contributors

# Capture one deliberately small Swift Concurrency trace after the normal
# benchmark has identified a workload/level worth inspecting. This is not part
# of the regular load matrix because Instruments changes execution cost.

set -euo pipefail

if (( $# < 1 )); then
  echo "Usage: $0 <output-dir> [benchmark arguments...]" >&2
  exit 64
fi

output_dir="$1"
shift
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
scratch_root="${BENCHMARK_SCRATCH_DIR:-/private/tmp/CellProtocol-runtime-capacity-build}"
benchmark_binary="$scratch_root/arm64-apple-macosx/release/CellRuntimeBenchmarks"
time_limit="${BENCHMARK_TRACE_TIME_LIMIT:-20s}"

if [[ ! -x "$benchmark_binary" ]]; then
  echo "Build the release benchmark first: $benchmark_binary" >&2
  exit 1
fi
mkdir -p "$output_dir"

xctrace record \
  --template "Swift Concurrency" \
  --time-limit "$time_limit" \
  --output "$output_dir/SwiftConcurrency.trace" \
  --target-stdout "$output_dir/benchmark.json" \
  --launch -- "$benchmark_binary" "$@"
xctrace export --input "$output_dir/SwiftConcurrency.trace" --toc \
  --output "$output_dir/trace-toc.xml"
