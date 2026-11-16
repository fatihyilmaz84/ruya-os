import QtQuick
import QtTest
import RuyaShell

// The game page, part 4 (02 §1.8, RUY-534): the About section (description 6 lines, What's new 4 lines
// with an update, More when cut) and the Text sheet (Accept on More; Up/Down scroll by 3 lines; Back).
// Signs in as "Ada" (p2, a Standard profile).
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
        name: "GameAbout"
        when: windowShown

        property Shell shell: null
        readonly property string racer: "flatpak:org.example.Racer"
        readonly property string puzzle: "flatpak:org.example.Puzzle"
        readonly property string chess: "flatpak:org.example.Chess"

        function find(name) { return findChild(tc.shell, name) }
        function page() { return find("page_appDetail") }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.language = "en"
            Library.resetMockForTests("")
            Session.mockReset()
            Store.mockReset()
        }

        function cleanup() {
            DeviceSettings.language = "en"
            DeviceSettings.reducedMotion = false
        }

        function start(itemCount) {
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
            tryVerify(() => Library.items.length === (itemCount ?? 10))
            tryVerify(() => Store.available && Store.catalogue.length > 0)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            wait(50)
        }

        function openPage(params) {
            tc.shell.openPage("appDetail", params)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000, "focus starts on the primary button")
        }

        function hintVerbs() {
            const bar = find("hintBar")
            const parts = []
            for (const b of ["accept", "back", "up_down"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        readonly property string longText: {
            const lines = []
            for (let i = 1; i <= 40; ++i)
                lines.push("Sentence number " + i + " of a description that goes on for a long while, so the About block has to cut it short.")
            return lines.join(" ")
        }

        // Open Chess (an update with notes) with a description far longer than six lines.
        function longOpenChess() {
            Library.resetMockForTests("chess")
            start(11)
            Store.mockSetAppText("org.example.Chess", "Open Chess", tc.longText, "Example Games")
            openPage({ id: tc.chess })
            tryCompare(page(), "hasUpdate", true)
            tryCompare(page(), "detailsReady", true)      // the notes come with GetApp
        }

        function focusAbout() {
            for (let i = 0; i < 4 && !find("detailAbout").activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(find("detailAbout").activeFocus, "About has the focus")
        }

        function openSheet() {
            keyClick(Qt.Key_Return)
            tryVerify(() => find("aboutTextSheet") !== null && find("aboutTextSheet").shown, 2000, "the sheet opens")
            tryVerify(() => find("aboutTextSheet").activeFocus, 2000, "the sheet has the focus")
            return find("aboutTextSheet")
        }

        function test_a_long_description_is_cut_at_six_lines_with_more() {
            longOpenChess()
            const d = find("aboutDescription")
            verify(find("detailAboutSection").visible)
            tryCompare(d, "lineCount", 6)
            verify(d.truncated, "cut")
            compare(d.lineHeight, 40 * page().u)
            verify(d.width <= 1200 * page().u + 0.5, "the reading measure")
            verify(find("detailAbout").width >= d.width, "the block spans the column")
            verify(find("aboutMore").visible, "More")
            compare(find("detailAboutSection").cut, true)
        }

        function test_a_short_description_has_no_more_and_accept_does_nothing() {
            start()
            openPage({ id: tc.racer })
            verify(find("detailAboutSection").visible)
            verify(!find("aboutDescription").truncated)
            verify(!find("aboutMore").visible)
            compare(find("detailAboutSection").cut, false)
            focusAbout()
            compare(hintVerbs(), "back Back")
            keyClick(Qt.Key_Return)
            wait(100)
            compare(find("aboutTextSheet"), null, "Accept does nothing without More")
            verify(find("detailAbout").activeFocus)
        }

        function test_whats_new_only_with_an_update_and_notes() {
            Library.resetMockForTests("chess")
            start(11)
            openPage({ id: tc.racer })
            tryCompare(page(), "detailsReady", true)
            verify(!find("aboutNotes").visible, "Turbo Racer has notes but no update")
            verify(!find("aboutNotesTitle").visible)
            tc.shell.closePage()
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            openPage({ id: tc.chess })
            tryCompare(page(), "hasUpdate", true)
            tryCompare(page(), "detailsReady", true)
            verify(find("aboutNotes").visible)
            compare(find("aboutNotesTitle").text, "What's new in 1.5.0")
            compare(find("aboutNotes").text, "A stronger computer opponent and a new board theme.")
        }

        function test_no_description_leaves_the_section_out() {
            start()
            openPage({ id: tc.puzzle })
            verify(!find("detailAboutSection").visible)
            keyClick(Qt.Key_Down)
            verify(!find("detailAbout").activeFocus, "no stop on the missing section")
        }

        function test_accept_on_more_opens_the_sheet_scrolls_and_back_returns() {
            longOpenChess()
            focusAbout()
            compare(hintVerbs(), "accept Read|back Back")
            const sheet = openSheet()
            compare(find("textSheetTitle").text, "Open Chess")
            const panel = find("textSheetPanel")
            compare(panel.width, 1296 * sheet.u)
            compare(panel.y, 54 * sheet.u)
            verify(panel.height <= 908 * sheet.u + 0.5, "at most 908 high")
            tryVerify(() => find("textSheetNotes").visible, 2000, "the notes follow the description")
            verify(sheet.scrolls, "this text is taller than the sheet")
            verify(sheet.moreBelow)
            compare(hintVerbs(), "back Close|up_down Scroll")
            compare(sheet.offset, 0)
            keyClick(Qt.Key_Up)
            compare(sheet.offset, 0, "stops at the top")
            keyClick(Qt.Key_Down)
            compare(sheet.offset, 120 * sheet.u, "three lines of 40")
            tryVerify(() => Math.abs(find("textSheetBody").y + 120 * sheet.u) < 0.5, 2000, "the text follows over glideMs")
            for (let i = 0; i < 80; ++i)
                keyClick(Qt.Key_Down)
            compare(sheet.offset, sheet.maxOffset, "stops at the end")
            verify(!sheet.moreBelow, "no fade at the end")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet.shown, 2000)
            tryVerify(() => find("detailAbout").activeFocus, 2000, "focus is back on About")
            compare(tc.shell.currentPage, "appDetail", "Back closed the sheet only")
        }

        function test_the_sheet_is_modal() {
            longOpenChess()
            focusAbout()
            openSheet()
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            compare(tc.shell.currentPage, "appDetail", "keys do not leak to the page")
            verify(find("aboutTextSheet").shown)
            verify(find("aboutTextSheet").activeFocus)
        }

        function test_reduced_motion_scrolls_at_once() {
            DeviceSettings.reducedMotion = true
            longOpenChess()
            focusAbout()
            const sheet = openSheet()
            compare(Theme.glideMs, 0)
            keyClick(Qt.Key_Down)
            compare(find("textSheetBody").y, -120 * sheet.u)
        }

        // ---- screenshots (dev.ps1 shots; English and Turkish, 1080p and 720p) ----

        function settle() { wait(900) }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            const turkish = "Dünyanın dört bir yanında dört oyuncuya kadar yarışın. Araçlarınızı açın, ayarlayın ve hayalet turları geride bırakın. "
            const english = "Race around the world with up to four players. Unlock cars, tune them and beat the ghost laps. "
            for (const size of [[1280, 720, "720p"], [1920, 1080, "1080p"]])
            for (const lang of ["en", "tr"]) {
                host.width = size[0]
                host.height = size[1]
                DeviceSettings.language = lang
                Library.resetMockForTests("chess")
                Session.mockReset()
                Store.mockReset()
                start(11)
                Store.mockSetAppText("org.example.Chess", "Open Chess", (lang === "tr" ? turkish : english).repeat(14), "Example Games")
                openPage({ id: tc.chess })
                tryCompare(page(), "hasUpdate", true)
                tryCompare(page(), "detailsReady", true)
                focusAbout()
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "110-game-about-" + lang + "-" + size[2] + ".png")
                openSheet()
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "111-game-text-sheet-" + lang + "-" + size[2] + ".png")
                keyClick(Qt.Key_Down)
                keyClick(Qt.Key_Down)
                settle()
                grabImage(tc.shell).save(shotsDir + "/" + "112-game-text-sheet-scrolled-" + lang + "-" + size[2] + ".png")
                tc.shell.destroy()
                wait(100)
            }
            host.width = 1280
            host.height = 720
        }
    }
}
