#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Tests of run-windows.py: which runner it takes and what it starts (RUY-36).

    python3 -I test_run_windows.py

No Wine and no Proton are needed: the runner folders are made here and os.execve is recorded, not
called (the self-test's subprocess.run too). Run by `make test` and by scripts/test-vm-checks.sh.
"""
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("run_windows", os.path.join(HERE, "run-windows.py"))
run_windows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_windows)


def make_runner(root, name, ver, **changes):
    """A runner folder like GE-Proton's, with the keys of runner.json changed by `changes`."""
    folder = os.path.join(root, name)
    os.makedirs(folder)
    runner = {
        "format": 1,
        "family": "proton-ge",
        "kind": "proton",
        "version": ver,
        "arch": "x86_64",
        "entry": {"proton": "proton"},
    }
    runner.update(changes)
    with open(os.path.join(folder, "runner.json"), "w", encoding="utf-8") as f:
        json.dump(runner, f)
    with open(os.path.join(folder, "proton"), "w", encoding="utf-8") as f:
        f.write("#!/usr/bin/env python3\n")
    return folder


def can_link():
    with tempfile.TemporaryDirectory() as d:
        try:
            os.symlink(d, os.path.join(d, "l"))
        except (OSError, NotImplementedError):
            return False
    return True


class PickRunner(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = self._tmp.name

    def test_takes_the_newest_major_it_supports(self):
        make_runner(self.root, "ProtonGE10", "GE-Proton10-34")
        make_runner(self.root, "ProtonGE11", "GE-Proton11-13")
        make_runner(self.root, "ProtonGE12", "GE-Proton12-1")  # newer than the majors it tested
        name, version, proton = run_windows.pick_runner(self.root)
        self.assertEqual((name, version), ("ProtonGE11", "GE-Proton11-13"))
        self.assertEqual(proton, os.path.join(self.root, "ProtonGE11", "proton"))

    def test_compares_the_numbers_not_the_folder_names(self):
        make_runner(self.root, "ProtonGE11", "GE-Proton10-34")
        make_runner(self.root, "ProtonGE10", "GE-Proton11-2")
        make_runner(self.root, "ProtonGE9", "GE-Proton11-13")
        self.assertEqual(run_windows.pick_runner(self.root)[:2], ("ProtonGE9", "GE-Proton11-13"))

    def test_skips_what_it_cannot_use(self):
        make_runner(self.root, "format2", "GE-Proton11-99", format=2)
        make_runner(self.root, "bool", "GE-Proton11-98", format=True)
        make_runner(self.root, "wine", "10.2", family="wine", kind="wine")
        make_runner(self.root, "valve", "9.0", family="proton")
        make_runner(self.root, "arm", "GE-Proton11-97", arch="aarch64")
        make_runner(self.root, "outside", "GE-Proton11-96", entry={"proton": "../proton"})
        make_runner(self.root, "absolute", "GE-Proton11-95", entry={"proton": "/usr/bin/python3"})
        make_runner(self.root, "noentry", "GE-Proton11-94", entry={})
        make_runner(self.root, "notext", "GE-Proton11-93", version=11)
        make_runner(self.root, "nonumber", "GE-Proton-latest")
        make_runner(self.root, "good", "GE-Proton10-1")
        self.assertEqual(run_windows.pick_runner(self.root)[0], "good")

    def test_a_missing_entry_file_or_runner_json_is_skipped(self):
        folder = make_runner(self.root, "gone", "GE-Proton11-13")
        os.remove(os.path.join(folder, "proton"))
        os.makedirs(os.path.join(self.root, "empty"))
        with open(os.path.join(self.root, "garbage"), "w", encoding="utf-8") as f:
            f.write("not a folder")
        os.makedirs(os.path.join(self.root, "broken"))
        with open(os.path.join(self.root, "broken", "runner.json"), "w", encoding="utf-8") as f:
            f.write("{")
        self.assertIsNone(run_windows.pick_runner(self.root))

    def test_no_folder_is_no_runner(self):
        self.assertIsNone(run_windows.pick_runner(os.path.join(self.root, "missing")))

    @unittest.skipUnless(can_link(), "this host cannot make symbolic links")
    def test_follows_no_links(self):
        real = make_runner(self.root, "real", "GE-Proton11-13")
        os.symlink(real, os.path.join(self.root, "link"), target_is_directory=True)
        folder = make_runner(self.root, "plain", "GE-Proton11-50")
        os.remove(os.path.join(folder, "proton"))
        os.symlink(os.path.join(real, "proton"), os.path.join(folder, "proton"))
        # `link` is a folder link and `plain` has a link as its entry: only `real` counts.
        self.assertEqual(run_windows.pick_runner(self.root)[0], "real")


class Main(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = os.path.join(self._tmp.name, "runners")
        self.data = os.path.join(self._tmp.name, "data")
        os.makedirs(self.root)
        env = mock.patch.dict(os.environ, {"XDG_DATA_HOME": self.data, "WINEPREFIX": "/inherited"})
        env.start()
        self.addCleanup(env.stop)

    def run_main(self, argv):
        calls = []
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(os, "execve", lambda *a: calls.append(a)):
            with redirect_stdout(out), redirect_stderr(err):
                code = run_windows.main(argv)
        return code, calls, out.getvalue(), err.getvalue()

    def test_starts_proton_the_way_the_console_does(self):
        make_runner(self.root, "ProtonGE11", "GE-Proton11-13")
        code, calls, out, _ = self.run_main(["--runners", self.root, "game.exe", "-windowed"])
        self.assertIsNone(code)
        self.assertEqual(len(calls), 1)
        path, argv, env = calls[0]
        proton = os.path.join(self.root, "ProtonGE11", "proton")
        self.assertEqual(path, proton)
        self.assertEqual(argv, [proton, "waitforexitandrun", "game.exe", "-windowed"])
        self.assertEqual(env["STEAM_COMPAT_DATA_PATH"], os.path.join(self.data, "proton"))
        self.assertEqual(env["STEAM_COMPAT_CLIENT_INSTALL_PATH"], os.path.join(self.data, "proton", "client"))
        self.assertTrue(os.path.isdir(env["STEAM_COMPAT_CLIENT_INSTALL_PATH"]))
        self.assertNotIn("WINEPREFIX", env)
        self.assertIn("using ProtonGE11 (GE-Proton11-13)", out)

    def test_proton_gets_a_game_id_and_a_working_folder_it_can_read(self):
        # protonfixes stops on a missing PWD, and on a compat folder without digits when no game
        # id is set: an id or PWD inherited from the caller must not leak through either.
        make_runner(self.root, "ProtonGE11", "GE-Proton11-13")
        with mock.patch.dict(os.environ, {"SteamAppId": "620", "SteamGameId": "620", "PWD": "/elsewhere"}):
            _, calls, _, _ = self.run_main(["--runners", self.root, "game.exe"])
        env = calls[0][2]
        self.assertEqual(env["SteamAppId"], "0")
        self.assertEqual(env["SteamGameId"], "0")
        self.assertEqual(env["PWD"], os.getcwd())

    def self_test(self, writes=True, status=0, display=":0"):
        """--self-test with subprocess.run recorded. `writes`: the fake cmd.exe does what the
        argument says (writes the marker to the Windows path after the `>`), as a real one does."""
        make_runner(self.root, "ProtonGE11", "GE-Proton11-13")
        calls = []

        def fake_run(argv, env=None):
            calls.append((argv, env))
            if writes:
                _, _, path = argv[4].partition(">")
                with open(path[2:].replace("\\", "/"), "w", encoding="utf-8", newline="") as f:
                    f.write(argv[4].partition(">")[0][len("echo "):] + "\r\n")
            return mock.Mock(returncode=status)

        out, err = io.StringIO(), io.StringIO()
        env = {"DISPLAY": display} if display else {}
        with mock.patch.dict(os.environ), mock.patch.object(run_windows.subprocess, "run", fake_run):
            os.environ.pop("DISPLAY", None)
            os.environ.update(env)
            with redirect_stdout(out), redirect_stderr(err):
                code = run_windows.main(["--runners", self.root, "--self-test"])
        return code, calls, out.getvalue(), err.getvalue()

    def test_the_self_test_runs_the_runners_own_cmd_and_reads_a_file(self):
        # Proton starts the program with CREATE_NEW_CONSOLE: what cmd.exe echoes goes to a console
        # window, never to stdout (RUY-980). So cmd.exe writes the marker to a file.
        code, calls, out, _ = self.self_test()
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 1)
        argv, env = calls[0]
        self.assertEqual(argv[1], "waitforexitandrun")
        self.assertEqual(argv[2], os.path.join(self.root, "ProtonGE11", "files/lib/wine/x86_64-windows/cmd.exe"))
        marker_file = os.path.join(self.data, "self-test-marker.txt")
        self.assertEqual(argv[3:], ["/c", "echo RUYA_HELLO_RUNNER_OK>Z:" + marker_file.replace("/", "\\")])
        self.assertEqual(env["DISPLAY"], ":0")
        self.assertIn("\nRUYA_HELLO_RUNNER_OK\n", out)
        self.assertFalse(os.path.exists(marker_file), "the marker file is removed after the run")

    def test_the_self_test_does_not_print_a_marker_the_program_never_wrote(self):
        code, _, out, err = self.self_test(writes=False)
        self.assertEqual(code, 1)
        self.assertNotIn("RUYA_HELLO_RUNNER_OK", out)
        self.assertIn("not RUYA_HELLO_RUNNER_OK", err)

    def test_the_self_test_ignores_a_marker_left_by_an_earlier_run(self):
        # A leftover file with the marker must not pass the self-test when the runner wrote nothing.
        os.makedirs(self.data)
        with open(os.path.join(self.data, "self-test-marker.txt"), "w", encoding="utf-8") as f:
            f.write("RUYA_HELLO_RUNNER_OK\r\n")
        code, calls, out, _ = self.self_test(writes=False)
        self.assertEqual(len(calls), 1)
        self.assertEqual(code, 1)
        self.assertNotIn("RUYA_HELLO_RUNNER_OK", out)

    def test_the_self_test_fails_when_proton_does(self):
        code, _, out, err = self.self_test(status=3)
        self.assertEqual(code, 1)
        self.assertNotIn("\nRUYA_HELLO_RUNNER_OK\n", out)
        self.assertIn("status 3", err)

    def test_the_self_test_without_a_display_starts_nothing(self):
        # Without a display Wine's console host waits for ever: say so instead of hanging.
        code, calls, _, err = self.self_test(display="")
        self.assertEqual(code, 1)
        self.assertEqual(calls, [])
        self.assertIn("needs an X display", err)

    def test_a_program_needs_no_display_check_and_is_still_exec_ed(self):
        make_runner(self.root, "ProtonGE11", "GE-Proton11-13")
        with mock.patch.dict(os.environ):
            os.environ.pop("DISPLAY", None)
            code, calls, _, _ = self.run_main(["--runners", self.root, "game.exe"])
        self.assertIsNone(code)
        self.assertEqual(len(calls), 1)

    def test_without_a_runner_it_says_so_and_starts_nothing(self):
        make_runner(self.root, "ProtonGE12", "GE-Proton12-1")
        code, calls, _, err = self.run_main(["--runners", self.root, "game.exe"])
        self.assertEqual(code, 1)
        self.assertEqual(calls, [])
        self.assertIn("no proton-ge runner of major 10 to 11", err)

    def test_without_a_program_it_prints_the_usage(self):
        code, calls, _, err = self.run_main(["--runners", self.root])
        self.assertEqual(code, 2)
        self.assertEqual(calls, [])
        self.assertIn("usage:", err)

    def test_a_runner_that_cannot_start_is_an_error_not_a_traceback(self):
        make_runner(self.root, "ProtonGE11", "GE-Proton11-13")
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(os, "execve", side_effect=OSError("denied")):
            with redirect_stdout(out), redirect_stderr(err):
                code = run_windows.main(["--runners", self.root, "game.exe"])
        self.assertEqual(code, 1)
        self.assertIn("cannot start", err.getvalue())


if __name__ == "__main__":
    unittest.main()
