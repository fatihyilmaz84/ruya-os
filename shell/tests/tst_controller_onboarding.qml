import QtQuick
import QtTest
import RuyaShell

// T-260: controller onboarding. The "connected" and "disconnected" toasts (ControllerToasts) with
// their debounce, and the guided pairing screen (ControllerOnboarding): the steps per family, the
// list of controllers found while the pairing window is open, one press of A to pair, the failure
// and its retry, and the try-a-button screen. Driven with the controller's keys only. Against the
// mock; the mock is reset before every test.
Item {
    id: host
    width: 1280
    height: 720

    Item { id: opener; objectName: "opener"; focus: true }

    ControllerToasts {
        id: toasts
        debounceMs: 40
    }

    ControllerOnboarding {
        id: onb
        objectName: "onboarding"
        anchors.fill: parent
        u: 720 / 1080
    }

    TestCase {
        id: tc
        name: "ControllerOnboarding"
        when: windowShown

        function find(name) { return findChild(host, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.language = "en"
            Bluetooth.mockReset()
            tryVerify(() => Bluetooth.powered && Bluetooth.devices.length === 3)
            onb.close()
            clearToasts()
            toasts.waiting = []
            toasts.shown = ({})
            toasts.connectedShown = 0
            toasts.disconnectedShown = 0
            opener.forceActiveFocus()
        }

        function cleanup() {
            onb.close()
            clearToasts()
        }

        function clearToasts() {
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text + (Notifications.model.get(i).detail !== "" ? " | " + Notifications.model.get(i).detail : ""))
            return out
        }

        function usb(connected, id, name, family) {
            Bluetooth.mockGamepad(connected, id, name, family ?? "", "usb")
        }

        // ---- the toasts ----

        function test_a_pad_that_appears_is_announced_once_with_its_glyph_and_battery() {
            usb(true, "usb-1", "Wireless Controller", "playstation")
            tryCompare(Notifications.model, "count", 1)
            compare(Notifications.model.get(0).text, "PlayStation controller connected")
            compare(Notifications.model.get(0).detail, "Battery 60% · USB")
            compare(Notifications.model.get(0).iconName, "pad_dualsense")
            compare(Notifications.model.get(0).kind, "success")
            usb(true, "usb-1", "Wireless Controller", "playstation")      // the same connection again
            wait(150)
            compare(Notifications.model.count, 1, "once per connection")
            compare(toasts.connectedShown, 1)
        }

        function test_a_pad_of_no_known_family_is_named_by_the_system() {
            usb(true, "usb-2", "Generic USB Joystick", "")
            tryCompare(Notifications.model, "count", 1)
            compare(Notifications.model.get(0).text, "Generic USB Joystick connected")
            compare(Notifications.model.get(0).detail, "Battery 60% · USB")
            compare(Notifications.model.get(0).iconName, "sports_esports")
        }

        function test_a_paired_pad_is_named_as_the_user_named_it_and_has_its_own_battery() {
            Bluetooth.mockPopulate()
            tryVerify(() => Bluetooth.devices.find(d => d.id === "bt-gallery-ps") !== undefined)
            Bluetooth.mockSetBattery("bt-gallery-ps", 55)
            tryVerify(() => Bluetooth.devices.find(d => d.id === "bt-gallery-ps").battery === 55)
            Bluetooth.mockGamepad(true, "bt-gallery-ps", "Wireless Controller", "playstation", "bluetooth")
            tryCompare(Notifications.model, "count", 1)
            compare(Notifications.model.get(0).text, "DualSense connected")
            compare(Notifications.model.get(0).detail, "Battery 55% · Bluetooth")
        }

        function test_a_flapping_cable_says_nothing() {
            usb(true, "usb-1", "Wireless Controller", "playstation")
            usb(false, "usb-1", "Wireless Controller", "playstation")      // gone before it was announced
            tryVerify(() => toasts.waiting.length === 0, 2000, "nothing is waiting any more")
            wait(150)
            compare(Notifications.model.count, 0, "it never connected as far as the user can tell")
            // Announced, then a flap: no "disconnected", no second "connected".
            usb(true, "usb-1", "Wireless Controller", "playstation")
            tryCompare(Notifications.model, "count", 1)
            toasts.noteInput()
            usb(false, "usb-1", "Wireless Controller", "playstation")
            usb(true, "usb-1", "Wireless Controller", "playstation")
            wait(150)
            compare(Notifications.model.count, 1, "the flap was quiet")
            compare(toasts.disconnectedShown, 0)
        }

        function test_a_pad_that_was_in_use_says_goodbye() {
            usb(true, "usb-1", "Wireless Controller", "playstation")
            tryCompare(toasts, "connectedShown", 1)
            toasts.noteInput()                                              // somebody pressed a key
            usb(false, "usb-1", "Wireless Controller", "playstation")
            tryCompare(toasts, "disconnectedShown", 1)
            compare(toastTexts()[1], "PlayStation controller disconnected")
            compare(Notifications.model.get(1).iconName, "pad_dualsense")
        }

        function test_a_pad_that_was_not_in_use_leaves_quietly() {
            usb(true, "usb-1", "Wireless Controller", "playstation")
            tryCompare(toasts, "connectedShown", 1)
            usb(false, "usb-1", "Wireless Controller", "playstation")
            tryVerify(() => !("usb-1" in toasts.shown), 2000, "it is forgotten")
            wait(150)
            compare(toasts.disconnectedShown, 0)
            compare(Notifications.model.count, 1)
            // and the next plug-in is announced again
            usb(true, "usb-1", "Wireless Controller", "playstation")
            tryCompare(toasts, "connectedShown", 2)
        }

        function test_the_last_input_device_leaving_is_always_said() {
            usb(true, "usb-1", "Wireless Controller", "playstation")
            tryCompare(toasts, "connectedShown", 1)
            Bluetooth.mockSetInputPresent(false)
            tryVerify(() => !Bluetooth.inputPresent)
            usb(false, "usb-1", "Wireless Controller", "playstation")
            tryCompare(toasts, "disconnectedShown", 1)
        }

        function test_keyboards_and_mice_say_nothing() {
            Bluetooth.mockPopulate()                                        // a keyboard and a mouse are connected now
            tryVerify(() => Bluetooth.devices.find(d => d.id === "bt-gallery-keyboard") !== undefined)
            wait(150)
            compare(Notifications.model.count, 0, "no toast for a keyboard or a mouse")
            usb(true, "usb-1", "Wireless Controller", "playstation")        // the pad after them is still announced
            tryCompare(Notifications.model, "count", 1)
            compare(toasts.connectedShown, 1)
        }

        function test_a_service_that_restarted_forgets_the_pads_it_announced() {
            usb(true, "usb-1", "Wireless Controller", "playstation")
            tryCompare(toasts, "connectedShown", 1)
            Bluetooth.mockServiceRestart()
            tryVerify(() => !("usb-1" in toasts.shown), 2000, "forgotten")
            toasts.noteInput()
            usb(false, "usb-1", "Wireless Controller", "playstation")
            wait(150)
            compare(toasts.disconnectedShown, 0, "a pad nobody was told about leaves quietly")
        }

        // ---- two pads of one model (T-334) ----

        readonly property string padA: "AA:00:00:00:00:04"
        readonly property string padB: "AA:00:00:00:00:05"

        function twoPads() {
            Bluetooth.mockTwoPads()
            tryVerify(() => Bluetooth.devices.find(d => d.id === tc.padA) !== undefined
                      && Bluetooth.devices.find(d => d.id === tc.padB) !== undefined, 2000, "both pads are listed")
        }

        function bt(connected, id) {
            Bluetooth.mockGamepad(connected, id, "Wireless Controller", "playstation", "bluetooth")
        }

        function test_two_connect_toasts() {
            twoPads()
            bt(true, tc.padA)
            bt(true, tc.padB)
            tryCompare(Notifications.model, "count", 2)
            tryCompare(toasts, "connectedShown", 2)
            // Two toasts, each with its own pad's name and battery: the same name would not tell
            // which one arrived.
            const texts = toastTexts()
            verify(texts.includes("Wireless Controller (00:04) connected | Battery 80% · Bluetooth"), texts.join(" | "))
            verify(texts.includes("Wireless Controller (00:05) connected | Battery 55% · Bluetooth"), texts.join(" | "))
            compare(Notifications.model.get(0).iconName, "pad_dualsense")
            compare(Notifications.model.get(1).iconName, "pad_dualsense")
            // The same connections again say nothing new.
            bt(true, tc.padA)
            bt(true, tc.padB)
            wait(150)
            compare(Notifications.model.count, 2, "once per connection")
        }

        function test_disconnect_toast_names_its_pad() {
            twoPads()
            bt(true, tc.padA)
            bt(true, tc.padB)
            tryCompare(toasts, "connectedShown", 2)
            clearToasts()
            toasts.noteInput()                                              // somebody pressed a key
            bt(false, tc.padB)
            tryCompare(toasts, "disconnectedShown", 1)
            compare(toastTexts(), ["Wireless Controller (00:05) disconnected"], "the pad that left, not the other")
            verify(tc.padA in toasts.shown, "pad A is still known as connected")
            verify(!(tc.padB in toasts.shown))
            // Then the other one.
            clearToasts()
            bt(false, tc.padA)
            tryCompare(toasts, "disconnectedShown", 2)
            compare(toastTexts(), ["Wireless Controller (00:04) disconnected"])
        }

        function test_a_pad_alone_keeps_its_plain_name() {
            twoPads()
            Bluetooth.mockSetName(tc.padB, "Ada's pad")
            tryVerify(() => Bluetooth.devices.find(d => d.id === tc.padB).name === "Ada's pad")
            bt(true, tc.padA)
            tryCompare(Notifications.model, "count", 1)
            compare(Notifications.model.get(0).text, "Wireless Controller connected", "no twin, no suffix")
            compare(Notifications.model.get(0).detail, "Battery 80% · Bluetooth")
        }

        // ---- the guided pairing screen ----

        function chip(family) { return find("onbChip_" + family) }

        function test_the_screen_opens_a_window_and_shows_the_steps_of_a_family() {
            Bluetooth.mockPairingScript("wait")
            opener.forceActiveFocus()
            onb.open()
            tryVerify(() => onb.shown)
            tryCompare(Bluetooth, "controllerPairing", "open")
            compare(Bluetooth.mockPairingStarts(), 1)
            verify(chip("playstation").activeFocus, "focus starts on the first family")
            verify(find("onboardingSteps").text.indexOf("Hold PS and Create") >= 0)
            keyClick(Qt.Key_Right)
            verify(chip("xbox").activeFocus)
            compare(find("onboardingSteps").text, "Press the pairing button on top until the Xbox logo flashes fast.")
            keyClick(Qt.Key_Right)
            verify(chip("nintendo").activeFocus)
            keyClick(Qt.Key_Right)
            verify(chip("8bitdo").activeFocus)
            verify(find("onboardingSteps").text.indexOf("Hold Start with X") >= 0)
            keyClick(Qt.Key_Right)
            verify(chip("other").activeFocus)
            compare(find("onboardingSteps").text, "Hold its pairing button until the light blinks. Pick the Bluetooth mode if it has several.")
            keyClick(Qt.Key_Right)
            verify(chip("other").activeFocus, "the row stops at its end")
            keyClick(Qt.Key_Left)
            verify(chip("8bitdo").activeFocus)
            compare(chip("8bitdo").Accessible.name, "8BitDo controller")
            compare(onb.modalHints.length, 2)
        }

        // RUY-154: the sync-button guidance for an Xbox 360 pad with its wireless receiver shows
        // with the Xbox steps only, and follows the language.
        function test_the_xbox_360_receiver_guidance_shows_with_the_xbox_steps() {
            onb.open()
            tryVerify(() => onb.shown)
            tryCompare(onb, "opacity", 1)
            verify(chip("playstation").activeFocus)
            verify(find("onboardingSteps").visible)
            verify(!find("onboardingReceiverSteps").visible, "not under the PlayStation steps")
            keyClick(Qt.Key_Right)
            verify(chip("xbox").activeFocus)
            compare(onb.family, "xbox")
            verify(find("onboardingReceiverSteps").visible)
            compare(find("onboardingReceiverSteps").text, "Xbox 360 pad with a wireless receiver: press the sync button on the receiver, then on the controller.")
            keyClick(Qt.Key_Right)
            verify(chip("nintendo").activeFocus)
            verify(!find("onboardingReceiverSteps").visible)
            keyClick(Qt.Key_Left)
            DeviceSettings.language = "tr"
            compare(find("onboardingReceiverSteps").text, "Kablosuz alıcılı Xbox 360 kontrolcüsü: önce alıcıdaki, sonra kontrolcüdeki eşleştirme düğmesine basın.")
        }

        // RUY-154: two Xbox 360 pads behind one receiver are announced one by one under the
        // driver's plain name; unplugging the receiver removes both, and the receiver itself is
        // never announced (the service sends one event per pad and none for the dongle).
        function test_pads_behind_an_xbox_360_receiver_come_and_go_without_a_receiver_toast() {
            usb(true, "usb-1/input0", "Xbox 360 Controller", "xbox")
            usb(true, "usb-1/input2", "Xbox 360 Controller", "xbox")
            tryCompare(toasts, "connectedShown", 2)
            const texts = toastTexts()
            compare(texts.length, 2)
            for (const t of texts) {
                verify(t.indexOf("Xbox 360 Controller") >= 0 || t.indexOf("Xbox controller") >= 0, t)
                // RUY-412 split the toast into title + detail ("... connected | Battery 60% · USB").
                verify(t.indexOf("connected") >= 0 && t.toLowerCase().indexOf("battery 60%") >= 0, t)
                verify(t.toLowerCase().indexOf("receiver") < 0, "no toast for the receiver: " + t)
            }
            compare(Notifications.model.get(0).iconName, "pad_xbox_series")
            clearToasts()
            toasts.noteInput()
            usb(false, "usb-1/input2", "Xbox 360 Controller", "xbox")
            tryCompare(toasts, "disconnectedShown", 1)
            verify("usb-1/input0" in toasts.shown, "the other pad stays known")
            // The receiver unplugged: the last pad goes, one toast, not a toast per dongle.
            clearToasts()
            usb(false, "usb-1/input0", "Xbox 360 Controller", "xbox")
            tryCompare(toasts, "disconnectedShown", 2)
            compare(toastTexts().length, 1)
            verify(!("usb-1/input0" in toasts.shown) && !("usb-1/input2" in toasts.shown), "no stale pads")
        }

        function test_B_closes_the_screen_and_the_window_and_gives_the_focus_back() {
            Bluetooth.mockPairingScript("wait")
            opener.forceActiveFocus()
            onb.open()
            tryCompare(Bluetooth, "controllerPairing", "open")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !onb.shown, 2000)
            tryCompare(Bluetooth, "controllerPairing", "idle")
            tryVerify(() => opener.activeFocus, 2000, "focus is back where it was")
        }

        function test_controllers_that_were_paired_before_are_not_listed() {
            onb.open()
            compare(onb.rowCount, 0)
            compare(find("onboardingFoundTitle").text, "Nothing found yet")
            verify(find("onbRow_bt-pad-main") === null)
        }

        // T-359: two pads of one make that turn up while the screen is open: the end of the address tells
        // the rows apart, as it does in Settings. A pad alone keeps its plain name.
        function test_found_nearby_tells_like_pads_apart() {
            Bluetooth.mockPairingScript("wait")
            opener.forceActiveFocus()
            onb.open()
            compare(onb.rowCount, 0)
            Bluetooth.mockTwoPads()
            tryVerify(() => find("onbRow_" + tc.padA) !== null && find("onbRow_" + tc.padB) !== null, 2000, "a row for each pad")
            compare(find("onboardingFoundTitle").text, "Found nearby")
            compare(find("onbRowName_" + tc.padA).text, "Wireless Controller (00:04)")
            compare(find("onbRowName_" + tc.padB).text, "Wireless Controller (00:05)")
            verify(find("onbRow_" + tc.padA).Accessible.name.indexOf("Wireless Controller (00:04),") === 0, find("onbRow_" + tc.padA).Accessible.name)
            verify(find("onbRow_" + tc.padB).Accessible.name.indexOf("Wireless Controller (00:05),") === 0, find("onbRow_" + tc.padB).Accessible.name)
            keyClick(Qt.Key_Down)
            verify(find("onbRow_" + tc.padA).activeFocus, "Down enters the list")
            // One of them is renamed: it has a name of its own, the other no twin any more.
            Bluetooth.mockSetName(tc.padB, "Ada's pad")
            tryCompare(find("onbRowName_" + tc.padB), "text", "Ada's pad")
            tryCompare(find("onbRowName_" + tc.padA), "text", "Wireless Controller")
            verify(find("onbRow_" + tc.padA).activeFocus, "focus stayed on the row")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !onb.shown, 2000, "Back leaves the screen")
            tryVerify(() => opener.activeFocus, 2000, "focus is back where it was")
        }

        // T-359: a too long name is cut before the end of the address, which stays whole.
        function test_found_nearby_cuts_a_long_name_before_its_address() {
            Bluetooth.mockPairingScript("wait")
            onb.open()
            Bluetooth.mockTwoPads()
            const wide = "W".repeat(48)
            Bluetooth.mockSetName(tc.padA, wide)
            Bluetooth.mockSetName(tc.padB, wide)
            tryVerify(() => find("onbRowName_" + tc.padB) !== null && find("onbRowName_" + tc.padB).name === wide, 2000)
            const name = find("onbRowName_" + tc.padB)
            verify(name.text.endsWith(" (00:05)"), "the tail is whole: " + name.text)
            verify(name.text.indexOf("\u2026") > 0, "the name is cut: " + name.text)
            verify(name.paintedWidth <= name.width + 0.5, "one line: " + name.paintedWidth + " > " + name.width)
            verify(name.width <= find("onbRow_" + tc.padB).width * 0.4 + 0.5)
            verify(find("onbRow_" + tc.padB).Accessible.name.indexOf(wide + " (00:05),") === 0, "the whole name is the accessible one")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !onb.shown, 2000, "Back leaves the screen")
        }

        function test_found_controllers_appear_in_place_and_focus_stays() {
            Bluetooth.mockPairingScript("wait")
            onb.open()
            Bluetooth.mockReveal("bt-flaky")
            tryVerify(() => find("onbRow_bt-flaky") !== null, 2000)
            compare(find("onboardingFoundTitle").text, "Found nearby")
            keyClick(Qt.Key_Down)
            verify(find("onbRow_bt-flaky").activeFocus, "Down enters the list")
            compare(find("onbRowState_bt-flaky").text, "A: pair")
            Bluetooth.mockReveal("bt-pad-new")                               // another one is found
            tryVerify(() => find("onbRow_bt-pad-new") !== null, 2000)
            verify(find("onbRow_bt-flaky").activeFocus, "focus stayed on the row")
            keyClick(Qt.Key_Down)
            verify(find("onbRow_bt-pad-new").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("onbRow_bt-pad-new").activeFocus, "the list ends there")
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Up)
            verify(chip("playstation").activeFocus, "Up from the first row is the family row again")
            // A headset is not a controller and is never offered.
            Bluetooth.mockReveal("bt-buds")
            wait(100)
            verify(find("onbRow_bt-buds") === null)
        }

        function test_one_press_pairs_a_found_controller() {
            Bluetooth.mockPairingScript("wait")
            onb.open()
            Bluetooth.mockReveal("bt-pad-new")
            tryVerify(() => find("onbRow_bt-pad-new") !== null, 2000)
            keyClick(Qt.Key_Down)
            Bluetooth.mockHoldPairing(true)
            keyClick(Qt.Key_Return)
            tryCompare(find("onbRowState_bt-pad-new"), "text", "Pairing…")
            keyClick(Qt.Key_Return)                                         // a second press does nothing
            compare(Bluetooth.mockPairCalls(), 1)
            Bluetooth.mockHoldPairing(false)
            tryCompare(find("onbRowState_bt-pad-new"), "text", "Connected, remembered · A: try its buttons")
            verify(find("onbRow_bt-pad-new").activeFocus, "focus stayed on the row")
            verify(Bluetooth.devices.find(d => d.id === "bt-pad-new").paired)
            compare(onb.stage, "pair")
        }

        function test_a_failed_pairing_says_why_and_a_second_press_tries_again() {
            Bluetooth.mockPairingScript("wait")
            onb.open()
            Bluetooth.mockReveal("bt-flaky")
            tryVerify(() => find("onbRow_bt-flaky") !== null, 2000)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(find("onbRowState_bt-flaky"), "text", "Pairing failed. Put the controller in pairing mode again. A: try again")
            verify(find("onbRow_bt-flaky").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => Bluetooth.mockPairCalls() === 2)
            tryCompare(find("onbRowState_bt-flaky"), "text", "Pairing failed. Put the controller in pairing mode again. A: try again")
            verify(!Bluetooth.devices.find(d => d.id === "bt-flaky").paired)
        }

        // Names the devices chose are text, never markup, and never break the layout (T-260).
        function test_names_from_devices_are_plain_text() {
            Bluetooth.mockPairingScript("wait")
            onb.open()
            Bluetooth.mockReveal("bt-flaky")
            Bluetooth.mockSetName("bt-flaky", "<b>x</b>" + String.fromCharCode(10) + "<i>y</i>")
            tryVerify(() => find("onbRowName_bt-flaky") !== null, 2000)
            tryCompare(find("onbRowName_bt-flaky"), "text", "<b>x</b> <i>y</i>")
            compare(find("onbRowName_bt-flaky").textFormat, Text.PlainText)
            Bluetooth.mockReveal("bt-pad-new")
            Bluetooth.mockSetName("bt-pad-new", "x".repeat(300))
            tryVerify(() => find("onbRow_bt-pad-new") !== null, 2000)
            verify(find("onbRowName_bt-pad-new").width <= find("onbRow_bt-pad-new").width * 0.4 + 1, "a long name is bounded")
            verify(find("onbRowState_bt-pad-new").width >= 0)
            usb(true, "usb-9", "<img src=\"http://host/x\">", "")
            tryCompare(onb, "stage", "try")
            compare(find("onboardingTryName").text, "<img src=\"http://host/x\"> is connected. Press its buttons: they light up here.")
            compare(find("onboardingTryName").textFormat, Text.PlainText)
        }

        function test_a_usb_pad_does_not_cut_a_pairing_short() {
            Bluetooth.mockPairingScript("wait")
            onb.open()
            Bluetooth.mockReveal("bt-pad-new")
            tryVerify(() => find("onbRow_bt-pad-new") !== null, 2000)
            keyClick(Qt.Key_Down)
            Bluetooth.mockHoldPairing(true)
            keyClick(Qt.Key_Return)
            tryCompare(find("onbRowState_bt-pad-new"), "text", "Pairing…")
            usb(true, "usb-9", "Wireless Controller", "playstation")
            wait(150)
            compare(onb.stage, "pair", "the row finishes first")
            Bluetooth.mockHoldPairing(false)
            tryCompare(find("onbRowState_bt-pad-new"), "text", "Connected, remembered · A: try its buttons")
            compare(onb.stage, "pair")
        }

        // The found list uses the same glyph table as every other screen (T-260).
        function test_found_controllers_have_their_familys_glyph() {
            Bluetooth.mockPairingScript("wait")
            onb.open()
            Bluetooth.mockReveal("bt-flaky")
            tryVerify(() => find("onbRow_bt-flaky") !== null, 2000)
            const table = [["playstation", "pad_dualsense"], ["xbox", "pad_xbox_series"], ["nintendo", "pad_switch_pro"],
                           ["8bitdo", "sports_esports"], ["", "sports_esports"]]
            for (const [family, glyph] of table) {
                Bluetooth.mockSetFamily("bt-flaky", family)
                tryVerify(() => findChild(find("onbRow_bt-flaky"), "onbRowGlyph").name === glyph, 2000, family)
                compare(DeviceIcons.iconFor("controller", family), glyph)
            }
            // The model the service names (RUY-491) is the pad's own silhouette, whatever the family.
            Bluetooth.mockSetFamily("bt-flaky", "nintendo")
            Bluetooth.mockSetModel("bt-flaky", "wiiu_pro")
            tryVerify(() => findChild(find("onbRow_bt-flaky"), "onbRowGlyph").name === "pad_wiiu_pro", 2000, "the model")
        }

        function test_a_controller_the_service_paired_itself_is_listed_as_done() {
            Bluetooth.mockPairingScript("success")
            onb.open()
            tryVerify(() => find("onbRow_bt-pad-new") !== null, 3000, "the pad the window paired")
            compare(find("onbRowState_bt-pad-new").text, "Connected, remembered · A: try its buttons")
        }

        function test_the_try_screen_lights_the_buttons_that_are_pressed() {
            Bluetooth.mockPairingScript("wait")
            onb.open()
            Bluetooth.mockReveal("bt-pad-new")
            tryVerify(() => find("onbRow_bt-pad-new") !== null, 2000)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(find("onbRow_bt-pad-new"), "phase", "done")
            keyClick(Qt.Key_Return)                                         // A on a connected pad: try it
            tryCompare(onb, "stage", "try")
            tryVerify(() => find("onboardingButtonTest").activeFocus, 2000, "the test screen has focus")
            tryCompare(Bluetooth, "controllerPairing", "idle", 2000, "the window is closed on the try screen")
            compare(find("onboardingTryName").text, "Ruya Pad is connected. Press its buttons: they light up here.")
            const test = find("onboardingButtonTest")
            verify(!test.isHeld("left") && !test.isTried("left"))
            keyPress(Qt.Key_Left)
            verify(test.isHeld("left"), "lit while held")
            compare(find("testButton_left").Accessible.name, "Left, pressed")
            keyRelease(Qt.Key_Left)
            verify(!test.isHeld("left"))
            verify(test.isTried("left"), "and marked once tried")
            compare(find("testButton_left").Accessible.name, "Left, tried")
            keyClick(Qt.Key_Return)                                         // A lights A; it does not leave
            verify(test.isTried("a"))
            verify(onb.shown)
            keyClick(Qt.Key_PageUp)
            keyClick(Qt.Key_PageDown)
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Right)
            compare(test.triedCount, 7)
            compare(onb.modalHints[0].action, "options")
            keyClick(Qt.Key_Menu)                                           // Start continues
            tryVerify(() => !onb.shown, 2000)
            tryVerify(() => opener.activeFocus, 2000)
        }

        function test_B_on_the_try_screen_closes_it() {
            onb.open()
            usb(true, "usb-9", "Wireless Controller", "playstation")        // plugged in over USB: nothing to pair
            tryCompare(onb, "stage", "try")
            compare(find("onboardingTryName").text, "PlayStation controller is connected. Press its buttons: they light up here.")
            tryVerify(() => find("onboardingButtonTest").activeFocus, 2000)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !onb.shown, 2000)
        }

        function test_a_bluetooth_pad_connecting_does_not_leave_the_pairing_stage() {
            onb.open()
            Bluetooth.mockGamepad(true, "bt-pad-main", "Wireless Controller", "playstation", "bluetooth")
            wait(150)
            compare(onb.stage, "pair", "a reconnecting bonded pad is not what we wait for")
            verify(chip("playstation").activeFocus)
        }

        // ---- RUY-503: "Buttons in games", after trying a Nintendo pad ----

        readonly property string procon: "usb-057e-2009-a1b2c3d4e5f6"

        function signedIn() {
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            Input.mockResetProfiles()
            Input.mockClearProfileCalls()
            Input.mockResetDevices()
            Input.mockAddDevice({ id: procon, name: "Pro Controller", family: "nintendo", model: "switch_pro",
                                  connection: "usb" })
            tryVerify(() => Input.devices.length === 4)
        }

        // Tries a USB pad of `family` with the onboarding screen open and presses Start.
        function tryPadAndStart(name, family, layout) {
            onb.open()
            usb(true, "usb-try", name, family)
            tryCompare(onb, "stage", "try")
            tryVerify(() => find("onboardingButtonTest").activeFocus, 2000)
            if (family === "nintendo" && Profiles.activeProfile !== "") {
                tryCompare(GameControls, "padId", procon)
                tryCompare(GameControls, "loadState", "ok")
                tryCompare(GameControls, "layout", layout ?? "standard")     // the answer to this pad's list
            }
            keyClick(Qt.Key_Menu)
        }

        function saves() {
            return Input.mockProfileCalls().filter(c => c.method === "SaveProfile").map(c => JSON.parse(c.args.json))
        }

        function test_start_after_a_nintendo_pad_with_the_standard_layout_asks_how_games_see_its_buttons() {
            signedIn()
            tryPadAndStart("Pro Controller", "nintendo")
            tryCompare(onb, "stage", "games")
            compare(find("onboardingTitle").text, "Buttons in games")
            compare(find("onboardingGamesBody").text, "Menus confirm with A on this controller. Games can see the buttons by their letters, or by position like an Xbox controller.")
            compare(find("gamesRowPosition").label, "By position")
            compare(find("gamesRowPosition").detail, "The bottom button is A in games, as on Xbox.")
            compare(find("gamesRowPosition").value, "Current")
            compare(find("gamesRowNintendo").label, "Nintendo labels")
            compare(find("gamesRowNintendo").detail, "Games see each button by the letter on it.")
            compare(find("gamesRowNintendo").value, "")
            compare(find("onboardingGamesNote").text, "You can change this later in Settings > Controllers.")
            verify(find("gamesRowPosition").activeFocus, "focus starts on the Current row")
            keyClick(Qt.Key_Up)
            verify(find("gamesRowPosition").activeFocus, "Up stops at the first row")
            keyClick(Qt.Key_Down)
            verify(find("gamesRowNintendo").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("gamesRowNintendo").activeFocus, "Down stops at the last row")
            compare(onb.modalHints.map(h => h.action + " " + h.text), ["accept Select", "back Close"])
            verify(onb.shown)
            compare(saves().length, 0, "asking changes nothing")
        }

        function test_other_pads_and_the_nintendo_layout_close_at_start_as_before() {
            signedIn()
            tryPadAndStart("Xbox Wireless Controller", "xbox")
            tryVerify(() => !onb.shown, 2000, "an Xbox pad is not asked")
            GameControls.show(procon)
            tryCompare(GameControls, "loadState", "ok")
            GameControls.setLayout("nintendo")
            tryVerify(() => !GameControls.busy, 3000)
            tryCompare(GameControls, "layout", "nintendo")
            tryPadAndStart("Pro Controller", "nintendo", "nintendo")
            tryVerify(() => !onb.shown, 2000, "a pad that already has the Nintendo layout is not asked")
        }

        function test_a_signed_out_screen_does_not_ask() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            Input.mockResetDevices()
            Input.mockAddDevice({ id: procon, name: "Pro Controller", family: "nintendo", model: "switch_pro",
                                  connection: "usb" })
            tryVerify(() => Input.devices.length === 4)
            tryPadAndStart("Pro Controller", "nintendo")
            tryVerify(() => !onb.shown, 2000)
        }

        function test_A_on_nintendo_labels_saves_the_pads_own_profile_and_closes() {
            signedIn()
            opener.forceActiveFocus()
            tryPadAndStart("Pro Controller", "nintendo")
            tryCompare(onb, "stage", "games")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => !onb.shown, 3000)
            tryVerify(() => opener.activeFocus, 2000, "focus returns where it was")
            const s = saves()
            compare(s.length, 1)
            compare(s[0].inherits, "nintendo")
            compare(s[0].id, "controls-device-" + procon, "the tried pad's own profile, never a family or all controllers")
        }

        function test_A_on_the_current_layout_closes_without_a_call() {
            signedIn()
            tryPadAndStart("Pro Controller", "nintendo")
            tryCompare(onb, "stage", "games")
            keyClick(Qt.Key_Return)
            tryVerify(() => !onb.shown, 2000)
            compare(saves().length, 0)
            compare(GameControls.layout, "standard")
        }

        function test_B_on_the_games_step_closes_and_changes_nothing() {
            signedIn()
            opener.forceActiveFocus()
            tryPadAndStart("Pro Controller", "nintendo")
            tryCompare(onb, "stage", "games")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !onb.shown, 2000)
            tryVerify(() => opener.activeFocus, 2000)
            compare(saves().length, 0)
            compare(GameControls.layout, "standard")
        }

        function test_a_refused_save_keeps_the_games_step_open_on_its_row() {
            signedIn()
            tryPadAndStart("Pro Controller", "nintendo")
            tryCompare(onb, "stage", "games")
            keyClick(Qt.Key_Down)
            Input.mockSetProfileStatusOnce("ValidateProfile", "invalid")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().indexOf("Could not save the change | Try again.") >= 0, 3000, toastTexts().join("; "))
            verify(onb.shown, "the screen stays open")
            compare(onb.stage, "games")
            tryVerify(() => find("gamesRowNintendo").activeFocus, 2000, "on the row that was chosen")
            compare(find("gamesRowPosition").value, "Current", "nothing changed")
            keyClick(Qt.Key_Return)                                         // a second try saves
            tryVerify(() => !onb.shown, 3000)
        }

        // The reviewer's case: the pad leaves while the step is open; nothing is saved for another pad.
        function test_a_pad_that_leaves_while_the_step_is_open_saves_nothing() {
            signedIn()
            tryPadAndStart("Pro Controller", "nintendo")
            tryCompare(onb, "stage", "games")
            Input.mockRemoveDevice(procon)
            tryVerify(() => !onb.shown, 2000, "the step closes when its pad leaves")
            compare(saves().length, 0)
        }

        function test_a_save_never_goes_to_a_pad_other_than_the_tried_one() {
            signedIn()
            tryPadAndStart("Pro Controller", "nintendo")
            tryCompare(onb, "stage", "games")
            GameControls.show("usb-045e-0b12-8e01c2d4a9f3")     // the shown pad is another one now
            tryCompare(GameControls, "padId", "usb-045e-0b12-8e01c2d4a9f3")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => !onb.shown, 2000)
            compare(saves().length, 0)
        }

        // The step only writes the tried pad's own device slot, never the shared profile.
        function test_a_pad_on_the_all_controllers_profile_gets_its_own_copy() {
            signedIn()
            Input.saveProfile("p2", JSON.stringify({ schema_version: 1, id: "controls-all", name: "All",
                                                      scope: { type: "global" },
                                                      mappings: [{ from: "l1", to: { type: "button", code: "r1" } }],
                                                      settings: { left_stick: { inner_deadzone: 0.12 } } }))
            Input.assignProfile("p2", "global", "", "controls-all")
            tryVerify(() => Input.mockProfileCalls().filter(c => c.method === "AssignProfile").length === 1)
            Input.mockClearProfileCalls()
            tryPadAndStart("Pro Controller", "nintendo")
            tryCompare(onb, "stage", "games")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => !onb.shown, 3000)
            const s = saves()
            compare(s.length, 1)
            compare(s[0].id, "controls-device-" + procon)
            compare(s[0].inherits, "nintendo")
            compare(s[0].match.device, procon)
            compare(s[0].mappings, [{ from: "l1", to: { type: "button", code: "r1" } }], "the copy keeps the shared mappings")
            compare(s[0].settings.left_stick.inner_deadzone, 0.12, "and its stick settings")
            compare(s.filter(p => p.id === "controls-all").length, 0, "the shared profile is not rewritten")
        }

        function test_a_pad_that_Input1_lists_late_is_still_asked() {
            signedIn()
            Input.mockRemoveDevice(procon)
            tryVerify(() => Input.devices.length === 3)
            onb.open()
            usb(true, "usb-try", "Pro Controller", "nintendo")
            tryCompare(onb, "stage", "try")
            compare(onb.tryPadId, "")
            Input.mockAddDevice({ id: procon, name: "Pro Controller", family: "nintendo", model: "switch_pro",
                                  connection: "usb" })
            tryCompare(onb, "tryPadId", procon)
            tryCompare(GameControls, "loadState", "ok")
            tryCompare(GameControls, "layout", "standard")
            keyClick(Qt.Key_Menu)
            tryCompare(onb, "stage", "games")
        }

        // RUY-703 case 1: another Nintendo pad is listed; the pad being tried is not yet.
        function test_a_pad_not_yet_listed_is_not_taken_for_another_nintendo_pad() {
            signedIn()                                  // a Pro Controller (usb) is listed
            const wiiu = "usb-057e-0330-c1d2e3f4a5b6"
            onb.open()
            usb(true, "usb-wiiu", "Nintendo RVL-CNT-01-UC", "nintendo")
            tryCompare(onb, "stage", "try")
            compare(onb.tryPadId, "", "the listed Pro Controller is not the pad being tried")
            Input.mockAddDevice({ id: wiiu, name: "Nintendo RVL-CNT-01-UC", family: "nintendo", model: "wiiu_pro",
                                  connection: "usb" })
            tryCompare(onb, "tryPadId", wiiu)
            keyClick(Qt.Key_Menu)
            tryCompare(onb, "stage", "games")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => !onb.shown, 3000)
            compare(saves().map(p => p.id), ["controls-device-" + wiiu])
        }

        function test_a_tried_pad_that_leaves_is_not_replaced_by_another_nintendo_pad() {
            signedIn()                                  // an older Pro Controller of the same name stays listed
            const tried = "usb-057e-2009-ffeeddccbbaa"
            onb.open()
            Input.mockAddDevice({ id: tried, name: "Pro Controller", family: "nintendo", model: "switch_pro",
                                  connection: "usb" })
            tryVerify(() => Input.devices.length === 5)
            usb(true, "usb-try", "Pro Controller", "nintendo")
            tryCompare(onb, "stage", "try")
            tryCompare(onb, "tryPadId", tried)
            Input.mockRemoveDevice(tried)
            tryVerify(() => Input.devices.length === 4)
            compare(onb.tryPadId, "")
            Input.mockRemoveDevice("usb-045e-0b12-8e01c2d4a9f3")        // the list changes again
            tryVerify(() => Input.devices.length === 3)
            wait(100)
            compare(onb.tryPadId, "", "never looks for another pad once its own left")
            keyClick(Qt.Key_Menu)
            tryVerify(() => !onb.shown, 2000)
            compare(saves().length, 0)
        }

        function test_the_games_step_in_turkish() {
            signedIn()
            tryPadAndStart("Pro Controller", "nintendo")
            tryCompare(onb, "stage", "games")
            DeviceSettings.language = "tr"
            compare(find("onboardingTitle").text, "Oyunlarda düğmeler")
            compare(find("gamesRowPosition").label, "Konuma göre")
            compare(find("gamesRowPosition").value, "Şu anki")
            compare(find("gamesRowNintendo").label, "Nintendo etiketleri")
            compare(find("gamesRowNintendo").detail, "Oyunlar her düğmeyi üzerindeki harfle görür.")
            compare(find("onboardingGamesNote").text, "Bunu sonra Ayarlar > Kontrolcüler’den değiştirebilirsin.")
            onb.close()
        }

        function test_the_nintendo_chip_and_its_steps() {
            onb.open()
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            verify(chip("nintendo").activeFocus)
            compare(find("onbChip_nintendo").Accessible.name, "Nintendo controller")
            compare(find("onboardingSteps").text, "Switch Pro Controller or Joy-Con: hold the small sync button until the lights run back and forth. Wii U Pro Controller: press the sync button on the back.")
            DeviceSettings.language = "tr"
            compare(find("onboardingSteps").text, "Switch Pro Controller ya da Joy-Con: ışıklar ileri geri yanana kadar küçük eşleme düğmesini basılı tut. Wii U Pro Controller: arkadaki eşleme düğmesine bas.")
            onb.close()
        }

        function test_zz_games_step_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            signedIn()
            tryPadAndStart("Pro Controller", "nintendo")
            tryCompare(onb, "stage", "games")
            wait(600)
            grabImage(host)
            wait(600)
            grabImage(host).save(shotsDir + "/RUY503-games-step-720.png")
            DeviceSettings.language = "tr"
            wait(600)
            grabImage(host).save(shotsDir + "/RUY503-games-step-tr-720.png")
            DeviceSettings.language = "en"
            keyClick(Qt.Key_Down)
            Input.mockSetProfileStatusOnce("ValidateProfile", "invalid")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().length > 0, 3000)
            wait(600)
            grabImage(host).save(shotsDir + "/RUY503-games-step-error-720.png")
            onb.u = 1
            host.width = 1920
            host.height = 1080
            wait(600)
            grabImage(host).save(shotsDir + "/RUY503-games-step-error.png")
            DeviceSettings.language = "tr"
            wait(600)
            grabImage(host).save(shotsDir + "/RUY503-games-step-error-tr.png")
            DeviceSettings.language = "en"
            keyClick(Qt.Key_Up)
            wait(600)
            grabImage(host).save(shotsDir + "/RUY503-games-step.png")
            onb.u = 720 / 1080
            host.width = 1280
            host.height = 720
            onb.close()
        }

        // Turkish: the steps, the chips' names and the toasts follow the language live.
        function test_turkish() {
            DeviceSettings.language = "tr"
            onb.open()
            keyClick(Qt.Key_Right)
            compare(find("onboardingSteps").text, "Xbox logosu hızlı yanıp sönene kadar üstteki eşleştirme düğmesine basın.")
            compare(chip("xbox").Accessible.name, "Xbox kontrolcüsü")
            compare(find("onboardingTitle").text, "Kontrolcü eşleştir")
            usb(true, "usb-1", "Wireless Controller", "playstation")
            tryCompare(Notifications.model, "count", 1)
            compare(Notifications.model.get(0).text, "PlayStation kontrolcüsü bağlandı")
            compare(Notifications.model.get(0).detail, "Pil 60% · USB")
            onb.close()
        }

        // T-359: "Found nearby" with two like pads, in English and Turkish.
        function test_zz_like_pads_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Bluetooth.mockPairingScript("wait")
            onb.open()
            Bluetooth.mockTwoPads()
            tryVerify(() => find("onbRow_" + tc.padA) !== null && find("onbRow_" + tc.padB) !== null, 2000)
            keyClick(Qt.Key_Down)
            wait(600)
            grabImage(host)
            wait(600)
            grabImage(host).save(shotsDir + "/T359-found-nearby-like-pads.png")
            DeviceSettings.language = "tr"
            wait(600)
            grabImage(host).save(shotsDir + "/T359-found-nearby-like-pads-tr.png")
            DeviceSettings.language = "en"
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Bluetooth.mockPairingScript("wait")
            onb.open()
            Bluetooth.mockReveal("bt-flaky")
            Bluetooth.mockReveal("bt-pad-new")
            tryVerify(() => find("onbRow_bt-pad-new") !== null, 2000)
            keyClick(Qt.Key_Right)
            wait(600)
            grabImage(host)
            wait(600)
            grabImage(host).save(shotsDir + "/T260-onboarding-pair.png")
            DeviceSettings.language = "tr"
            wait(600)
            grabImage(host).save(shotsDir + "/T260-onboarding-pair-tr.png")
            DeviceSettings.language = "en"
            wait(300)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(find("onbRow_bt-flaky"), "phase", "failed")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(find("onbRow_bt-pad-new"), "phase", "done")
            wait(600)
            grabImage(host).save(shotsDir + "/T260-onboarding-result.png")
            keyClick(Qt.Key_Return)
            tryCompare(onb, "stage", "try")
            keyPress(Qt.Key_Left)
            keyRelease(Qt.Key_Left)
            keyPress(Qt.Key_Return)
            wait(600)
            grabImage(host).save(shotsDir + "/T260-onboarding-try.png")
            DeviceSettings.language = "tr"
            wait(600)
            grabImage(host).save(shotsDir + "/T260-onboarding-try-tr.png")
            DeviceSettings.language = "en"
            keyRelease(Qt.Key_Return)
        }
    }
}
