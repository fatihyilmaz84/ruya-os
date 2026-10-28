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

        function test_space_shape() {
            compare(Theme.spaceXxs, 4)
            compare(Theme.spaceXs, 8)
            compare(Theme.spaceS, 16)
            compare(Theme.spaceM, 24)
            compare(Theme.spaceL, 36)
            compare(Theme.spaceXl, 48)
            compare(Theme.spaceXxl, 64)
            compare(Theme.spaceXxxl, 96)
            compare(Theme.radiusS, 12)
            compare(Theme.radiusM, 18)
            compare(Theme.radiusL, 32)
            compare(Theme.rowHeight, 84)
            compare(Theme.buttonHeight, 76)
            compare(Theme.tileWidth, 400)
            compare(Theme.tileHeight, 260)
            compare(Theme.avatarSize, 200)
            compare(Theme.focusRingWidth, 4)
            compare(Theme.focusRingOffset, 7)
            compare(Theme.badgeFillAlpha, 0.18)
        }
    }
}
