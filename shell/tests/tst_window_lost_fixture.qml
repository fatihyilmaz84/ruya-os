import QtQuick
import QtTest
import RuyaShell

// Fixture for the WindowGuard (T-429): the window "loses activation" mid-test and does not get it
// back, so the running test must fail with TEST WINDOW LOST ACTIVATION. It is a red-by-design
// check, so a normal run skips it. To see the message:
//   $env:RUYA_ACTIVATION_FIXTURE = "1"; .\scripts\dev.ps1 qml tst_window_lost_fixture
Item {
    width: 400
    height: 300

    TestCase {
        name: "WindowLostFixture"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
        }

        function cleanup() {
            windowGuard.endSimulation()
        }

        function test_the_window_loses_activation_mid_test() {
            if (!windowGuard.fixtureEnabled)
                skip("fixture: set RUYA_ACTIVATION_FIXTURE=1 to run it (it fails by design)")
            windowGuard.simulateLoss()
            wait(2200)                      // longer than the guard's grace period
        }
    }
}
