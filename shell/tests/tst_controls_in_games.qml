import QtQuick
import QtTest
import RuyaShell

// Controls in games (RUY-465, 06 §7, RUY-42's design comment): the page from Settings > Controllers
// and from a controller page, Remap buttons with the capture dialog, the stick editor, export to and
// import from a USB drive, Reset; against the Input mock's three pads and profiles and the Storage
// mock's stick. Signs in as "Ada" (p2, no PIN). Each test resets the pads, the profiles and the drives.
Item {
    id: host
    width: 1920
    height: 1080

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: effectiveSpy; target: Input; signalName: "effectiveProfileFetched" }

    TestCase {
        id: tc
        name: "ControlsInGames"
        when: windowShown

        property Shell shell: null

        readonly property string ds: "bluetooth-054c-0ce6-3f2a9c41d0b7"
        readonly property string xbox: "usb-045e-0b12-8e01c2d4a9f3"
        readonly property string pro: "bluetooth-057e-2009-b7c0e1f2a3d4"
        // The DualSense's own profile (RUY-545: an edit on its page makes it).
        readonly property string dsOwn: "controls-device-" + ds

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            host.width = 1920
            host.height = 1080
            DeviceSettings.language = "en"
            Input.mockFail(false)
            Input.mockResetDevices()
            Input.mockResetProfiles()
            Input.mockClearProfileCalls()
            Storage.mockReset()
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
            Input.mockHoldSaves(false)
            Input.mockResetProfiles()
            DeviceSettings.language = "en"
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
        function hasToast(text) {
            return toastTexts().indexOf(text) >= 0
        }

        function calls(method) {
            return Input.mockProfileCalls().filter(c => c.method === method)
        }

        function hintVerbs() {
            return tc.shell.hintList.map(h => (h.buttons ?? [h.button]).join("") + " " + h.text).join("|")
        }

        function plugStick() {
            Storage.mockPlugStick()
            tryVerify(() => Storage.volumes.some(v => v.id === "vol-stick" && v.mounted))
        }

        // Settings on Controllers, the focus on its Controls in games row.
        function openPaneOnControls() {
            tc.shell.openPage("settings", { category: "controllers" })
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneControllers").activeFocus, 2000, "the pane has the focus")
            for (let i = 0; i < 6 && !find("rowControlsInGames").activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(find("rowControlsInGames").activeFocus, "on Controls in games")
        }

        // The page, opened from Settings > Controllers; the focus on Applies to.
        function openControls() {
            openPaneOnControls()
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controls")
            tryVerify(() => find("rowAppliesTo") !== null && find("rowAppliesTo").activeFocus, 2000, "focus enters on row 1")
            tryCompare(GameControls, "loadState", "ok")
        }

        // Down on the page's pane until `name` has the focus.
        function focusRow(pane, name) {
            const rows = find(pane).focusableRows()
            const at = rows.findIndex(r => r.objectName === name)
            verify(at >= 0, name + " is a focusable row of " + pane)
            for (let i = 0; i < rows.length && !find(name).activeFocus; ++i)
                keyClick(rows.findIndex(r => r.activeFocus) < at ? Qt.Key_Down : Qt.Key_Up)
            verify(find(name).activeFocus, name + " has the focus")
        }

        function openRemap() {
            openControls()
            focusRow("controlsBody", "rowRemap")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controlsRemap")
            tryVerify(() => find("remap_south") !== null && find("remap_south").activeFocus, 2000, "focus on the first button")
        }

        function openCapture(source) {
            focusRow("remapBody", "remap_" + source)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("remapCapture") !== null && find("remapCapture").shown && find("remapCapture").activeFocus,
                      2000, "the capture dialog takes the keys")
            tryVerify(() => Input.mockTestRunning(ds), 2000, "it reads the pad's stream")
        }

        function openStick(side) {
            openControls()
            focusRow("controlsBody", side === "right" ? "rowRightStick" : "rowLeftStick")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controlsStick")
            tryVerify(() => find("rowInner") !== null && find("rowInner").activeFocus, 2000, "focus on Inner dead zone")
        }

        // The profile the last SaveProfile carried.
        function lastSaved() {
            const saves = calls("SaveProfile")
            verify(saves.length > 0, "a save reached the service")
            return JSON.parse(saves[saves.length - 1].args.json)
        }

        function rowNames(pane) {
            return find(pane).focusableRows().map(r => r.objectName)
        }

        // ---- the entries and the page --------------------------------------------------------------------------

        // RUY-513: the kinds of the page's rows, and the hints they now give by themselves.
        function test_row_kinds_and_hints() {
            openControls()
            const kinds = { rowRemap: "page", rowLeftStick: "page", rowRightStick: "page", rowExport: "action",
                            rowImport: "action", rowReset: "action", rowNoDrive: "info" }
            for (const name in kinds)
                compare(find(name).kind, kinds[name], name)
            compare(hintVerbs(), "Left/Right Change|A Next|B Back", "a choice")
            focusRow("controlsBody", "rowRemap")
            compare(hintVerbs(), "A Open|B Back")
            focusRow("controlsBody", "rowReset")
            compare(hintVerbs(), "A Select|B Back")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
        }

        function test_the_stick_pages_reset_row_is_an_action_with_the_default_hints() {
            openStick("left")
            compare(find("rowResetStick").kind, "action")
            compare(hintVerbs(), "Left/Right Adjust|B Back", "a slider")
            focusRow("stickBody", "rowResetStick")
            compare(hintVerbs(), "A Select|B Back")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controls")
        }

        function test_the_settings_row_opens_the_page_and_back_returns() {
            openPaneOnControls()
            compare(find("paneControllers").focusableRows().map(r => r.objectName),
                    ["pad_" + ds, "pad_" + pro, "pad_" + xbox, "rowConfirmButton", "rowControlsInGames", "rowPadsPair"],
                    "after the pads and the Confirm button (RUY-40), before Pair")
            tryCompare(find("rowControlsInGames"), "value", "Default")
            compare(hintVerbs(), "A Open|B Back")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controls")
            tryVerify(() => find("rowAppliesTo").activeFocus, 2000, "focus enters on Applies to")
            compare(find("page_controls").title, "Controls in games")
            compare(hintVerbs(), "Left/Right Change|A Next|B Back")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("rowControlsInGames").activeFocus, 2000, "Back lands on the row that opened it")
        }

        function test_the_controller_page_row_opens_the_page_for_that_pad() {
            tc.shell.openPage("controller", { id: pro })
            tryCompare(tc.shell, "currentPage", "controller")
            tryVerify(() => find("rowButtonTest").activeFocus, 2000)
            keyClick(Qt.Key_Down)
            const row = findChild(find("page_controller"), "rowControlsInGames")
            verify(row && row.activeFocus, "Controls in games follows Button test")
            compare(row.value, "Default")
            compare(hintVerbs(), "A Open|B Back")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controls")
            tryVerify(() => find("rowAppliesTo").activeFocus, 2000)
            compare(find("controlsGlyph").name, DeviceIcons.iconFor("controller", "nintendo"), "the Pro Controller's glyph")
            compare(find("rowAppliesTo").options.map(o => o.label),
                    ["All controllers", "Nintendo controllers", "This Pro Controller"])
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controller")
            tryVerify(() => row.activeFocus, 2000, "back on the controller page's row")
        }

        function test_the_main_rows_and_their_values() {
            openControls()
            compare(rowNames("controlsBody"), ["rowAppliesTo", "rowLayout", "rowRemap", "rowLeftStick", "rowRightStick",
                                               "rowReset"], "no drive: no Export and Import")
            verify(find("rowNoDrive").visible && !find("rowNoDrive").enabled, "the unavailable line, without focus")
            compare(find("rowNoDrive").label, "Plug in a USB drive first.")
            compare(find("controlsGamesOnly").text, "Changes here reach games only. Menus keep their buttons.")
            compare(find("controlsProfileName").text, "Profile: Ada")
            compare(find("controlsGlyph").name, DeviceIcons.iconFor("controller", "playstation"), "the first pad: the DualSense")
            compare(find("rowAppliesTo").currentLabel, "All controllers")
            compare(find("rowAppliesTo").options.map(o => o.label), ["All controllers", "PlayStation controllers", "This DualSense"])
            compare(find("rowLayout").currentLabel, "Standard")
            compare(find("rowRemap").value, "Default")
            compare(find("rowLeftStick").value, "Default")
            compare(find("rowRightStick").value, "Default")
            plugStick()
            tryVerify(() => find("rowExport").visible && find("rowImport").visible && !find("rowNoDrive").visible)
            compare(find("rowExport").value, "Ruya Stick", "the drive's label")
            compare(rowNames("controlsBody"), ["rowAppliesTo", "rowLayout", "rowRemap", "rowLeftStick", "rowRightStick",
                                               "rowExport", "rowImport", "rowReset"])
            focusRow("controlsBody", "rowRemap")
            compare(hintVerbs(), "A Open|B Back")
            focusRow("controlsBody", "rowExport")
            compare(hintVerbs(), "A Select|B Back")
            focusRow("controlsBody", "rowReset")
            compare(hintVerbs(), "A Select|B Back")
            keyClick(Qt.Key_Left)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("rowControlsInGames").activeFocus, 2000, "Left leaves the page too")
        }

        function test_the_nintendo_layout_is_saved_and_shown() {
            openControls()
            focusRow("controlsBody", "rowLayout")
            keyClick(Qt.Key_Right)
            compare(find("rowLayout").currentLabel, "Nintendo", "shown at once")
            tryVerify(() => calls("AssignProfile").length === 1, 2000, "saved and assigned")
            compare(calls("ValidateProfile").length, 1, "validated first")
            const saved = lastSaved()
            compare(saved.inherits, "nintendo")
            // RUY-545: nothing applied to the DualSense, so the edit is a profile of its own.
            compare(saved.id, dsOwn)
            compare(saved.match, { device: ds })
            compare(saved.scope, { type: "global" })
            compare(calls("AssignProfile")[0].args, { profile: "p2", scope: "global", scope_id: "device:" + ds, profile_id: dsOwn })
            compare(find("rowAppliesTo").currentLabel, "This DualSense", "Applies to says whose it is")
            tryVerify(() => GameControls.changed, 2000, "the service says the controls changed")
            verify(find("rowLayout").activeFocus, "the row keeps the focus")
            compare(find("rowRemap").value, "Default", "a layout is not a remap")
            keyClick(Qt.Key_Return)                      // Accept is Next
            compare(find("rowLayout").currentLabel, "Standard")
            tryVerify(() => calls("SaveProfile").length === 2, 2000)
            verify(lastSaved().inherits === undefined, "Standard inherits the default")
            tryVerify(() => !GameControls.changed, 2000)
            keyClick(Qt.Key_Right)
            tryVerify(() => calls("SaveProfile").length === 3 && GameControls.changed, 2000)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            tryCompare(find("rowControlsInGames"), "value", "Changed")
        }

        // RUY-545: each choice saves the pad's settings under that slot's id and assigns that slot;
        // a wider one also empties the pad's narrower slots, so the pad takes it.
        function test_applies_to_limits_the_profile() {
            openControls()
            keyClick(Qt.Key_Right)
            compare(find("rowAppliesTo").currentLabel, "PlayStation controllers")
            tryVerify(() => calls("AssignProfile").length === 1, 2000)
            compare(lastSaved().match, { family: "playstation" })
            compare(lastSaved().id, "controls-family-playstation")
            compare(calls("AssignProfile")[0].args.scope_id, "family:playstation")
            keyClick(Qt.Key_Right)
            compare(find("rowAppliesTo").currentLabel, "This DualSense")
            tryVerify(() => calls("SaveProfile").length === 2, 2000)
            compare(lastSaved().match, { device: ds })
            compare(lastSaved().id, dsOwn)
            tryVerify(() => calls("AssignProfile").length === 2, 2000)
            compare(calls("AssignProfile")[1].args.scope_id, "device:" + ds, "a narrower slot empties nothing")
            keyClick(Qt.Key_Right)                       // wraps
            compare(find("rowAppliesTo").currentLabel, "All controllers")
            tryVerify(() => calls("SaveProfile").length === 3, 2000)
            verify(lastSaved().match === undefined, "all controllers: no match")
            compare(lastSaved().id, "controls-all")
            tryVerify(() => calls("AssignProfile").length === 5, 2000)
            compare(calls("AssignProfile").slice(2).map(c => c.args.scope_id + "=" + c.args.profile_id),
                    ["=controls-all", "device:" + ds + "=", "family:playstation="])
            tryCompare(find("rowAppliesTo"), "currentLabel", "All controllers")
            verify(find("rowAppliesTo").activeFocus)
        }

        // What the service would apply to a pad: its chain, most specific first.
        function chainOf(device) {
            const before = effectiveSpy.count
            Input.getEffectiveProfile("p2", device, "")
            tryCompare(effectiveSpy, "count", before + 1)
            const a = effectiveSpy.signalArguments[before]
            compare(a[3], "ok")
            return a[5]
        }

        // A controller page's Controls in games row, with the focus on it.
        function openControllerRow(id) {
            tc.shell.openPage("controller", { id: id })
            tryCompare(tc.shell, "currentPage", "controller")
            tryVerify(() => find("rowButtonTest").activeFocus, 2000)
            keyClick(Qt.Key_Down)
            const row = findChild(find("page_controller"), "rowControlsInGames")
            verify(row && row.activeFocus, "on Controls in games")
            return row
        }

        // From a controller page's row onto that pad's Controls in games page.
        function openControlsFrom(row) {
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controls")
            tryVerify(() => find("rowAppliesTo") !== null && find("rowAppliesTo").activeFocus, 2000, "focus on Applies to")
            tryCompare(GameControls, "loadState", "ok")
        }

        // RUY-538 / RUY-545: with two pads, a change on one pad's page reaches only that pad, until
        // Applies to = All controllers gives it to the other one too.
        function test_a_change_on_one_pad_leaves_the_other() {
            // The DualSense's left stick: inner dead zone 8 % -> 9 %.
            let row = openControllerRow(ds)
            compare(row.value, "Default")
            openControlsFrom(row)
            compare(find("rowAppliesTo").currentLabel, "All controllers", "nothing applies yet")
            focusRow("controlsBody", "rowLeftStick")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controlsStick")
            tryVerify(() => find("rowInner") !== null && find("rowInner").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            tryVerify(() => calls("AssignProfile").length === 1, 2000, "saved and assigned once it rests")
            compare(lastSaved().id, dsOwn)
            compare(lastSaved().settings, { left_stick: { inner_deadzone: 0.09 } })
            compare(calls("AssignProfile")[0].args.scope_id, "device:" + ds)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controls")
            tryVerify(() => find("rowLeftStick").activeFocus, 2000, "Back lands on Left stick")
            tryCompare(find("rowLeftStick"), "value", "Changed")
            compare(find("rowAppliesTo").currentLabel, "This DualSense")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controller")
            tryVerify(() => row.activeFocus, 2000, "back on the DualSense's row")
            tryCompare(row, "value", "Changed")
            compare(chainOf(ds), [dsOwn, "default"])
            compare(chainOf(pro), ["default"], "the Pro Controller's effective profile is unchanged")

            // The Pro Controller: Default on its controller page and on its Controls in games page.
            keyClick(Qt.Key_Escape)
            row = openControllerRow(pro)
            tryCompare(row, "value", "Default")
            openControlsFrom(row)
            compare(GameControls.pad.id, pro, "the page edits the Pro Controller")
            compare(find("rowLeftStick").value, "Default")
            compare(find("rowAppliesTo").currentLabel, "All controllers")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controller")
            tryVerify(() => row.activeFocus, 2000)
            keyClick(Qt.Key_Escape)

            // Back on the DualSense: still Changed; Applies to = All controllers gives it to the Pro too.
            row = openControllerRow(ds)
            tryCompare(row, "value", "Changed")
            openControlsFrom(row)
            compare(find("rowLeftStick").value, "Changed")
            compare(find("rowAppliesTo").currentLabel, "This DualSense")
            const before = calls("AssignProfile").length
            keyClick(Qt.Key_Right)                       // wraps to All controllers
            compare(find("rowAppliesTo").currentLabel, "All controllers")
            tryVerify(() => calls("AssignProfile").length === before + 2, 2000, "assigned, and the pad's own slot emptied")
            compare(lastSaved().id, "controls-all")
            compare(lastSaved().settings, { left_stick: { inner_deadzone: 0.09 } }, "the DualSense's settings")
            verify(find("rowAppliesTo").activeFocus, "the row keeps the focus")
            tryVerify(() => chainOf(pro)[0] === "controls-all", 2000, "the Pro Controller now takes them")
            compare(chainOf(ds), ["controls-all", "default"])
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controller")
            keyClick(Qt.Key_Escape)
            row = openControllerRow(pro)
            tryCompare(row, "value", "Changed")
            openControlsFrom(row)
            compare(find("rowLeftStick").value, "Changed")
            compare(find("rowAppliesTo").currentLabel, "All controllers")
            // An edit there now changes all controllers' profile in place (the page put it there).
            focusRow("controlsBody", "rowLayout")
            keyClick(Qt.Key_Right)
            tryVerify(() => calls("SaveProfile").length > 0 && lastSaved().inherits === "nintendo", 2000)
            compare(lastSaved().id, "controls-all")
            tryVerify(() => chainOf(ds)[1] === "nintendo", 2000, "the DualSense follows")
        }

        // Saves and assigns a profile through the mock before the pages open, and waits for it.
        function given(id, extra, slot, device) {
            Input.saveProfile("p2", profileText(id, extra))
            Input.assignProfile("p2", "global", slot, id)
            tryVerify(() => chainOf(device)[0] === id, 2000, id + " applies to " + device)
        }

        // The saves that reached the service for one profile id, parsed.
        function savesOf(id) {
            return calls("SaveProfile").map(c => JSON.parse(c.args.json)).filter(p => p.id === id)
        }

        // Round 2: a pad's profile that arrives while another pad's change waits is the one shown
        // and edited (it was dropped and the next edit overwrote it), and both pads' changes are saved.
        function test_a_profile_that_arrives_during_another_pad_s_save_is_the_one_edited() {
            const proOwn = "controls-device-" + pro
            given(proOwn, { match: { device: pro }, settings: { left_stick: { inner_deadzone: 0.12 } } }, "device:" + pro, pro)
            Input.mockClearProfileCalls()
            openStick("left")                            // the DualSense (the first pad)
            keyClick(Qt.Key_Right)                       // a slider step: its save waits for the rest
            verify(GameControls.busy, "the DualSense's change waits")
            GameControls.show(pro)                       // the Pro Controller's page meanwhile
            tryVerify(() => GameControls.stored !== null && GameControls.stored.id === proOwn, 2000)
            verify(GameControls.busy, "its profile arrived while the other change still waited")
            compare(GameControls.stick("left").inner_deadzone, 0.12, "the Pro Controller's own value is shown")
            GameControls.setStick("left", "outer_deadzone", 0.05, false)
            tryVerify(() => savesOf(proOwn).length === 1, 3000, "the Pro Controller's change is saved")
            compare(savesOf(proOwn)[0].settings, { left_stick: { inner_deadzone: 0.12, outer_deadzone: 0.05 } },
                    "nothing of its own is lost")
            compare(savesOf(proOwn)[0].match, { device: pro })
            tryVerify(() => savesOf(dsOwn).length === 1, 3000, "the DualSense's waiting change is saved too")
            compare(savesOf(dsOwn)[0].settings, { left_stick: { inner_deadzone: 0.09 } })
            tryVerify(() => !GameControls.busy, 3000)
            compare(chainOf(ds)[0], dsOwn)
            compare(chainOf(pro)[0], proOwn)
        }

        // RUY-571: a refused save drops that pad's waiting change only; the other pad's is saved next.
        function test_a_refused_save_keeps_the_other_pads_waiting_change() {
            const proOwn = "controls-device-" + pro
            Input.mockClearProfileCalls()
            openStick("left")                            // the DualSense
            keyClick(Qt.Key_Right)
            verify(GameControls.busy, "the DualSense's change waits")
            Input.mockSetProfileStatusOnce("ValidateProfile", "invalid")    // the first save is refused
            GameControls.show(pro)
            GameControls.setStick("left", "outer_deadzone", 0.05, false)
            tryVerify(() => hasToast("Could not save the change for DualSense / Try again."), 3000, toastTexts().join("; "))
            verify(!hasToast("Could not save the change / Try again."), "the refused pad is named, not the shown one")
            tryVerify(() => savesOf(proOwn).length === 1, 3000, "the other pad's change is saved")
            tryVerify(() => !GameControls.busy, 3000)
            compare(savesOf(proOwn).length + savesOf(dsOwn).length, 1, "only the refused pad's change is lost")
        }

        // RUY-586: the shown pad's own refusal keeps the plain toast.
        function test_a_refused_save_of_the_shown_pad_keeps_the_plain_toast() {
            openStick("left")                            // the DualSense, shown
            Input.mockSetProfileStatusOnce("ValidateProfile", "invalid")
            GameControls.setStick("left", "outer_deadzone", 0.05, false)
            tryVerify(() => hasToast("Could not save the change / Try again."), 3000, toastTexts().join("; "))
            tryVerify(() => !GameControls.busy, 3000)
            compare(toastTexts().filter(t => t.indexOf(" for ") >= 0).length, 0, toastTexts().join("; "))
        }

        // RUY-595: an import drops the pad's waiting change (it would be saved after the import).
        function test_an_import_drops_the_pads_waiting_change() {
            plugStick()
            Storage.mockSetFile("vol-stick", "mine.json", profileText("mine", { inherits: "nintendo" }), 1731456000)
            openControls()
            GameControls.setStick("left", "inner_deadzone", 0.2, true)   // waits 300 ms
            verify(GameControls.busy, "the change waits")
            GameControls.importFrom("vol-stick", "mine.json")
            tryVerify(() => !GameControls.importing && !GameControls.busy, 3000)
            compare(savesOf(dsOwn).length, 1, "only the import is saved")
            compare(savesOf(dsOwn)[0].inherits, "nintendo")
            tryVerify(() => chainOf(ds)[0] === dsOwn, 2000)
        }

        // RUY-595: an import starts after the save in flight; a new edit waits behind the import.
        function test_an_import_waits_for_the_save_in_flight() {
            plugStick()
            Storage.mockSetFile("vol-stick", "mine.json", profileText("mine", { inherits: "nintendo" }), 1731456000)
            openControls()
            Input.mockHoldSaves(true)
            GameControls.setStick("left", "inner_deadzone", 0.2, false)
            tryCompare(GameControls, "phase", "save")
            GameControls.importFrom("vol-stick", "mine.json")
            verify(GameControls.pendingImport !== null, "the import waits")
            GameControls.setStick("left", "outer_deadzone", 0.05, false)   // behind the import
            verify(GameControls.busy)
            compare(calls("ValidateProfile").length, 1, "the import did not start")
            Input.mockHoldSaves(false)
            tryVerify(() => !GameControls.importing && !GameControls.busy, 3000)
            const saves = savesOf(dsOwn)
            compare(saves.length, 2, "the first edit and the import; the edit made meanwhile is dropped")
            compare(saves[0].inherits, undefined)
            compare(saves[1].inherits, "nintendo", "the import is what the service ends with")
            compare(saves[1].settings, undefined)
        }

        // RUY-595: while the import runs, the pad's new edit is held; an accepted import drops it.
        function test_an_edit_during_a_running_import_is_held_and_dropped_when_accepted() {
            plugStick()
            Storage.mockSetFile("vol-stick", "mine.json", profileText("mine", { inherits: "nintendo" }), 1731456000)
            openControls()
            Input.mockHoldSaves(true)
            GameControls.importFrom("vol-stick", "mine.json")
            compare(GameControls.phase, "", "no save in flight: the import runs at once")
            tryVerify(() => calls("SaveProfile").length === 1, 3000, "the import's save is held")
            const validates = calls("ValidateProfile").length
            GameControls.setStick("left", "outer_deadzone", 0.05, false)
            compare(GameControls.queue.length, 1, "the edit waits behind the import")
            compare(GameControls.phase, "", "and does not start")
            compare(calls("ValidateProfile").length, validates)
            Input.mockHoldSaves(false)
            tryVerify(() => !GameControls.importing && !GameControls.busy, 3000)
            compare(savesOf(dsOwn).length, 1, "only the import was saved")
            compare(savesOf(dsOwn)[0].inherits, "nintendo")
        }

        // RUY-595: after a refused import the held edit is saved as usual.
        function test_an_edit_during_a_refused_import_is_saved_after_it() {
            plugStick()
            Storage.mockSetFile("vol-stick", "bad.json", "not json at all", 1731456000)
            openControls()
            GameControls.importFrom("vol-stick", "bad.json")
            GameControls.setStick("left", "outer_deadzone", 0.05, false)
            compare(GameControls.queue.length, 1, "the edit waits behind the import")
            tryVerify(() => hasToast("That file can't be used / It isn't a RuyaOS controls file."), 3000, toastTexts().join("; "))
            tryVerify(() => savesOf(dsOwn).length === 1, 3000, "the edit is saved")
            tryVerify(() => !GameControls.busy, 3000)
        }

        // RUY-595: an import on one pad's page leaves another pad's waiting change to be saved.
        function test_an_import_keeps_another_pads_waiting_change() {
            const proOwn = "controls-device-" + pro
            plugStick()
            Storage.mockSetFile("vol-stick", "mine.json", profileText("mine", { inherits: "nintendo" }), 1731456000)
            openControls()
            GameControls.show(pro)
            GameControls.setStick("left", "outer_deadzone", 0.05, true)    // the Pro Controller's change waits
            GameControls.show(ds)
            GameControls.importFrom("vol-stick", "mine.json")
            tryVerify(() => savesOf(proOwn).length === 1, 3000, "the other pad's change is saved")
            tryVerify(() => !GameControls.importing && !GameControls.busy, 3000)
            compare(savesOf(dsOwn).length, 1, "the DualSense has only the import")
            compare(savesOf(dsOwn)[0].inherits, "nintendo")
        }

        // RUY-596: a game-scope file with another pad's controls-device id is refused; that pad's profile stays.
        function test_an_import_may_not_take_another_pads_reserved_id() {
            const proOwn = "controls-device-" + pro
            plugStick()
            given(proOwn, { match: { device: pro }, settings: { left_stick: { inner_deadzone: 0.12 } } }, "device:" + pro, pro)
            Storage.mockSetFile("vol-stick", "steal.json",
                                profileText(proOwn, { scope: { type: "game", game_id: "quake" } }), 1731456000)
            openControls()
            const before = calls("SaveProfile").length
            GameControls.importFrom("vol-stick", "steal.json")
            tryVerify(() => hasToast("That file can't be used / It isn't a RuyaOS controls file."), 3000, toastTexts().join("; "))
            tryVerify(() => !GameControls.importing && !GameControls.busy, 3000)
            compare(calls("SaveProfile").length, before, "nothing was saved")
            compare(chainOf(pro)[0], proOwn, "the other pad keeps its profile")
        }

        // RUY-595: a new owner does not inherit the old one's import hold.
        function test_an_owner_change_ends_the_import_hold() {
            plugStick()
            Storage.mockSetFile("vol-stick", "mine.json", profileText("mine", { inherits: "nintendo" }), 1731456000)
            openControls()
            Input.mockHoldSaves(true)
            GameControls.importFrom("vol-stick", "mine.json")
            tryVerify(() => calls("SaveProfile").length === 1, 3000, "the import's save is held")
            verify(GameControls.importing)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            verify(!GameControls.importing, "the hold ended with the owner")
            verify(GameControls.pendingImport === null)
        }

        // RUY-595: an export that waited for the save in flight still runs after the import that went first.
        function test_an_export_waiting_behind_an_import_still_runs() {
            plugStick()
            Storage.mockSetFile("vol-stick", "mine.json", profileText("mine", { inherits: "nintendo" }), 1731456000)
            given(dsOwn, { match: { device: ds } }, "device:" + ds, ds)
            openControls()
            tryVerify(() => GameControls.stored !== null, 2000)
            Input.mockHoldSaves(true)
            GameControls.setStick("left", "inner_deadzone", 0.2, false)
            tryCompare(GameControls, "phase", "save")
            GameControls.importFrom("vol-stick", "mine.json")
            GameControls.exportTo("vol-stick")
            compare(GameControls.exportVolume, "vol-stick", "the export waits")
            Input.mockHoldSaves(false)
            tryVerify(() => hasToast("Saved to the USB drive / " + Input.exportFileName("p2")), 4000, toastTexts().join("; "))
            tryVerify(() => !GameControls.importing && !GameControls.busy, 3000)
            compare(GameControls.exportVolume, "")
        }

        function confirmReset() {
            focusRow("controlsBody", "rowReset")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("controlsResetConfirm").shown, 2000)
            keyClick(Qt.Key_Right)
            verify(findChild(find("controlsResetConfirm"), "powerConfirm").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => !find("controlsResetConfirm").shown, 2000)
            tryVerify(() => find("rowReset").activeFocus, 2000, "the focus returns to Reset")
        }

        // Reset with a changed profile for all controllers under the pad's own: the pad's own is saved
        // empty (deleting it would hand the pad all controllers' changes), the all slot stays.
        function test_reset_empties_the_own_profile_when_a_wider_one_would_apply() {
            given("controls-all", { inherits: "nintendo" }, "", xbox)
            given(dsOwn, { match: { device: ds }, settings: { left_stick: { inner_deadzone: 0.2 } } }, "device:" + ds, ds)
            Input.mockClearProfileCalls()
            openControls()
            compare(find("rowAppliesTo").currentLabel, "This DualSense")
            confirmReset()
            tryVerify(() => savesOf(dsOwn).length === 1, 2000)
            compare(calls("DeleteProfile").length, 0, "not deleted")
            const saved = savesOf(dsOwn)[0]
            compare(saved.match, { device: ds })
            verify(saved.settings === undefined && saved.inherits === undefined && saved.mappings === undefined,
                   "nothing in it: " + JSON.stringify(saved))
            tryVerify(() => !GameControls.changed, 2000, "the DualSense is back to the default")
            compare(chainOf(ds), [dsOwn, "default"])
            compare(chainOf(xbox), ["controls-all", "nintendo", "default"], "all controllers' profile stays")
            compare(find("rowLayout").currentLabel, "Standard")
        }

        // Reset when what applies is an all-controllers profile the page did not put there (an
        // import): a copy for This <pad> with nothing in it, so the other pads keep the import.
        function test_reset_on_a_shared_import_makes_an_empty_copy_for_the_pad() {
            given("imported", { inherits: "nintendo" }, "", ds)
            Input.mockClearProfileCalls()
            openControls()
            compare(find("rowAppliesTo").currentLabel, "All controllers")
            compare(find("rowLayout").currentLabel, "Nintendo")
            confirmReset()
            tryVerify(() => calls("AssignProfile").length === 1, 2000)
            compare(calls("DeleteProfile").length, 0, "the import stays")
            compare(savesOf("imported").length, 0, "and is not rewritten")
            const saved = savesOf(dsOwn)[0]
            compare(saved.match, { device: ds })
            verify(saved.inherits === undefined && saved.settings === undefined, "nothing in it")
            compare(calls("AssignProfile")[0].args, { profile: "p2", scope: "global", scope_id: "device:" + ds, profile_id: dsOwn })
            tryVerify(() => !GameControls.changed, 2000)
            tryCompare(find("rowAppliesTo"), "currentLabel", "This DualSense")
            compare(chainOf(pro), ["imported", "nintendo", "default"], "the Pro Controller keeps the import")
        }

        // ---- remap -----------------------------------------------------------------------------------------------

        function test_the_remap_list_names_the_family_buttons() {
            openRemap()
            compare(rowNames("remapBody").map(n => n.slice(6)), GameControls.sources)
            compare(GameControls.sources, ["south", "east", "west", "north", "l1", "r1", "left_trigger", "right_trigger",
                                           "l3", "r3", "dpad_up", "dpad_down", "dpad_left", "dpad_right", "select", "start"])
            const south = find("remap_south")
            compare(south.label, "Cross")
            compare(south.glyph, "A", "the position letter in the icon slot")
            verify(findChild(south, "rowGlyph").visible, "a ButtonGlyph in the icon slot")
            compare(south.targetName, "Cross", "every button as itself")
            verify(!south.changed)
            compare(find("remap_left_trigger").label, "L2")
            compare(find("remap_start").label, "Options")
            compare(hintVerbs(), "A Change|B Back")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controls")
            tryVerify(() => find("rowRemap").activeFocus, 2000, "Back lands on Remap buttons")
        }

        function test_a_capture_sets_the_target_and_the_row_keeps_the_focus() {
            openRemap()
            openCapture("south")
            const dialog = find("remapCapture")
            compare(findChild(dialog, "remapCaptureTitle").text, "Press the new button for Cross")
            compare(findChild(dialog, "remapCaptureDetail").text, "Any button on the DualSense. Nothing for 5 seconds cancels.")
            compare(findChild(dialog, "remapCaptureSource").height, 80, "the source glyph at 80 u")
            compare(hintVerbs(), "Esc Cancel")
            keyClick(Qt.Key_Down)                        // navigation keys do nothing here
            verify(dialog.activeFocus && dialog.shown, "every key is taken")
            Input.mockTestInput(ds, "east", 1, "raw:pad:1:305")
            tryVerify(() => !dialog.shown, 2000, "the first press closes it")
            Input.mockTestInput(ds, "east", 0, "raw:pad:1:305")
            tryVerify(() => find("remap_south").activeFocus, 2000, "the row keeps the focus")
            compare(find("remap_south").targetName, "Circle", "updated in place")
            verify(find("remap_south").changed, "DemiBold")
            tryVerify(() => hasToast("Cross now acts as Circle / DualSense Wireless Controller"), 2000, toastTexts().join("; "))
            compare(lastSaved().mappings, [{ from: "south", to: { type: "button", code: "east" } }])
            tryVerify(() => !Input.mockTestRunning(ds), 2000, "the stream stops")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controls")
            tryCompare(find("rowRemap"), "value", "1 changed")
        }

        function test_a_trigger_can_be_the_target() {
            openRemap()
            openCapture("south")
            Input.mockTestInput(ds, "left_trigger", 4000, "raw:pad:3:2")      // a light touch is no press
            wait(50)
            verify(find("remapCapture").shown)
            Input.mockTestInput(ds, "left_trigger", 30000, "raw:pad:3:2")
            tryVerify(() => !find("remapCapture").shown, 2000)
            compare(find("remap_south").targetName, "L2")
            tryVerify(() => calls("SaveProfile").length === 1, 2000)
            compare(lastSaved().mappings, [{ from: "south", to: { type: "axis", code: "left_trigger" } }])
        }

        function test_the_same_button_changes_nothing() {
            openRemap()
            openCapture("south")
            Input.mockTestInput(ds, "south", 1, "raw:pad:1:304")
            tryVerify(() => !find("remapCapture").shown, 2000)
            Input.mockTestInput(ds, "south", 0, "raw:pad:1:304")
            tryVerify(() => find("remap_south").activeFocus, 2000, "the row keeps the focus")
            wait(100)
            compare(calls("ValidateProfile").length + calls("SaveProfile").length, 0, "nothing is saved")
            compare(toastTexts(), [], "and nothing is said")
            verify(!find("remap_south").changed)
        }

        function test_esc_cancels_silently() {
            openRemap()
            openCapture("east")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("remapCapture").shown, 2000, "Esc cancels")
            tryVerify(() => find("remap_east").activeFocus, 2000, "back on the row")
            tryVerify(() => !Input.mockTestRunning(ds), 2000)
            compare(tc.shell.currentPage, "controlsRemap", "the page stays")
            compare(calls("SaveProfile").length, 0)
            compare(toastTexts(), [])
        }

        function test_a_pad_b_press_wins_over_its_esc_key() {
            openRemap()
            openCapture("south")
            keyClick(Qt.Key_Escape)                      // a pad's B sends Esc and its press on the stream
            Input.mockTestInput(ds, "east", 1, "raw:pad:1:305")
            tryVerify(() => !find("remapCapture").shown, 2000)
            compare(find("remap_south").targetName, "Circle", "the press, not a cancel")
            tryVerify(() => calls("SaveProfile").length === 1, 2000)
        }

        function test_the_key_of_the_capturing_press_does_not_reopen_it() {
            openRemap()
            openCapture("north")
            Input.mockTestInput(ds, "south", 1, "raw:pad:1:304")
            keyClick(Qt.Key_Return)                      // the Enter the same press of A sent
            tryVerify(() => !find("remapCapture").shown, 2000)
            wait(100)
            verify(!find("remapCapture").shown, "Enter reached nothing")
            Input.mockTestInput(ds, "south", 0, "raw:pad:1:304")
            tryVerify(() => find("remap_north").activeFocus, 2000, "the focus comes back after the release")
            verify(!find("remapCapture").shown)
            compare(find("remap_north").targetName, "Cross")
        }

        function test_five_seconds_without_a_press_cancel() {
            openRemap()
            openCapture("west")
            const dialog = find("remapCapture")
            compare(dialog.timeoutMs, 5000)
            compare(findChild(dialog, "remapCaptureTimer").width, 480, "the 480 u bar")
            wait(1000)
            verify(dialog.shown, "still waiting after a second")
            verify(dialog.remaining < 1 && dialog.remaining > 0.5, "the bar drains: " + dialog.remaining)
            tryVerify(() => !dialog.shown, 6000, "gone after 5 s")
            tryVerify(() => find("remap_west").activeFocus, 2000)
            compare(calls("SaveProfile").length, 0)
            compare(toastTexts(), [])
        }

        function test_a_refused_remap_says_so_and_shows_the_stored_target() {
            openRemap()
            Input.mockSetProfileStatus("SaveProfile", "failed")
            openCapture("south")
            Input.mockTestInput(ds, "west", 1, "raw:pad:1:308")
            tryVerify(() => hasToast("Could not save the change / Try again."), 2000, toastTexts().join("; "))
            compare(find("remap_south").targetName, "Cross", "back to what the service has")
            verify(!hasToast("Cross now acts as Square / DualSense Wireless Controller"), "no success toast")
        }

        function test_without_a_controller_the_rows_say_so() {
            for (const id of [ds, xbox, pro])
                Input.mockRemoveDevice(id)
            tryVerify(() => Input.devices.length === 0)
            tc.shell.openPage("controlsRemap", {})
            tryCompare(tc.shell, "currentPage", "controlsRemap")
            tryVerify(() => find("remap_south") !== null && find("remap_south").activeFocus, 2000)
            verify(find("remap_south").dimmed)
            compare(find("remap_south").label, "A", "no family: the position letters")
            keyClick(Qt.Key_Return)
            tryVerify(() => hasToast("Connect a controller first. / "), 2000, toastTexts().join("; "))
            verify(find("remapCapture") === null || !find("remapCapture").shown, "no capture")
            verify(find("remap_south").activeFocus)
        }

        // ---- the stick editor ------------------------------------------------------------------------------------

        function test_a_slider_saves_once_it_rests() {
            openStick("left")
            compare(find("page_controlsStick").title, "Left stick")
            compare(rowNames("stickBody"), ["rowInner", "rowOuter", "rowAnti", "rowCurve", "rowSensitivity", "rowInvert",
                                            "rowResetStick"])
            compare(find("rowInner").value, 8, "the default inner dead zone")
            compare(find("rowOuter").value, 2)
            compare(find("rowAnti").value, 0)
            compare(find("rowSensitivity").value, 100)
            compare(find("rowCurve").currentLabel, "Linear")
            compare(hintVerbs(), "Left/Right Adjust|B Back")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(find("rowInner").value, 11)
            fuzzyCompare(findChild(find("plotPosition"), "innerZone").width, 2 * 0.11 * 160, 0.01, "the plot follows every step")
            compare(calls("SaveProfile").length + calls("ValidateProfile").length, 0, "nothing saved while the slider moves")
            tryVerify(() => calls("SaveProfile").length === 1, 2000, "one save once it rests")
            compare(lastSaved().settings, { left_stick: { inner_deadzone: 0.11 } })
            wait(400)
            compare(calls("SaveProfile").length, 1, "only one")
            verify(find("rowInner").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controls")
            tryVerify(() => find("rowLeftStick").activeFocus, 2000, "Back lands on Left stick")
            compare(find("rowLeftStick").value, "Changed")
            compare(find("rowRightStick").value, "Default")
        }

        function test_a_refused_save_restores_the_stored_value() {
            openStick("left")
            Input.mockSetProfileStatus("ValidateProfile", "invalid")
            // The list cannot be read again either: the stored value comes back without it.
            Input.mockSetProfileStatus("ListProfiles", "failed")
            keyClick(Qt.Key_Right)
            compare(find("rowInner").value, 9)
            tryVerify(() => hasToast("Could not save the change / Try again."), 2000, toastTexts().join("; "))
            tryCompare(find("rowInner"), "value", 8)
            compare(calls("SaveProfile").length, 0, "an invalid profile is never saved")
            verify(find("rowInner").activeFocus, "the focus stays")
        }

        function test_the_curve_inversion_and_the_stick_reset() {
            openStick("right")
            compare(find("page_controlsStick").title, "Right stick")
            focusRow("stickBody", "rowCurve")
            compare(hintVerbs(), "Left/Right Change|A Next|B Back")
            keyClick(Qt.Key_Right)
            compare(find("rowCurve").currentLabel, "Precise")
            tryVerify(() => calls("SaveProfile").length === 1, 2000, "a choice saves at once")
            compare(lastSaved().settings, { right_stick: { curve: "precise" } })
            focusRow("stickBody", "rowInvert")
            compare(hintVerbs(), "A Toggle|B Back")
            keyClick(Qt.Key_Return)
            verify(find("rowInvert").checked)
            tryVerify(() => calls("SaveProfile").length === 2, 2000)
            compare(lastSaved().settings, { right_stick: { curve: "precise", invert_y: true } })
            focusRow("stickBody", "rowResetStick")
            compare(hintVerbs(), "A Select|B Back")
            keyClick(Qt.Key_Return)
            tryVerify(() => hasToast("Right stick reset / "), 2000, toastTexts().join("; "))
            verify(lastSaved().settings === undefined, "the stick's settings are gone")
            compare(find("rowCurve").currentLabel, "Linear")
            verify(!find("rowInvert").checked)
            verify(find("rowResetStick").activeFocus)
        }

        function test_the_preview_follows_the_stream() {
            openStick("left")
            tryVerify(() => Input.mockTestRunning(ds), 2000, "the stream runs while the page is open")
            verify(find("stickPreviewLive").visible && !find("stickPreviewEmpty").visible)
            Input.mockTestInput(ds, "left_x", Math.round(0.53 * 32767), "raw:pad:3:0")
            Input.mockTestInput(ds, "right_x", 32767, "raw:pad:3:3")          // the other stick: not this page's
            tryCompare(find("stickReadout"), "text", "In 0.53 · Out 0.50")
            const dot = findChild(find("plotPosition"), "outputDot")
            fuzzyCompare(dot.x + dot.width / 2 - 160, 0.5 * 160, 0.5, "the output dot at radius out")
            const ring = findChild(find("plotPosition"), "rawRing")
            fuzzyCompare(ring.x + ring.width / 2 - 160, 0.53 * 160, 0.5, "the raw ring at radius r")
            DeviceSettings.language = "tr"
            tryCompare(find("stickReadout"), "text", "Giriş 0,53 · Çıkış 0,50")
            const left = find("axisStick")
            const right = find("axisGameSees")
            tryCompare(right, "text", "↑ Oyunun gördüğü")
            verify(right.x >= left.x + left.width + 16 - 0.5,
                   "the axis captions keep apart: " + (left.x + left.width) + " / " + right.x)
            DeviceSettings.language = "en"
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controls")
            tryVerify(() => !Input.mockTestRunning(ds), 2000, "the stream stops when the page closes")
        }

        function test_the_left_stick_page_holds_the_stick_s_arrow_keys_and_the_right_page_does_not() {
            // The mock plays the service's stick-to-arrow path (off for every other test): a pushed
            // left stick is an arrow key unless the running test holds it (RUY-479).
            Input.mockStickNavigates(true)
            openStick("left")
            tryVerify(() => Input.mockTestRunning(ds), 2000)
            verify(Input.mockTestHoldsLeftStick(ds), "the Left stick page starts its test holding the stick")
            compare(find("rowInner").value, 8)
            Input.mockTestInput(ds, "left_x", 32767, "raw:pad:3:0")
            Input.mockTestInput(ds, "left_x", 0, "raw:pad:3:0")
            Input.mockTestInput(ds, "left_y", 32767, "raw:pad:3:1")
            Input.mockTestInput(ds, "left_y", 0, "raw:pad:3:1")
            compare(find("rowInner").value, 8, "the slider did not move")
            verify(find("rowInner").activeFocus, "the focus did not move")
            tryCompare(find("stickReadout"), "text", "In 0.00 · Out 0.00")      // the stream still reached the preview
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controls")
            tryVerify(() => !Input.mockTestRunning(ds), 2000)

            focusRow("controlsBody", "rowRightStick")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controlsStick")
            tryVerify(() => find("rowInner") !== null && find("rowInner").activeFocus, 2000)
            tryVerify(() => Input.mockTestRunning(ds), 2000)
            verify(!Input.mockTestHoldsLeftStick(ds), "the Right stick page does not hold it")
            compare(find("rowInner").value, 8)
            Input.mockTestInput(ds, "left_x", 32767, "raw:pad:3:0")
            compare(find("rowInner").value, 9, "without the hold the same push moves the slider")
            Input.mockTestInput(ds, "left_y", 32767, "raw:pad:3:1")
            tryVerify(() => find("rowOuter").activeFocus, 2000, "and the focus")
        }

        function test_the_stick_editor_without_a_controller() {
            for (const id of [ds, xbox, pro])
                Input.mockRemoveDevice(id)
            tryVerify(() => Input.devices.length === 0)
            tc.shell.openPage("controlsStick", { side: "left" })
            tryCompare(tc.shell, "currentPage", "controlsStick")
            tryVerify(() => find("rowInner") !== null && find("rowInner").activeFocus, 2000)
            verify(find("stickPreviewEmpty").visible && !find("stickPreviewLive").visible)
            compare(find("stickPreviewEmptyText").text, "Connect a controller to see the stick move.")
            keyClick(Qt.Key_Right)
            tryVerify(() => calls("SaveProfile").length === 1, 2000, "the rows still work")
        }

        // ---- export and import -----------------------------------------------------------------------------------

        function test_export_writes_the_file_and_says_so() {
            plugStick()
            openControls()
            focusRow("controlsBody", "rowExport")
            keyClick(Qt.Key_Return)
            const name = Input.exportFileName("p2")
            tryVerify(() => hasToast("Saved to the USB drive / " + name), 2000, toastTexts().join("; "))
            verify(Object.keys(Storage.mockSavedFiles()).indexOf(name) >= 0, "the file is on the stick")
            compare(JSON.parse(Storage.mockSavedFiles()[name]).id, dsOwn, "the pad's controls (RUY-545)")
            verify(find("rowExport").activeFocus)
            clearToasts()
            Storage.mockSetSaveStatus("read-only")
            keyClick(Qt.Key_Return)
            tryVerify(() => hasToast("Could not save to the USB drive / Try again."), 2000, toastTexts().join("; "))
        }

        function openImport() {
            plugStick()
            openControls()
            focusRow("controlsBody", "rowImport")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("controlsImport") !== null && find("controlsImport").shown, 2000, "the picker opens")
            tryVerify(() => find("controlsImport").listState !== "loading" && find("controlsImport").opacity >= 1, 2000)
            return find("controlsImport")
        }

        function profileText(id, extra) {
            const p = { schema_version: 1, id: id, name: "From " + id, scope: { type: "global" } }
            for (const k in (extra || {}))
                p[k] = extra[k]
            return JSON.stringify(p)
        }

        function test_import_lists_the_files_and_imports_one() {
            Storage.mockSetFile("vol-stick", "old-controls.json", profileText("old"), 1731412800)       // 12 Nov 2024, midday UTC
            Storage.mockSetFile("vol-stick", "my-controls.json", profileText("mine", { inherits: "nintendo" }), 1731456000)
            Storage.mockSetFile("vol-stick", "notes.txt", "x", 1731456100)
            const picker = openImport()
            compare(findChild(picker, "controlsImportTitle").text, "Import from USB drive")
            compare(findChild(picker, "controlsImportDrive").text, "Ruya Stick")
            compare(picker.files.map(f => f.name), ["my-controls.json", "old-controls.json"], "the .json files, newest first")
            tryVerify(() => find("controlsImportFile_0").activeFocus, 2000, "focus on the first")
            tryVerify(() => find("controlsImportFile_1") !== null, 2000)
            compare(find("controlsImportFile_1").value, "12 Nov")
            compare(hintVerbs(), "A Import|B Cancel")
            keyClick(Qt.Key_Up)
            verify(find("controlsImportFile_0").activeFocus, "Up clamps")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("controlsImportFile_1").activeFocus, "Down clamps")
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Return)
            tryVerify(() => hasToast("Controls imported / my-controls.json"), 2000, toastTexts().join("; "))
            tryVerify(() => !picker.shown, 2000, "the sheet closes")
            tryVerify(() => find("rowImport").activeFocus, 2000, "back on the Import row")
            tryCompare(find("rowLayout"), "currentLabel", "Nintendo")
            tryVerify(() => GameControls.changed)
        }

        // RUY-572: an import on a pad's page lands in the slot that page edits, not in all controllers.
        function test_an_import_on_one_pad_s_page_changes_only_that_pad() {
            Storage.mockSetFile("vol-stick", "mine.json", profileText("mine", { inherits: "nintendo" }), 1731456000)
            const picker = openImport()
            tryVerify(() => find("controlsImportFile_0").activeFocus, 2000)
            compare(GameControls.pad.id, ds, "the DualSense's page")
            keyClick(Qt.Key_Return)
            tryVerify(() => hasToast("Controls imported / mine.json"), 2000, toastTexts().join("; "))
            tryVerify(() => !picker.shown, 2000)
            const saved = savesOf(dsOwn)
            compare(saved.length, 1, "saved as the DualSense's own profile")
            compare(saved[0].match, { device: ds })
            compare(savesOf("mine").length, 0, "not under the file's own id")
            tryVerify(() => chainOf(ds)[0] === dsOwn, 2000, "the DualSense takes it")
            compare(chainOf(ds)[1], "nintendo")
            compare(chainOf(pro), ["default"], "the Pro Controller is untouched")
            tryCompare(find("rowAppliesTo"), "currentLabel", "This DualSense")
        }

        function test_an_import_with_applies_to_all_controllers_goes_to_the_all_slot() {
            given("controls-all", {}, "", ds)
            Storage.mockSetFile("vol-stick", "mine.json", profileText("mine", { inherits: "nintendo" }), 1731456000)
            const picker = openImport()
            compare(find("rowAppliesTo").currentLabel, "All controllers")
            tryVerify(() => find("controlsImportFile_0").activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => hasToast("Controls imported / mine.json"), 2000, toastTexts().join("; "))
            tryVerify(() => !picker.shown, 2000)
            compare(savesOf("controls-all").length, 2, "the given one and the import")
            verify(savesOf("controls-all")[1].match === undefined, "no slot narrower than all")
            tryVerify(() => chainOf(pro)[0] === "controls-all", 2000, "the Pro Controller takes it too")
            compare(chainOf(pro)[1], "nintendo")
            compare(savesOf(dsOwn).length, 0, "no copy for the DualSense")
        }

        function test_a_refused_import_keeps_the_sheet_open() {
            Storage.mockSetFile("vol-stick", "big.json", profileText("big") + " ".repeat(65536), 1731456000)
            Storage.mockSetFile("vol-stick", "bad.json", '{"schema_version":2}', 1731369600)
            const picker = openImport()
            tryVerify(() => find("controlsImportFile_0").activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => hasToast("That file can't be used / It is larger than 64 KB."), 2000, toastTexts().join("; "))
            verify(picker.shown, "the sheet stays")
            tryVerify(() => find("controlsImportFile_0").activeFocus, 2000, "on that file")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => hasToast("That file can't be used / It isn't a RuyaOS controls file."), 2000, toastTexts().join("; "))
            verify(picker.shown)
            verify(find("controlsImportFile_1").activeFocus)
            compare(calls("SaveProfile").length, 0, "nothing saved")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !picker.shown, 2000)
            tryVerify(() => find("rowImport").activeFocus, 2000, "Back returns the focus to Import")
        }

        function test_a_drive_without_controls_files_says_so() {
            const picker = openImport()
            tryVerify(() => find("controlsImportNone").visible, 2000, "the unavailable line")
            verify(!find("controlsImportNone").enabled, "it takes no focus")
            compare(find("controlsImportNone").label, "No controls files on this drive.")
            verify(picker.activeFocus, "the sheet holds the keys")
            compare(hintVerbs(), "B Cancel")
            keyClick(Qt.Key_Return)
            verify(picker.shown, "nothing to import")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !picker.shown, 2000)
            tryVerify(() => find("rowImport").activeFocus, 2000)
        }

        // ---- reset -------------------------------------------------------------------------------------------------

        function test_reset_asks_first_and_puts_everything_back() {
            openControls()
            focusRow("controlsBody", "rowLayout")
            keyClick(Qt.Key_Right)
            tryVerify(() => GameControls.changed, 2000)
            focusRow("controlsBody", "rowReset")
            keyClick(Qt.Key_Return)
            const dialog = find("controlsResetConfirm")
            tryVerify(() => dialog.shown, 2000)
            compare(findChild(dialog, "powerConfirmTitle").text, "Reset controls in games?")
            compare(findChild(dialog, "powerConfirmDetail").text, "Every button, stick and curve goes back to the default.")
            compare(findChild(dialog, "powerConfirmLabel").text, "Reset controls")
            verify(findChild(dialog, "powerCancel").activeFocus, "Cancel first")
            compare(hintVerbs(), "A Select|B Cancel")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !dialog.shown, 2000)
            tryVerify(() => find("rowReset").activeFocus, 2000, "Back is Cancel: focus on Reset")
            compare(calls("DeleteProfile").length, 0)
            keyClick(Qt.Key_Return)
            tryVerify(() => dialog.shown, 2000)
            keyClick(Qt.Key_Right)
            verify(findChild(dialog, "powerConfirm").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => calls("DeleteProfile").length === 1, 2000)
            compare(calls("DeleteProfile")[0].args, { profile: "p2", profile_id: dsOwn }, "the pad's own profile (RUY-545)")
            tryVerify(() => !GameControls.changed, 2000)
            compare(find("rowLayout").currentLabel, "Standard")
            tryVerify(() => find("rowReset").activeFocus, 2000, "the focus returns to Reset")
        }

        // ---- the Settings pane's states ----------------------------------------------------------------------

        function test_no_pad_puts_the_row_after_pair() {
            tc.shell.openPage("settings", { category: "controllers" })
            tryCompare(tc.shell, "currentPage", "settings")
            keyClick(Qt.Key_Right)
            for (const id of [ds, xbox, pro])
                Input.mockRemoveDevice(id)
            tryVerify(() => find("rowPadsNone").visible, 2000)
            tryVerify(() => find("rowPadsPair").activeFocus, 2000)
            compare(rowNames("paneControllers"), ["rowPadsPair", "rowControlsInGamesLast"])
            keyClick(Qt.Key_Down)
            verify(find("rowControlsInGamesLast").activeFocus)
            compare(find("rowControlsInGamesLast").value, "Default")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controls")
            tryVerify(() => find("rowAppliesTo").activeFocus, 2000)
            compare(find("rowAppliesTo").options.map(o => o.label), ["All controllers"], "no pad: one choice")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("rowControlsInGamesLast").activeFocus, 2000)
        }

        function test_a_failed_list_dims_the_row() {
            tc.shell.openPage("settings", { category: "controllers" })
            tryCompare(tc.shell, "currentPage", "settings")
            keyClick(Qt.Key_Right)
            Input.mockListFail(true)
            Input.refreshDevices()
            tryCompare(Input, "devicesState", "failed")
            tryVerify(() => find("rowPadsRetry").activeFocus, 2000)
            compare(rowNames("paneControllers"),
                    ["rowPadsRetry", "rowConfirmButtonUnavailable", "rowControlsInGames", "rowPadsPair"])
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("rowControlsInGames").activeFocus)
            verify(find("rowControlsInGames").dimmed)
            compare(find("rowControlsInGames").value, "Not available")
            keyClick(Qt.Key_Return)
            tryVerify(() => hasToast("Controls in games: Not available. / "), 2000, toastTexts().join("; "))
            compare(tc.shell.currentPage, "settings", "nothing opens")
            Input.mockListFail(false)
        }

        // ---- screenshots ------------------------------------------------------------------------------------------

        function settle() {
            wait(600)
            grabImage(tc.shell)                          // the first grab lays the pane out
            wait(400)
        }

        function shots(dir, lang, suffix) {
            plugStick()
            wait(Storage.groupWindowMs + 300)            // the "Drive inserted" toast is not what these shots show
            clearToasts()
            openControls()
            focusRow("controlsBody", "rowRemap")
            settle()
            grabImage(tc.shell).save(dir + "28-controls-" + lang + suffix + ".png")
            focusRow("controlsBody", "rowReset")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("controlsResetConfirm").shown, 2000)
            settle()
            grabImage(tc.shell).save(dir + "28-controls-reset-" + lang + suffix + ".png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("rowReset").activeFocus, 2000)
            // The import picker, then a refused file.
            Storage.mockSetFile("vol-stick", "RuyaOS-controls-p2-2026-11-12.json", profileText("mine"), 1762905600)
            Storage.mockSetFile("vol-stick", "racing-wheel-layout.json", '{"schema_version":2}', 1762819200)
            focusRow("controlsBody", "rowImport")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("controlsImport").shown && find("controlsImportFile_0") !== null, 2000)
            settle()
            grabImage(tc.shell).save(dir + "28-controls-import-" + lang + suffix + ".png")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => Notifications.model.count > 0, 2000)
            settle()
            grabImage(tc.shell).save(dir + "28-controls-import-refused-" + lang + suffix + ".png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("rowImport").activeFocus, 2000)
            clearToasts()
            // Remap: the list after one change, then the capture dialog.
            focusRow("controlsBody", "rowRemap")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("remap_south") !== null && find("remap_south").activeFocus, 2000)
            openCapture("south")
            Input.mockTestInput(ds, "east", 1, "raw:pad:1:305")
            Input.mockTestInput(ds, "east", 0, "raw:pad:1:305")
            tryVerify(() => find("remap_south").activeFocus, 2000)
            clearToasts()
            settle()
            grabImage(tc.shell).save(dir + "28-controls-remap-" + lang + suffix + ".png")
            openCapture("west")
            Theme.motionFactor = 1.0                     // the bar mid-drain, as on the console
            wait(1500)
            grabImage(tc.shell).save(dir + "28-controls-capture-" + lang + suffix + ".png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("remap_west").activeFocus, 2000)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controls")
            // RUY-572: the page after an edit: Applies to = This DualSense, a Remap count.
            tryCompare(GameControls, "appliesTo", "device")
            focusRow("controlsBody", "rowAppliesTo")
            clearToasts()
            settle()
            grabImage(tc.shell).save(dir + "28-controls-edited-" + lang + suffix + ".png")
            // The stick editor: default, then inner 12 % and Precise with the stick pushed.
            focusRow("controlsBody", "rowLeftStick")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("rowInner") !== null && find("rowInner").activeFocus, 2000)
            tryVerify(() => Input.mockTestRunning(ds), 2000)
            Input.mockTestInput(ds, "left_x", 18000, "raw:pad:3:0")
            Input.mockTestInput(ds, "left_y", -16000, "raw:pad:3:1")
            settle()
            grabImage(tc.shell).save(dir + "28-controls-stick-" + lang + suffix + ".png")
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            focusRow("stickBody", "rowCurve")
            keyClick(Qt.Key_Right)
            tryVerify(() => calls("SaveProfile").length > 0 && lastSaved().settings?.left_stick?.curve === "precise", 3000)
            clearToasts()
            settle()
            grabImage(tc.shell).save(dir + "28-controls-stick-changed-" + lang + suffix + ".png")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "controls")
            // No drive, then no controller.
            Storage.mockReset()
            tryVerify(() => find("rowNoDrive").visible, 2000)
            settle()
            grabImage(tc.shell).save(dir + "28-controls-no-drive-" + lang + suffix + ".png")
            for (const id of [ds, xbox, pro])
                Input.mockRemoveDevice(id)
            focusRow("controlsBody", "rowLeftStick")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("stickPreviewEmpty") !== null && find("stickPreviewEmpty").visible, 2000)
            settle()
            grabImage(tc.shell).save(dir + "28-controls-stick-no-controller-" + lang + suffix + ".png")
            Theme.motionFactor = 1.0
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            shots(shotsDir + "/", "en", "")
        }

        function test_zz_screenshots_tr() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.language = "tr"
            shots(shotsDir + "/", "tr", "")
        }

        function test_zz_screenshots_720p() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            host.width = 1280
            host.height = 720
            shots(shotsDir + "/", "en", "-720p")
        }

        function test_zz_screenshots_720p_tr() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            host.width = 1280
            host.height = 720
            DeviceSettings.language = "tr"
            shots(shotsDir + "/", "tr", "-720p")
        }
    }
}
