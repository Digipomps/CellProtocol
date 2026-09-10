#!/usr/bin/env bash
# Exercise SwiftPM's downstream product filtering, not just manifest text.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/cellprotocol-transport-floor.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT

python3 - "$probe_dir" "$repo_dir" <<'PY'
import json
import pathlib
import sys

probe, repo = map(pathlib.Path, sys.argv[1:])
(probe / "Sources/Probe").mkdir(parents=True)
(probe / "Sources/Probe/Probe.swift").write_text("import CellVapor\n")
(probe / "Package.swift").write_text('''// swift-tools-version: 5.8
import PackageDescription
let package = Package(
    name: "TransportFloorProbe",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(name: "CellProtocol", path: ''' + json.dumps(str(repo), ensure_ascii=False) + '''),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.36.1")
    ],
    targets: [.target(name: "Probe", dependencies: [
        .product(name: "CellVapor", package: "CellProtocol"),
        .product(name: "NIOSSL", package: "swift-nio-ssl")
    ])]
)
''')
PY

log_file="$probe_dir/resolve.log"
if "${SWIFT_BIN:-swift}" package --package-path "$probe_dir" resolve >"$log_file" 2>&1; then
    echo "ERROR: a CellVapor consumer accepted vulnerable NIOSSL 2.36.1" >&2
    exit 1
fi
# A fetch, compiler or environment failure is not a passing security assertion.
if ! grep -F 'Dependencies could not be resolved' "$log_file" >/dev/null ||
   ! grep -E "depends on 'swift-nio-ssl' 2\.37\.2\.\.<3\.0\.0" "$log_file" >/dev/null; then
    cat "$log_file" >&2
    echo "ERROR: resolution failed without proving the CellProtocol security floor" >&2
    exit 1
fi
grep -F 'Dependencies could not be resolved' "$log_file"
echo "PASS: downstream CellVapor rejects the vulnerable NIOSSL pin"
