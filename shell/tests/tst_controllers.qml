import QtQuick
import QtTest
import RuyaShell

// Settings -> Controllers, the controller page and the Button test (RUY-39 / T-368) against the
// Input mock's three pads (a DualSense over Bluetooth, an Xbox pad over USB, a Pro Controller over
// Bluetooth whose motion node does not open). Signs in as "Ada" (p2, no PIN). Each test resets the
// mock's pads.
Item {
    id: host
    width: 1920
    height: 1080

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "Controllers"
        when: windowShown

        property Shell shell: null

        readonly property string ds: "bluetooth-054c-0ce6-3f2a9c41d0b7"
        readonly property string xbox: "usb-045e-0b12-8e01c2d4a9f3"
        readonly property string pro: "bluetooth-057e-2009-b7c0e1f2a3d4"

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            host.width = 1920
            host.height = 1080
            DeviceSettings.language = "en"
            Input.mockResetDevices()
            Input.mockResetProfiles()
            Input.mockActiveInput("", "")
            tryVerify(() => Input.devicesState === "ok" && Input.devices.length === 3)
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
            DeviceSettings.language = "en"
            DeviceSettings.theme = "dreamglass"
        }

        function clearToasts() {
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text + " / " + Notifications.model.get(i).detail)
            return out
        }

        // Settings on Controllers, the focus in the pane.
        function openPane() {
            tc.shell.openPage("settings", { category: "controllers" })
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000)
            compare(find("page_settings").current.key, "controllers")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneControllers").activeFocus, 2000, "the pane has the focus")
            return find("paneControllers")
        }

        function padRow(id) { return find("pad_" + id) }

        function hintVerbs() {
            return find("page_settings").hints.map(h => h.button + " " + h.text).join("|")
        }

        // The pane's focusable rows, top to bottom, by objectName.
        function rowNames() {
            return find("paneControllers").focusableRows().map(r => r.objectName)
        }

        function openController(id) {
            const pane = openPane()
            for (let i = 0; i < 6 && !padRow(id).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(padRow(id).activeFocus, "on the pad row")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controller")
            tryVerify(() => find("rowButtonTest") !== null && find("rowButtonTest").activeFocus, 2000,
                      "the Button test row has the focus")
            return pane
        }

        function openTest(id) {
            openController(id)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "buttonTest")
            tryVerify(() => find("buttonTestKeys").activeFocus, 2000, "the test takes every key")
            tryVerify(() => Input.mockTestRunning(id), 2000, "the stream starts when the page opens")
        }

        // ---- the pane ------------------------------------------------------------------------------------------

        // The capability rows of the controller page, top to bottom.
        function capRows() {
            return findChild(find("page_controller"), "controllerBody").focusableRows().filter(r => r.objectName.startsWith("cap_"))
        }

        // RUY-513: the kinds of the pane's rows and of the controller page's.
        function test_row_kinds() {
            openPane()
            compare(padRow(ds).kind, "page")
            compare(find("rowControlsInGames").kind, "page")
            compare(find("rowPadsPair").kind, "action")
            compare(find("rowPadsRetry").kind, "action")
            compare(find("rowControlsInGamesLast").kind, "page")
            compare(hintVerbs(), "A Open|B Back", "a pad row opens its page")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controller")
            tryVerify(() => find("rowButtonTest") !== null && find("rowButtonTest").activeFocus, 2000)
            compare(find("rowButtonTest").kind, "page")
            compare(findChild(find("page_controller"), "rowControlsInGames").kind, "page")
            const heading = find("capsHeading")
            verify(heading !== null && heading.visible, "the heading is there")
            compare(heading.text, "What it can do")
            verify(heading.focusable === undefined, "a group label is never focusable")
            verify(heading.Accessible.role === Accessible.Heading)
            for (const name of ["cap_buttons", "cap_gyro"])
                compare(find(name).kind, "info", name)
            // The last fact of the run has no hairline (04 section 5), also after the rows came late and in Turkish.
            tryVerify(() => capRows().length > 1)
            tryCompare(capRows()[capRows().length - 1], "ruleBelow", false)
            verify(capRows().slice(0, -1).every(r => r.ruleBelow), "the others have one")
            DeviceSettings.language = "tr"
            wait(100)
            tryCompare(capRows()[capRows().length - 1], "ruleBelow", false)
            DeviceSettings.language = "en"
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("cap_buttons").activeFocus, "Down from Controls in games skips the heading")
            compare(find("page_controller").hints.map(h => h.button + " " + h.text).join("|"), "B Back")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
        }

        function test_the_list_shows_every_connected_pad() {
            openPane()
            compare(rowNames(), ["pad_" + ds, "pad_" + pro, "pad_" + xbox, "rowConfirmButton", "rowControlsInGames", "rowPadsPair"],
                    "sorted by name, then the Confirm button (RUY-40), Controls in games (RUY-465) and Pair")
            verify(padRow(ds).activeFocus, "focus enters on the first row")
            compare(padRow(ds).label, "DualSense Wireless Controller")
            compare(padRow(ds).detail, "Bluetooth · Battery 62 %, charging")
            compare(padRow(pro).detail, "Bluetooth · Battery 12 %, low")
            compare(padRow(xbox).detail, "USB · Battery not reported")
            compare(padRow(ds).value, "", "no player in the record: no value")
            compare(padRow(ds).iconName, "pad_dualsense", "the record names the model: its own silhouette")
            compare(padRow(ds).Accessible.name,
                    "DualSense Wireless Controller, PlayStation controller, Bluetooth · Battery 62 %, charging")
            compare(hintVerbs(), "A Open|B Back")
            keyClick(Qt.Key_Down)
            verify(padRow(pro).activeFocus)
            keyClick(Qt.Key_Down)
            verify(padRow(xbox).activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("rowConfirmButton").activeFocus)
            compare(hintVerbs(), "Left/Right Change|A Next|B Back", "the Confirm button is a choice row (RUY-40)")
            keyClick(Qt.Key_Down)
            verify(find("rowControlsInGames").activeFocus)
            compare(hintVerbs(), "A Open|B Back", "Controls in games opens a page")
            keyClick(Qt.Key_Down)
            verify(find("rowPadsPair").activeFocus)
            compare(hintVerbs(), "A Select|B Back")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Back returns to the category list")
            compare(find("page_settings").current.key, "controllers", "on Controllers")
        }

        function test_the_detail_line_is_one_line_under_the_label() {
            openPane()
            const row = padRow(ds)
            const label = findChild(row, "label")
            const detail = findChild(row, "detail")
            verify(detail.visible)
            compare(detail.font.pixelSize, Theme.typeCaption * tc.shell.u)
            verify(detail.y >= label.y + label.height, "under the label")
            // The pair is centred in the row.
            const top = label.y
            const bottom = detail.y + detail.height
            verify(Math.abs((top + bottom) / 2 - row.height / 2) <= 1, "centred: " + top + ".." + bottom + " in " + row.height)
            verify(detail.x + detail.width <= row.width, "inside the row")
        }

        // RUY-491: the record's model names the silhouette (the pane's row and the controller page's glyph);
        // a pad with no model, or one this shell has no glyph for, is drawn as its family's; one with
        // neither is the generic gamepad.
        function test_a_pad_is_drawn_as_its_model_else_its_family() {
            const wiiu = "bluetooth-057e-0330-c1d2e3f4a5b6"
            Input.mockAddDevice({ id: wiiu, name: "Nintendo RVL-CNT-01-UC", family: "nintendo", model: "wiiu_pro",
                                  connection: "bluetooth", battery: 80 })
            const newer = "usb-1234-0001-aaaaaaaaaaaa"
            Input.mockAddDevice({ id: newer, name: "Pad from the future", family: "xbox", model: "no_such_model",
                                  connection: "usb" })
            const plain = "usb-1234-0002-aaaaaaaaaaaa"
            Input.mockAddDevice({ id: plain, name: "Plain pad", family: "generic", connection: "usb" })
            tryVerify(() => Input.devices.length === 6)
            openPane()
            tryVerify(() => padRow(plain) !== null, 2000)
            compare(padRow(ds).iconName, "pad_dualsense")
            compare(padRow(wiiu).iconName, "pad_wiiu_pro", "its own silhouette, not the Switch Pro of its family")
            compare(padRow(newer).iconName, "pad_xbox_series", "a model this shell does not know: the family's")
            compare(padRow(plain).iconName, "sports_esports", "no model, no family: the generic gamepad")
            for (let i = 0; i < 6 && !padRow(wiiu).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(padRow(wiiu).activeFocus, "on the pad row")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controller")
            compare(find("controllerGlyph").name, "pad_wiiu_pro", "the controller page draws the same silhouette")
        }

        function test_a_player_shows_when_the_record_has_one() {
            Input.mockAddDevice({ id: "usb-2dc8-6001-aaaaaaaaaaaa", name: "8BitDo Pro 2", family: "generic",
                                  connection: "usb", slot: 2 })
            openPane()
            tryVerify(() => padRow("usb-2dc8-6001-aaaaaaaaaaaa") !== null, 2000)
            compare(padRow("usb-2dc8-6001-aaaaaaaaaaaa").value, "Player 2")
            compare(rowNames()[0], "pad_usb-2dc8-6001-aaaaaaaaaaaa", "a player sorts first")
        }

        function test_a_battery_change_updates_the_row_in_place() {
            openPane()
            keyClick(Qt.Key_Down)
            verify(padRow(pro).activeFocus)
            const before = padRow(pro)
            Input.mockAddDevice({ id: pro, name: "Pro Controller", family: "nintendo", connection: "bluetooth", battery: 50 })
            tryCompare(padRow(pro), "detail", "Bluetooth · Battery 50 %")
            verify(padRow(pro) === before, "the same row")
            verify(padRow(pro).activeFocus, "the focus did not move")
        }

        function test_a_focused_pad_that_goes_hands_the_focus_to_the_row_before() {
            openPane()
            keyClick(Qt.Key_Down)
            verify(padRow(pro).activeFocus)
            Input.mockRemoveDevice(pro)
            tryVerify(() => padRow(pro) === null, 2000)
            tryVerify(() => padRow(ds).activeFocus, 2000, "the row before it")
            // The first row going: the next one.
            Input.mockRemoveDevice(ds)
            tryVerify(() => padRow(ds) === null, 2000)
            tryVerify(() => padRow(xbox).activeFocus, 2000, "the row now at its place")
        }

        function test_no_pad_says_so_and_offers_pairing() {
            openPane()
            for (const id of [ds, xbox, pro])
                Input.mockRemoveDevice(id)
            tryVerify(() => find("rowPadsNone").visible, 2000)
            compare(find("rowPadsNone").label, "No controllers connected.")
            verify(!find("rowPadsNone").enabled, "an unavailable line takes no focus")
            tryVerify(() => find("rowPadsPair").activeFocus, 2000, "Pair a new controller has the focus")
            compare(rowNames(), ["rowPadsPair", "rowControlsInGamesLast"], "Pair first, then Controls in games (RUY-465)")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("controllerOnboardingControllers") !== null
                            && find("controllerOnboardingControllers").shown, 2000, "the pairing screen opens")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("controllerOnboardingControllers").shown, 2000)
            tryVerify(() => find("rowPadsPair").activeFocus, 2000, "back on Pair")
        }

        function test_a_failed_list_offers_try_again() {
            openPane()
            for (let i = 0; i < 5; ++i)
                keyClick(Qt.Key_Down)
            verify(find("rowPadsPair").activeFocus, "on Pair, which stays")
            Input.mockListFail(true)
            Input.refreshDevices()
            tryCompare(Input, "devicesState", "failed")
            tryVerify(() => find("rowPadsFailed").visible, 2000)
            compare(find("rowPadsFailed").label, "Controllers can't be read right now.")
            verify(!padRow(ds).visible, "no stale pad rows")
            tryVerify(() => find("rowPadsRetry").activeFocus, 2000, "Try again has the focus")
            compare(rowNames(), ["rowPadsRetry", "rowConfirmButtonUnavailable", "rowControlsInGames", "rowPadsPair"],
                    "the Confirm button and Controls in games stay, dimmed (RUY-40, RUY-465)")
            compare(find("rowConfirmButtonUnavailable").value, "Not available")
            verify(find("rowConfirmButtonUnavailable").dimmed)
            keyClick(Qt.Key_Return)                      // still failing
            tryCompare(Input, "devicesState", "failed")
            verify(find("rowPadsRetry").activeFocus)
            Input.mockListFail(false)
            keyClick(Qt.Key_Return)
            tryCompare(Input, "devicesState", "ok")
            tryVerify(() => padRow(ds).visible && !find("rowPadsFailed").visible, 2000)
            tryVerify(() => find("paneControllers").focusableRows().some(r => r.activeFocus), 2000, "a row has the focus")
        }

        function test_the_hub_row_opens_controllers() {
            // The Hub's "Controller settings" (tst_hub_controllers) asks for this category.
            tc.shell.openPage("settings", { category: "controllers" })
            tryCompare(tc.shell, "currentPage", "settings")
            compare(find("page_settings").labelFor("bluetooth"), "Bluetooth")
            compare(find("page_settings").labelFor("controllers"), "Controllers")
            const keys = find("page_settings").categories.map(c => c.key)
            compare(keys.indexOf("controllers"), keys.indexOf("bluetooth") + 1, "directly after Bluetooth")
        }

        // ---- the controller page ---------------------------------------------------------------------------------

        function test_the_controller_page_lists_what_the_pad_can_do() {
            openController(ds)
            compare(find("page_controller").title, "DualSense Wireless Controller")
            compare(find("page_controller").hints.map(h => h.button + " " + h.text).join("|"), "A Open|B Back")
            tryVerify(() => find("cap_buttons") !== null, 2000, "the capabilities arrived")
            compare(find("cap_buttons").value, "Works")
            compare(find("cap_analog_triggers").value, "Works")
            compare(find("cap_rumble").value, "Works")
            compare(find("cap_gyro").value, "Not passed to games")
            compare(find("cap_touchpad").value, "Not passed to games")
            compare(find("cap_adaptive_triggers").value, "Not supported yet")
            compare(find("cap_microphone").value, "Not supported yet")
            verify(find("cap_battery") === null, "the battery is in the left column")
            verify(find("cap_sticks") === null && find("cap_dpad") === null, "one row for buttons and sticks")
            verify(find("cap_trigger_rumble") === null, "what the model does not have has no row")
            verify(find("capsHeading").visible)
            keyClick(Qt.Key_Down)
            verify(findChild(find("page_controller"), "rowControlsInGames").activeFocus, "Controls in games after Button test (RUY-465)")
            compare(find("page_controller").hints.map(h => h.button + " " + h.text).join("|"), "A Open|B Back")
            keyClick(Qt.Key_Down)
            verify(find("cap_buttons").activeFocus, "the capability rows take the focus, for scrolling")
            compare(find("page_controller").hints.map(h => h.button + " " + h.text).join("|"), "B Back")
            keyClick(Qt.Key_Return)                      // read-only: nothing happens
            compare(tc.shell.currentPage, "controller")
            verify(find("cap_buttons").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => padRow(ds).activeFocus, 2000, "Back lands on that pad's row")
        }

        function test_a_node_that_does_not_open_is_not_available_now() {
            openController(pro)
            tryVerify(() => find("cap_gyro") !== null, 2000)
            compare(find("cap_gyro").value, "Not available now")
            compare(find("cap_accelerometer").value, "Not available now")
            verify(find("cap_analog_triggers") === null, "digital triggers: no analog row")
            compare(find("cap_player_leds").value, "Not supported yet")
        }

        function test_the_pad_going_closes_the_controller_page() {
            openController(pro)
            Input.mockRemoveDevice(pro)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => padRow(ds).activeFocus, 2000, "focus on the nearest pad row")
            tryVerify(() => toastTexts().includes("Controller disconnected / Pro Controller"), 2000, toastTexts().join(";"))
        }

        function test_a_pad_going_after_its_page_was_left_keeps_settings_open() {
            openController(pro)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            Input.mockRemoveDevice(pro)
            tryVerify(() => padRow(pro) === null, 2000)
            wait(Theme.pageMs + 100)
            compare(tc.shell.currentPage, "settings", "the closed controller page does not close Settings")
            verify(find("paneControllers").activeFocus, "the pane keeps the focus")
            verify(!toastTexts().some(t => t.startsWith("Controller disconnected")), "no toast for a page that is gone")
        }

        // ---- the button test ---------------------------------------------------------------------------------------

        function test_the_button_test_lights_the_pressed_control() {
            openTest(ds)
            const south = find("padCtl_south")
            compare(south.look, "idle")
            compare(find("raw_last").text, "None")
            compare(find("raw_source").text, "—")
            Input.mockTestInput(ds, "south", 1, "raw:pad:1:304")
            tryCompare(south, "look", "held")
            compare(south.color, Theme.primaryFill)
            compare(find("raw_last").text, "Cross (south)")
            compare(find("raw_source").text, "raw:pad:1:304")
            Input.mockTestInput(ds, "south", 0, "raw:pad:1:304")
            tryCompare(south, "look", "tried")
            compare(south.color, Theme.selectedFill)
            compare(find("padCtl_north").look, "idle", "only what was pressed")
            // A stick moves its dot and shows its raw values.
            const dot = find("padStickDot_left")
            const rest = dot.x
            Input.mockTestInput(ds, "left_x", 32767, "raw:pad:3:0")
            Input.mockTestInput(ds, "left_y", -1204, "raw:pad:3:1")
            tryVerify(() => dot.x > rest + 40 * tc.shell.u, 2000, "the dot follows the axis")
            compare(find("raw_left").text, "x 32 767  y −1 204")
            // A trigger fills its track.
            Input.mockTestInput(ds, "right_trigger", 24250, "raw:pad:3:5")
            tryVerify(() => find("padTrackFill_right_trigger").height > 0, 2000)
            compare(find("raw_triggers").text, "0 · 24 250")
            compare(find("padCtl_right_trigger").look, "held")
            // A raw input without a normal name is shown by its source.
            Input.mockTestInput(ds, "raw:pad:1:704", 1, "raw:pad:1:704")
            tryCompare(find("raw_last"), "text", "raw:pad:1:704")
            verify(find("buttonTestKeys").activeFocus, "the focus stayed on the test")
        }

        function test_a_wii_u_pro_gets_its_layout_and_its_minus_plus_and_home_light() {
            const wiiu = "bluetooth-057e-0330-c1d2e3f4a5b6"
            Input.mockAddDevice({ id: wiiu, name: "Nintendo Wii Remote Pro Controller", family: "nintendo",
                                  layout: "nintendo-wiiu", connection: "bluetooth", battery: 80 })
            tryVerify(() => Input.devices.length === 4)
            openTest(wiiu)
            const d = find("padDiagram")
            compare(d.kind, "nintendo-wiiu")
            for (const [input, word] of [["select", "−"], ["start", "+"], ["guide", "Home"]]) {
                const k = find("padCtl_" + input)
                compare(k.children.filter(c => c.text !== undefined)[0].text, word)
                Input.mockTestInput(wiiu, input, 1, "raw:pad:1:0")
                tryCompare(k, "look", "held")
            }
            Input.mockTestInput(wiiu, "dpad_left", 1, "raw:pad:1:0")
            tryCompare(find("padCtl_dpad_left"), "look", "held")
            Input.mockTestInput(wiiu, "left_trigger", 32767, "raw:pad:1:0")
            tryCompare(find("padCtl_left_trigger"), "look", "held")
            compare(find("padTrackFill_left_trigger").height, 0, "ZL is a button: its track stays empty")
        }

        function test_a_switch_pro_takes_the_nintendo_drawing() {
            openTest(pro)
            compare(find("padDiagram").kind, "nintendo")
            compare(find("padCtl_guide").children.filter(c => c.text !== undefined)[0].text, "Home")
        }

        function test_back_twice_leaves_the_test() {
            openTest(ds)
            keyClick(Qt.Key_Escape)
            compare(tc.shell.currentPage, "buttonTest", "one Back press does not leave")
            compare(find("testMessage").text, "Press B again to leave.")
            verify(find("buttonTestKeys").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controller")
            tryVerify(() => find("rowButtonTest").activeFocus, 2000, "back on Button test")
            tryVerify(() => !Input.mockTestRunning(ds), 2000, "the stream stops when the page closes")
        }

        function test_two_slow_back_presses_do_not_leave() {
            openTest(ds)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("testMessage").text.startsWith("Press any button"), 3000, "the wait for the second press ends")
            keyClick(Qt.Key_Escape)
            compare(tc.shell.currentPage, "buttonTest", "the second press came after 1 s")
            verify(find("buttonTestKeys").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controller")
        }

        function test_holding_back_for_a_second_leaves_the_test() {
            openTest(ds)
            keyPress(Qt.Key_Escape)
            wait(500)
            compare(tc.shell.currentPage, "buttonTest", "not before 1 s")
            tryCompare(tc.shell, "currentPage", "controller", 2000)
            keyRelease(Qt.Key_Escape)
            tryVerify(() => find("rowButtonTest").activeFocus, 2000, "back on Button test")
            tryVerify(() => !Input.mockTestRunning(ds), 2000)
        }

        function test_other_keys_do_not_leave() {
            openTest(ds)
            for (const key of [Qt.Key_Left, Qt.Key_Up, Qt.Key_Return, Qt.Key_PageDown, Qt.Key_Menu, Qt.Key_Backspace])
                keyClick(key)
            compare(tc.shell.currentPage, "buttonTest")
            verify(find("buttonTestKeys").activeFocus)
        }

        function test_two_idle_minutes_end_the_test() {
            openTest(ds)
            Input.mockEndTest(ds, "idle")
            tryCompare(tc.shell, "currentPage", "controller")
            tryVerify(() => find("rowButtonTest").activeFocus, 2000)
            tryVerify(() => toastTexts().includes("Button test ended / No input for 2 minutes."), 2000, toastTexts().join(";"))
        }

        function test_the_pad_going_closes_the_test_and_its_page() {
            openTest(pro)
            Input.mockRemoveDevice(pro)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => padRow(ds).activeFocus, 2000, "focus on the nearest pad row")
            tryVerify(() => toastTexts().includes("Controller disconnected / Pro Controller"), 2000, toastTexts().join(";"))
            compare(toastTexts().filter(t => t.startsWith("Controller disconnected")).length, 1, "one toast")
        }

        function test_the_test_needs_the_shell_route() {
            // Another route (the Hub over a game): the service refuses; back in "shell" it starts again.
            openTest(ds)
            Input.setRoute("overlay", "", "", "p2")
            tryVerify(() => !Input.mockTestRunning(ds), 2000, "a route change ends the test")
            compare(tc.shell.currentPage, "buttonTest", "the page stays")
            Input.setRoute("shell", "", "", "p2")
            tryVerify(() => Input.mockTestRunning(ds), 2000, "started again in the shell")
        }

        // ---- the Confirm button (RUY-40) ---------------------------------------------------------------------------

        function confirmRow() { return find("rowConfirmButton") }

        function openConfirm() {
            openPane()
            for (let i = 0; i < 5 && !confirmRow().activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(confirmRow().activeFocus, "on the Confirm button row")
            return confirmRow()
        }

        function test_the_confirm_row_applies_at_once_and_keeps_the_focus() {
            const row = openConfirm()
            compare(row.label, "Confirm button")
            compare(row.currentLabel, "As on the controller")
            compare(hintVerbs(), "Left/Right Change|A Next|B Back")
            Input.mockClearProfileCalls()
            keyClick(Qt.Key_Right)
            compare(row.currentLabel, "Bottom")
            compare(Input.confirmButton, "south")
            tryCompare(Input, "confirmButton", "south")
            compare(Input.mockConfirmButton("p2"), "south", "the service holds it, per console profile")
            const calls = Input.mockProfileCalls().filter(c => c.method === "SetConfirmButton")
            compare(calls.length, 1)
            compare(calls[0].args.profile, "p2")
            compare(calls[0].args.mode, "south")
            keyClick(Qt.Key_Right)
            compare(row.currentLabel, "Right")
            compare(Input.mockConfirmButton("p2"), "east")
            keyClick(Qt.Key_Return)                      // Accept = Next, as on a ChoiceRow
            compare(row.currentLabel, "As on the controller")
            compare(Input.mockConfirmButton("p2"), "family")
            verify(row.activeFocus, "the row keeps the focus while its value changes")
            keyClick(Qt.Key_Left)
            compare(row.currentLabel, "Right")
            verify(row.activeFocus)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Back returns to the category list")
        }

        function test_the_note_names_the_buttons_of_the_active_pad() {
            const row = openConfirm()
            verify(find("confirmNoteKeyboard").visible, "no pad has pressed yet: the keyboard sentence")
            compare(find("confirmNoteKeyboard").text, "On the keyboard: Enter confirms, Esc goes back.")
            verify(!find("confirmNoteAccept").visible)
            Input.mockActiveInput(ds, "playstation")
            tryCompare(Input, "activeFamily", "playstation")
            compare(Input.activeDevice, ds)
            verify(find("confirmNoteAccept").visible && !find("confirmNoteKeyboard").visible)
            compare(find("confirmNoteAccept").button, "A", "position letters: south")
            compare(find("confirmNoteBack").button, "B")
            compare(row.Accessible.name.indexOf("Confirm button"), 0)
            verify(row.Accessible.name.endsWith("On this controller: A confirms, B goes back."), row.Accessible.name)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)                       // Right: Circle confirms on a PlayStation pad
            compare(row.currentLabel, "Right")
            compare(find("confirmNoteAccept").button, "B")
            compare(find("confirmNoteBack").button, "A")
            keyClick(Qt.Key_Left)                        // Bottom
            keyClick(Qt.Key_Left)                        // As on the controller
            Input.mockActiveInput(pro, "nintendo")
            tryCompare(find("confirmNoteAccept"), "button", "B")   // A on a Pro Controller is east
            compare(find("confirmNoteBack").button, "A")
        }

        function test_a_refused_change_puts_the_stored_value_back() {
            const row = openConfirm()
            Input.mockSetProfileStatus("SetConfirmButton", "failed")
            keyClick(Qt.Key_Right)
            tryVerify(() => toastTexts().some(t => t === "Could not change the confirm button / Try again."), 2000,
                      toastTexts().join(" | "))
            tryCompare(row, "currentLabel", "As on the controller")
            compare(Input.confirmButton, "family")
            compare(Input.mockConfirmButton("p2"), "family")
            verify(row.activeFocus)
            Input.mockResetProfiles()
            keyClick(Qt.Key_Right)
            tryCompare(Input, "confirmButton", "south")
        }

        function test_the_setting_follows_the_profile() {
            const row = openConfirm()
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            tryCompare(Input, "confirmButton", "east")
            Input.setRoute("shell", "", "", "p1")
            tryCompare(Input, "confirmButton", "family")
            tryCompare(row, "currentLabel", "As on the controller")
            Input.setRoute("shell", "", "", "p2")
            tryCompare(Input, "confirmButton", "east")
        }

        function test_the_service_failing_dims_the_row() {
            openPane()
            Input.mockFail(true)
            Input.mockRestart()                          // the service is back, but every call fails
            tryVerify(() => !Input.confirmButtonAvailable, 2000)
            tryVerify(() => find("rowConfirmButtonUnavailable").visible, 2000)
            verify(!confirmRow().visible)
            compare(find("rowConfirmButtonUnavailable").value, "Not available")
            Input.mockFail(false)
            Input.mockRestart()
            tryVerify(() => confirmRow().visible, 2000)
        }

        // ---- screenshots --------------------------------------------------------------------------------------------

        function settle() {
            wait(600)
            grabImage(tc.shell)                          // the first grab lays the pane out
            wait(400)
        }

        function shots(dir, lang) {
            openPane()
            settle()
            grabImage(tc.shell).save(dir + "27-settings-controllers-" + lang + ".png")
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Down)
            verify(confirmRow().activeFocus)
            settle()
            grabImage(tc.shell).save(dir + "40-confirm-button-" + lang + ".png")
            Input.mockActiveInput(ds, "playstation")      // Right on a PlayStation pad: Circle confirms
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            tryCompare(Input, "confirmButton", "east")
            settle()
            grabImage(tc.shell).save(dir + "40-confirm-button-right-playstation-" + lang + ".png")
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            tryCompare(Input, "confirmButton", "family")
            Input.mockActiveInput("", "")
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Up)
            verify(padRow(ds).activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controller")
            tryVerify(() => find("cap_buttons") !== null, 2000)
            settle()
            grabImage(tc.shell).save(dir + "27-controller-page-" + lang + ".png")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "buttonTest")
            tryVerify(() => Input.mockTestRunning(ds), 2000)
            settle()
            grabImage(tc.shell).save(dir + "27-button-test-idle-" + lang + ".png")
            Input.mockTestInput(ds, "south", 1, "raw:pad:1:304")
            Input.mockTestInput(ds, "east", 1, "raw:pad:1:305")
            Input.mockTestInput(ds, "east", 0, "raw:pad:1:305")
            Input.mockTestInput(ds, "l1", 1, "raw:pad:1:310")
            Input.mockTestInput(ds, "l1", 0, "raw:pad:1:310")
            Input.mockTestInput(ds, "left_x", -1204, "raw:pad:3:0")
            Input.mockTestInput(ds, "left_y", 18090, "raw:pad:3:1")
            Input.mockTestInput(ds, "right_trigger", 24250, "raw:pad:3:5")
            Input.mockTestInput(ds, "south", 1, "raw:pad:1:304")
            settle()
            keyClick(Qt.Key_Escape)                      // one Back press: the message asks for the second
            wait(300)
            verify(find("testMessage").text.startsWith(lang === "en" ? "Press B again" : "Çıkmak için B"))
            grabImage(tc.shell).save(dir + "27-button-test-pressed-" + lang + ".png")
            tryVerify(() => !find("page_buttonTest").awaitingSecondBack, 3000)
            keyClick(Qt.Key_Escape)                      // the wait for the second press is over: two presses
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controller")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            for (const id of [ds, xbox, pro])
                Input.mockRemoveDevice(id)
            tryVerify(() => find("rowPadsNone") !== null && find("rowPadsNone").visible, 2000)
            settle()
            grabImage(tc.shell).save(dir + "27-settings-controllers-empty-" + lang + ".png")
            Input.mockListFail(true)
            Input.refreshDevices()
            tryVerify(() => find("rowPadsFailed").visible, 2000)
            settle()
            grabImage(tc.shell).save(dir + "27-settings-controllers-error-" + lang + ".png")
            Input.mockListFail(false)
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            shots(shotsDir + "/", "en")
        }

        function test_zz_screenshots_tr() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.language = "tr"
            shots(shotsDir + "/", "tr")
        }

        // The Button test of one pad with a few inputs pressed, for the layout shots (RUY-486).
        function layoutShot(dir, device, name, inputs) {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            if (device.id !== ds && device.id !== xbox && device.id !== pro) {
                Input.mockAddDevice(device)
                tryVerify(() => Input.devices.length === 4)
            }
            openTest(device.id)
            for (const i of inputs) {
                Input.mockTestInput(device.id, i, 1, "raw:pad:1:0")
                Input.mockTestInput(device.id, i, 0, "raw:pad:1:0")
            }
            for (const i of inputs.slice(0, 3))
                Input.mockTestInput(device.id, i, 1, "raw:pad:1:0")
            settle()
            grabImage(tc.shell).save(dir + "27-button-test-layout-" + name + "-en.png")
        }

        function test_zz_screenshots_layout_playstation() { layoutShot(shotsDir + "/", { id: ds }, "playstation", ["select", "dpad_left", "l3", "guide"]) }
        function test_zz_screenshots_layout_xbox() { layoutShot(shotsDir + "/", { id: xbox }, "xbox", ["start", "dpad_down", "r3", "guide"]) }
        function test_zz_screenshots_layout_nintendo() { layoutShot(shotsDir + "/", { id: pro }, "nintendo", ["select", "dpad_right", "l3", "guide"]) }
        function test_zz_screenshots_layout_wiiu() {
            layoutShot(shotsDir + "/", { id: "bluetooth-057e-0330-c1d2e3f4a5b6", name: "Nintendo Wii Remote Pro Controller", family: "nintendo",
                         layout: "nintendo-wiiu", connection: "bluetooth", battery: 80 }, "nintendo-wiiu", ["select", "start", "dpad_up", "r3", "guide"])
        }
        function test_zz_screenshots_layout_generic() {
            layoutShot(shotsDir + "/", { id: "usb-2dc8-3106-aabbccddeeff", name: "8BitDo Pro 2", family: "generic", connection: "usb", battery: -1 },
                       "generic", ["select", "start", "dpad_down", "l3", "guide"])
        }

        function test_zz_screenshots_720p() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            host.width = 1280
            host.height = 720
            openController(ds)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "buttonTest")
            Input.mockTestInput(ds, "north", 1, "raw:pad:1:307")
            settle()
            grabImage(tc.shell).save(shotsDir + "/27-button-test-720p-en.png")
            openPaneShot720(shotsDir + "/")
        }

        // RUY-512: the pane's rows in the light theme (the facts, the page rows and the choice arrows read against it).
        function test_zz_screenshots_daylight() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.theme = "daylight"
            host.width = 1280
            host.height = 720
            openPane()
            settle()
            grabImage(tc.shell).save(shotsDir + "/27-settings-controllers-720p-daylight.png")
        }

        function openPaneShot720(dir) {
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controller")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            settle()
            grabImage(tc.shell).save(dir + "27-settings-controllers-720p-en.png")
        }
    }
}
