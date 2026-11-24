"""Run with python3 tests/sh_integration.py path/to/zosixutils (Linux)."""

import errno
import fcntl
import os
from pathlib import Path
import pty
import resource
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest


BINARY = Path(sys.argv.pop(1)).resolve()
ENV = {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}


class ShellTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="zosixutils-sh-")
        self.addCleanup(temporary.cleanup)
        self.cwd = Path(temporary.name)
        self.env = dict(ENV, HOME=str(self.cwd), PWD=str(self.cwd))
        self.shell = [str(BINARY), "sh"]

    def fixture(self, name, contents, mode=0o644):
        path = self.cwd / name
        path.write_bytes(contents)
        path.chmod(mode)
        return path

    def launch(self, args, data=None, shell=None, **kwargs):
        return subprocess.run(
            (shell or self.shell) + args, input=data, cwd=self.cwd, env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8, **kwargs,
        )

    def check(self, result, status=0, stdout=b"", stderr=b""):
        self.assertEqual((result.returncode, result.stdout), (status, stdout), result.stderr)
        if stderr is not None:
            self.assertEqual(result.stderr, stderr)

    def test_invocation_and_shared_input(self):
        link = self.cwd / "sh"
        link.symlink_to(BINARY)
        script = b'printf "%s:%s:%s\n" "$0" "$#" "$1"\n'
        self.check(self.launch(["-c", script, "name", "-x"]), stdout=b"name:1:-x\n")
        self.check(self.launch(["-c", script], shell=[str(link)]), stdout=os.fsencode(link) + b":0:\n")
        self.fixture("script", script + b'read line\nprintf "%s\n" "$line"\n')
        self.check(self.launch(["-", "script", "arg"], b"file stdin\n"), stdout=b"script:1:arg\nfile stdin\n")
        self.check(self.launch(["-s", "--", "arg"], script), stdout=b"sh:1:arg\n")
        data = b'read line\nfrom builtin\nprintf "%s\n" "$line"\ndd bs=1 count=11 status=none\nfrom child\nprintf "after\n"\n'
        self.check(self.launch([], data), stdout=b"from builtin\nfrom child\nafter\n")

    def test_wait_with_inherited_blocked_sigchld(self):
        def block_sigchld():
            signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGCHLD})

        result = self.launch(
            ["-c", '/bin/sleep 0.05 & wait "$!"; printf "%s\\n" "$?"'], preexec_fn=block_sigchld,
        )
        self.check(result, stdout=b"0\n")

    def test_exec_lookup_and_environment(self):
        self.fixture("tool", b'printf "%s:%s:%s\n" "$0" "$A" "$1"\n', 0o755)
        self.fixture("blocked", b":\n")
        self.fixture("binary", b"not text\0\n", 0o755)
        self.fixture("source", b'X=inside\nreturn 7\n', 0o644)
        script = b'A=old; PATH=:$PATH A=new tool arg; printf "%s\n" "$A"; PATH=:$PATH; . source; printf "%s:%s\n" "$?" "$X"'
        self.check(self.launch(["-c", script]), stdout=b"tool:new:arg\nold\n7:inside\n")
        for name, status in [("missing", 127), ("blocked", 126), ("binary", 126)]:
            result = self.launch(["-c", f"PATH=:$PATH {name}"])
            self.check(result, status=status, stderr=None)
            self.assertIn(name.encode(), result.stderr)
        result = self.launch(["-c", "A=exported exec /usr/bin/env; printf unreached"])
        self.assertEqual((result.returncode, result.stderr), (0, b""))
        self.assertIn(b"A=exported", result.stdout.splitlines())
        self.assertNotIn(b"unreached", result.stdout)
        self.check(self.launch(["-c", "exec -- >kept; printf retained"]))
        self.assertEqual((self.cwd / "kept").read_bytes(), b"retained")
        self.check(self.launch(["-c", 'command exec nonexistent; printf "%s" "$?"']), stdout=b"127", stderr=None)

    def test_alias_timing_and_scope(self):
        self.fixture("alias", b"printf 'external alias\n'\n", 0o755)
        script = b"""PATH=:$PATH
alias say='printf "%s\\n" old'
alias say='printf "%s\\n" new'; say
say
alias lead='printf "%s\\n" '; alias word=expanded
lead word
printf '%s\\n' word
(say; alias say=false)
say
X=prefix >out say
alias say >definition
alias not_defined 2>diagnostic
command -v say
unalias say
command -v say || printf 'removed\\n'
"""
        self.check(self.launch(["-c", script]), stdout=(
            b"old\nnew\nexpanded\nword\nnew\nnew\n"
            b"alias say='printf \"%s\\n\" new'\nremoved\n"
        ))
        self.assertEqual((self.cwd / "out").read_bytes(), b"new\n")
        self.assertEqual((self.cwd / "definition").read_bytes(), b"say='printf \"%s\\n\" new'\n")
        self.assertIn(b"alias not found", (self.cwd / "diagnostic").read_bytes())
        self.check(self.launch(["-c", "command -v say"]), status=1)
        self.check(self.launch(["-c", "alias() { printf function; }; alias; command alias"]), stdout=b"function")
        result = self.launch(["alias"], shell=[str(BINARY)])
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"unknown applet 'alias'", result.stderr)

    def test_only_reached_branches_and_positional_fields(self):
        self.fixture("one.txt", b"")
        self.fixture("two.txt", b"")
        self.fixture(".hidden.txt", b"")
        (self.cwd / "child").mkdir()
        script = b"""if false; then printf broken >unreached; elif true; then :; fi
false && printf broken >unreached
true || : "${missing:?unreached}"
f() { printf '<%s>\\n' "$@"; return 9; }
f "" 'a b'; printf 'ret=%s\\n' "$?"
set -- start finish; shift
for arg do printf '%s\\n' "$arg"; done
n=; until [ "$n" ]; do n=ok; continue; done
while true; do break; done
case "$n" in o*) printf 'match\\n' ;& x) printf 'fallthrough\\n' ;; esac
printf '%s\\n' *.txt
set -f; printf '%s\\n' *.txt
(cd child; n=subshell); printf '%s:%s\\n' "$n" "${PWD##*/}"
"""
        expected = b"<>\n<a b>\nret=9\nfinish\nmatch\nfallthrough\none.txt\ntwo.txt\n*.txt\nok:"
        self.check(self.launch(["-c", script]), stdout=expected + self.cwd.name.encode() + b"\n")
        self.assertFalse((self.cwd / "unreached").exists())

    def test_redirection_order_and_failures(self):
        self.fixture("both", b"printf 'out\\n'; printf 'err\\n' >&2\n", 0o755)
        script = b"./both 2>&1 >first; ./both >second 2>&1; alias a=a 1>partial 8>&9; printf restored"
        self.check(self.launch(["-c", script]), stdout=b"err\nrestored", stderr=None)
        self.assertEqual((self.cwd / "first").read_bytes(), b"out\n")
        self.assertEqual((self.cwd / "second").read_bytes(), b"out\nerr\n")
        self.assertEqual((self.cwd / "partial").read_bytes(), b"")
        self.check(self.launch(["-c", ": 9>&8; printf unreached"]), status=1, stderr=None)
        self.check(self.launch(["-c", "readonly X; X=fail true; printf unreached"]), status=1, stderr=None)
        self.check(self.launch(["-c", 'command shift 3; printf "%s" "$?"']), stdout=b"1", stderr=None)
        self.check(self.launch(["-c", 'exec >closed; : 1>&1; printf opened'], preexec_fn=lambda: os.close(1)))
        self.assertEqual((self.cwd / "closed").read_bytes(), b"opened")
        result = self.launch(["-c", 'alias X=Y; alias X 2>alias-error'], preexec_fn=lambda: os.close(1))
        self.check(result, status=1)
        self.assertIn(b"cannot write", (self.cwd / "alias-error").read_bytes())
        self.check(self.launch(["-c", '(:) >"${target:=subshell}"; printf "%s" "${target-unset}"']), stdout=b"unset")
        self.assertTrue((self.cwd / "subshell").is_file())

    def test_large_pipeline_substitution_and_here_document(self):
        payload = b"x" * 130_000
        script = b"data=$(cat <<'EOF' | cat | cat\n" + payload + b"\nEOF\n)\nprintf %s \"$data\"\n"
        self.check(self.launch([], script), stdout=payload)
        script = b"X=value; cat <<-EOF\n\t\"$X\"\n\tEOF\nfalse | true; printf ':%s:' \"$?\"; ! true | true; printf '%s' \"$?\"\n"
        self.check(self.launch([], script), stdout=b'"value"\n:0:1')

        def restrict_descriptors():
            resource.setrlimit(resource.RLIMIT_NOFILE, (7, 7))

        result = self.launch(["-c", "printf early >ran | cat | cat"], preexec_fn=restrict_descriptors)
        self.check(result, status=2, stderr=None)
        self.assertFalse((self.cwd / "ran").exists())

    def test_nonblocking_stdin_is_normalized(self):
        rd, wr = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
        try:
            os.write(wr, b"printf normalized\n")
        finally:
            os.close(wr)
        try:
            self.check(self.launch([], stdin=rd), stdout=b"normalized")
            self.assertFalse(fcntl.fcntl(rd, fcntl.F_GETFL) & os.O_NONBLOCK)
        finally:
            os.close(rd)

    def test_unsupported_and_incomplete_are_distinct(self):
        for script, diagnostic in [
            ("echo $((1))", b"unsupported"),
            ("echo `:`", b"unsupported"), ("echo $'x'", b"unsupported"),
            ("if true; then :", b"unexpected end"),
        ]:
            result = self.launch(["-c", script])
            self.check(result, status=2, stderr=None)
            self.assertIn(diagnostic, result.stderr)
        self.check(self.launch(["-c", ""]))
        self.check(self.launch([], b""))

    def test_async_wait_and_subshell_isolation(self):
        script = rb'''printf '<%s:%s>\n' "$!" "${!}"
/bin/sh -c 'printf "%s" "$$" >pid; exit 7' & p=$!
wait "$p"; printf 'status=%s\n' "$?"
read actual <pid; printf 'same=%s\n' "$([ "$p" = "$actual" ] && printf yes)"
wait "$p"; printf 'consumed=%s\n' "$?"
false && printf bad >bad || /bin/false & p=$!
wait "$p"; printf 'list=%s\n' "$?"
(/bin/false & q=$!; wait "$q"; printf 'inner=%s\n' "$?"; wait "$p"; printf 'foreign=%s\n' "$?")
if [ "$p" = "$!" ]; then printf 'parent=yes\n'; else printf 'parent=no\n'; fi
/bin/sleep 0.1 & live=$!; (printf 'empty=<%s>\n' "$!"; wait "$live"; printf 'live-foreign=%s\n' "$?"); wait "$live"
s=$(printf '<%s>' "$!"); printf 'sub=%s\n' "$s"
/bin/false & /bin/true & wait; printf 'all=%s\n' "$?"
/bin/false & early=$!; /bin/sleep 0.1; wait "$early"; printf 'early=%s\n' "$?"
wait 99999999 "$p"; printf 'last=%s\n' "$?"
command -v wait; command -v kill
'''
        self.check(self.launch(["-c", script]), stdout=(
            b"<:>\nstatus=7\nsame=yes\nconsumed=127\nlist=1\n"
            b"inner=1\nforeign=127\nparent=yes\nempty=<>\nlive-foreign=127\nsub=<>\n"
            b"all=0\nearly=1\nlast=127\nwait\nkill\n"
        ))
        self.assertFalse((self.cwd / "bad").exists())

    def test_async_input_status_and_redirections(self):
        self.fixture("input", b"value\n")
        script = rb'''read x & p=$!; wait "$p"; printf 'stdin=%s\n' "$?"
{ read x; printf '%s\n' "$x" >result; } <input & p=$!; wait "$p"
/bin/sh -c 'kill -TERM "$$"' & p=$!; wait "$p"; printf 'signal=%s\n' "$?"
/bin/false & a=$!; /bin/true & b=$!; wait "$a" "$b"; printf 'last=%s\n' "$?"
wait not-a-pid 2>err; printf 'invalid=%s\n' "$?"
wait 0; printf 'zero=%s\n' "$?"
/bin/sh -c 'kill -INT "$$"; printf survived >ignored' & p=$!; wait "$p"
{ /bin/sh -c 'kill -QUIT "$$"; printf nested >nested'; } & p=$!; wait "$p"
kill -0 99999999 2>kill-err; printf 'kill=%s\n' "$?"
'''
        self.check(self.launch(["-c", script]), stdout=b"stdin=1\nsignal=143\nlast=0\ninvalid=1\nzero=127\nkill=1\n")
        self.assertEqual((self.cwd / "result").read_bytes(), b"value\n")
        self.assertIn(b"invalid PID", (self.cwd / "err").read_bytes())
        self.assertEqual((self.cwd / "ignored").read_bytes(), b"survived")
        self.assertEqual((self.cwd / "nested").read_bytes(), b"nested")
        self.assertTrue((self.cwd / "kill-err").read_bytes())

    def test_async_pipeline_here_document_and_no_exit_wait(self):
        script = b"""cat <<EOF | cat >result & p=$!
hello
EOF
wait "$p"; printf 'pipeline=%s\\n' "$?"
"""
        self.check(self.launch([], script), stdout=b"pipeline=0\n")
        self.assertEqual((self.cwd / "result").read_bytes(), b"hello\n")
        start = time.monotonic()
        result = self.launch(["-c", '/bin/sleep 30 </dev/null >/dev/null 2>&1 & printf "%s" "$!"'])
        try:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertLess(time.monotonic() - start, 0.8)
        finally:
            if result.stdout.isdigit():
                try:
                    os.kill(int(result.stdout), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_async_pty_reaping_and_interruptible_wait(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.cwd)
            os.execve(BINARY, self.shell, self.env)
        self.addCleanup(os.close, fd)

        def finish():
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass

        self.addCleanup(finish)
        pending = b""

        def until(marker):
            nonlocal pending
            deadline = time.monotonic() + 5
            while marker not in pending:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
                    self.fail(f"missing {marker!r} in PTY output {pending!r}")
                pending += os.read(fd, 4096)
            before, pending = pending.split(marker, 1)
            return before

        until(b"$ ")
        os.write(fd, b"/bin/sleep 0.2 &\n")
        output = until(b"$ ")
        match = re.search(rb"\r\n([0-9]+)\r\n", output)
        self.assertIsNotNone(match, output)
        child = int(match.group(1))
        deadline = time.monotonic() + 5
        while Path(f"/proc/{child}").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(Path(f"/proc/{child}").exists(), "idle child was not reaped")
        os.write(fd, b'wait "$!"; printf "saved=%s\\n" "$?"\n')
        self.assertIn(b"saved=0", until(b"$ "))
        os.write(fd, b'/bin/sleep 0.2 & printf "foreground-pid=%s\\n" "$!"; /bin/sleep 1\n')
        until(b"\r\nforeground-pid=")
        foreground_child = int(until(b"\r\n"))
        deadline = time.monotonic() + 0.8
        while Path(f"/proc/{foreground_child}").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(Path(f"/proc/{foreground_child}").exists(), "child not reaped during foreground wait")
        until(b"$ ")
        os.write(fd, b"/bin/sleep 30 &\n")
        until(b"$ ")
        os.write(fd, b'wait "$!"\n')
        time.sleep(0.1)
        os.write(fd, b"\x03")
        until(b"$ ")
        os.write(fd, b'printf "interrupted=%s\\n" "$?"; kill -KILL "$!"; wait "$!"; printf "after=%s\\n" "$?"\n')
        output = until(b"$ ")
        self.assertIn(b"interrupted=130", output)
        self.assertIn(b"after=137", output)

    def test_nested_quoting_in_expansion(self):
        script = rb"""v='a*b'
printf '%s\n' "${none:-it's}" "${none:-\}}" "${v#'a*'}" "$( )"
"""
        self.check(self.launch(["-c", script]), stdout=b"it's\n}\nb\n\n")

    def test_cd_and_read_in_current_environment(self):
        (self.cwd / "real" / "inside").mkdir(parents=True)
        (self.cwd / "link").symlink_to("real/inside", target_is_directory=True)
        self.fixture("input", b"scalar\\ with space\nraw\\ value\n")
        script = rb"""cd -L link/..; printf 'L:%s\n' "$PWD"
cd -P link/..; printf 'P:%s\n' "$PWD"
cd -; printf 'back:%s\n' "$PWD"
{ read a b; read -r c d; } <input
printf '<%s>\n' "$a" "$b" "$c" "$d"
"""
        cwd = os.fsencode(self.cwd)
        expected = b"L:" + cwd + b"\nP:" + cwd + b"/real\n" + cwd + b"\nback:" + cwd + b"\n"
        self.check(self.launch(["-c", script]), stdout=expected + b"<scalar with>\n<space>\n<raw\\>\n<value>\n")
        self.check(self.launch(["-c", 'read IFS rest; printf "%s:%s" "$IFS" "$rest"'], b"new three words\n"), stdout=b"new:three words")

    def test_terminal_prompts_and_interrupts(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.cwd)
            os.execve(BINARY, self.shell, self.env)
        self.addCleanup(os.close, fd)

        def finish():
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass

        self.addCleanup(finish)
        pending = b""

        def until(marker):
            nonlocal pending
            deadline = time.monotonic() + 5
            while marker not in pending:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
                    self.fail(f"missing {marker!r} in PTY output {pending!r}")
                pending += os.read(fd, 4096)
            before, pending = pending.split(marker, 1)
            return before

        until(b"$ ")
        os.write(fd, b"\n")
        until(b"$ ")
        os.write(fd, b"alias greet='printf ready\\\\n'\n")
        until(b"$ ")
        os.write(fd, b"greet\n")
        self.assertIn(b"ready", until(b"$ "))
        os.write(fd, b")\n")
        self.assertIn(b"syntax error", until(b"$ "))
        for prefix, prompt in [(b"", b"$ "), (b"if true; then\n", b"> ")]:
            if prefix:
                os.write(fd, prefix)
                until(prompt)
            os.write(fd, b"\x03")
            until(b"$ ")
            os.write(fd, b'printf "status=%s\\n" "$?"\n')
            self.assertIn(b"status=130", until(b"$ "))
        os.write(fd, b"{ printf 'started\\n'; sleep 30; } | cat\n")
        until(b"started\r\n")
        os.write(fd, b"\x03")
        until(b"$ ")
        os.write(fd, b'printf "status=%s\\n" "$?"\n')
        self.assertIn(b"status=130", until(b"$ "))
        os.write(fd, b"\x04")
        ready, _, _ = select.select([fd], [], [], 5)
        self.assertTrue(ready, "PTY did not close on EOF")
        try:
            self.assertEqual(os.read(fd, 4096), b"")
        except OSError as exc:
            self.assertEqual(exc.errno, errno.EIO)
        self.assertEqual(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]), 0)


if __name__ == "__main__":
    unittest.main()
