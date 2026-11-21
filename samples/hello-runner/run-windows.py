#!/usr/bin/env python3
# SPDX-License-Identifier: CC0-1.0
"""Runs a Windows program through the console's GE-Proton, from your own Flatpak (RUY-36).

The console mounts its system runners into your sandbox under /app/runners/<Name>/ (the extension
point your manifest declares). This script does what a launcher does and nothing else:

  1. read every /app/runners/*/runner.json (format 1) instead of guessing a path,
  2. keep the GE-Proton runners whose major version you tested, and take the newest,
  3. start the program with the argv and environment ADR-037 gives Proton:
     <proton> waitforexitandrun <program.exe> ...   with STEAM_COMPAT_DATA_PATH and
     STEAM_COMPAT_CLIENT_INSTALL_PATH under your own data folder (per profile, because the data
     folder is), SteamAppId and SteamGameId set to 0, and PWD.

    hello-runner game.exe [arguments]    run a program
    hello-runner --self-test             run the runner's own cmd.exe: prints RUYA_HELLO_RUNNER_OK
    hello-runner --runners DIR ...       read the runners from DIR (default /app/runners)
"""
import json
import os
import re
import sys

# The family you ask for and the majors you tested. A major leaves the console two majors after it
# appeared, so list the ones you tested and take the newest that is still there.
FAMILY = "proton-ge"
MIN_MAJOR = 10
# Raise MAX_MAJOR after you test a newer GE-Proton: until then a console that only has a newer major
# makes this script say there is no runner, which is safer than running a game on one you never tried.
MAX_MAJOR = 11
MARKER = "RUYA_HELLO_RUNNER_OK"
# GE-Proton keeps the Windows programs of its Wine here; only --self-test uses it.
SELF_TEST_EXE = "files/lib/wine/x86_64-windows/cmd.exe"
MAX_FOLDERS = 32  # the console's own launcher reads at most this many


def numbers(version):
    """The numbers in a version text, compared in order: GE-Proton11-12 is [11, 12]."""
    return [int(n) for n in re.findall(r"[0-9]+", version)]


def read_runner(folder):
    """(version numbers, version text, path of the proton script) of a usable runner, else None."""
    try:
        with open(os.path.join(folder, "runner.json"), encoding="utf-8") as f:
            r = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(r, dict):
        return None
    fmt = r.get("format")
    # A format above 1 may mean something else: skip it, as the console's launcher would refuse it.
    if not isinstance(fmt, int) or isinstance(fmt, bool) or fmt != 1:
        return None
    if r.get("family") != FAMILY or r.get("kind") != "proton" or r.get("arch") != "x86_64":
        return None
    version = r.get("version")
    entry = r.get("entry")
    rel = entry.get("proton") if isinstance(entry, dict) else None
    if not isinstance(version, str) or not isinstance(rel, str):
        return None
    nums = numbers(version)
    if not nums or not MIN_MAJOR <= nums[0] <= MAX_MAJOR:
        return None
    parts = rel.split("/")
    if rel.startswith("/") or ".." in parts or "" in parts:
        return None
    proton = os.path.join(folder, *parts)
    if os.path.islink(proton) or not os.path.isfile(proton):
        return None
    return nums, version, proton


def pick_runner(root):
    """(folder name, version, proton script) of the newest runner you support, or None."""
    best = None
    try:
        names = sorted(os.listdir(root))[:MAX_FOLDERS]
    except OSError:
        return None
    for name in names:
        folder = os.path.join(root, name)
        if os.path.islink(folder) or not os.path.isdir(folder):
            continue
        found = read_runner(folder)
        if found and (best is None or found[0] > best[0]):
            best = (found[0], name, found[1], found[2])
    return best[1:] if best else None


def proton_environment(data):
    """The environment ADR-037 gives Proton. Proton derives its prefix (<data>/proton/pfx) itself,
    so a WINEPREFIX of your own would be wrong."""
    compat = os.path.join(data, "proton")
    client = os.path.join(compat, "client")
    os.makedirs(client, exist_ok=True)
    env = dict(os.environ)
    env.pop("WINEPREFIX", None)
    env["STEAM_COMPAT_DATA_PATH"] = compat
    env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = client
    # No Steam game id outside Steam: without one protonfixes parses a number out of the compat
    # folder's name and stops when there is none. 0 makes it apply its defaults only.
    env["SteamAppId"] = env["SteamGameId"] = "0"
    # protonfixes reads PWD without a fallback; a shell sets it, a direct start does not.
    env["PWD"] = os.getcwd()
    return env


def main(argv):
    root = "/app/runners"
    if argv[:1] == ["--runners"] and len(argv) >= 2:
        root, argv = argv[1], argv[2:]
    if not argv:
        sys.stderr.write("usage: hello-runner [--runners DIR] (--self-test | program.exe [arguments])\n")
        return 2
    picked = pick_runner(root)
    if picked is None:
        sys.stderr.write(
            "hello-runner: no %s runner of major %d to %d under %s (is the extension point "
            "declared, and does this console have the runner?)\n" % (FAMILY, MIN_MAJOR, MAX_MAJOR, root)
        )
        return 1
    name, version, proton = picked
    program, args = argv[0], argv[1:]
    if program == "--self-test":
        program, args = os.path.join(os.path.dirname(proton), SELF_TEST_EXE), ["/c", "echo", MARKER]
    data = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    env = proton_environment(data)
    print("hello-runner: using %s (%s)" % (name, version), flush=True)
    try:
        os.execve(proton, [proton, "waitforexitandrun", program] + args, env)
    except OSError as e:
        sys.stderr.write("hello-runner: cannot start %s: %s\n" % (proton, e))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
