#!/usr/bin/env python3
"""ruya-inputd's relay latency on the Dell (RUY-842), run as root there by scripts/dell-perf-bench.sh
next to vm-input-probe.py and vm_uinput_trust.py:

  python3 dell-perf-latency.py <profile> <presses> <control dir>

The Dell has no pad plugged in, so the "physical" pad is a uinput gamepad root vouches for (the probe's
FakePad, RUY-1063; an image from before it has no trust directory and takes every uinput device as
hardware). It is seated as <profile>'s player 1 (JoinPlayer) and held, printing "ready" (or
"skipped=<reason>"): a seated player whose pad is gone makes the shell open the Hub over a game, so the
bench keeps the pad plugged in for the whole run. With a pad plugged in the Hub is open over a game that
starts (the route is `overlay`): when the file <control dir>/front appears (the game was just started) the
script waits for the route `app` or `overlay`, taps the pad's Back button until it is `app` (up to three
times) and prints
"front <route>". When <control dir>/go appears (the route is `app` and ruya-inputd makes the virtual
pad, phys ruya-input/pad1) one button is
pressed and released <presses> times (0: none) and both nodes are read: the latency of a press is the
kernel timestamp of the event on the virtual pad minus the timestamp of the same event on the physical
pad (both stamps come from the same clock, taken as each event enters its evdev node). Prints
"relay_p50_ms=<> relay_p99_ms=<> relay_n=<count>" or "skipped=<reason>". <control dir>/stop ends it
without measuring; with neither file after 15 minutes it ends by itself."""
import importlib.util
import os
import select
import statistics
import sys
import time

sys.dont_write_bytecode = True
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("vm_input_probe", os.path.join(here, "vm-input-probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

BUTTON = probe.BTN_TL      # a shoulder button: the shell and a menu do nothing with it
VIRTUAL_PHYS = "ruya-input/pad1"


def read_keys(fd):
    """The (timestamp s, value) of every button event of BUTTON waiting on the node."""
    out = []
    while True:
        try:
            data = os.read(fd, probe.EVENT.size * 64)
        except BlockingIOError:
            return out
        for i in range(0, len(data) - probe.EVENT.size + 1, probe.EVENT.size):
            sec, usec, t, c, v = probe.EVENT.unpack_from(data, i)
            if t == probe.EV_KEY and c == BUTTON:
                out.append((sec + usec / 1e6, v))


def percentile(sorted_values, p):
    return sorted_values[min(len(sorted_values) - 1, max(0, -(-len(sorted_values) * p // 100) - 1))]


def measure(pad, phys, presses):
    """The relay latencies of `presses` presses (two events each) as sorted ms, or a skip reason."""
    virtual = probe.wait_for(lambda: probe.node_by("phys", VIRTUAL_PHYS)[0], 5)
    if not virtual:
        return "no_virtual_pad_(no_game_in_front,_so_the_route_is_not_app)"
    fds = [os.open(n, os.O_RDONLY | os.O_NONBLOCK) for n in (phys, virtual)]
    got = ([], [])
    try:
        read_keys(fds[0]), read_keys(fds[1])
        for _ in range(presses):
            for value in (1, 0):
                pad.emit(probe.EV_KEY, BUTTON, value)
                time.sleep(0.05)
                for fd, sink in zip(fds, got):
                    sink.extend(read_keys(fd))
        time.sleep(0.2)
        for fd, sink in zip(fds, got):
            sink.extend(read_keys(fd))
    finally:
        for fd in fds:
            os.close(fd)
    sent, relayed = got
    if len(sent) != 2 * presses or len(relayed) != len(sent):
        return f"the_virtual_pad_gave_{len(relayed)}_button_events_for_{len(sent)}_sent"
    return sorted((b[0] - a[0]) * 1000 for a, b in zip(sent, relayed))


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    profile, presses, control = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    # An image before RUY-1063 has no trust directory and takes every uinput device as hardware.
    pad = probe.FakePad(trusted=os.path.isdir(probe.trusted_uinput().TRUSTED_DIR))
    bus = probe.Bus()
    try:
        phys = probe.wait_for(lambda: probe.node_by("phys", probe.PHYS)[0], 3)
        status, _ = probe.join_by_name(bus, probe.NAME, profile)
        if not phys or status != "ok":
            print(f"skipped=the_test_pad_could_not_be_seated_({status})", flush=True)
            return
        print("ready", flush=True)
        def asked(*names):
            return probe.wait_for(lambda: any(os.path.exists(os.path.join(control, n)) for n in names), 900, step=0.2)
        if asked("front", "stop") and os.path.exists(os.path.join(control, "front")):
            probe.wait_for(lambda: probe.route_prop() in ("app", "overlay"), 30)
            for _ in range(3):
                if probe.route_prop() == "app":
                    break
                pad.emit(probe.EV_KEY, probe.BTN_EAST, 1)
                time.sleep(0.1)
                pad.emit(probe.EV_KEY, probe.BTN_EAST, 0)
                probe.wait_for(lambda: probe.route_prop() == "app", 4)
            print(f"front {probe.route_prop()}", flush=True)
        asked("go", "stop")
        if presses == 0 or not os.path.exists(os.path.join(control, "go")):
            return
        lat = measure(pad, phys, presses)
        if isinstance(lat, str):
            print(f"skipped={lat}", flush=True)
        else:
            print(f"relay_p50_ms={statistics.median(lat):.3f} relay_p99_ms={percentile(lat, 99):.3f} relay_n={len(lat)}", flush=True)
    finally:
        bus.close()
        pad.close()


if __name__ == "__main__":
    main()
