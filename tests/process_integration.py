#!/usr/bin/env python3
"""Linux integration tests for kill and nohup."""

import os
from pathlib import Path
import pty
import signal
import stat
import subprocess
import sys
import tempfile
import unittest


BINARY = Path(sys.argv.pop(1)).resolve()
TIMEOUT = 5


class ProcessApplets(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="zosix-process-")
        self.addCleanup(temp.cleanup)
        self.cwd = Path(temp.name)
        self.home = self.cwd / "home"
        self.home.mkdir()
        self.env = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": str(self.home)}
        for applet in ("kill", "nohup"):
            (self.cwd / applet).symlink_to(BINARY)

    def argv(self, applet, *args, link=False):
        return [self.cwd / applet, *args] if link else [BINARY, applet, *args]

    def run_applet(self, applet, *args, link=False, **kwargs):
        return subprocess.run(
            self.argv(applet, *args, link=link), cwd=self.cwd, env=self.env,
            timeout=TIMEOUT, **kwargs,
        )

    def spawn(self, argv, **kwargs):
        child = subprocess.Popen(argv, cwd=self.cwd, env=self.env, **kwargs)

        def reap():
            try:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=TIMEOUT)
            finally:
                for stream in (child.stdin, child.stdout, child.stderr):
                    if stream is not None:
                        stream.close()

        self.addCleanup(reap)
        return child

    def terminal(self):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        return slave

    def test_kill_link_numeric_status_and_owned_process_group(self):
        result = self.run_applet("kill", "-l", str(128 + signal.SIGTERM), link=True, capture_output=True)
        self.assertEqual((result.returncode, result.stdout), (0, b"TERM\n"))
        child = self.spawn(["/bin/sleep", "30"], start_new_session=True)
        result = self.run_applet("kill", "-s", "0", str(child.pid), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_applet("kill", "-TeRm", "--", "not-a-pid", str(-child.pid), link=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"not-a-pid", result.stderr)
        self.assertEqual(child.wait(timeout=TIMEOUT), -signal.SIGTERM)

    def test_nohup_piped_stdin_environment_pid_and_signal_status(self):
        self.env["MARK"] = "inherited"
        code = (
            "import os, signal, sys; print(os.getpid(), os.environ['MARK'], flush=True); "
            "assert sys.stdin.read() == 'pipe'; os.kill(os.getpid(), signal.SIGHUP); "
            "os.kill(os.getpid(), signal.SIGTERM)"
        )
        child = self.spawn(
            self.argv("nohup", sys.executable, "-c", code, link=True),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        out, err = child.communicate(b"pipe", timeout=TIMEOUT)
        self.assertEqual((out, err), (f"{child.pid} inherited\n".encode(), b""))
        self.assertEqual(child.returncode, -signal.SIGTERM)
        self.assertFalse((self.cwd / "nohup.out").exists())

    def test_nohup_preserves_other_ignored_signals(self):
        result = self.run_applet(
            "nohup", "/bin/sh", "-c", 'kill -s PIPE "$$"; exit 31',
            restore_signals=False, capture_output=True,
        )
        self.assertEqual(result.returncode, 31, result.stderr)

    def test_nohup_terminal_stdin_stdout_and_append_permissions(self):
        tty = self.terminal()
        output = self.cwd / "nohup.out"
        code = "import os; assert not os.read(0, 1); os.write(1,b'out\\n'); os.write(2,b'err\\n')"
        for mode, expected in ((0o777, 0o600), (0o022, 0o640)):
            result = self.run_applet(
                "nohup", sys.executable, "-c", code, stdin=tty, stdout=tty, stderr=subprocess.PIPE, umask=mode,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b"nohup.out", result.stderr)
            self.assertTrue(result.stderr.endswith(b"err\n"))
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), expected)
            output.chmod(0o640)
        self.assertEqual(output.read_bytes(), b"out\nout\n")

    def test_nohup_terminal_stderr_follows_open_stdout(self):
        result = self.run_applet(
            "nohup", "/bin/sh", "-c", "echo out; echo err >&2",
            stdout=subprocess.PIPE, stderr=self.terminal(),
        )
        self.assertEqual((result.returncode, result.stdout), (0, b"out\nerr\n"))
        self.assertFalse((self.cwd / "nohup.out").exists())

    def test_nohup_closed_stdout_terminal_stderr_and_home_fallback(self):
        (self.cwd / "nohup.out").mkdir()
        tty = self.terminal()
        code = (
            "import errno, os; exec('try:\\n os.fstat(1)\\nexcept OSError as err:\\n"
            " assert err.errno == errno.EBADF\\nelse:\\n raise AssertionError'); os.write(2, b'err\\n')"
        )
        result = self.run_applet(
            "nohup", sys.executable, "-c", code, stdout=subprocess.PIPE, stderr=tty,
            preexec_fn=lambda: os.close(1),
        )
        self.assertEqual((result.returncode, result.stdout), (0, b""))
        self.assertEqual((self.home / "nohup.out").read_bytes(), b"err\n")

    def test_nohup_terminal_outputs_preserve_initially_closed_stdin(self):
        tty = self.terminal()
        code = (
            "import errno, os; exec('try:\\n os.fstat(0)\\nexcept OSError as err:\\n"
            " assert err.errno == errno.EBADF\\nelse:\\n raise AssertionError'); "
            "os.write(1, b'out\\n'); os.write(2, b'err\\n')"
        )
        result = self.run_applet(
            "nohup", sys.executable, "-c", code, stdin=subprocess.PIPE, stdout=tty, stderr=tty,
            preexec_fn=lambda: os.close(0),
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.cwd / "nohup.out").read_bytes(), b"out\nerr\n")

    def test_nohup_setup_failure_does_not_run_utility(self):
        (self.cwd / "nohup.out").mkdir()
        (self.home / "nohup.out").mkdir()
        result = self.run_applet(
            "nohup", "/bin/sh", "-c", "> unexpectedly-ran", stdout=self.terminal(), stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 127)
        self.assertIn(b"nohup.out", result.stderr)
        self.assertFalse((self.cwd / "unexpectedly-ran").exists())

    def test_nohup_lookup_failures_and_bundled_executable_text(self):
        self.env["PATH"] = ":/dev/null"
        script = self.cwd / "text"
        script.write_bytes(b'/bin/echo "$0:$1"; exit 24\n')
        script.chmod(0o700)
        bad = self.cwd / "bad"
        bad.write_bytes(b"echo unexpectedly-ran\n#" + b"x" * 4096 + b"\x00")
        bad.chmod(0o700)
        denied = self.cwd / "denied"
        denied.write_bytes(b"unused")
        denied.chmod(0o600)
        no_interpreter = self.cwd / "no-interpreter"
        no_interpreter.write_bytes(b"#!/does-not-exist\n")
        no_interpreter.chmod(0o700)
        result = self.run_applet("nohup", "--", "text", "arg", capture_output=True)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (24, b"text:arg\n", b""))
        for utility, code in (("bad", 126), ("denied", 126), ("no-interpreter", 126), ("missing", 127)):
            with self.subTest(utility=utility):
                result = self.run_applet("nohup", utility, capture_output=True)
                self.assertEqual((result.returncode, result.stdout), (code, b""))


if __name__ == "__main__":
    unittest.main()
