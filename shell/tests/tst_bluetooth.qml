import QtQuick
import QtTest
import RuyaShell

// Settings -> Bluetooth & controllers against the mock backend: power, scanning (a controller
// needs two scans), pairing by keys, a failed pairing, connect/disconnect, forgetting, the
// low-battery toast, and every status string of the contract. Signs in as "Ada" (p2, no PIN).
// The mock is reset before every test.
Item {
    id: host
    width: 1280
    height: 720

    // Every answer of the service, in order: { op, id, status }.
    property var answers: []
    Connections {
        target: Bluetooth
        function onFinished(op, id, status) { host.answers = host.answers.concat([{ op: op, id: id, status: status }]) }
    }

    SignalSpy { id: lowSpy; target: Bluetooth; signalName: "batteryLow" }

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "Bluetooth"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Bluetooth.mockReset()
            tryVerify(() => Bluetooth.powered && !Bluetooth.discovering && Bluetooth.devices.length === 3)
            host.answers = []
            lowSpy.clear()
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
            clearToasts()
        }

        function cleanup() {
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
                out.push(Notifications.model.get(i).text)
            return out
        }

        function openBluetoothPane() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus, 2000, "category list has focus")
            keyClick(Qt.Key_Down)                        // Network
            keyClick(Qt.Key_Down)                        // Bluetooth & controllers
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneBluetooth").visible)
            tryVerify(() => find("rowBtPower").activeFocus, 2000, "the power switch takes focus")
        }

        // Down (or else up) to the named row (which must exist), asserting that the pane keeps focus.
        function goTo(name) {
            tryVerify(() => find(name) !== null, 3000, name + " exists")
            for (let i = 0; i < 25 && !find(name).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            for (let i = 0; i < 25 && !find(name).activeFocus; ++i)
                keyClick(Qt.Key_Up)                      // the row is above the focused one
            tryVerify(() => find(name).activeFocus, 2000, name + " has focus")
        }

        function scan() {
            goTo("rowBtAdd")
            keyClick(Qt.Key_Return)
            tryCompare(Bluetooth, "discovering", true)
            tryCompare(find("rowBtAdd"), "value", "Scanning…")
            tryCompare(Bluetooth, "discovering", false, 3000)
            tryVerify(() => find("rowBtAdd").activeFocus, 2000, "focus stays on the scan row")
        }

        function device(id) { return Bluetooth.devices.find(d => d.id === id) }

        function answerFor(op, id) {
            return host.answers.find(a => a.op === op && a.id === id)
        }

        // Runs one command and returns the status of its answer. A top-level function: qmllint
        // goes blind on a local declared inside a nested one (T-189, scripts/lint-test-members.ps1).
        function runCommand(seen, op, id, call) {
            host.answers = []
            call()
            tryVerify(() => answerFor(op, id) !== undefined, 2000, op + " " + id + " answered")
            const status = answerFor(op, id).status
            seen.add(status)
            return status
        }

        function test_contract_statuses() {
            const seen = new Set()
            const run = (op, id, call) => runCommand(seen, op, id, call)
            compare(run("pair", "", () => Bluetooth.pair("")), "invalid")
            compare(run("pair", "nope", () => Bluetooth.pair("nope")), "unknown-device")
            compare(run("scan", "", () => Bluetooth.startScan()), "ok")
            tryVerify(() => device("bt-flaky") !== undefined && device("bt-sleepy") !== undefined)
            compare(run("pair", "bt-flaky", () => Bluetooth.pair("bt-flaky")), "pairing-failed")
            compare(run("pair", "bt-sleepy", () => Bluetooth.pair("bt-sleepy")), "timeout")
            compare(run("connect", "bt-flaky", () => Bluetooth.connectDevice("bt-flaky")), "failed")
            compare(run("pair", "bt-buds", () => Bluetooth.pair("bt-buds")), "ok")
            compare(run("disconnect", "bt-buds", () => Bluetooth.disconnectDevice("bt-buds")), "ok")
            compare(run("power", "", () => Bluetooth.setPowered(false)), "ok")
            tryCompare(Bluetooth, "powered", false)
            compare(run("scan", "", () => Bluetooth.startScan()), "unavailable")
            compare(run("pair", "bt-buds", () => Bluetooth.pair("bt-buds")), "unavailable")
            for (const s of ["ok", "unknown-device", "pairing-failed", "timeout", "unavailable", "invalid", "failed"])
                verify(seen.has(s), "status " + s + " exercised")
            compare(seen.size, 7, "no status outside the contract")
        }

        function test_power_off_hides_and_stops_scan() {
            openBluetoothPane()
            verify(find("rowBtAdd").visible)
            verify(find("btDev_bt-pad-main").visible)
            verify(!find("rowBtOff").visible)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowBtAdd").activeFocus)
            keyClick(Qt.Key_Return)                      // start a scan ...
            tryCompare(Bluetooth, "discovering", true)
            keyClick(Qt.Key_Up)
            tryVerify(() => find("rowBtPower").activeFocus)
            keyClick(Qt.Key_Return)                      // ... and switch off while it runs
            tryCompare(Bluetooth, "powered", false)
            compare(Bluetooth.discovering, false, "scanning stops")
            tryVerify(() => !find("rowBtAdd").visible)
            tryVerify(() => find("rowBtOff").visible, 2000, "the pane says Bluetooth is off")
            tryCompare(find("rowBtOff"), "label", "Bluetooth is off")
            tryVerify(() => find("btDev_bt-pad-main") === null || !find("btDev_bt-pad-main").visible)
            tryVerify(() => find("btForget_bt-pad-main") === null || !find("btForget_bt-pad-main").visible)
            tryVerify(() => find("rowBtPower").activeFocus, 2000, "focus stays on the switch")
            compare(find("rowBtPower").checked, false)
            keyClick(Qt.Key_Down)                        // nothing else to focus
            tryVerify(() => find("rowBtPower").activeFocus)

            keyClick(Qt.Key_Return)                      // on again
            tryCompare(Bluetooth, "powered", true)
            tryVerify(() => find("rowBtAdd").visible)
            tryVerify(() => find("btDev_bt-pad-main") !== null && find("btDev_bt-pad-main").visible)
            tryVerify(() => !find("rowBtOff").visible)
            tryVerify(() => find("rowBtPower").activeFocus)
            compare(find("rowBtPower").checked, true)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowBtAdd").activeFocus)
            tryCompare(find("btDev_bt-pad-main"), "value", "Connected · Battery 80%", 2000,
                       "the paired controller reconnects")
        }

        function test_scan_and_pair_a_controller() {
            openBluetoothPane()
            scan()
            verify(device("bt-flaky"), "first scan finds the flaky pad")
            verify(device("bt-buds"))
            verify(!device("bt-pad-new"), "the controller needs a second scan")
            scan()
            tryVerify(() => device("bt-pad-new") !== undefined, 2000, "second scan finds the controller")
            goTo("btDev_bt-pad-new")
            compare(find("btDev_bt-pad-new").value, "Not paired")
            keyClick(Qt.Key_Return)
            tryVerify(() => device("bt-pad-new").paired && device("bt-pad-new").connected, 2000)
            tryCompare(find("btDev_bt-pad-new"), "value", "Connected · Battery 64%")
            verify(device("bt-pad-new").trusted)
            tryVerify(() => find("btDev_bt-pad-new").activeFocus, 2000, "focus stays on the paired device")
            compare(toastTexts().length, 0, "no error shown")
            tryVerify(() => find("btForget_bt-pad-new").visible, 2000, "it can be forgotten now")
        }

        function test_failed_pairing_keeps_focus() {
            openBluetoothPane()
            scan()
            goTo("btDev_bt-flaky")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().includes("Pairing failed. Put the device in pairing mode and try again."),
                      2000, "the message is shown")
            verify(!device("bt-flaky").paired)
            tryCompare(find("btDev_bt-flaky"), "value", "Not paired")
            tryVerify(() => find("btDev_bt-flaky").activeFocus, 2000, "focus stays on the row")

            goTo("btDev_bt-sleepy")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().includes("The device did not answer."), 2000)
            tryVerify(() => find("btDev_bt-sleepy").activeFocus, 2000, "focus stays on the row")
        }

        function test_second_accept_while_pairing_does_not_pair_again() {
            openBluetoothPane()
            scan()
            goTo("btDev_bt-buds")
            Bluetooth.mockHoldPairing(true)              // a pairing that takes a while
            keyClick(Qt.Key_Return)
            tryVerify(() => Bluetooth.mockPairCalls() === 1, 2000, "pair sent")
            tryCompare(find("btDev_bt-buds"), "value", "Pairing…")
            keyClick(Qt.Key_Return)                      // a second Accept, a key repeat
            keyClick(Qt.Key_Return)
            wait(100)                                    // a second call would have arrived by now
            compare(Bluetooth.mockPairCalls(), 1, "still one pair call")
            Bluetooth.mockHoldPairing(false)             // the answer comes
            tryVerify(() => device("bt-buds").paired, 2000)
            tryVerify(() => find("btDev_bt-buds").value.startsWith("Connected"), 2000, "connected")
            compare(Bluetooth.mockPairCalls(), 1)
            keyClick(Qt.Key_Return)                      // free again: now it disconnects
            tryVerify(() => find("btDev_bt-buds").value === "Paired", 2000, "disconnected")
        }

        function test_failed_disconnect_says_so() {
            openBluetoothPane()
            Bluetooth.disconnectDevice("bt-nobody-paired")   // unknown device
            tryVerify(() => toastTexts().includes("That device is no longer available."), 2000)
            clearToasts()
            scan()
            Bluetooth.disconnectDevice("bt-flaky")       // found but not paired: the mock answers "failed"
            tryVerify(() => answerFor("disconnect", "bt-flaky") !== undefined, 2000)
            compare(answerFor("disconnect", "bt-flaky").status, "failed")
            tryVerify(() => toastTexts().includes("Could not disconnect."), 2000, "the disconnect message")
            verify(!toastTexts().includes("Could not connect."))
        }

        function test_connect_and_disconnect() {
            openBluetoothPane()
            compare(find("btDev_bt-pad-main").value, "Connected · Battery 80%")
            compare(find("btDev_bt-soundbar").value, "Connected", "no battery shown when unknown")
            compare(find("btDev_bt-pad-old").value, "Paired")
            goTo("btDev_bt-pad-old")
            keyClick(Qt.Key_Return)
            tryCompare(find("btDev_bt-pad-old"), "value", "Connected")
            tryVerify(() => find("btDev_bt-pad-old").activeFocus)
            keyClick(Qt.Key_Return)                      // Accept on a connected device disconnects
            tryCompare(find("btDev_bt-pad-old"), "value", "Paired")
            tryVerify(() => find("btDev_bt-pad-old").activeFocus)
            compare(toastTexts().length, 0)
        }

        function test_forget_moves_focus_to_a_valid_row() {
            openBluetoothPane()
            goTo("btForget_bt-pad-old")
            keyClick(Qt.Key_Return)
            tryVerify(() => device("bt-pad-old") === undefined, 2000, "the device is gone")
            tryVerify(() => find("btDev_bt-pad-old") === null, 2000, "its row is gone")
            tryVerify(() => find("btForget_bt-pad-old") === null)
            tryVerify(() => find("btForget_bt-soundbar").activeFocus, 2000, "focus moves to the next row")
            verify(find("paneBluetooth").activeFocus)
            keyClick(Qt.Key_Return)                      // the last paired device but one
            tryVerify(() => device("bt-soundbar") === undefined, 2000)
            tryVerify(() => find("btForget_bt-pad-main").activeFocus, 2000, "focus moves up from the last row")
            // A forgotten device has to be found again.
            scan()
            tryVerify(() => device("bt-pad-old") !== undefined && !device("bt-pad-old").paired, 2000)
        }

        function test_low_battery_toast_once_per_crossing() {
            // The soundbar stands for any connected device that is not a controller; controllers
            // are reported by Batteries (UPower), see tst_battery.qml.
            Bluetooth.mockSetBattery("bt-soundbar", 20)
            tryVerify(() => device("bt-soundbar").battery === 20)
            compare(lowSpy.count, 0, "above the limit")
            Bluetooth.mockSetBattery("bt-soundbar", 14)
            tryCompare(lowSpy, "count", 1)
            tryVerify(() => toastTexts().includes("Soundbar: battery low (14%)"), 2000)
            Bluetooth.mockSetBattery("bt-soundbar", 12)
            tryVerify(() => device("bt-soundbar").battery === 12)
            Bluetooth.mockSetBattery("bt-soundbar", 9)
            tryVerify(() => device("bt-soundbar").battery === 9)
            compare(lowSpy.count, 1, "still low: no second toast")
            compare(toastTexts().filter(t => t.includes("battery low")).length, 1)
            Bluetooth.mockSetBattery("bt-soundbar", 40)  // recharged ...
            tryVerify(() => device("bt-soundbar").battery === 40)
            Bluetooth.mockSetBattery("bt-soundbar", 10)  // ... and low again
            tryCompare(lowSpy, "count", 2)
            // An unconnected or unknown battery never toasts.
            Bluetooth.mockSetBattery("bt-pad-old", 3)
            tryVerify(() => device("bt-pad-old").battery === 3)
            compare(lowSpy.count, 2)
            // A controller never toasts here: Batteries owns it.
            Bluetooth.mockSetBattery("bt-pad-main", 5)
            tryVerify(() => device("bt-pad-main").battery === 5)
            compare(lowSpy.count, 2)
        }

        function test_back_leaves_the_pane() {
            openBluetoothPane()
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "back to the category list")
            tryCompare(tc.shell, "currentPage", "settings")
        }

        function test_an_older_reply_arriving_late_is_dropped() {
            // Powered, three devices. Ask again (the replies, a snapshot of that, are held back),
            // then Bluetooth is switched off: the late replies must not power it on again or bring
            // the devices back. The state and the list are two kinds of reply.
            Bluetooth.mockRefreshDelayed(150)
            compare(Bluetooth.mockPendingReplies(), 1)
            Bluetooth.setPowered(false)
            tryCompare(Bluetooth, "powered", false)
            tryVerify(() => Bluetooth.devices.length === 0)
            tryVerify(() => Bluetooth.mockPendingReplies() === 0)
            compare(Bluetooth.powered, false, "the late powered state was dropped")
            compare(Bluetooth.devices.length, 0, "the late device list was dropped")
        }

        // ---- T-203: the controller pairing window ----

        function test_pair_a_controller_row_opens_the_window() {
            Bluetooth.mockPairingScript("wait")
            openBluetoothPane()
            goTo("rowBtPairController")
            compare(find("rowBtPairController").value, "")
            keyClick(Qt.Key_Return)
            tryCompare(Bluetooth, "controllerPairing", "open")
            tryCompare(find("rowBtPairController"), "value", "Waiting for a controller…")
            compare(Bluetooth.mockPairingStarts(), 1)
            verify(find("rowBtPairController").activeFocus, "focus stays on the row")
            tryVerify(() => host.answers.some(a => a.op === "controller-pairing" && a.status === "ok"))
            compare(toastTexts().length, 0, "no error shown")
            // A second Accept closes the window again
            keyClick(Qt.Key_Return)
            tryCompare(Bluetooth, "controllerPairing", "idle")
            compare(find("rowBtPairController").value, "")
            verify(find("rowBtPairController").activeFocus)
        }

        function test_a_controller_that_pairs_in_the_window_is_listed() {
            Bluetooth.mockPairingScript("success")
            openBluetoothPane()
            goTo("rowBtPairController")
            keyClick(Qt.Key_Return)
            tryCompare(find("rowBtPairController"), "value", "Paired", 3000)
            tryVerify(() => device("bt-pad-new") !== undefined && device("bt-pad-new").paired, 2000)
            tryVerify(() => find("btDev_bt-pad-new") !== null, 2000, "the pad is a row of the pane")
            tryVerify(() => find("rowBtPairController").activeFocus, 2000, "focus did not move")
            compare(toastTexts().length, 0)
        }

        function test_a_timed_out_window_says_so_and_can_be_opened_again() {
            Bluetooth.mockPairingScript("timeout")
            openBluetoothPane()
            goTo("rowBtPairController")
            keyClick(Qt.Key_Return)
            tryCompare(find("rowBtPairController"), "value", "Nothing found", 3000)
            keyClick(Qt.Key_Return)                      // again
            tryVerify(() => Bluetooth.mockPairingStarts() === 2)
            tryCompare(find("rowBtPairController"), "value", "Nothing found", 3000)
        }

        function test_a_rejected_device_is_toasted_and_the_window_stays_open() {
            Bluetooth.mockPairingScript("rejected")
            openBluetoothPane()
            goTo("rowBtPairController")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().indexOf("A device that is not a controller was ignored.") >= 0, 3000)
            compare(Bluetooth.controllerPairing, "open")
        }

        function test_leaving_the_pane_closes_the_window() {
            Bluetooth.mockPairingScript("wait")
            openBluetoothPane()
            goTo("rowBtPairController")
            keyClick(Qt.Key_Return)
            tryCompare(Bluetooth, "controllerPairing", "open")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000)
            keyClick(Qt.Key_Up)                           // Network: the Bluetooth pane is hidden
            tryVerify(() => !find("paneBluetooth").visible, 2000)
            tryCompare(Bluetooth, "controllerPairing", "idle")
        }

        function test_the_window_statuses() {
            const seen = new Set()
            const run = (id, call) => runCommand(seen, "controller-pairing", id, call)
            compare(run("start", () => Bluetooth.startControllerPairing()), "ok")
            tryCompare(Bluetooth, "controllerPairing", "open")
            compare(run("start", () => Bluetooth.startControllerPairing()), "busy")
            compare(run("stop", () => Bluetooth.stopControllerPairing()), "ok")
            tryCompare(Bluetooth, "controllerPairing", "idle")
            compare(run("stop", () => Bluetooth.stopControllerPairing()), "ok")
            Bluetooth.setPowered(false)
            tryCompare(Bluetooth, "powered", false)
            compare(run("start", () => Bluetooth.startControllerPairing()), "unavailable")
            verify(seen.has("ok") && seen.has("busy") && seen.has("unavailable"))
            compare(seen.size, 3, "no status outside the contract")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openBluetoothPane()
            goTo("rowBtPairController")
            keyClick(Qt.Key_Return)
            tryCompare(Bluetooth, "controllerPairing", "open")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/26b-settings-bluetooth-pair-controller.png")
            keyClick(Qt.Key_Return)
            tryCompare(Bluetooth, "controllerPairing", "idle")
            scan()
            scan()
            goTo("btDev_bt-pad-new")
            keyClick(Qt.Key_Return)
            tryCompare(find("btDev_bt-pad-new"), "value", "Connected · Battery 64%")
            goTo("btDev_bt-buds")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/26-settings-bluetooth.png")
        }
    }
}
