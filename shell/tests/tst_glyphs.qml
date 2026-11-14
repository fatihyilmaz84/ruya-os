import QtQuick
import QtTest
import RuyaShell

// RUY-41 (ADR-027, 06 §11.4, 04 §3.7): the hint bar and every button glyph draw the buttons of the
// device that pressed last. One table (Glyphs.qml): per family and action, after the Confirm setting;
// per family and button position. The active input switches on a press of another device (a pad's
// ActiveInputChanged, a key from a real keyboard), never on a connect.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }
    Component { id: glyphComponent; ButtonGlyph { } }
    Component {
        id: barComponent
        HintBar { hints: [{ action: "accept", text: "Select" }, { action: "back", text: "Back" },
                          { actions: ["tabPrev", "tabNext"], text: "Sections" }, { action: "options", text: "Options" }] }
    }

    TestCase {
        id: tc
        name: "Glyphs"
        when: windowShown

        property Shell shell: null
        readonly property string ds: "bluetooth-054c-0ce6-3f2a9c41d0b7"
        readonly property string xbox: "usb-045e-0b12-8e01c2d4a9f3"
        readonly property string pro: "bluetooth-057e-2009-b7c0e1f2a3d4"

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.language = "en"
            Input.mockResetDevices()
            Input.mockResetProfiles()
            Input.mockActiveInput("", "")
            tryCompare(Input, "activeFamily", "")
            tc.shell = null
        }

        function cleanup() {
            DeviceSettings.language = "en"
            Input.mockActiveInput("", "")
        }

        // What a glyph draws, in one word: its text, "shape:<name>" or "dots:<position>".
        function drawn(g) {
            return g.kind === "text" ? g.shown : g.kind === "shape" ? "shape:" + g.shape : "dots:" + g.dotPosition
        }
        // The glyphs of one hint of a bar.
        function glyphsOf(bar, name) {
            const hint = findChild(bar, name)
            verify(hint, name)
            return hint.children.filter(c => c.kind !== undefined)      // in the model's order
        }
        function glyphOf(action, family, mode) {
            const g = createTemporaryObject(glyphComponent, host, { action: action, family: family, confirmMode: mode ?? "family" })
            verify(g)
            return drawn(g)
        }
        function positionOf(position, family) {
            const g = createTemporaryObject(glyphComponent, host, { position: position, family: family })
            verify(g)
            return drawn(g)
        }

        // ---- the table ---------------------------------------------------------------------------------------

        function test_accept_and_back_per_family_and_confirm_mode_data() {
            return [
                { tag: "xbox", family: "xbox", modes: { family: ["A", "B"], south: ["A", "B"], east: ["B", "A"] } },
                { tag: "playstation", family: "playstation",
                  modes: { family: ["shape:cross", "shape:circle"], south: ["shape:cross", "shape:circle"], east: ["shape:circle", "shape:cross"] } },
                { tag: "nintendo", family: "nintendo", modes: { family: ["A", "B"], south: ["B", "A"], east: ["A", "B"] } },
                { tag: "generic", family: "generic",
                  modes: { family: ["dots:south", "dots:east"], south: ["dots:south", "dots:east"], east: ["dots:east", "dots:south"] } },
                { tag: "an unknown family is generic", family: "steam", modes: { family: ["dots:south", "dots:east"] } },
                { tag: "no press yet: the Xbox letters", family: "", modes: { family: ["A", "B"] } },
                { tag: "keyboard (no Confirm setting)", family: "keyboard", modes: { family: ["Enter", "Esc"], east: ["Enter", "Esc"] } }
            ]
        }
        function test_accept_and_back_per_family_and_confirm_mode(data) {
            for (const mode in data.modes) {
                compare(glyphOf("accept", data.family, mode), data.modes[mode][0], "accept, " + mode)
                compare(glyphOf("back", data.family, mode), data.modes[mode][1], "back, " + mode)
            }
        }

        function test_other_actions_per_family_data() {
            return [
                { tag: "xbox", family: "xbox", want: { tabPrev: "LB", tabNext: "RB", pagePrev: "LT", pageNext: "RT", options: "Menu", view: "View", done: "Menu", left: "←", guide: "Guide" } },
                { tag: "playstation", family: "playstation", want: { tabPrev: "L1", tabNext: "R1", pagePrev: "L2", pageNext: "R2", options: "Options", view: "Create", done: "Options", left: "←", guide: "Guide" } },
                { tag: "nintendo", family: "nintendo", want: { tabPrev: "L", tabNext: "R", pagePrev: "ZL", pageNext: "ZR", options: "+", view: "−", done: "+", left: "←", guide: "Home" } },
                { tag: "generic", family: "generic", want: { tabPrev: "LB", tabNext: "RB", options: "Menu", right: "→" } },
                { tag: "keyboard: key caps", family: "keyboard", want: { tabPrev: "PgUp", tabNext: "PgDn", pagePrev: "Home", pageNext: "End", options: "Menu", view: "Tab", done: "Enter", up: "↑", down: "↓", left: "←", right: "→", guide: "Super" } }
            ]
        }
        function test_other_actions_per_family(data) {
            for (const action in data.want)
                compare(glyphOf(action, data.family), data.want[action], action)
        }

        // The printed label of each face position (06 §11.4; RUY-500 draws "Games see [B] as A" from it).
        function test_positions_per_family_data() {
            return [
                { tag: "xbox", family: "xbox", glyphs: ["Y", "B", "A", "X"], names: ["Y", "B", "A", "X"] },
                { tag: "playstation", family: "playstation", glyphs: ["shape:triangle", "shape:circle", "shape:cross", "shape:square"],
                  names: ["Triangle", "Circle", "Cross", "Square"] },
                { tag: "nintendo", family: "nintendo", glyphs: ["X", "A", "B", "Y"], names: ["X", "A", "B", "Y"] },
                { tag: "generic", family: "generic", glyphs: ["dots:north", "dots:east", "dots:south", "dots:west"],
                  names: ["Top button", "Right button", "Bottom button", "Left button"] }
            ]
        }
        function test_positions_per_family(data) {
            const order = ["north", "east", "south", "west"]
            for (let i = 0; i < 4; ++i) {
                compare(positionOf(order[i], data.family), data.glyphs[i], order[i])
                compare(Glyphs.labelForPosition(order[i], data.family), data.names[i], order[i] + " in words")
            }
            compare(positionOf("l1", "playstation"), "L1")
            compare(positionOf("right_trigger", "nintendo"), "ZR")
            compare(positionOf("dpad_up", "xbox"), "↑")
        }

        function test_the_generic_glyph_fills_one_dot_of_four() {
            const g = createTemporaryObject(glyphComponent, host, { position: "east", family: "generic" })
            for (const p of ["north", "east", "south", "west"])
                compare(findChild(g, "glyphDot_" + p).filled, p === "east", p)
            verify(findChild(g, "glyphDots").visible)
            verify(!findChild(g, "glyphShape").visible)
            verify(!findChild(g, "glyphText").visible)
        }

        // Geometry at the hint bar's size: a shape sits inside its circle; a key cap is a pill.
        function test_glyph_geometry_at_the_hint_bar_size() {
            const shape = createTemporaryObject(glyphComponent, host, { action: "accept", family: "playstation", u: 1 })
            compare(shape.height, Theme.glyphSize)
            compare(shape.width, shape.height, "a shape glyph is a circle")
            const s = findChild(shape, "glyphShape")
            verify(s.visible)
            compare(s.width, shape.height / 2)
            const cap = createTemporaryObject(glyphComponent, host, { action: "accept", family: "keyboard", u: 1 })
            verify(cap.width > cap.height, "Enter is a pill: " + cap.width)
            compare(cap.radius, cap.height / 2)
        }

        // ---- the active input -----------------------------------------------------------------------------

        function test_glyphs_follow_the_pad_that_pressed() {
            const bar = createTemporaryObject(barComponent, host)
            const first = () => glyphsOf(bar, "hint_accept")[0]
            compare(drawn(first()), "A", "no press yet: Xbox letters")
            Input.mockActiveInput(ds, "playstation")
            tryCompare(Input, "activeFamily", "playstation")
            compare(drawn(first()), "shape:cross")
            compare(drawn(glyphsOf(bar, "hint_tabPrev_tabNext")[0]), "L1")
            Input.mockActiveInput(pro, "nintendo")
            tryCompare(Input, "activeFamily", "nintendo")
            compare(drawn(first()), "A", "A is the right button on a Nintendo pad")
            compare(drawn(glyphsOf(bar, "hint_back")[0]), "B")
            compare(drawn(glyphsOf(bar, "hint_options")[0]), "+")
            Input.mockActiveInput(xbox, "xbox")
            tryCompare(Input, "activeFamily", "xbox")
            compare(drawn(first()), "A")
            compare(drawn(glyphsOf(bar, "hint_options")[0]), "Menu")
        }

        // A ButtonGlyph that names no family draws the active input's (the toast footer, any caller).
        function test_a_glyph_without_a_family_follows_the_active_input() {
            const g = createTemporaryObject(glyphComponent, host, { action: "accept" })
            compare(drawn(g), "A")
            Input.mockActiveInput(ds, "playstation")
            tryCompare(Input, "activeFamily", "playstation")
            compare(drawn(g), "shape:cross")
            Input.mockKeyFrom("USB Keyboard", Qt.Key_Return)
            compare(drawn(g), "Enter")
        }

        function test_accept_follows_the_active_pads_confirm_mode() {
            const bar = createTemporaryObject(barComponent, host)
            Input.setRoute("shell", "", "", "p2")
            Input.setConfirmButton(ds, "east")
            tryVerify(() => Input.mockConfirmButton("p2", ds) === "east", 2000)
            Input.mockActiveInput(ds, "playstation")
            tryCompare(Input, "confirmButton", "east")
            compare(drawn(glyphsOf(bar, "hint_accept")[0]), "shape:circle", "with Right, Circle confirms")
            compare(drawn(glyphsOf(bar, "hint_back")[0]), "shape:cross")
            Input.mockActiveInput(xbox, "xbox")
            tryCompare(Input, "confirmButton", "family")
            compare(drawn(glyphsOf(bar, "hint_accept")[0]), "A")
        }

        function test_a_key_from_a_keyboard_shows_key_caps() {
            const bar = createTemporaryObject(barComponent, host)
            Input.mockActiveInput(ds, "playstation")
            tryCompare(Input, "activeFamily", "playstation")
            Input.mockKeyFrom("AT Translated Set 2 keyboard", Qt.Key_Down)
            compare(Input.activeFamily, "keyboard")
            compare(Input.activeDevice, "")
            compare(drawn(glyphsOf(bar, "hint_accept")[0]), "Enter")
            compare(drawn(glyphsOf(bar, "hint_back")[0]), "Esc")
            compare(drawn(glyphsOf(bar, "hint_tabPrev_tabNext")[0]), "PgUp")
            compare(drawn(glyphsOf(bar, "hint_tabPrev_tabNext")[1]), "PgDn")
            // The same pad pressing again: the service does not announce it a second time, but its
            // keys come from the navigation device, which brings the pad back.
            Input.mockKeyFrom("RuyaOS Navigation", Qt.Key_Return)
            compare(Input.activeFamily, "playstation")
            compare(Input.activeDevice, ds)
            compare(drawn(glyphsOf(bar, "hint_accept")[0]), "shape:cross")
            // Another pad's press while the keyboard is active switches to that pad.
            Input.mockKeyFrom("USB Keyboard", Qt.Key_A)
            compare(Input.activeFamily, "keyboard")
            Input.mockActiveInput(pro, "nintendo")
            tryCompare(Input, "activeFamily", "nintendo")
        }

        function test_keys_that_do_not_tell_the_keyboard_apart_change_nothing() {
            Input.mockActiveInput(ds, "playstation")
            tryCompare(Input, "activeFamily", "playstation")
            Input.mockKeyFrom("", Qt.Key_Down)                          // no device name
            Input.mockKeyFrom("core keyboard", Qt.Key_Down)             // Qt's own: a platform that names none
            Input.mockKeyFrom("RuyaOS Navigation", Qt.Key_Down)         // the pad itself
            Input.mockKeyFrom("Consumer Control", Qt.Key_VolumeUp)      // a remote's volume key
            Input.mockKeyFrom("Power Button", Qt.Key_PowerOff)
            compare(Input.activeFamily, "playstation")
            keyClick(Qt.Key_Down)                                       // a test's key: Qt's core keyboard
            compare(Input.activeFamily, "playstation")
            compare(Input.activeDevice, ds)
        }

        function test_a_connect_does_not_switch() {
            const bar = createTemporaryObject(barComponent, host)
            Input.mockActiveInput(xbox, "xbox")
            tryCompare(Input, "activeFamily", "xbox")
            Input.mockAddDevice({ id: "usb-054c-0ce6-aa11bb22cc33", name: "DualSense Wireless Controller", family: "playstation",
                                  connection: "usb", battery: -1 })
            tryVerify(() => Input.devices.length === 4)
            wait(50)
            compare(Input.activeFamily, "xbox", "a pad that connects is not the active input")
            compare(drawn(glyphsOf(bar, "hint_accept")[0]), "A")
            Input.mockRemoveDevice("usb-054c-0ce6-aa11bb22cc33")
            tryVerify(() => Input.devices.length === 3)
            compare(Input.activeFamily, "xbox")
        }

        // A screen reader hears the family's names.
        function test_the_accessible_name_is_the_printed_label() {
            const g = createTemporaryObject(glyphComponent, host, { action: "accept", family: "playstation" })
            compare(g.Accessible.name, "Cross")
            g.family = "xbox"
            compare(g.Accessible.name, "A")
            g.family = "generic"
            compare(g.Accessible.name, "Bottom button")
            g.family = "keyboard"
            compare(g.Accessible.name, "Enter")
        }

        // ---- screenshots: Home's and Settings' hint bars per family, a PlayStation pad's page ---------

        function signIn() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            host.width = 1920
            host.height = 1080
            tc.shell = createTemporaryObject(shellComponent, host)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => findChild(tc.shell, "profileList").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => findChild(tc.shell, "homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function familyShots(dir, name, device, family) {
            if (!dir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            signIn()
            if (family === "keyboard")
                Input.mockKeyFrom("USB Keyboard", Qt.Key_Down)
            else
                Input.mockActiveInput(device, family)
            tryCompare(Input, "activeFamily", family)
            wait(800)
            grabImage(tc.shell).save(dir + "/41-glyphs-home-" + name + "-en.png")
            tc.shell.openPage("settings")
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => findChild(tc.shell, "categoryList").activeFocus, 2000)
            keyClick(Qt.Key_Right)                       // into a pane: Change / Next / Back on a choice row
            wait(800)
            grabImage(tc.shell).save(dir + "/41-glyphs-settings-" + name + "-en.png")
        }
        function test_zz_screenshots_xbox() { familyShots(shotsDir, "xbox", xbox, "xbox") }
        function test_zz_screenshots_playstation() { familyShots(shotsDir, "playstation", ds, "playstation") }
        function test_zz_screenshots_nintendo() { familyShots(shotsDir, "nintendo", pro, "nintendo") }
        function test_zz_screenshots_generic() { familyShots(shotsDir, "generic", "usb-2dc8-3106-aabbccddeeff", "generic") }
        function test_zz_screenshots_keyboard() { familyShots(shotsDir, "keyboard", "", "keyboard") }

        function test_zz_screenshots_playstation_controller_page() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            signIn()
            Input.mockActiveInput(ds, "playstation")
            tryCompare(Input, "activeFamily", "playstation")
            tc.shell.openPage("settings", { category: "controllers" })
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => findChild(tc.shell, "categoryList").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            tryVerify(() => findChild(tc.shell, "paneControllers").activeFocus, 2000)
            for (let i = 0; i < 6 && !findChild(tc.shell, "pad_" + ds).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(findChild(tc.shell, "pad_" + ds).activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "controller")
            tryVerify(() => findChild(tc.shell, "rowButtonTest") !== null && findChild(tc.shell, "rowButtonTest").activeFocus, 2000)
            for (let i = 0; i < 3 && !findChild(tc.shell, "rowConfirmButton").activeFocus; ++i)
                keyClick(Qt.Key_Down)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/41-glyphs-controller-playstation-en.png")
        }
    }
}
