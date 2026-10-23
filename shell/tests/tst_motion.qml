import QtQuick
import QtTest
import RuyaShell

// Device display settings: reduced motion, effects quality tiers, overscan. Signs in as
// "Ada" (p2, no PIN) with controller keys. DeviceSettings is in-memory under test
// (RUYA_SETTINGS_EPHEMERAL=1) and restored to defaults after every test.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    Component { id: spyComponent; SignalSpy {} }
    SignalSpy { id: switchSpy; target: Profiles; signalName: "switchFinished" }

    TestCase {
        id: tc
        name: "Motion"
        when: windowShown

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("tiles").activeFocus, 2000, "home shelf takes focus after sign-in")
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.overscan = 0.05
        }

        function test_defaults() {
            compare(DeviceSettings.reducedMotion, false)
            compare(DeviceSettings.effectsQuality, "high")
            compare(DeviceSettings.overscan, 0.05)
            compare(Theme.focusMs, 140)
            compare(Theme.pageMs, 300)
            compare(Theme.tintMs, 700)
            compare(Theme.blurMax, 64)
            verify(find("backdrop").drifting, "ambient drift runs by default")
            verify(find("shelfBlur").visible)
        }

        function test_reduced_motion() {
            DeviceSettings.reducedMotion = true
            compare(Theme.focusMs, 0)
            compare(Theme.pageMs, 0)
            compare(Theme.tintMs, 0)
            tryVerify(() => !find("backdrop").drifting, 2000, "backdrop animations stop")

            // Navigation still works and is not left half-way.
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("page_settings") !== null && find("page_settings").activeFocus, 2000)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("tiles").activeFocus, 2000)

            DeviceSettings.reducedMotion = false
            compare(Theme.focusMs, 140)
            tryVerify(() => find("backdrop").drifting, 2000, "drift resumes")
        }

        // Types a wrong PIN on the open PIN pad and waits for the service's answer.
        function submitWrongPin(pad) {
            const before = switchSpy.count
            for (const d of "0000")
                keyClick(d)
            keyClick(Qt.Key_Enter)
            tryCompare(switchSpy, "count", before + 1)
            tryVerify(() => pad.message.indexOf("attempt") >= 0, 2000, "the error message is shown")
        }

        // The PIN-pad shake and the tile pulse are feedback animations: they run normally and
        // do not run at all under reduced motion (the message/sound and the page change remain).
        function test_feedback_animations_respect_reduced_motion() {
            // Tile pulse (home shelf is showing, Ada is signed in).
            const tile = find("tiles").currentItem
            const pulse = findChild(tile, "pulseAnimation")
            verify(pulse, "the tile has a pulse animation")
            const pulseSpy = createTemporaryObject(spyComponent, host, { target: pulse, signalName: "runningChanged" })
            verify(pulseSpy.valid)

            DeviceSettings.reducedMotion = true
            tile.pulse()
            wait(150)
            compare(pulseSpy.count, 0, "no pulse under reduced motion")
            verify(!pulse.running)

            DeviceSettings.reducedMotion = false
            tile.pulse()
            tryVerify(() => pulseSpy.count > 0, 2000, "the pulse runs with motion on")

            // PIN-pad shake: wrong PIN for Player One (p1, PIN 1234; 2 of the 5 free attempts).
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => find("profilePicker").enabled)
            const pad = find("pinPad")
            const shake = findChild(pad, "pinShake")
            verify(shake, "the PIN pad has a shake animation")
            const shakeSpy = createTemporaryObject(spyComponent, host, { target: shake, signalName: "runningChanged" })
            verify(shakeSpy.valid)
            pad.open(Profiles.profiles[0])
            tryVerify(() => pad.shown)

            DeviceSettings.reducedMotion = true
            submitWrongPin(pad)
            wait(150)
            compare(shakeSpy.count, 0, "no shake under reduced motion")
            verify(!shake.running)

            DeviceSettings.reducedMotion = false
            submitWrongPin(pad)
            tryVerify(() => shakeSpy.count > 0, 2000, "the shake runs with motion on")
        }

        function test_quality_tiers() {
            DeviceSettings.effectsQuality = "balanced"
            compare(Theme.blurMax, 32)
            verify(find("shelfBlur").visible)
            verify(find("backdrop").drifting, "balanced keeps ambient drift")

            DeviceSettings.effectsQuality = "performance"
            compare(Theme.blurMax, 0)
            verify(!find("shelfBlur").visible, "performance hides the blur effect")
            tryVerify(() => !find("backdrop").drifting, 2000, "performance stops ambient drift")

            DeviceSettings.effectsQuality = "high"
            compare(Theme.blurMax, 64)
            verify(find("shelfBlur").visible)
        }

        function test_invalid_values_rejected() {
            ignoreWarning(/rejecting invalid effectsQuality/)
            DeviceSettings.effectsQuality = "ultra"
            compare(DeviceSettings.effectsQuality, "high")

            ignoreWarning(/rejecting out-of-range overscan/)
            DeviceSettings.overscan = 0.5
            compare(DeviceSettings.overscan, 0.05)
            ignoreWarning(/rejecting out-of-range overscan/)
            DeviceSettings.overscan = -0.01
            compare(DeviceSettings.overscan, 0.05)

            // The limits themselves are valid.
            DeviceSettings.overscan = 0.0
            compare(DeviceSettings.overscan, 0.0)
            DeviceSettings.overscan = 0.10
            compare(DeviceSettings.overscan, 0.10)
        }

        function test_overscan_moves_header() {
            const before = find("brand").x
            compare(before, tc.shell.width * 0.05)
            DeviceSettings.overscan = 0.10
            verify(find("brand").x > before, "header moves inward with more overscan")
            compare(find("brand").x, tc.shell.width * 0.10)
            DeviceSettings.overscan = 0.0
            compare(find("brand").x, 0)
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.effectsQuality = "performance"
            DeviceSettings.reducedMotion = true
            wait(500)   // lets the sign-in fade (started at the old duration) finish
            grabImage(tc.shell).save(shotsDir + "/6-performance-tier.png")
        }
    }
}
