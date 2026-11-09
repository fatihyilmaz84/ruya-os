import QtQuick
import QtTest
import RuyaShell

// The hint bar (T-158): what the buttons do on the screen on top, never focusable, clear of the
// Recent row and inside the safe area, hidden while an app is focused. Signs in as "Ada" (p2).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    Component {
        id: appComponent
        Item { objectName: "standInApp"; Keys.onPressed: event => { event.accepted = true } }
    }

    Component { id: barePane; SettingsPane { } }
    Component { id: wallpaperComponent; WallpaperPicker { anchors.fill: parent } }
    Component { id: zoneComponent; ZonePicker { anchors.fill: parent } }
    Component { id: confirmComponent; PowerConfirm { anchors.fill: parent } }

    Component {
        id: pinComponent
        PinPad { anchors.fill: parent }
    }

    Component {
        id: entryComponent
        TextEntry { anchors.fill: parent }
    }

    TestCase {
        id: tc
        name: "Hints"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        // The hints as "A Select|B Back", read from the bar's own delegates (what is drawn).
        function shown() {
            const bar = find("hintBar")
            if (!bar.visible)
                return ""
            const parts = []
            for (const b of ["Left/Right", "A", "B", "X", "Y", "LBRB", "Start"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        function init() {
            DeviceSettings.effectsQuality = "high"
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
        }

        function signInAsAda() {
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function test_home_and_page() {
            signInAsAda()
            compare(tc.shown(), "A Select|LBRB Sections")
            verify(find("homePlay").activeFocus)

            tc.shell.openPage("settings")
            tryCompare(tc.shell, "currentPage", "settings")
            compare(tc.shown(), "A Select|B Back")
            verify(!find("hintBar").activeFocus)
            // T-189: this read `tc.shell.activeFocusItem`, which Shell does not have, so it was
            // `undefined !== ...` and always true; the window has the property.
            verify(tc.shell.Window.window.activeFocusItem !== find("hintBar"))

            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Back returns focus to Play")
            compare(tc.shown(), "A Select|LBRB Sections")
        }

        function test_sections_is_one_hint_with_two_glyphs() {
            signInAsAda()
            const hint = find("hint_LBRB")
            verify(hint, "one hint for LB and RB")
            compare(hint.verb, "Sections")
            compare(findChild(tc.shell, "hint_LB"), null)
            compare(findChild(tc.shell, "hint_RB"), null)
            // the glyphs sit in a Repeater inside the hint row
            const found = []
            collectGlyphs(hint, found)
            compare(found.join(","), "LB,RB")
        }

        // A top-level function: qmllint goes blind on a local declared inside a nested function (T-189).
        function collectGlyphs(it, found) {
            for (const c of it.children) {
                if (c.button !== undefined)
                    found.push(c.button)
                else
                    collectGlyphs(c, found)
            }
        }

        function test_placeholder_page_and_about_show_only_back() {
            signInAsAda()
            tc.shell.openPage("media")
            tryCompare(tc.shell, "currentPage", "media")
            compare(tc.shown(), "B Back")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homePlay").activeFocus, 2000)

            tc.shell.openPage("settings")
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000)
            compare(tc.shown(), "A Select|B Back")
            for (let i = 0; i < 9; ++i)
                keyClick(Qt.Key_Down)
            tryCompare(find("categoryList"), "currentIndex", 9)
            compare(tc.shown(), "A Select|B Back", "the category list still enters About")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("paneAbout").activeFocus, 2000, "About took focus")
            compare(tc.shown(), "B Back", "a fact row of About does nothing on A")
            // The last row opens System information (T-226): that one row offers A.
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("aboutSystemInfo").activeFocus, 2000)
            compare(tc.shown(), "A Select|B Back", "the System information row")
            keyClick(Qt.Key_Up)
            tryVerify(() => !find("aboutSystemInfo").activeFocus, 2000)
            compare(tc.shown(), "B Back")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000)
            compare(tc.shown(), "A Select|B Back")
        }

        function test_panes_supply_their_own_hints() {
            signInAsAda()
            tc.shell.openPage("settings")
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000)
            find("paneMyProfile").forceActiveFocus()
            tryVerify(() => find("paneMyProfile").activeFocus, 2000)
            tryVerify(() => find("rowWho").activeFocus, 2000, "the pane opens on the read-only identity row")
            compare(tc.shown(), "B Back", "A does nothing on the identity row")
            compare(shownOf(find("paneMyProfile")), "B Back")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowRenameMe").activeFocus)
            compare(tc.shown(), "A Select|B Back")
            compare(find("paneAbout"), null, "About is built when it is first selected (T-349)")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000)
            for (let i = 0; i < 9; ++i)
                keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("paneAbout").activeFocus, 2000)
            compare(shownOf(find("paneAbout")), "B Back")
            compare(tc.shown(), "B Back", "About's own hints")
            // A pane that sets no hints gets the default.
            const bare = createTemporaryObject(barePane, host)
            compare(shownOf(bare), "A Select|B Back")
        }
        function shownOf(pane) { return pane.hints.map(h => h.button + " " + h.text).join("|") }

        function test_mock_badge_is_bottom_right_off_the_bar() {
            signInAsAda()
            const badge = find("mockBadge")
            const bar = find("hintBar")
            verify(badge.visible)
            const b = badge.mapToItem(tc.shell, 0, 0)
            verify(b.x > tc.shell.width / 2, "badge on the right half")
            verify(b.x + badge.width <= find("versionTag").mapToItem(tc.shell, 0, 0).x, "left of the version tag")
            verify(b.y > tc.shell.height * 0.9, "at the bottom edge, not above the bar's row")
            verify(!(b.x < bar.mapToItem(tc.shell, bar.width, 0).x), "clear of the hint bar")
        }

        function test_overlay() {
            signInAsAda()
            keyClick(Qt.Key_HomePage)
            tryCompare(find("systemPanel"), "open", true)
            compare(tc.shown(), "A Select|B Close")
            verify(!find("hintBar").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(find("systemPanel"), "open", false)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            compare(tc.shown(), "A Select|LBRB Sections")
        }

        function test_pin_pad_modal() {
            signInAsAda()
            const pad = createTemporaryObject(pinComponent, find("modalLayer"))
            verify(pad)
            pad.collect("New PIN", false)
            tryVerify(() => pad.activeFocus, 2000, "the pad takes focus")
            compare(tc.shown(), "B Cancel")
            verify(!find("hintBar").activeFocus)
            pad.destroy()
        }

        // T-194: the on-screen keyboard says what Back does with the text in the field.
        function test_text_entry_back_cue() {
            signInAsAda()
            const entry = createTemporaryObject(entryComponent, find("modalLayer"))
            verify(entry)
            entry.open("Name", "ab")
            tryVerify(() => entry.activeFocus, 2000, "the keyboard takes focus")
            compare(tc.shown(), "A Type|B Delete|Start Done")
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            compare(entry.text, "")
            compare(tc.shown(), "A Type|B Cancel|Start Done", "an empty field: Back cancels")
            entry.destroy()
        }

        // T-285: every modal that takes Accept says "A Select".
        function test_modals_that_take_accept_say_select() {
            signInAsAda()
            const layer = find("modalLayer")
            const wp = createTemporaryObject(wallpaperComponent, layer)
            wp.open()
            tryVerify(() => tc.shell.Window.window.activeFocusItem && tc.hasAncestor(tc.shell.Window.window.activeFocusItem, wp), 2000)
            compare(tc.shown(), "A Select|B Cancel", "wallpaper picker")
            wp.close()
            const zone = createTemporaryObject(zoneComponent, layer)
            zone.open()
            tryVerify(() => tc.hasAncestor(tc.shell.Window.window.activeFocusItem, zone), 2000)
            compare(tc.shown(), "A Select|B Cancel", "zone chooser")
            zone.close()
            const confirm = createTemporaryObject(confirmComponent, layer)
            confirm.open("restart")
            tryVerify(() => confirm.shown && tc.hasAncestor(tc.shell.Window.window.activeFocusItem, confirm), 2000)
            compare(tc.shown(), "A Select|B Cancel", "power confirm")
            confirm.close()
        }
        function hasAncestor(item, ancestor) {
            for (let p = item; p; p = p.parent) {
                if (p === ancestor)
                    return true
            }
            return false
        }

        function test_mode_picker_says_select() {
            Display.mockReset()
            tryVerify(() => Display.available)
            signInAsAda()
            tc.shell.openPage("settings", { category: "display" })
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus, 2000)
            for (let i = 0; i < 12 && !find("rowResolution").activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(find("rowResolution").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("resolutionPicker").shown)
            tryVerify(() => tc.hasAncestor(tc.shell.Window.window.activeFocusItem, find("resolutionPicker")), 2000)
            compare(tc.shown(), "A Select|B Cancel", "mode picker")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("resolutionPicker").shown)
            Display.mockReset()
        }

        function test_choice_row_pane_says_left_right() {
            signInAsAda()
            tc.shell.openPage("settings")
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000)
            for (let i = 0; i < 7; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => find("category_power"))
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowScreenSaver").activeFocus, 2000, "the first row has focus")
            compare(tc.shown(), "Left/Right Change|B Back")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000)
        }

        function test_activity_chart_says_left_right() {
            signInAsAda()
            tc.shell.openPage("activity")
            tryCompare(tc.shell, "currentPage", "activity")
            tryCompare(Usage, "ready", true)
            tryVerify(() => find("activityWeek").activeFocus, 2000, "the chart row has focus first")
            compare(tc.shown(), "Left/Right Browse|B Back")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(!find("activityWeek").activeFocus)
            verify(tc.shown().indexOf("Left/Right") < 0, "other rows: " + tc.shown())
        }

        function test_picker_pin_pad() {
            // Player One (first profile) has a PIN: its pad replaces the chooser.
            keyClick(Qt.Key_Return)
            tryVerify(() => find("pinPad").shown, 2000, "the picker's PIN pad opens")
            tryVerify(() => find("pinKeys").activeFocus, 2000)
            compare(tc.shown(), "B Cancel")
            verify(!find("hintBar").activeFocus)
        }

        function test_home_layout() {
            signInAsAda()
            for (const tier of ["high", "performance"]) {
                DeviceSettings.effectsQuality = tier
                const bar = find("hintBar")
                const row = find("recentRow")
                const bottomOfRow = row.mapToItem(tc.shell, 0, row.height).y
                const barTop = bar.mapToItem(tc.shell, 0, 0).y
                const barBottom = bar.mapToItem(tc.shell, 0, bar.height).y
                verify(barTop >= bottomOfRow, "bar below the Recent row, tier " + tier + ": " + barTop + " vs " + bottomOfRow)
                verify(barBottom <= tc.shell.height * (1 - Theme.safeArea) + 0.5, "bar inside the safe area, tier " + tier)
                verify(bar.mapToItem(tc.shell, 0, 0).x >= tc.shell.width * Theme.safeArea - 0.5)
            }
        }

        function test_hidden_with_app() {
            signInAsAda()
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app)
            tryVerify(() => app.activeFocus, 2000, "the app takes focus")
            compare(find("hintBar").visible, false)
            tc.shell.removeApp(app)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            compare(find("hintBar").visible, true)
        }

        function test_zz_screenshots_page() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            signInAsAda()
            tc.shell.openPage("settings")
            tryCompare(tc.shell, "currentPage", "settings")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/hints-page.png")
        }
    }
}
