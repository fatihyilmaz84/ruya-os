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

    Component {
        id: pinComponent
        PinPad { anchors.fill: parent }
    }

    TestCase {
        id: tc
        name: "Hints"
        when: windowShown

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }

        // The hints as "A Select|B Back", read from the bar's own delegates (what is drawn).
        function shown() {
            const bar = find("hintBar")
            if (!bar.visible)
                return ""
            const parts = []
            for (const b of ["A", "B", "X", "Y", "LBRB", "Start"]) {
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
            verify(tc.shell.activeFocusItem !== find("hintBar"))

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
            const collect = it => { for (const c of it.children) { if (c.button !== undefined) found.push(c.button); else collect(c) } }
            collect(hint)
            compare(found.join(","), "LB,RB")
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
            for (let i = 0; i < 8; ++i)
                keyClick(Qt.Key_Down)
            tryCompare(find("categoryList"), "currentIndex", 8)
            compare(tc.shown(), "A Select|B Back", "the category list still enters About")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("paneAbout").activeFocus, 2000, "About took focus")
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
            find("paneProfiles").forceActiveFocus()
            tryVerify(() => find("paneProfiles").activeFocus, 2000)
            compare(tc.shown(), "A Select|B Back")
            compare(shownOf(find("paneProfiles")), "A Select|B Back")
            compare(shownOf(find("paneAbout")), "B Back")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000)
            for (let i = 0; i < 8; ++i)
                keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("paneAbout").activeFocus, 2000)
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
