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
    Component { id: cardComponent; ArtCard { itemId: "steam:620"; title: "Portal 2" } }
    SignalSpy { id: switchSpy; target: Profiles; signalName: "switchFinished" }
    SignalSpy { id: launchSpy; target: Library; signalName: "launchRequested" }

    TestCase {
        id: tc
        name: "Motion"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Theme.motionFactor = 1.0           // real time for the whole file: the duration tokens are the subject (T-463)
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
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
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
            verify(find("glassBlur").visible)
            openSettings()
            tryVerify(() => find("backdrop").drifting, 2000, "ambient drift runs by default where the blobs are seen")
        }

        // Settings from Home or the section nav with the controller keys. The drift is checked on a page:
        // on Home the hero's opaque field covers the blobs and they rest (T-421).
        function openSettings() {
            if (!find("sectionNav").activeFocus)
                keyClick(Qt.Key_Up)                    // the section nav
            tryVerify(() => find("sectionNav").activeFocus, 2000, "the section nav has focus")
            // Right to the gear, the last pill, and no further: Right from the gear goes on to the bell (RUY-413).
            for (let i = 0; i < 4 && find("sectionNav").currentIndex < 4; ++i)
                keyClick(Qt.Key_Right)
            tryCompare(find("sectionNav"), "currentIndex", 4)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("page_settings") !== null && find("page_settings").activeFocus, 2000, "Settings has focus")
        }

        function test_reduced_motion() {
            openSettings()
            tryVerify(() => find("backdrop").drifting, 2000, "the blobs drift on a page")
            DeviceSettings.reducedMotion = true
            compare(Theme.focusMs, 0)
            compare(Theme.pageMs, 0)
            compare(Theme.tintMs, 0)
            tryVerify(() => !find("backdrop").drifting, 2000, "backdrop animations stop")

            // Navigation still works and is not left half-way.
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("sectionNav").activeFocus, 2000)
            openSettings()
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("sectionNav").activeFocus, 2000)

            DeviceSettings.reducedMotion = false
            compare(Theme.focusMs, 140)
            openSettings()
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

        // Accept on a Recent card pulses it and starts the game; under reduced motion only the
        // launch remains.
        function test_recent_card_accept_pulses() {
            keyClick(Qt.Key_Down)
            tryVerify(() => find("recentRow").activeFocus, 2000, "Down goes to the Recent row")
            const card = find("recentRow").currentItem
            verify(card)
            const pulse = findChild(card, "pulseAnimation")
            verify(pulse, "the card has a pulse animation")
            const pulseSpy = createTemporaryObject(spyComponent, host, { target: pulse, signalName: "runningChanged" })
            verify(pulseSpy.valid)

            DeviceSettings.reducedMotion = true
            launchSpy.clear()
            keyClick(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
            wait(150)
            compare(pulseSpy.count, 0, "no pulse under reduced motion")

            // The launch splash holds the keys while the app starts: end it, so the card gets Accept again.
            tc.shell.endLaunch(true)
            tryVerify(() => find("recentRow").activeFocus, 2000, "the focus is back on the card")
            DeviceSettings.reducedMotion = false
            keyClick(Qt.Key_Return)
            tryCompare(launchSpy, "count", 2)
            tryVerify(() => pulseSpy.count > 0, 2000, "Accept pulses the card with motion on")
        }

        // The PIN-pad shake and the card pulse are feedback animations: they run normally and
        // do not run at all under reduced motion (the message/sound and the page change remain).
        function test_feedback_animations_respect_reduced_motion() {
            // Card pulse (a stand-alone ArtCard).
            const card = createTemporaryObject(cardComponent, host)
            verify(card)
            const pulse = findChild(card, "pulseAnimation")
            verify(pulse, "the card has a pulse animation")
            const pulseSpy = createTemporaryObject(spyComponent, host, { target: pulse, signalName: "runningChanged" })
            verify(pulseSpy.valid)

            DeviceSettings.reducedMotion = true
            card.pulse()
            wait(150)
            compare(pulseSpy.count, 0, "no pulse under reduced motion")
            verify(!pulse.running)

            DeviceSettings.reducedMotion = false
            card.pulse()
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
            openSettings()                             // where the blobs are seen (T-421)
            DeviceSettings.effectsQuality = "balanced"
            compare(Theme.blurMax, 32)
            verify(find("glassBlur").visible)
            tryVerify(() => find("backdrop").drifting, 2000, "balanced keeps ambient drift")

            DeviceSettings.effectsQuality = "performance"
            compare(Theme.blurMax, 0)
            verify(!find("glassBlur").visible, "performance hides the blur effect")
            tryVerify(() => !find("backdrop").drifting, 2000, "performance stops ambient drift")

            DeviceSettings.effectsQuality = "high"
            compare(Theme.blurMax, 64)
            verify(find("glassBlur").visible)
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
            const before = find("sectionNav").x
            compare(before, tc.shell.width * 0.05)
            DeviceSettings.overscan = 0.10
            verify(find("sectionNav").x > before, "header moves inward with more overscan")
            compare(find("sectionNav").x, tc.shell.width * 0.10)
            DeviceSettings.overscan = 0.0
            compare(find("sectionNav").x, 0)
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
