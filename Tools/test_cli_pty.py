#!/usr/bin/env python3
"""Run an already-built ModeleafCLI through a real controlling PTY."""

from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import pty
import select
import signal
import stat
import subprocess
import sys
import tempfile
import termios
import textwrap
import time
import unittest
from dataclasses import dataclass
from typing import Any, Dict, Optional, Sequence


SESSION_TIMEOUT = 5.0
MAX_OUTPUT = 1024 * 1024


@dataclass
class Result:
    command: str
    exit_code: Optional[int]
    signal_number: Optional[int]
    output: str
    marker: Optional[Dict[str, Any]]
    timed_out: bool

    def describe(self) -> str:
        status = "timed out" if self.timed_out else "completed"
        if self.exit_code is not None:
            status += ", exit code %d" % self.exit_code
        if self.signal_number is not None:
            status += ", signal %d" % self.signal_number
        marker = "<none>" if self.marker is None else json.dumps(self.marker, sort_keys=True)
        output = self.output if self.output else "<empty>"
        return "PTY command %r %s\nmarker: %s\ncaptured output:\n---\n%s\n---" % (
            self.command, status, marker, output
        )


class FakeBrew:
    _BODY = textwrap.dedent(
        r'''
        import json
        import os
        import sys
        import termios
        import tty

        fd = sys.stdin.fileno()
        try:
            foreground = os.tcgetpgrp(fd)
        except OSError:
            foreground = None
        print(json.dumps({
            "argv": sys.argv[1:],
            "pgrp": os.getpgrp(),
            "pid": os.getpid(),
            "tcgetpgrp": foreground,
        }, sort_keys=True, separators=(",", ":")), flush=True)

        if os.environ.get("MODELEAF_FAKE_BREW_NONINTERACTIVE") == "1":
            print("fake brew stdout", flush=True)
            print("fake brew stderr", file=sys.stderr, flush=True)
            raise SystemExit(42)

        original = termios.tcgetattr(fd)
        # Keep Python's default SIGINT handler: Ctrl+C raises KeyboardInterrupt.
        try:
            tty.setcbreak(fd)
            print("FAKE_BREW_INPUT_READY", flush=True)
            while True:
                byte = os.read(fd, 1)
                if not byte:
                    raise SystemExit(1)
                if byte in (b"y", b"Y"):
                    print("fake brew accepted", flush=True)
                    raise SystemExit(0)
                if byte in (b"n", b"N"):
                    print("fake brew declined", flush=True)
                    raise SystemExit(23)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, original)
        '''
    ).lstrip()

    def __init__(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="modeleaf-cli-pty-")
        self.path = os.path.join(self.directory.name, "brew")
        with open(self.path, "w", encoding="utf-8") as helper:
            helper.write("#!" + os.path.realpath(sys.executable) + "\n")
            helper.write(self._BODY)
        os.chmod(self.path, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)

    def close(self) -> None:
        self.directory.cleanup()

    def environment(self, noninteractive: bool = False) -> Dict[str, str]:
        result = os.environ.copy()
        result["PATH"] = self.directory.name
        result["LC_ALL"] = "C"
        result["PYTHONUNBUFFERED"] = "1"
        if noninteractive:
            result["MODELEAF_FAKE_BREW_NONINTERACTIVE"] = "1"
        else:
            result.pop("MODELEAF_FAKE_BREW_NONINTERACTIVE", None)
        return result


def marker_from(output: str) -> Optional[Dict[str, Any]]:
    for line in output.splitlines():
        if not line.startswith("{") or not line.endswith("}"):
            continue
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict) and all(
            key in value for key in ("argv", "pid", "pgrp", "tcgetpgrp")
        ):
            return value
    return None


def kill_pid(pid: Optional[int]) -> None:
    if not isinstance(pid, int) or pid <= 0:
        return
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError as error:
        if error.errno not in (errno.ESRCH, errno.EPERM):
            raise


def kill_group(
    pid: Optional[int],
    expected_pgrp: Optional[int],
    expected_session: Optional[int] = None,
) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        session = os.getsid(pid) if expected_session is not None else None
        pgrp = os.getpgid(pid)
    except OSError:
        return False
    if expected_session is not None and session != expected_session:
        return False
    if expected_pgrp is not None and pgrp != expected_pgrp:
        return False
    if pgrp <= 1 or pgrp == os.getpgrp():
        return False
    try:
        os.killpg(pgrp, signal.SIGKILL)
    except OSError as error:
        if error.errno not in (errno.ESRCH, errno.EPERM):
            raise
        return False
    return True


def wait_for_child(pid: int, deadline: float) -> Optional[int]:
    while time.monotonic() < deadline:
        try:
            waited_pid, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return None
        if waited_pid == pid:
            return status
        select.select([], [], [], 0.02)
    return None


def run_pty(
    cli_path: str,
    command: str,
    environment: Dict[str, str],
    input_bytes: Optional[bytes] = None,
    interactive: bool = False,
    timeout: float = SESSION_TIMEOUT,
) -> Result:
    child_pid, master = pty.fork()
    if child_pid == pty.CHILD:
        try:
            os.environ.clear()
            os.environ.update(environment)
            os.execv(cli_path, [cli_path, command])
        except BaseException as error:
            os.write(2, ("test_cli_pty: exec failed: %s\n" % error).encode())
            os._exit(127)

    try:
        terminal_modes = termios.tcgetattr(master)
    except (OSError, termios.error):
        terminal_modes = None
    flags = fcntl.fcntl(master, fcntl.F_GETFL)
    fcntl.fcntl(master, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    output = bytearray()
    marker: Optional[Dict[str, Any]] = None
    child_status: Optional[int] = None
    sent_input = input_bytes is None
    master_open = True
    timed_out = False
    exception_occurred = False
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            if child_status is None:
                try:
                    waited_pid, status = os.waitpid(child_pid, os.WNOHANG)
                except ChildProcessError:
                    waited_pid, status = child_pid, None
                if waited_pid == child_pid:
                    child_status = status

            if master_open:
                try:
                    ready, _, _ = select.select(
                        [master], [], [], min(0.05, max(0.0, deadline - time.monotonic()))
                    )
                except (OSError, ValueError):
                    ready = []
                if ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError as error:
                        if error.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                            data = None
                        elif error.errno == errno.EIO:
                            data = b""
                        else:
                            raise
                    if data:
                        output.extend(data[: max(0, MAX_OUTPUT - len(output))])
                    elif data == b"":
                        master_open = False

            decoded = bytes(output).decode("utf-8", errors="replace")
            marker = marker or marker_from(decoded)
            if (
                input_bytes is not None
                and not sent_input
                and marker is not None
                and (not interactive or "FAKE_BREW_INPUT_READY" in decoded)
            ):
                try:
                    os.write(master, input_bytes)
                except OSError as error:
                    if error.errno not in (errno.EIO, errno.EPIPE, errno.ESRCH):
                        raise
                sent_input = True

            if child_status is not None and not master_open:
                break
        timed_out = child_status is None
    except BaseException:
        exception_occurred = True
        raise
    finally:
        if child_status is None:
            kill_group(child_pid, child_pid)
            kill_pid(child_pid)
        if child_status is None and (timed_out or exception_occurred):
            if marker is not None:
                helper_pid, helper_pgrp = marker.get("pid"), marker.get("pgrp")
                if isinstance(helper_pid, int) and isinstance(helper_pgrp, int):
                    if kill_group(helper_pid, helper_pgrp, expected_session=child_pid):
                        kill_pid(helper_pid)

        if child_status is None:
            child_status = wait_for_child(child_pid, time.monotonic() + 1.0)
        if child_status is None:
            try:
                _, child_status = os.waitpid(child_pid, 0)
            except ChildProcessError:
                child_status = None
        if terminal_modes is not None:
            try:
                termios.tcsetattr(master, termios.TCSANOW, terminal_modes)
            except (OSError, termios.error):
                pass
        try:
            os.close(master)
        except OSError:
            pass

    decoded = bytes(output).decode("utf-8", errors="replace")
    exit_code = os.WEXITSTATUS(child_status) if child_status is not None and os.WIFEXITED(child_status) else None
    signal_number = os.WTERMSIG(child_status) if child_status is not None and os.WIFSIGNALED(child_status) else None
    return Result(command, exit_code, signal_number, decoded, marker or marker_from(decoded), timed_out)


class ModeleafCLIPTYTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if CLI_PATH is None:
            raise RuntimeError("--cli is required")
        cls.fake_brew = FakeBrew()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.fake_brew.close()

    def assert_success(self, result: Result, code: int) -> None:
        self.assertFalse(result.timed_out, result.describe())
        self.assertIsNone(result.signal_number, result.describe())
        self.assertEqual(result.exit_code, code, result.describe())

    def assert_foreground(self, result: Result) -> None:
        self.assertIsNotNone(result.marker, result.describe())
        if result.marker is None:
            return
        for key in ("pid", "pgrp", "tcgetpgrp"):
            self.assertIsInstance(result.marker.get(key), int, result.describe())
        self.assertEqual(result.marker["pgrp"], result.marker["tcgetpgrp"], result.describe())

    def test_interactive_update_and_remove_y_n(self) -> None:
        cases = [
            ("update", b"y", 0, ["upgrade", "--cask", "modeleaf"]),
            ("update", b"n", 23, ["upgrade", "--cask", "modeleaf"]),
            ("remove", b"y", 0, ["uninstall", "--cask", "modeleaf"]),
            ("remove", b"n", 23, ["uninstall", "--cask", "modeleaf"]),
        ]
        for command, answer, code, expected_args in cases:
            with self.subTest(command=command, answer=answer):
                result = run_pty(
                    CLI_PATH, command, self.fake_brew.environment(), answer, interactive=True
                )
                self.assert_success(result, code)
                self.assert_foreground(result)
                self.assertIsNotNone(result.marker, result.describe())
                if result.marker is not None:
                    self.assertEqual(result.marker["argv"], expected_args, result.describe())
                self.assertIn("FAKE_BREW_INPUT_READY", result.output, result.describe())

    def test_ctrl_c_terminates_foreground_brew(self) -> None:
        result = run_pty(
            CLI_PATH, "update", self.fake_brew.environment(), b"\x03", interactive=True
        )
        self.assertFalse(result.timed_out, result.describe())
        self.assertTrue(
            (result.signal_number == signal.SIGINT and result.exit_code is None)
            or (result.signal_number is None and result.exit_code == 130),
            result.describe(),
        )
        self.assert_foreground(result)
        self.assertIn("FAKE_BREW_INPUT_READY", result.output, result.describe())

    def test_noninteractive_status_and_output_propagate(self) -> None:
        result = run_pty(CLI_PATH, "update", self.fake_brew.environment(noninteractive=True))
        self.assert_success(result, 42)
        self.assert_foreground(result)
        self.assertIn("fake brew stdout", result.output, result.describe())
        self.assertIn("fake brew stderr", result.output, result.describe())
        self.assertNotIn("FAKE_BREW_INPUT_READY", result.output, result.describe())
        self.assertIsNotNone(result.marker, result.describe())
        if result.marker is not None:
            self.assertEqual(result.marker["argv"], ["upgrade", "--cask", "modeleaf"], result.describe())

    def test_noninteractive_pipes_preserve_streams(self) -> None:
        completed = subprocess.run(
            [CLI_PATH, "update"],
            env=self.fake_brew.environment(noninteractive=True),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 42)
        marker = marker_from(completed.stdout)
        self.assertIsNotNone(marker, completed.stdout)
        if marker is not None:
            self.assertEqual(marker["argv"], ["upgrade", "--cask", "modeleaf"])
            self.assertIsNone(marker["tcgetpgrp"])
        self.assertIn("fake brew stdout", completed.stdout)
        self.assertNotIn("fake brew stderr", completed.stdout)
        self.assertIn("fake brew stderr", completed.stderr)
        self.assertNotIn("fake brew stdout", completed.stderr)
        self.assertNotIn("FAKE_BREW_INPUT_READY", completed.stdout)

    def test_missing_brew_returns_127(self) -> None:
        with tempfile.TemporaryDirectory(prefix="modeleaf-cli-no-brew-") as path:
            environment = os.environ.copy()
            environment["PATH"] = path
            environment["LC_ALL"] = "C"
            result = run_pty(CLI_PATH, "update", environment)
        self.assert_success(result, 127)
        self.assertIsNone(result.marker, result.describe())
        self.assertIn("brew", result.output.lower(), result.describe())


CLI_PATH: Optional[str] = None


def main(argv: Optional[Sequence[str]] = None) -> int:
    global CLI_PATH
    parser = argparse.ArgumentParser(
        description="Run ModeleafCLI's Homebrew commands through a controlling PTY."
    )
    parser.add_argument("--cli", required=True, help="path to an already-built ModeleafCLI executable")
    parsed, unittest_args = parser.parse_known_args(argv)
    CLI_PATH = os.path.abspath(parsed.cli)
    if not os.path.isfile(CLI_PATH) or not os.access(CLI_PATH, os.X_OK):
        parser.error("--cli must name an executable file: %s" % parsed.cli)
    program = unittest.main(module=__name__, argv=[sys.argv[0]] + unittest_args, exit=False)
    return 0 if program.result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
