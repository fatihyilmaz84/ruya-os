import QtQuick
import QtTest
import RuyaShell

// Design tokens (04 §3). DeviceSettings is in-memory under test and restored after each test.
Item {
    width: 400
    height: 300

    TestCase {
        name: "Theme"
        when: windowShown

        function cleanup() { DeviceSettings.reducedMotion = false }

        function test_type_scale() {
            compare(Theme.typeHero, 96)
            compare(Theme.typeDisplay, 64)
            compare(Theme.typeTitle, 48)
            compare(Theme.typeHeadline, 34)
            compare(Theme.typeBody, 30)
            compare(Theme.typeCaption, 24)
            compare(Theme.typeMicro, 20)
            DeviceSettings.reducedMotion = false
            compare(Theme.overlayMs, 200)
            DeviceSettings.reducedMotion = true
            compare(Theme.overlayMs, 0)
        }
    }
}
