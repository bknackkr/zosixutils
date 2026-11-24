"""Run with python3 tests/ps_integration.py path/to/zosixutils (Linux)."""

import fcntl
import os
from pathlib import Path
import pty
import signal
import subprocess
import sys
import tempfile
import termios
import unittest

BINARY = Path(sys.argv.pop(1)).resolve()


class PsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zosixutils-ps-")
        self.addCleanup(self.temp.cleanup)
        self.link = Path(self.temp.name) / "ps"
        self.link.symlink_to(BINARY)
        self.env = dict(os.environ, LC_ALL="C", COLUMNS="250")

    def ps(self, *args, linked=False, env=None, **kwargs):
        command = [str(self.link)] if linked else [str(BINARY), "ps"]
        return subprocess.run(command + list(args), env=env or self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=8, **kwargs)

    def child(self, terminal=False):
        master = slave = None
        setup = os.setsid
        if terminal:
            master, slave = pty.openpty()
            self.addCleanup(os.close, master)
            self.addCleanup(os.close, slave)

            def setup():
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(60)", "bad\x1b\nname"],
            stdin=slave if terminal else subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, preexec_fn=setup,
        )

        def cleanup():
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
            process.wait(timeout=8)

        self.addCleanup(cleanup)
        return process, os.ttyname(slave)[5:] if terminal else None

    def test_routes_headers_and_sanitization(self):
        child, _ = self.child()
        for linked in (False, True):
            result = self.ps("-p", str(child.pid), "-o", "pid=Process ID", "-o", "args=", linked=linked)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertIn(b"Process ID", lines[0])
            self.assertEqual(len(lines), 2)
            self.assertIn(b"bad??name", lines[1])
            self.assertNotIn(b"\x1b", result.stdout)
            result = self.ps("-p", str(child.pid), "-o", "pid=", "-o", "tty=", linked=linked)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.split(), [str(child.pid).encode(), b"?"])

    def test_terminal_and_union(self):
        child, tty = self.child(terminal=True)
        other, _ = self.child()
        result = self.ps("-t", tty, "-p", str(other.pid), "-o", "pid=", "-o", "tty=")
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [line.split() for line in result.stdout.splitlines()]
        self.assertIn([str(child.pid).encode(), tty.encode()], rows)
        self.assertIn([str(other.pid).encode(), b"?"], rows)
        pids = [int(row[0]) for row in rows]
        self.assertEqual(pids, sorted(pids))

    def test_default_uses_controlling_terminal_not_stdin(self):
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        tty = os.ttyname(slave)[5:]

        def setup():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            [str(BINARY), "ps", "-o", "pid=", "-o", "tty="],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=self.env, preexec_fn=setup,
        )
        output, error = process.communicate(timeout=8)
        self.assertEqual(process.returncode, 0, error)
        self.assertIn([str(process.pid).encode(), tty.encode()],
                      [line.split() for line in output.splitlines()])

    def test_standard_fields_and_ids(self):
        child, _ = self.child()
        fields = "ruser,user,rgroup,group,pid,ppid,pgid,pcpu,vsz,nice,etime,time,tty,comm,args"
        result = self.ps("-p", str(child.pid), "-o", fields)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[0].split(), [
            b"RUSER", b"USER", b"RGROUP", b"GROUP", b"PID", b"PPID", b"PGID",
            b"%CPU", b"VSZ", b"NI", b"ELAPSED", b"TIME", b"TT", b"COMMAND", b"COMMAND",
        ])
        for selector, ident in (("-U", os.getuid()), ("-u", os.geteuid()),
                                ("-G", os.getgid()), ("-g", os.getsid(child.pid))):
            result = self.ps(selector, str(ident), "-o", "pid=")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(str(child.pid).encode(), result.stdout.split())

    def test_invalid_options_and_width(self):
        for args in (("-p", "invalid"), ("-o", "unknown"), ("-n", "file"), ("operand",)):
            result = self.ps(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(result.stderr.startswith(b"ps:"))
        child, _ = self.child()
        env = dict(self.env, COLUMNS="20")
        result = self.ps("-p", str(child.pid), "-o", "pid,args", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(len(line) <= 20 for line in result.stdout.splitlines()))


if __name__ == "__main__":
    unittest.main()
