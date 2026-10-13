#!/usr/bin/env python3
"""One bounded red/green CI run; refuses to compile on the local host."""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

BASE = '3824cf84b58903f900a49b0987ee660085f3d875'
SOURCES = [
    'Sources/CellBase/Cells/Bridging/BridgeChannelTransport.swift',
    'Sources/CellBase/Cells/Bridging/BridgeMultiplexing.swift',
    'Sources/CellVapor/CloudBridge/VaporBridgeTransport.swift',
]
TESTS = [
    'testMuxHeldOperationAllowsSiblingAndSelectiveCloseOnSameSocket',
    'testMuxFlowOrderIsLocalToItsChannelOnSameSocket',
    'testHeldCellDoesNotBlockAnotherProtectedReadOnSameWebSocket',
]
FILTER = '|'.join(TESTS)
TSAN = '|'.join(['VaporWebSocketAdmissionTests', 'BridgeChannelWebSocketTests',
    'BridgeMultiplexingTests', 'BridgeMuxSendLifetimeTests', 'BridgeResponseLifetimeTests',
    'BridgeFeedAndRPCOrderingTests', 'BridgeChannelSequenceTests'])


def main():
    if os.environ.get('GITHUB_ACTIONS') != 'true' or sys.platform != 'darwin':
        raise SystemExit('This driver is restricted to the explicitly approved macOS CI job.')
    root = Path.cwd()
    evidence = Path(os.environ['RUNNER_TEMP']) / 'bridge-mux-n35-evidence'
    evidence.mkdir(exist_ok=True)
    started = time.monotonic()
    deadline = started + 22 * 60
    result = {'base': BASE, 'candidate': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              'internal_deadline_seconds': 1320, 'steps': [], 'completed': False}
    saved = {p: (root / p).read_bytes() for p in SOURCES}
    pins = (root / 'Package.resolved').read_bytes()
    result['source_hashes'] = {p: hashlib.sha256(data).hexdigest() for p, data in saved.items()}

    def report():
        (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')

    def run(name, args):
        remaining = deadline - time.monotonic()
        if remaining <= 10:
            raise TimeoutError('Aggregate CI deadline exhausted; no further command started.')
        print(name, flush=True)
        begin = time.monotonic()
        path = evidence / (name + '.log')
        code = None
        timed_out = False
        with path.open('wb') as log:
            process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=remaining - 10)
            except subprocess.TimeoutExpired:
                timed_out = True
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)
                code = process.returncode
        result['steps'].append({'name': name, 'command': args, 'exit': code,
                                'seconds': round(time.monotonic() - begin, 3), 'timed_out': timed_out})
        report()
        if timed_out:
            raise TimeoutError(name)
        return code, path.read_text(errors='replace')

    swift = ['swift', 'test', '--disable-automatic-resolution', '--jobs', '2']
    previous_handlers = {}

    def interrupted(signum, _frame):
        # Allow the child cleanup and source restoration to finish on cancellation.
        for sig in previous_handlers:
            signal.signal(sig, signal.SIG_IGN)
        raise RuntimeError('CI driver interrupted by signal ' + str(signum))

    for sig in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[sig] = signal.signal(sig, interrupted)
    report()
    try:
        subprocess.run(['git', 'diff', '--exit-code'], check=True, timeout=15)
        for path in SOURCES:
            (root / path).write_bytes(subprocess.check_output(['git', 'show', BASE + ':' + path], timeout=15))
        try:
            code, output = run('original-regressions', swift + ['--filter', FILTER])
            # Compiler/setup failure cannot be accepted as a reproduced regression.
            if code == 0 or not re.search(r'Executed 3 tests, with [1-9]', output):
                raise RuntimeError('Original code did not produce three executed, failing regression tests.')
            for name in TESTS:
                if not re.search(r"Test Case '[^\n]*" + re.escape(name) + r"[^\n]*' failed", output):
                    raise RuntimeError('Missing original runtime test failure: ' + name)
            result['original_regressions_reproduced'] = True
        finally:
            for path, data in saved.items():
                (root / path).write_bytes(data)
        for name, args in [
            ('fixed-regressions', swift + ['--filter', FILTER]),
            ('fixed-full-suite', swift),
            ('fixed-tsan', swift + ['--sanitize', 'thread', '--filter', TSAN]),
        ]:
            code, _ = run(name, args)
            if code:
                raise RuntimeError(name + ' failed; no retry')
        subprocess.run(['git', 'diff', '--exit-code'], check=True, timeout=15)
        if (root / 'Package.resolved').read_bytes() != pins:
            raise RuntimeError('Dependency pins changed')
        result['completed'] = True
    except BaseException as error:
        result['failure'] = str(error)
        raise
    finally:
        for path, data in saved.items():
            (root / path).write_bytes(data)
        result['elapsed_seconds'] = round(time.monotonic() - started, 3)
        result['candidate_sources_restored'] = all((root / p).read_bytes() == b for p, b in saved.items())
        report()
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)


if __name__ == '__main__':
    main()
