import QtQuick
import QtTest
import RuyaShell

// The systemd watchdog of the shell (RUY-483, 01 section 2): WATCHDOG=1 every WATCHDOG_USEC / 2 from
// the GUI thread. The interval rule through intervalFor; the start through startWith (the test hook
// with the values start() reads from the environment) and start() itself, which finds no
// WATCHDOG_USEC here. Off Linux nothing ever runs; on Linux (CI) a ping to a socket nobody listens on
// fails, and that is logged once, not once per tick.
Item {
    id: host
    width: 1280
    height: 720

    Component { id: watchdogComponent; SystemdWatchdog { } }

    TestCase {
        id: tc
        name: "SystemdWatchdog"
        when: windowShown

        property SystemdWatchdog wd: null

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            wd = createTemporaryObject(watchdogComponent, host)
            verify(wd !== null)
        }

        function test_interval_is_half_the_timeout() {
            compare(wd.intervalFor("30000000", "", 4242), 15000)
            compare(wd.intervalFor("5000000", "", 4242), 2500)
            compare(wd.intervalFor(" 200000 ", "", 4242), 100)
            // Below a millisecond it still runs, as often as a timer can.
            compare(wd.intervalFor("1000", "", 4242), 1)
        }

        function test_interval_off_without_a_timeout() {
            compare(wd.intervalFor("", "", 4242), 0, "unset")
            compare(wd.intervalFor("0", "", 4242), 0, "0")
            compare(wd.intervalFor("x", "", 4242), 0, "garbage")
            compare(wd.intervalFor("-30000000", "", 4242), 0, "negative")
            compare(wd.intervalFor("30s", "", 4242), 0, "not microseconds")
        }

        function test_interval_only_for_our_pid() {
            compare(wd.intervalFor("30000000", "4242", 4242), 15000, "WATCHDOG_PID is ours")
            compare(wd.intervalFor("30000000", "4243", 4242), 0, "WATCHDOG_PID of another process")
            compare(wd.intervalFor("30000000", "x", 4242), 0, "WATCHDOG_PID garbage")
        }

        function test_nothing_runs_without_watchdog_usec() {
            // The test process has no WATCHDOG_USEC (no systemd unit with WatchdogSec runs it).
            verify(!wd.start())
            verify(!wd.active)
            compare(wd.intervalMs, 0)
            compare(wd.pings, 0)
            verify(!wd.startWith("", "", "@ruya-test-watchdog"))
            verify(!wd.active)
            verify(!wd.startWith("0", "", "@ruya-test-watchdog"))
            verify(!wd.active)
            compare(wd.pings, 0)
        }

        function test_nothing_runs_without_a_socket() {
            verify(!wd.startWith("200000", "", ""))
            verify(!wd.active)
            compare(wd.pings, 0)
        }

        // Off Linux nothing runs even with a timeout and a socket; on Linux (CI) it pings at once,
        // then on the timer.
        function test_start_runs_only_on_linux() {
            if (!wd.supported) {
                verify(!wd.startWith("200000", "", "@ruya-test-watchdog"))
                verify(!wd.active)
                compare(wd.intervalMs, 0)
                compare(wd.pings, 0)
                return
            }
            // Nobody listens on this abstract name: every send fails, and only the first warns.
            ignoreWarning(/systemd watchdog: WATCHDOG=1 not sent/)
            failOnWarning(/systemd watchdog: WATCHDOG=1 not sent/)
            verify(wd.startWith("200000", "", "@ruya-test-watchdog-" + Date.now()))
            verify(wd.active)
            compare(wd.intervalMs, 100)
            compare(wd.pings, 1, "the first ping goes at once")
            tryVerify(() => wd.pings >= 3, 2000)
            compare(wd.failedPings, wd.pings)
            wd.stop()
            verify(!wd.active)
            compare(wd.intervalMs, 0)
        }
    }
}
