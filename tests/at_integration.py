#!/usr/bin/env python3
"""Exercise the production scheduler in an isolated Linux mount namespace."""

from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import sys
import tempfile
import time
import unittest


BINARY = Path(sys.argv.pop(1)).resolve()
TIMEOUT = 8


class Scheduler(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="case-", dir="/home")
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        Path("/etc/passwd").write_text(f"tester:x:0:0::{self.home}:/bin/sh\n")
        self.policy = Path("/etc/zosixutils")
        for file in self.policy.iterdir():
            file.unlink()
        self.work = self.home / "work"
        self.work.mkdir()
        self.spool = self.home / ".local/state/zosixutils/at"
        self.mail = self.home / "Maildir/new"
        self.env = {"HOME": str(self.work), "TZ": "UTC0", "PATH": "/bin:/usr/bin", "LC_ALL": "C"}
        for applet in ("at", "batch", "atd"):
            (self.work / applet).symlink_to(BINARY)

    def argv(self, applet, *args, link=False):
        return [self.work / applet, *args] if link else [BINARY, applet, *args]

    def run_applet(self, applet, *args, link=False, **kwargs):
        return subprocess.run(
            self.argv(applet, *args, link=link), cwd=self.work, env=self.env,
            capture_output=True, text=True, timeout=TIMEOUT, **kwargs,
        )

    def submit(self, applet, *args, source, **kwargs):
        result = self.run_applet(applet, *args, input=source, **kwargs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        match = re.fullmatch(r"job ([0-9a-f]{32}) at ([^\n]+)\n", result.stderr)
        self.assertIsNotNone(match, result.stderr)
        return match.groups()

    def runner(self, *, link=False):
        errors = tempfile.TemporaryFile(mode="w+")
        self.addCleanup(errors.close)
        child = subprocess.Popen(
            self.argv("atd", link=link), cwd=self.work, env=self.env,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=errors, start_new_session=True,
        )
        self.addCleanup(self.stop, child)
        return child, errors

    @staticmethod
    def stop(child):
        if child.poll() is None:
            child.kill()
            child.wait(timeout=TIMEOUT)

    def await_condition(self, condition, runner):
        child, errors = runner
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            if condition():
                return
            if child.poll() is not None:
                break
            time.sleep(0.02)
        errors.seek(0)
        self.fail(f"scheduler did not reach expected state (exit={child.poll()}): {errors.read()}")

    def test_offline_persistence_options_links_and_queue_policy(self):
        source = self.work / "script"
        source.write_text(":\n")
        allow = self.policy / "at.allow"
        allow.write_text("someone-else\n")
        denied = self.run_applet("at", "now", input=":\n")
        self.assertEqual(denied.returncode, 1)
        self.assertIn("not permitted", denied.stderr)
        self.assertFalse(self.spool.exists())
        allow.unlink()

        job, date = self.submit("at", "-f", source, "-t", "204001020304.05", link=True, source="ignored\n", umask=0o777)
        self.assertEqual(date, "Mon Jan  2 03:04:05 2040")
        batch, batch_date = self.submit("batch", source=":\n", link=True)
        batch2, _ = self.submit("at", "-m", "-q", "b", "now", source=":\n")
        result = self.run_applet("at", "-lq", "b")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"{batch}\t{batch_date}\n", result.stdout)
        self.assertIn(batch2, result.stdout)
        self.assertNotIn(job, result.stdout)
        result = self.run_applet("at", "-l", job)
        self.assertEqual((result.returncode, result.stdout), (0, f"{job}\t{date}\n"))
        self.assertFalse((self.work / ".local").exists())

        (self.policy / "at.deny").write_text("")
        (self.policy / "at.allow").write_text("someone-else\n")
        denied = self.run_applet("at", "now", input=":\n")
        self.assertEqual(denied.returncode, 1)
        self.assertIn("not permitted", denied.stderr)
        (self.policy / "at.allow").unlink()
        invalid = self.run_applet("at", "-l", "-m")
        self.assertEqual(invalid.returncode, 1)
        self.assertIn("invalid option", invalid.stderr)
        result = self.run_applet("at", "-r", job, batch, batch2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_applet("at", "-l").stdout, "")

    def test_runner_context_and_notification_rules(self):
        self.env["MARK"] = "exported value"
        self.env["SHELL"] = "/not-the-job-shell"

        def limit():
            _, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
            resource.setrlimit(resource.RLIMIT_FSIZE, (4096, hard))

        program = (
            'if read line; then exit 21; fi\n'
            '/bin/echo "$MARK"; /bin/pwd; > private\n'
            f"'{sys.executable}' -c 'import os,resource; assert not os.isatty(0); "
            'assert os.getsid(0) == os.getpgrp(); assert not os.path.exists("/proc/self/fd/3"); '
            "assert resource.getrlimit(resource.RLIMIT_FSIZE)[0] == 4096' || exit 22\n"
            'exit 7\n'
        )
        loud, _ = self.submit("at", "now", source=program, umask=0o077, preexec_fn=limit)
        silent, _ = self.submit("at", "now", source=": > no-notice\n")
        notify, _ = self.submit("at", "-m", "now", source=":\n")
        runner = self.runner(link=True)
        self.await_condition(lambda: (self.mail / f"zosix-at-{loud}").exists() and
                             (self.mail / f"zosix-at-{notify}").exists() and
                             (self.work / "no-notice").exists() and not (self.spool / "running" / silent).exists(), runner)
        message = (self.mail / f"zosix-at-{loud}").read_text()
        self.assertIn("status 7.", message)
        self.assertIn(f"exported value\n{self.work}\n", message)
        self.assertEqual((self.work / "private").stat().st_mode & 0o777, 0o600)
        self.assertEqual({entry.name for entry in self.mail.iterdir()}, {f"zosix-at-{loud}", f"zosix-at-{notify}"})

    def test_runner_waits_for_inherited_output_and_excludes_second_runner(self):
        job, _ = self.submit("at", "now", source=": > entered\n(/bin/sleep 0.2; /bin/echo late-output) &\n")
        runner = self.runner()
        self.await_condition((self.work / "entered").exists, runner)
        second = self.run_applet("atd", link=True)
        self.assertEqual(second.returncode, 1)
        self.assertIn("already running", second.stderr)
        message = self.mail / f"zosix-at-{job}"
        self.await_condition(message.exists, runner)
        self.assertIn("late-output\n", message.read_text())

    def test_delivery_failure_retains_output_without_rerunning(self):
        (self.home / "Maildir").symlink_to(self.work, target_is_directory=True)
        job, _ = self.submit("at", "now", source="/bin/echo ran >> count; /bin/echo captured\n")
        runner = self.runner()
        self.await_condition(lambda: (self.spool / "finished" / job).is_dir(), runner)
        self.stop(runner[0])
        self.assertEqual((self.spool / "finished" / job / "output").read_text(), "captured\n")
        (self.home / "Maildir").unlink()
        runner = self.runner()
        self.await_condition(lambda: (self.mail / f"zosix-at-{job}").exists(), runner)
        self.assertIn("captured\n", (self.mail / f"zosix-at-{job}").read_text())
        self.assertEqual((self.work / "count").read_text(), "ran\n")

    def test_restart_quarantines_claim_and_retains_pending_jobs(self):
        marker = self.work / "started"
        struck, _ = self.submit("at", "now", source='/bin/echo "$$" > started; exec /bin/sleep 30\n')
        pending, _ = self.submit("at", "-t", "204001020304.05", source=":\n")
        runner = self.runner()
        self.await_condition(lambda: marker.exists() and bool(marker.read_text().strip()), runner)
        pid = int(marker.read_text())
        try:
            self.stop(runner[0])
        finally:
            # Only the job in this fixture occupies this new session/group.
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        runner = self.runner()
        self.await_condition(lambda: (self.spool / "quarantine" / struck).is_dir(), runner)
        self.assertEqual(marker.read_text(), f"{pid}\n")
        self.assertIn(pending, self.run_applet("at", "-l").stdout)
        self.assertNotIn(struck, self.run_applet("at", "-l").stdout)

    def test_concurrent_submit_then_remove_or_claim(self):
        with ThreadPoolExecutor(max_workers=4) as workers:
            jobs = list(workers.map(lambda n: self.submit("at", "now", source=f": > ran-{n}\n")[0], range(4)))
        self.assertEqual(len(set(jobs)), 4)
        with ThreadPoolExecutor(max_workers=4) as workers:
            removed = [workers.submit(self.run_applet, "at", "-r", job) for job in jobs]
            runner = self.runner()
            for n, result in enumerate(removed):
                result = result.result(timeout=TIMEOUT)
                ran = self.work / f"ran-{n}"
                if result.returncode == 0:
                    self.assertFalse(ran.exists())
                else:
                    self.await_condition(ran.exists, runner)
        self.assertEqual(self.run_applet("at", "-l").stdout, "")


def isolated_main(outer_namespace):
    if os.readlink("/proc/self/ns/mnt") == outer_namespace:
        raise RuntimeError("scheduler fixtures require a separate mount namespace")
    with tempfile.TemporaryDirectory(prefix="zosix-at-") as temp:
        fixture = Path(temp)
        for name in ("etc", "home"):
            (fixture / name).mkdir()
        (fixture / "etc/zosixutils").mkdir()
        mounted = []
        try:
            for name in ("etc", "home"):
                target = f"/{name}"
                subprocess.run(["mount", "--bind", fixture / name, target], check=True, timeout=TIMEOUT)
                mounted.append(target)
            return 0 if unittest.main(exit=False, argv=[sys.argv[0]]).result.wasSuccessful() else 1
        finally:
            for target in reversed(mounted):
                subprocess.run(["umount", target], check=True, timeout=TIMEOUT)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--isolated":
        sys.exit(isolated_main(sys.argv[2]))
    else:
        if os.geteuid() != 0:
            sys.exit("scheduler integration requires root with unshare, mount, and umount")
        outer = os.readlink("/proc/self/ns/mnt")
        sys.exit(subprocess.call([
            "unshare", "--user", "--map-root-user", "--mount", "--propagation", "private",
            "--pid", "--fork", "--kill-child", "--mount-proc",
            sys.executable, __file__, BINARY, "--isolated", outer,
        ], timeout=90))
