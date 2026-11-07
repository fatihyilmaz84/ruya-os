import QtQuick
import QtTest
import RuyaShell

// T-203: the profile picker on a console with no keyboard or controller at all. It says how to
// pair one, keeps the pairing window open (and opens it again after a timeout, since nobody can
// press Retry), and stops when an input device exists. Against the mock backend; the mock is
// reset before every test.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "PickerPairing"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Bluetooth.mockReset()
            tryVerify(() => Bluetooth.inputKnown && Bluetooth.inputPresent && Bluetooth.controllerPairing === "idle")
            Profiles.lock()
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
        }

        function startShell() {
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has focus")
        }

        function hint() { return find("pickerControllerHint") }

        function test_no_hint_and_no_window_when_an_input_device_exists() {
            startShell()
            verify(!hint().visible, "no hint")
            compare(Bluetooth.mockPairingStarts(), 0)
            compare(Bluetooth.controllerPairing, "idle")
        }

        function test_hint_and_window_when_there_is_no_input_device() {
            Bluetooth.mockSetInputPresent(false)
            tryVerify(() => !Bluetooth.inputPresent)
            startShell()
            tryVerify(() => hint().visible, 2000, "the hint is shown")
            tryCompare(Bluetooth, "controllerPairing", "open")
            compare(Bluetooth.mockPairingStarts(), 1)
            verify(find("pickerControllerHintText").text.indexOf("Hold the pairing button") >= 0)
            verify(find("profileList").activeFocus, "the picker keeps focus")
        }

        function test_the_hint_goes_when_a_controller_pairs_and_the_pad_signs_in() {
            Bluetooth.mockSetInputPresent(false)
            Bluetooth.mockPairingScript("success")
            tryVerify(() => !Bluetooth.inputPresent)
            startShell()
            tryVerify(() => hint().visible, 2000)
            tryVerify(() => !hint().visible, 4000, "the hint is gone once a controller is there")
            tryCompare(Bluetooth, "controllerPairing", "idle", 2000, "the window is closed")
            verify(find("profileList").activeFocus, "the picker still has focus")
            keyClick(Qt.Key_Right)                         // Ada has no PIN
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
        }

        function test_a_timed_out_window_is_opened_again_but_only_three_times() {
            Bluetooth.mockSetInputPresent(false)
            Bluetooth.mockPairingScript("timeout")
            tryVerify(() => !Bluetooth.inputPresent)
            startShell()
            tryVerify(() => Bluetooth.mockPairingStarts() >= 3, 5000, "the window was opened again, twice")
            tryCompare(find("pickerControllerHintText"), "text", "Press A to start pairing.", 3000)
            compare(Bluetooth.controllerPairing, "timeout")
            // time for a fourth window, if one were going to open: every window lasts 300 ms here
            wait(1500)
            compare(Bluetooth.mockPairingStarts(), 3, "nothing opens by itself after the third")
            verify(hint().visible, "the prompt stays")
            // A starts a new series (and does not sign anyone in)
            keyClick(Qt.Key_Return)
            tryVerify(() => Bluetooth.mockPairingStarts() >= 4, 3000, "A opened a new window")
            tryVerify(() => Bluetooth.mockPairingStarts() === 6 && hint().exhausted, 5000, "again three windows, then the prompt")
            wait(1000)
            compare(Bluetooth.mockPairingStarts(), 6)
            compare(Profiles.activeProfile, "")
        }

        function test_the_text_names_the_dualsense_combination() {
            Bluetooth.mockSetInputPresent(false)
            tryVerify(() => !Bluetooth.inputPresent)
            startShell()
            tryVerify(() => hint().visible, 2000)
            verify(find("pickerControllerHintText").text.indexOf("PS + Create") >= 0)
            verify(find("pickerControllerHintText").text.indexOf("Hold the pairing button") >= 0, "and the generic words")
        }

        // T-260: with nobody able to press a button the picker lists the steps of every family.
        function test_the_steps_of_every_family_are_listed() {
            Bluetooth.mockSetInputPresent(false)
            tryVerify(() => !Bluetooth.inputPresent)
            startShell()
            tryVerify(() => hint().visible, 2000)
            verify(find("pickerControllerHintFamilies").visible)
            const expected = [
                ["playstation", "PlayStation controller. Hold PS and Create"],
                ["xbox", "Xbox controller. Press the pairing button on top until the Xbox logo flashes fast."],
                ["nintendo", "Nintendo controller. Press the small sync button"],
                ["8bitdo", "8BitDo controller. Hold Start with X"],
                ["other", "Other controller. Hold its pairing button"],
            ]
            for (const [family, words] of expected) {
                const row = find("pickerControllerHintFamily_" + family)
                verify(row !== null && row.visible, family + " has its steps")
                verify(findChild(row, "familyText").Accessible.name.startsWith(words), family + ": " + findChild(row, "familyText").Accessible.name)
            }
            verify(find("profileList").activeFocus, "the picker keeps focus")
        }

        // The hint, with the steps of every family, has to fit above the hint bar at the size a real
        // screen has (the picker's profiles move up to make room).
        function test_the_hint_and_the_family_steps_fit_on_the_screen() {
            startShell()
            tryVerify(() => find("profileList").y > 100, 2000, "laid out")
            compare(Math.round(find("profileList").anchors.verticalCenterOffset), 27, "the profiles rest below the middle with nothing to say")
            Bluetooth.mockSetInputPresent(false)
            tryVerify(() => hint().visible, 2000)
            tryVerify(() => find("pickerControllerHintFamily_other").visible)
            wait(500)
            compare(Math.round(find("profileList").anchors.verticalCenterOffset), -100, "the profiles move up to make room")
            const last = find("pickerControllerHintFamily_other")
            const bottom = last.mapToItem(tc.shell, 0, last.height).y
            const barTop = find("hintBar").mapToItem(tc.shell, 0, 0).y
            verify(bottom <= barTop, "the last family line (" + bottom + ") ends above the hint bar (" + barTop + ")")
            const list = find("profileList")
            verify(list.mapToItem(tc.shell, 0, list.height).y <= hint().mapToItem(tc.shell, 0, 0).y + 1,
                   "the profiles end where the hint starts")
        }

        function test_a_stops_answer_is_not_taken_for_the_starts() {
            Bluetooth.mockSetInputPresent(false)
            Bluetooth.mockPairingScript("wait")
            tryVerify(() => !Bluetooth.inputPresent)
            startShell()
            tryCompare(Bluetooth, "controllerPairing", "open")
            tryVerify(() => hint().armed)
            Bluetooth.setPowered(false)
            tryCompare(Bluetooth, "powered", false)
            // stop, then start again at once: the stop answers "ok", the start "unavailable"
            hint().stop()
            hint().start()
            tryCompare(hint(), "startStatus", "unavailable", 3000)
            verify(hint().failed, "the start's own answer decides")
            verify(!hint().armed)
        }

        function test_signing_in_closes_the_window() {
            Bluetooth.mockSetInputPresent(false)
            Bluetooth.mockPairingScript("wait")
            tryVerify(() => !Bluetooth.inputPresent)
            startShell()
            tryCompare(Bluetooth, "controllerPairing", "open")
            // (the test sends the keys a real pad would, though the mock says there is no input)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryCompare(Bluetooth, "controllerPairing", "idle", 2000, "no window outside the picker")
            verify(!hint().visible)
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Bluetooth.mockSetInputPresent(false)
            tryVerify(() => !Bluetooth.inputPresent)
            startShell()
            tryVerify(() => hint().visible, 2000)
            tryCompare(Bluetooth, "controllerPairing", "open")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/10b-picker-no-controller.png")
            DeviceSettings.language = "tr"
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/10c-picker-no-controller-tr.png")
            DeviceSettings.language = "en"
        }
    }
}
