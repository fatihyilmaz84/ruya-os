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

        function inConfirm(name) { return findChild(find("btForgetConfirm"), name) }

        // Accept on a "Forget" row, then the confirmation that names the device: Cancel has focus,
        // Right moves to the red button, Accept forgets.
        function confirmForget(name) {
            keyClick(Qt.Key_Return)
            tryVerify(() => find("btForgetConfirm").shown, 2000, "the confirmation is up")
            compare(inConfirm("powerConfirmTitle").text, "Forget " + name + "?")
            tryVerify(() => inConfirm("powerCancel").activeFocus, 2000, "Cancel has focus first")
            keyClick(Qt.Key_Right)
            tryVerify(() => inConfirm("powerConfirm").activeFocus)
            compare(inConfirm("powerConfirm").Accessible.name, "Forget " + name)
            keyClick(Qt.Key_Return)
            tryVerify(() => !find("btForgetConfirm").shown, 2000)
        }

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
            compare(find("btDev_bt-pad-old").value, "Reconnects automatically")
            goTo("btDev_bt-pad-old")
            keyClick(Qt.Key_Return)
            tryCompare(find("btDev_bt-pad-old"), "value", "Connected")
            tryVerify(() => find("btDev_bt-pad-old").activeFocus)
            keyClick(Qt.Key_Return)                      // Accept on a connected device disconnects
            tryCompare(find("btDev_bt-pad-old"), "value", "Reconnects automatically")
            tryVerify(() => find("btDev_bt-pad-old").activeFocus)
            compare(toastTexts().length, 0)
        }

        // The on-screen keyboard key with this value gets focus (a top-level function: T-189).
        function keyboardGoTo(entry, value) {
            let target = null
            for (let r = 0; r < entry.rows.length && !target; ++r) {
                const c = entry.rows[r].keys.findIndex(k => k.value === value)
                if (c >= 0)
                    target = { row: r, col: c }
            }
            verify(target !== null, "keyboard has '" + value + "'")
            for (let step = 0; step < 60; ++step) {
                if (entry.focusRow === target.row && entry.focusCol === target.col)
                    return
                if (entry.focusRow !== target.row) {
                    keyClick(entry.focusRow < target.row ? Qt.Key_Down : Qt.Key_Up)
                } else {
                    const n = entry.rows[target.row].keys.length
                    const right = (target.col - entry.focusCol + n) % n
                    keyClick(right <= n - right ? Qt.Key_Right : Qt.Key_Left)
                }
            }
            fail("could not reach '" + value + "'")
        }

        // T-260: the paired list. A paired controller offers Rename (the on-screen keyboard, stored
        // as BlueZ's alias) and Forget (after a confirmation); other kinds only Forget.
        function test_rename_a_controller() {
            openBluetoothPane()
            verify(!find("btRename_bt-soundbar").visible, "a speaker has no Rename row")
            compare(find("btRename_bt-pad-old").label, "Rename Retro Pad")
            goTo("btRename_bt-pad-old")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("btRenameEntry").shown, 2000)
            compare(find("btRenameEntry").text, "Retro Pad", "pre-filled with the current name")
            keyboardGoTo(find("btRenameEntry"), "x")
            keyClick(Qt.Key_Return)
            keyboardGoTo(find("btRenameEntry"), "done")
            keyClick(Qt.Key_Return)
            tryVerify(() => device("bt-pad-old").name === "Retro Padx", 2000, "the service has the new name")
            verify(device("bt-pad-old").paired, "still paired")
            tryCompare(find("btRename_bt-pad-old"), "label", "Rename Retro Padx")
            tryVerify(() => find("btRename_bt-pad-old").activeFocus, 2000, "focus is back on the row")
            compare(toastTexts().length, 0)
        }

        // T-300: ListDevices tells whether a paired device is bonded (BlueZ's Bonded) and what the device
        // calls itself (BlueZ's Name) while `name` stays the alias. A client that gets neither key (an older
        // service) reads bonded=true and deviceName="" (the D-Bus client's defaults); the mock sends both.
        function test_bonded_flag_from_mock() {
            verify(device("bt-pad-old").paired)
            compare(device("bt-pad-old").bonded, true, "a normal pairing keeps its keys")
            compare(device("bt-pad-old").deviceName, "Retro Pad", "the device's own name")
            Bluetooth.mockSetBonded("bt-pad-old", false)
            tryVerify(() => device("bt-pad-old").bonded === false, 2000, "paired but not bonded")
            verify(device("bt-pad-old").paired)
            compare(device("bt-pad-main").bonded, true, "the others are untouched")
            // A rename changes the alias only.
            Bluetooth.rename("bt-pad-old", "Living room pad")
            tryVerify(() => device("bt-pad-old").name === "Living room pad", 2000)
            compare(device("bt-pad-old").deviceName, "Retro Pad", "the model stays what the device advertises")
            compare(device("bt-pad-old").bonded, false)
            // Forgetting and pairing again bonds it.
            Bluetooth.forget("bt-pad-old")
            tryVerify(() => device("bt-pad-old") === undefined, 2000, "forgotten")
            Bluetooth.mockReveal("bt-pad-old")
            tryVerify(() => device("bt-pad-old") !== undefined, 2000)
            compare(device("bt-pad-old").bonded, false, "found again: not paired, so not bonded")
            Bluetooth.pair("bt-pad-old")
            tryVerify(() => device("bt-pad-old").paired && device("bt-pad-old").bonded, 2000, "pairing again bonds")
        }

        // T-301: a paired device that is not bonded says "Not fully paired" and offers "Pair again" among its
        // actions: Forget, a scan that finds it again, then Pair. Bonded devices have no such row.
        function test_pair_again_for_unbonded() {
            openBluetoothPane()
            compare(find("btRepair_bt-pad-old").visible, false, "a bonded device has no Pair again row")
            tryCompare(find("btDev_bt-pad-old"), "value", "Reconnects automatically")
            Bluetooth.mockSetBonded("bt-pad-old", false)
            tryCompare(find("btRepair_bt-pad-old"), "visible", true)
            tryCompare(find("btDev_bt-pad-old"), "value", "Not fully paired")
            compare(find("btRepair_bt-pad-main").visible, false, "the bonded pad is untouched")
            tryCompare(find("btDev_bt-pad-main"), "value", "Connected · Battery 80%")
            goTo("btRepair_bt-pad-old")
            compare(find("btRepair_bt-pad-old").label, "Pair again Retro Pad")
            compare(find("btRepair_bt-pad-old").value, "Put it in pairing mode first", "it says what the device must do")
            host.answers = []
            keyClick(Qt.Key_Return)
            tryVerify(() => device("bt-pad-old") !== undefined && device("bt-pad-old").paired && device("bt-pad-old").bonded,
                      3000, "forgotten, found again and paired")
            compare(Bluetooth.mockPairCalls(), 1, "one Pair call")
            const ops = host.answers.map(a => a.op + ":" + a.id)
            verify(ops.indexOf("forget:bt-pad-old") >= 0 && ops.indexOf("pair:bt-pad-old") > ops.indexOf("forget:bt-pad-old"),
                   "Forget first, then Pair: " + ops)
            compare(answerFor("pair", "bt-pad-old").status, "ok")
            tryCompare(find("btRepair_bt-pad-old"), "visible", false)
            tryCompare(find("btDev_bt-pad-old"), "value", "Connected")
            tryVerify(() => find("paneBluetooth").activeFocus, 2000, "focus stays in the pane")
            compare(toastTexts().length, 0)
        }

        // T-301: if the scan does not find the device again (it is not in pairing mode) the repair ends with
        // a toast and nothing is paired; the device is just a normal unpaired one to pair by hand.
        function test_pair_again_when_the_device_is_not_found() {
            openBluetoothPane()
            Bluetooth.mockSetBonded("bt-pad-old", false)
            Bluetooth.mockSetSilent("bt-pad-old", true)
            tryCompare(find("btRepair_bt-pad-old"), "visible", true)
            goTo("btRepair_bt-pad-old")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().includes("Could not find it. Put the device in pairing mode and try again."), 3000)
            compare(Bluetooth.mockPairCalls(), 0, "nothing to pair")
            verify(device("bt-pad-old") === undefined, "it is gone from the list")
            tryVerify(() => find("paneBluetooth").activeFocus, 2000, "focus stays in the pane")
            // A later try with the device found: Accept pairs it as any new device.
            Bluetooth.mockSetSilent("bt-pad-old", false)
            scan()
            tryVerify(() => device("bt-pad-old") !== undefined && !device("bt-pad-old").paired, 2000)
            goTo("btDev_bt-pad-old")
            keyClick(Qt.Key_Return)
            tryVerify(() => device("bt-pad-old").paired && device("bt-pad-old").bonded, 3000)
        }

        // T-301: the pane and the pairing screen use one mapping from a status to words (BluetoothText); the
        // controller screen says "controller" where the pane says "device" and nothing else changes.
        function test_status_text_single_mapping() {
            openBluetoothPane()
            const pane = find("paneBluetooth")
            const onb = find("controllerOnboarding")
            verify(pane !== null && onb !== null)
            const words = {
                "pairing-failed": ["Pairing failed. Put the device in pairing mode and try again.",
                                   "Pairing failed. Put the controller in pairing mode again."],
                "timeout": ["The device did not answer.", "The controller did not answer."],
                "unavailable": ["Bluetooth is off.", "Bluetooth is off."],
                "unknown-device": ["That device is no longer available.", "The controller went away."],
                "failed": ["Could not pair the device.", "Could not pair the controller."],
                "invalid": ["Could not pair the device.", "Could not pair the controller."]
            }
            for (const status in words) {
                compare(pane.statusText("pair", status), words[status][0], "the pane, " + status)
                compare(onb.reasonText(status), words[status][1], "the pairing screen, " + status)
                compare(BluetoothText.statusText("pair", status, "device"), words[status][0])
                compare(BluetoothText.statusText("pair", status, "controller"), words[status][1])
            }
            compare(pane.statusText("connect", "failed"), "Could not connect.")
            compare(pane.statusText("disconnect", "failed"), "Could not disconnect.")
            compare(pane.statusText("connect", "unavailable"), onb.reasonText("unavailable"), "the same words where they do not name the device")
        }

        // T-300: DeviceIcons.plain (QML) and pairing::is_format_char (Rust) strip the same characters, and
        // both are held to services/ruya-devices/tests/fixtures/format-chars.txt. Every Basic Multilingual
        // Plane code point (control characters are stripped as a class on both sides) is run through plain().
        function test_format_characters_are_the_services_fixture() {
            const xhr = new XMLHttpRequest()
            xhr.open("GET", Qt.resolvedUrl("../../services/ruya-devices/tests/fixtures/format-chars.txt"), false)
            xhr.send()
            const ranges = []
            for (const raw of xhr.responseText.split("\n")) {
                const line = raw.trim()
                if (line === "" || line.startsWith("#"))
                    continue
                const parts = line.split("-")
                ranges.push([parseInt(parts[0], 16), parseInt(parts[parts.length - 1], 16)])
            }
            verify(ranges.length >= 7, "the fixture was read: " + xhr.responseText.length + " bytes")
            const bad = []
            for (let code = 0; code <= 0xFFFF; ++code) {
                if (code < 32 || (code >= 127 && code <= 159) || (code >= 0xD800 && code <= 0xDFFF))
                    continue
                const listed = ranges.some(r => code >= r[0] && code <= r[1])
                const ch = String.fromCharCode(code)
                const expected = listed ? "a b" : "a" + ch + "b"
                if (DeviceIcons.plain("a" + ch + "b") !== expected)
                    bad.push("U+" + code.toString(16).toUpperCase().padStart(4, "0"))
            }
            compare(bad.join(" "), "", "DeviceIcons.plain and the fixture disagree on these characters")
        }

        function test_a_name_the_service_refuses_says_so() {
            openBluetoothPane()
            Bluetooth.rename("bt-pad-old", "   ")
            tryVerify(() => toastTexts().includes("That name does not work. Try another."), 2000)
            Bluetooth.rename("bt-pad-old", "a" + String.fromCharCode(7) + "b")      // a control character
            tryVerify(() => host.answers.filter(a => a.op === "rename" && a.status === "invalid").length === 2, 2000)
            Bluetooth.rename("bt-flaky", "Pad")                                      // found, not paired
            Bluetooth.rename("nope", "Pad")
            tryVerify(() => toastTexts().includes("Could not rename the controller."), 2000)
            compare(device("bt-pad-old").name, "Retro Pad")
        }

        function test_cancelling_the_forget_confirmation_keeps_the_pairing() {
            openBluetoothPane()
            goTo("btForget_bt-pad-old")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("btForgetConfirm").shown, 2000)
            tryVerify(() => inConfirm("powerCancel").activeFocus, 2000)
            keyClick(Qt.Key_Return)                      // Cancel
            tryVerify(() => !find("btForgetConfirm").shown, 2000)
            tryVerify(() => find("btForget_bt-pad-old").activeFocus, 2000, "focus is back on the row")
            verify(device("bt-pad-old") !== undefined && device("bt-pad-old").paired)
            // B cancels as well
            keyClick(Qt.Key_Return)
            tryVerify(() => find("btForgetConfirm").shown, 2000)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("btForgetConfirm").shown, 2000)
            verify(device("bt-pad-old").paired)
            tryVerify(() => find("btForget_bt-pad-old").activeFocus, 2000)
        }

        function test_forget_moves_focus_to_a_valid_row() {
            openBluetoothPane()
            goTo("btForget_bt-pad-old")
            confirmForget("Retro Pad")
            tryVerify(() => device("bt-pad-old") === undefined, 2000, "the device is gone")
            tryVerify(() => find("btDev_bt-pad-old") === null, 2000, "its row is gone")
            tryVerify(() => find("btForget_bt-pad-old") === null)
            tryVerify(() => find("btForget_bt-soundbar").activeFocus, 2000, "focus moves to the next row")
            verify(find("paneBluetooth").activeFocus)
            confirmForget("Soundbar")                    // the last paired device but one
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
            Bluetooth.mockSetBattery("bt-soundbar", 16)
            tryVerify(() => device("bt-soundbar").battery === 16)
            compare(lowSpy.count, 0, "16 % is not low")
            Bluetooth.mockSetBattery("bt-soundbar", 15)   // exactly the limit: low, like the status cluster's alert
            tryCompare(lowSpy, "count", 1)
            tryVerify(() => toastTexts().includes("Soundbar: battery low (15%)"), 2000)
            Bluetooth.mockSetBattery("bt-soundbar", 14)
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

        function test_pair_a_new_controller_row_opens_the_guided_screen_and_its_window() {
            Bluetooth.mockPairingScript("wait")
            openBluetoothPane()
            goTo("rowBtPairController")
            compare(find("rowBtPairController").label, "Pair a new controller")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("controllerOnboarding").shown, 2000)
            tryCompare(Bluetooth, "controllerPairing", "open")
            compare(Bluetooth.mockPairingStarts(), 1)
            tryVerify(() => find("onbChip_playstation").activeFocus, 2000, "focus is in the screen, on the first family")
            tryVerify(() => host.answers.some(a => a.op === "controller-pairing" && a.status === "ok"))
            compare(toastTexts().length, 0, "no error shown")
            keyClick(Qt.Key_Escape)                      // B closes the screen and the window
            tryVerify(() => !find("controllerOnboarding").shown, 2000)
            tryCompare(Bluetooth, "controllerPairing", "idle")
            tryVerify(() => find("rowBtPairController").activeFocus, 2000, "focus is back on the row")
        }

        function test_a_controller_that_pairs_in_the_window_is_listed() {
            Bluetooth.mockPairingScript("success")
            openBluetoothPane()
            goTo("rowBtPairController")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("onbRow_bt-pad-new") !== null, 3000, "the pad shows in the screen's list")
            tryCompare(find("onbRowState_bt-pad-new"), "text", "Connected, remembered · A: try its buttons")
            tryVerify(() => device("bt-pad-new") !== undefined && device("bt-pad-new").paired, 2000)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("btDev_bt-pad-new") !== null, 2000, "the pad is a row of the pane")
            tryVerify(() => find("rowBtPairController").activeFocus, 2000, "focus is back on the row")
            compare(toastTexts().length, 0)
        }

        function test_a_timed_out_window_says_so_and_can_be_opened_again() {
            Bluetooth.mockPairingScript("timeout")
            openBluetoothPane()
            goTo("rowBtPairController")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("onboardingSearchAgain").visible, 3000)
            keyClick(Qt.Key_Return)                      // again (focus is on a family chip)
            tryVerify(() => Bluetooth.mockPairingStarts() === 2)
            tryVerify(() => find("onboardingSearchAgain").visible, 3000)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("controllerOnboarding").shown, 2000)
        }

        function test_a_rejected_device_is_toasted_and_the_window_stays_open() {
            Bluetooth.mockPairingScript("rejected")
            openBluetoothPane()
            goTo("rowBtPairController")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().indexOf("A device that is not a controller was ignored.") >= 0, 3000)
            tryVerify(() => find("onboardingHintIgnored").visible, 2000, "and the screen says so")
            compare(Bluetooth.controllerPairing, "open")
        }

        function test_leaving_the_pane_closes_the_window() {
            Bluetooth.mockPairingScript("wait")
            openBluetoothPane()
            goTo("rowBtPairController")
            keyClick(Qt.Key_Return)
            tryCompare(Bluetooth, "controllerPairing", "open")
            tryVerify(() => find("controllerOnboarding").shown)
            // The pane goes away under the open screen without B (another category is selected from
            // code, as a stray event could): the screen and the window must go with it. The pane is
            // only hidden, not destroyed, so nothing else would close them.
            find("categoryList").currentIndex = 1
            tryVerify(() => !find("paneBluetooth").visible, 3000, "the pane is hidden")
            tryVerify(() => !find("controllerOnboarding").shown, 2000, "the screen closed with it")
            tryCompare(Bluetooth, "controllerPairing", "idle")
        }

        function test_B_closes_the_screen_and_the_window_and_the_pane_stays() {
            Bluetooth.mockPairingScript("wait")
            openBluetoothPane()
            goTo("rowBtPairController")
            keyClick(Qt.Key_Return)
            tryCompare(Bluetooth, "controllerPairing", "open")
            keyClick(Qt.Key_Escape)
            tryCompare(Bluetooth, "controllerPairing", "idle")
            tryVerify(() => find("rowBtPairController").activeFocus, 2000)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000)
            keyClick(Qt.Key_Up)                           // Network: the Bluetooth pane is hidden
            tryVerify(() => !find("paneBluetooth").visible, 2000)
            tryCompare(Bluetooth, "controllerPairing", "idle")
        }

        // A name a device chose is text, never markup (T-260): in the toast and in the pane's rows.
        function test_a_pad_named_with_markup_is_shown_as_it_is() {
            Bluetooth.mockGamepad(true, "usb-7", "<b>x</b>", "", "usb")
            tryVerify(() => toastTexts().some(t => t.startsWith("<b>x</b> connected")), 4000)
            tryVerify(() => find("toastText") !== null, 2000)
            compare(find("toastText").textFormat, Text.PlainText)
            Bluetooth.mockSetName("bt-pad-old", "<font size=7>big</font>")
            openBluetoothPane()
            tryVerify(() => find("btDev_bt-pad-old") !== null)
            tryCompare(findChild(find("btDev_bt-pad-old"), "label"), "textFormat", Text.PlainText)
            compare(find("btDev_bt-pad-old").label, "<font size=7>big</font>")
        }

        // T-260: the Shell hosts the toasts and tells them about every key, so "disconnected" is for a pad in use.
        function test_the_shell_announces_a_pad_and_its_departure_after_use() {
            Bluetooth.mockGamepad(true, "usb-1", "Wireless Controller", "playstation", "usb")
            tryVerify(() => toastTexts().some(t => t.startsWith("PlayStation controller connected")), 4000)
            keyClick(Qt.Key_Down)                         // somebody used the console
            Bluetooth.mockGamepad(false, "usb-1", "Wireless Controller", "playstation", "usb")
            tryVerify(() => toastTexts().includes("PlayStation controller disconnected"), 4000)
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

        // T-199: the icon of every kind and controller family, in the pane and in toasts.
        function rowIcon(id) {
            const row = find("btDev_" + id)
            return row ? findChild(row, "rowIcon") : null
        }

        function chipGlyph(id) {
            const chip = find("batteryChip_" + id)
            return chip ? findChild(chip, "batteryKindIcon").name : ""
        }

        // T-260 (owner bug, Dell 0.0.50): the same device had a different glyph in the status cluster
        // than in Settings. One table (DeviceIcons) now serves the chip, the pane's rows (the paired
        // list), the toasts and the pairing screens; this walks every kind and family through all of
        // them. A family-less Batteries record would give the generic pad here and fail the first row.
        function test_one_glyph_per_device_everywhere() {
            const table = [
                ["controller", "playstation", "bt-gallery-ps", "pad_playstation"],
                ["controller", "xbox", "bt-gallery-xbox", "pad_xbox"],
                ["controller", "nintendo", "bt-gallery-switch", "pad_switch"],
                ["controller", "8bitdo", "bt-gallery-8bitdo", "sports_esports"],
                ["controller", "", "bt-gallery-pad", "sports_esports"],
                ["headset", "", "bt-gallery-headset", "headphones"],
                ["speaker", "", "bt-gallery-speaker", "speaker"],
                ["keyboard", "", "bt-gallery-keyboard", "keyboard"],
                ["mouse", "", "bt-gallery-mouse", "mouse"],
            ]
            Bluetooth.mockPopulate()
            tryVerify(() => device("bt-gallery-8bitdo") !== undefined, 2000)
            openBluetoothPane()
            for (let i = 0; i < table.length; ++i) {
                const [kind, family, id, glyph] = table[i]
                compare(DeviceIcons.iconFor(kind, family), glyph, "the table: " + id)
                // the paired list in Settings
                tryVerify(() => rowIcon(id) !== null, 2000, id + " has a row")
                compare(rowIcon(id).name, glyph, "pane row of " + id)
                // the chip in the status cluster, for a Batteries record of the same kind and family
                const bat = "bat-" + i
                Batteries.mockClear()
                Batteries.mockSet(bat, 50, "discharging", kind, "Device " + i, family)
                tryVerify(() => chipGlyph(bat) === glyph, 2000, "chip of " + id + ": " + chipGlyph(bat))
                // the low-battery toast (controllers: Batteries; the other kinds: Bluetooth)
                clearToasts()
                if (kind === "controller")
                    Batteries.mockSet(bat, 10, "discharging", kind, "Device " + i, family)
                else
                    Bluetooth.mockSetBattery(id, 10)
                tryVerify(() => Notifications.model.count === 1 && Notifications.model.get(0).iconName === glyph, 3000,
                          "low-battery toast of " + id)
                // the connected toast and the pad's glyph there (controllers)
                if (kind === "controller") {
                    clearToasts()
                    Bluetooth.mockGamepad(true, id, "Pad", family, "bluetooth")
                    tryVerify(() => Notifications.model.count === 1 && Notifications.model.get(0).iconName === glyph, 4000,
                              "connected toast of " + id)
                }
            }
            Batteries.mockReset()
        }

        function test_every_kind_and_family_has_its_icon_in_the_pane() {
            Bluetooth.mockPopulate()
            tryVerify(() => device("bt-gallery-gizmo") !== undefined, 2000)
            openBluetoothPane()
            const expected = [
                ["bt-gallery-ps", "pad_playstation", "PlayStation controller"],
                ["bt-gallery-xbox", "pad_xbox", "Xbox controller"],
                ["bt-gallery-switch", "pad_switch", "Nintendo controller"],
                ["bt-gallery-pad", "sports_esports", "Controller"],
                ["bt-gallery-headset", "headphones", "Headset"],
                ["bt-gallery-speaker", "speaker", "Speaker"],
                ["bt-gallery-keyboard", "keyboard", "Keyboard"],
                ["bt-gallery-mouse", "mouse", "Mouse"],
                ["bt-gallery-phone", "smartphone", "Phone"],
                ["bt-gallery-other", "bluetooth", "Bluetooth device"],
                ["bt-gallery-gizmo", "bluetooth", "Bluetooth device"],   // a kind no shell knows: the generic glyph
                ["bt-soundbar", "speaker", "Speaker"],                   // the service's word for a sound bar
                ["bt-pad-main", "sports_esports", "Controller"],         // no family told: the generic gamepad
            ]
            for (const [id, icon, word] of expected) {
                tryVerify(() => rowIcon(id) !== null, 2000, id + " has an icon")
                compare(rowIcon(id).name, icon, id)
                verify(rowIcon(id).visible, id + " draws it")
                verify(rowIcon(id).known, id + " is a glyph the font has")
                const row = find("btDev_" + id)
                verify(row.Accessible.name.startsWith(row.label + ", " + word + ", "),
                       id + " is named: " + row.Accessible.name)
            }
            // The state still follows the kind in the name.
            compare(find("btDev_bt-gallery-ps").Accessible.name, "DualSense, PlayStation controller, Connected")
        }

        function test_rows_of_the_other_panes_have_no_icon() {
            openBluetoothPane()
            compare(find("rowBtAdd").hasIcon, false)
            compare(find("rowBtPower").hasIcon, false)
        }

        function test_a_device_toast_carries_the_devices_icon() {
            Bluetooth.mockPopulate()
            tryVerify(() => device("bt-gallery-headset") !== undefined, 2000)
            Bluetooth.mockSetBattery("bt-gallery-headset", 12)
            tryCompare(lowSpy, "count", 1)
            compare(lowSpy.signalArguments[0][3], "headset", "the signal says what the device is")
            compare(lowSpy.signalArguments[0][4], "", "and its family")
            tryVerify(() => toastTexts().includes("WH-1000XM4: battery low (12%)"), 2000)
            tryVerify(() => find("toastIcon") !== null && find("toastIcon").visible, 2000)
            compare(find("toastIcon").name, "headphones")
            compare(Notifications.model.get(0).iconName, "headphones")
        }

        function test_a_toast_without_an_icon_name_shows_its_text_glyph() {
            Notifications.show("Plain", "info", "i")
            tryVerify(() => Notifications.model.count === 1)
            compare(Notifications.model.get(0).iconName, "")
            tryVerify(() => find("toastIcon") !== null)
            compare(find("toastIcon").visible, false)
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openBluetoothPane()
            goTo("rowBtPairController")
            keyClick(Qt.Key_Return)
            tryCompare(Bluetooth, "controllerPairing", "open")
            Bluetooth.mockReveal("bt-flaky")
            tryVerify(() => find("onbRow_bt-flaky") !== null, 2000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/26b-settings-bluetooth-pair-controller.png")
            keyClick(Qt.Key_Escape)
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

        // T-301: a paired device that is not bonded, with its "Pair again" action under it.
        function test_zz_pair_again_screenshot() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Bluetooth.mockSetBonded("bt-pad-old", false)
            openBluetoothPane()
            tryVerify(() => find("btRepair_bt-pad-old").visible, 2000)
            goTo("btRepair_bt-pad-old")
            wait(600)
            grabImage(tc.shell)                          // the first grab of a window makes it lay the pane out
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/bt-pair-again.png")
        }

        // T-199: the pane with a device of every kind and family, and a toast that names a device.
        function test_zz_device_icon_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Bluetooth.mockPopulate()
            tryVerify(() => device("bt-gallery-gizmo") !== undefined, 2000)
            openBluetoothPane()
            goTo("btDev_bt-gallery-ps")
            wait(600)
            grabImage(tc.shell)                          // the first grab of a window makes it lay the pane out
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/bt-icons-1-controllers.png")
            goTo("btDev_bt-gallery-mouse")
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/bt-icons-2-others.png")
            Bluetooth.mockSetBattery("bt-gallery-headset", 12)
            tryVerify(() => Notifications.model.count === 1, 2000)
            grabImage(tc.shell)                          // a real window lays the toast list out on its next frame
            tryVerify(() => find("toastIcon") !== null && find("toastIcon").visible, 2000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/bt-icons-3-toast.png")
        }
    }
}
