"""Exercise CI orchestration locally with simulated Swift; never starts a build."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('driver', Path(__file__).with_name('run-bridge-mux-n35-ci.py'))
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class DriverTests(unittest.TestCase):
    def exercise(self, mode):
        calls, killed = [], []
        old_cwd = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in driver.SOURCES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'candidate')
            (root / 'Package.resolved').write_bytes(b'pins')
            red = '\n'.join("Test Case '-[Suite " + name + "]' failed (0.001 seconds)." for name in driver.TESTS)
            red += '\nExecuted 3 tests, with 3 failures (0 unexpected) in 0.1 seconds\n'

            class Child:
                pid = 123456
                returncode = None
                waits = 0
                def __init__(self, args, stdout, stderr, start_new_session):
                    self.index = len(calls)
                    calls.append(args)
                    assert start_new_session and stderr == subprocess.STDOUT
                    expected = b'original' if self.index == 0 else b'candidate'
                    assert all((root / p).read_bytes() == expected for p in driver.SOURCES)
                    if mode == 'compiler' and self.index == 0:
                        stdout.write(b'error: failed to compile\n')
                    elif mode == 'missing' and self.index == 0:
                        stdout.write(red.replace(driver.TESTS[1], 'unrelated').encode())
                    else:
                        stdout.write((red if self.index == 0 else 'passed\n').encode())
                    if mode == 'pins' and self.index == 3:
                        (root / 'Package.resolved').write_bytes(b'drift')
                def wait(self, timeout):
                    self.waits += 1
                    if mode in ('timeout', 'kill') and self.index == 0:
                        if self.waits == 1 or (mode == 'kill' and self.waits == 2):
                            raise subprocess.TimeoutExpired(calls[-1], timeout)
                    if mode == 'signal' and self.index == 0 and self.waits == 1:
                        signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
                    self.returncode = 1 if self.index == 0 or (mode == 'fixed' and self.index == 1) else 0
                    if mode == 'unexpected-pass' and self.index == 0:
                        self.returncode = 0
                    return self.returncode
                def poll(self):
                    return self.returncode

            def git_output(args, **kwargs):
                return 'test-candidate\n' if args[1] == 'rev-parse' else b'original'

            handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
            error = None
            try:
                os.chdir(root)
                with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true', 'RUNNER_TEMP': directory}), \
                     patch.object(driver.sys, 'platform', 'darwin'), \
                     patch.object(driver.subprocess, 'check_output', side_effect=git_output), \
                     patch.object(driver.subprocess, 'run') as git_run, \
                     patch.object(driver.subprocess, 'Popen', Child), \
                     patch.object(driver.os, 'killpg', side_effect=lambda pid, sig: killed.append(sig)):
                    try:
                        driver.main()
                    except (RuntimeError, TimeoutError) as caught:
                        error = caught
                result = json.loads((root / 'bridge-mux-n35-evidence/result.json').read_text())
                self.assertTrue(result['candidate_sources_restored'])
                self.assertTrue(all((root / p).read_bytes() == b'candidate' for p in driver.SOURCES))
                self.assertEqual(handlers, {sig: signal.getsignal(sig) for sig in handlers})
                return calls, killed, result, error
            finally:
                os.chdir(old_cwd)

    def test_complete_red_green_full_and_tsan_once(self):
        calls, _, result, error = self.exercise('success')
        self.assertIsNone(error)
        self.assertTrue(result['completed'])
        self.assertEqual(len(calls), 4)
        self.assertIn('--sanitize', calls[-1])
        self.assertTrue(all(command[:5] == ['swift', 'test', '--disable-automatic-resolution', '--jobs', '2'] for command in calls))

    def test_compile_error_is_not_red_regression(self):
        calls, _, result, error = self.exercise('compiler')
        self.assertEqual(len(calls), 1)
        self.assertIsNotNone(error)
        self.assertFalse(result['completed'])

    def test_every_named_regression_must_fail_on_original(self):
        for mode in ('missing', 'unexpected-pass'):
            with self.subTest(mode=mode):
                calls, _, _, error = self.exercise(mode)
                self.assertEqual(len(calls), 1)
                self.assertIsNotNone(error)

    def test_fixed_failure_stops_without_retry(self):
        calls, _, _, error = self.exercise('fixed')
        self.assertEqual(len(calls), 2)
        self.assertIsNotNone(error)

    def test_timeout_terminates_process_group(self):
        calls, killed, result, error = self.exercise('timeout')
        self.assertEqual(len(calls), 1)
        self.assertEqual(killed, [signal.SIGTERM])
        self.assertTrue(result['steps'][0]['timed_out'])
        self.assertIsInstance(error, TimeoutError)

    def test_noncooperative_child_is_killed(self):
        _, killed, _, error = self.exercise('kill')
        self.assertEqual(killed, [signal.SIGTERM, signal.SIGKILL])
        self.assertIsInstance(error, TimeoutError)

    def test_cancellation_cleans_child_and_restores_sources(self):
        calls, killed, _, error = self.exercise('signal')
        self.assertEqual(len(calls), 1)
        self.assertEqual(killed, [signal.SIGTERM])
        self.assertIn('interrupted', str(error))

    def test_dependency_drift_fails(self):
        _, _, result, error = self.exercise('pins')
        self.assertFalse(result['completed'])
        self.assertIn('pins changed', str(error))

    def test_local_host_is_refused_before_any_subprocess(self):
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}), patch.object(driver.subprocess, 'check_output') as command:
            with self.assertRaises(SystemExit):
                driver.main()
            command.assert_not_called()


if __name__ == '__main__':
    unittest.main()
