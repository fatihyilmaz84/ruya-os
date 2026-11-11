import QtQuick
import QtTest
import RuyaShell

// The test motion scale (T-463): every test starts with a short Theme.motionFactor, set by
// windowGuard.ensureActive() in init(), so offscreen tests do not wait for full-length fades. A test
// whose subject is a duration sets 1.0 itself (shell/CLAUDE.md, Tests). Skipped under `shots`, which
// renders at full motion and runs only the functions that save a screenshot.
Item {
    width: 200
    height: 200

    TestCase {
        name: "TestMotion"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
        }

        function cleanup() {
            Theme.motionFactor = 1.0       // as several test files do after a test
        }

        // Functions run in alphabetical order: a_ changes the factor, b_ must find it put back.
        function test_a_a_test_starts_with_the_short_scale_and_may_change_it() {
            compare(Theme.motionFactor, windowGuard.testMotion, "the scale is set before the test body")
            if (windowGuard.testMotion === 0.1) {
                compare(Theme.pageMs, 30, "a page fade is a tenth of 300 ms")
                compare(Theme.glideMs, 28)
            }
            Theme.motionFactor = 1.0
            compare(Theme.pageMs, 300, "a test can ask for real time")
        }

        function test_b_the_scale_is_put_back_for_the_next_test() {
            compare(Theme.motionFactor, windowGuard.testMotion, "the cleanup of the test before set 1.0; init() put it back")
            verify(windowGuard.testMotion < 1 || windowGuard.testMotion === Theme.motionFactor)
        }
    }
}
