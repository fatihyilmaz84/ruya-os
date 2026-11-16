import QtQuick
import QtTest
import RuyaShell

// The game page, part 3 (02 §1.8, RUY-533): the Screenshots row and the full-screen viewer.
// Turbo Racer (not installed) has five pictures, the third cannot be loaded; Block Puzzle has none.
// Signs in as "Ada" (p2).
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
        name: "GameScreenshots"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        function page() { return find("page_appDetail") }
        function strip() { return find("screenshotStrip") }
        function viewer() { return find("screenshotViewer") }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.language = "en"
            Library.resetMockForTests("")
            Store.mockReset()
            Store.mockArtDir(artFixtures)
        }

        function cleanup() {
            DeviceSettings.language = "en"
            DeviceSettings.reducedMotion = false
            host.width = 1280
            host.height = 720
        }

        function start() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => Store.available && Store.catalogue.length > 0)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            wait(50)
        }

        // Opens the page for an app and, when it has the row, moves the focus onto it.
        function openRow(appId) {
            tc.shell.openPage("appDetail", { appId: appId })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
            tryCompare(page(), "detailsReady", true)
        }

        function toRow() {
            for (let i = 0; i < 6 && !strip().activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(strip().activeFocus, "the row has the focus")
        }

        function openViewer(at) {
            toRow()
            for (let i = 0; i < at; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => viewer() && viewer().shown && viewer().activeFocus, 2000)
            tryCompare(viewer(), "opacity", 1)
        }

        function hintVerbs() {
            const bar = find("hintBar")
            const parts = []
            for (const b of ["accept", "back", "left_right"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        // ---- the row ----

        function test_the_row_is_left_out_without_screenshots() {
            start()
            openRow("org.example.Puzzle")
            compare(find("detailScreenshotsSection").visible, false)
            for (let i = 0; i < 8; ++i)
                keyClick(Qt.Key_Down)
            verify(!strip().activeFocus, "no stop for the row")
        }

        function test_the_row_has_a_card_per_picture_in_the_card_size() {
            start()
            openRow("org.example.Racer")
            compare(find("detailScreenshotsSection").visible, true)
            compare(find("screenshotsHeading").text, "Screenshots")
            const card = find("screenshotCard_0")
            const u = page().u
            compare(card.width, Theme.cardWidthHero * u)
            compare(card.height, Theme.cardWidthHero * u * 9 / 16)
            tryVerify(() => Math.abs(find("screenshotCard_1").x - card.x - (Theme.cardWidthHero + Theme.cardGap) * u) < 0.5, 2000, "cards laid out one step apart")
            verify(find("screenshotCard_4"))
            verify(!find("screenshotCard_5"))
        }

        function test_left_and_right_move_along_the_row_and_stop_at_the_ends() {
            start()
            openRow("org.example.Racer")
            toRow()
            compare(strip().currentIndex, 0)
            let navs = Sfx.navigateCount
            keyClick(Qt.Key_Left)
            compare(strip().currentIndex, 0)
            compare(Sfx.navigateCount, navs, "no sound at the start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(strip().currentIndex, 2)
            compare(Sfx.navigateCount, navs + 2)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(strip().currentIndex, 4)
            navs = Sfx.navigateCount
            keyClick(Qt.Key_Right)
            compare(strip().currentIndex, 4)
            compare(Sfx.navigateCount, navs, "no sound at the end")
            verify(strip().activeFocus, "still on the row")
        }

        // The card as drawn (focus scale included) lies inside the viewport's clip.
        function inside(c, viewport) {
            const a = c.mapToItem(viewport, 0, 0)
            const b = c.mapToItem(viewport, c.width, c.height)
            return a.x >= -0.5 && b.x <= viewport.width + 0.5
        }

        function test_the_focused_card_is_fully_in_view() {
            start()
            openRow("org.example.Racer")
            toRow()
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            const card = find("screenshotCard_4")
            const viewport = find("detailViewport")
            tryVerify(() => inside(card, viewport), 2000, "card 5 inside the viewport")
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Left)
            tryVerify(() => inside(find("screenshotCard_0"), viewport), 2000, "card 1 inside the viewport")
        }

        function test_the_first_card_stays_at_the_content_edge_and_the_row_runs_to_the_screen_edge() {
            host.width = 1920
            host.height = 1080
            start()
            openRow("org.example.Racer")
            tryCompare(tc.shell, "u", 1)
            tryVerify(() => tc.shell.slots[tc.shell.slots.length - 1].settled, 2000, "the page has finished sliding in")
            toRow()
            const column = find("detailColumn")
            const first = find("screenshotCard_0")
            tryVerify(() => Math.abs(first.parent.mapToItem(column, first.x, 0).x) < 0.5, 2000, "the first card is at the content's left edge")
            compare(strip().scrollX, 0)
            compare(Math.round(column.mapToItem(tc.shell, 0, 0).x), 96, "and the content starts at x 96")
            // the fifth card starts inside the content and runs on past its right edge, to the screen's
            const fifth = find("screenshotCard_4")
            const content = column.width
            const startX = fifth.parent.mapToItem(column, fifth.x, 0).x
            verify(startX < content && startX + fifth.width > content, "the peek runs past the content's right edge")
            const viewport = find("detailViewport")
            fuzzyCompare(viewport.mapToItem(tc.shell, viewport.width, 0).x, tc.shell.width, 0.5, "the row's clip is the screen's edge")
            keyClick(Qt.Key_Left)
            compare(strip().scrollX, 0)
        }

        function test_the_row_says_view_and_back_and_the_heading_is_scrolled_to() {
            host.width = 1920
            host.height = 1080
            start()
            openRow("org.example.Racer")
            toRow()
            compare(hintVerbs(), "accept View|back Back")
            const heading = find("screenshotsHeading")
            const viewport = find("detailViewport")
            tryVerify(() => heading.mapToItem(viewport, 0, 0).y >= -0.5 && heading.mapToItem(viewport, 0, 0).y < viewport.height / 2, 2000,
                      "the heading is in the upper half of the viewport")
        }

        function test_loading_shows_four_placeholders_that_take_no_focus() {
            start()
            openRow("org.example.Puzzle")
            page().detailsReady = false      // GetApp is pending again
            tryVerify(() => find("detailScreenshotsSection").visible, 1000, "placeholders while pending")
            compare(find("screenshotCard_3").objectName, "screenshotCard_3")
            verify(!find("screenshotCard_4"))
            verify(find("screenshotArt").shimmering || !Theme.shimmerOn)
            for (let i = 0; i < 8; ++i)
                keyClick(Qt.Key_Down)
            verify(!strip().activeFocus, "placeholders are not focusable")
        }

        // ---- the viewer ----

        function test_accept_opens_the_viewer_at_the_card() {
            start()
            openRow("org.example.Racer")
            openViewer(1)
            compare(viewer().index, 1)
            compare(find("viewerCounter").text, "2 of 5")
            compare(hintVerbs(), "back Close|left_right Browse")
        }

        function test_the_viewer_steps_and_stops_at_the_ends_without_sound() {
            start()
            openRow("org.example.Racer")
            openViewer(0)
            compare(find("viewerCounter").text, "1 of 5")
            let navs = Sfx.navigateCount
            keyClick(Qt.Key_Left)
            compare(viewer().index, 0)
            compare(Sfx.navigateCount, navs, "no sound at the first")
            keyClick(Qt.Key_Right)
            compare(viewer().index, 1)
            compare(Sfx.navigateCount, navs + 1)
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            compare(viewer().index, 4)
            compare(find("viewerCounter").text, "5 of 5")
            navs = Sfx.navigateCount
            keyClick(Qt.Key_Right)
            compare(viewer().index, 4)
            compare(Sfx.navigateCount, navs, "no sound at the last")
        }

        function test_the_arrows_show_only_with_a_neighbour() {
            start()
            openRow("org.example.Racer")
            openViewer(0)
            compare(find("viewerPrevious").visible, false)
            compare(find("viewerNext").visible, true)
            keyClick(Qt.Key_Right)
            compare(find("viewerPrevious").visible, true)
            compare(find("viewerNext").visible, true)
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            compare(find("viewerPrevious").visible, true)
            compare(find("viewerNext").visible, false)
            verify(!find("viewerPrevious").activeFocus && !find("viewerNext").activeFocus, "cues, not stops")
        }

        function test_a_picture_that_cannot_be_loaded_says_so() {
            start()
            openRow("org.example.Racer")
            openViewer(2)
            tryVerify(() => viewer().current.failed, 3000)
            tryVerify(() => viewer().current.children.some(c => c.objectName === "viewerFailed" && c.visible), 1000)
            compare(find("viewerFailedText").text, "Couldn't load this picture.")
            keyClick(Qt.Key_Left)
            tryVerify(() => viewer().current.ready, 3000)
            compare(viewer().current.failed, false)
        }

        function test_back_closes_and_the_focus_goes_to_the_card_last_shown() {
            start()
            openRow("org.example.Racer")
            openViewer(0)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            const backs = Sfx.backCount
            keyClick(Qt.Key_Escape)
            tryVerify(() => !viewer().shown, 1000)
            compare(Sfx.backCount, backs + 1)
            tryVerify(() => strip().activeFocus, 1000, "the row has the focus again")
            compare(strip().currentIndex, 3)
            compare(tc.shell.currentPage, "appDetail", "Back closed the viewer only")
            tryCompare(viewer(), "visible", false)
        }

        function test_keys_do_not_leak_to_the_page() {
            start()
            openRow("org.example.Racer")
            openViewer(1)
            const rowIndex = strip().currentIndex
            for (const k of [Qt.Key_Up, Qt.Key_Down, Qt.Key_Return, Qt.Key_Space])
                keyClick(k)
            compare(tc.shell.currentPage, "appDetail")
            compare(strip().currentIndex, rowIndex)
            verify(viewer().shown, "still open")
            verify(viewer().activeFocus)
        }

        function test_reduced_motion_removes_the_fades() {
            DeviceSettings.reducedMotion = true
            compare(Theme.overlayMs, 0)
            compare(Theme.focusMs, 0)
        }

        function test_turkish_words() {
            DeviceSettings.language = "tr"
            start()
            openRow("org.example.Racer")
            compare(find("screenshotsHeading").text, "Ekran görüntüleri")
            toRow()
            compare(hintVerbs(), "accept Görüntüle|back Geri")
            keyClick(Qt.Key_Return)
            tryVerify(() => viewer() && viewer().shown, 2000)
            compare(find("viewerCounter").text, "1 / 5")
            compare(hintVerbs(), "back Kapat|left_right Gözat")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            tryVerify(() => viewer().current.failed, 3000)
            compare(find("viewerFailedText").text, "Bu resim yüklenemedi.")
        }

        function settle() { wait(900) }

        // Screenshots for the review (RUYA_SHOTS_DIR): the row focused, the viewer in the middle, at the
        // last picture and on the picture that cannot be loaded, and the loading row; en/tr at 1080p and 720p.
        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            for (const size of [[1280, 720, "720p"], [1920, 1080, "1080p"]])
            for (const lang of ["en", "tr"]) {
                host.width = size[0]
                host.height = size[1]
                DeviceSettings.language = lang
                Store.mockReset()
                Store.mockArtDir(artFixtures)
                start()
                const name = n => shotsDir + "/" + n + "-" + lang + "-" + size[2] + ".png"
                openRow("org.example.Racer")
                toRow()
                keyClick(Qt.Key_Right)
                settle()
                grabImage(tc.shell).save(name("110-game-screenshots-row"))
                keyClick(Qt.Key_Return)
                tryVerify(() => viewer() && viewer().shown, 2000)
                settle()
                grabImage(tc.shell).save(name("111-game-screenshot-viewer"))
                keyClick(Qt.Key_Right)
                settle()
                tryVerify(() => viewer().current.failed, 3000)
                grabImage(tc.shell).save(name("112-game-screenshot-viewer-failed"))
                keyClick(Qt.Key_Right)
                keyClick(Qt.Key_Right)
                settle()
                grabImage(tc.shell).save(name("113-game-screenshot-viewer-last"))
                keyClick(Qt.Key_Escape)
                tryVerify(() => !viewer().shown, 1000)
                tc.shell.closePage()
                tryCompare(tc.shell, "currentPage", "")
                // loading: GetApp has not answered
                tc.shell.openPage("appDetail", { appId: "org.example.Broken" })      // not installed: no activity block above the row
                tryCompare(tc.shell, "currentPage", "appDetail")
                tryCompare(page(), "detailsReady", true)
                page().detailsReady = false
                tryVerify(() => find("detailScreenshotsSection").visible, 1000)
                settle()
                page().detailsReady = false      // again, in case a late answer came in
                wait(200)
                grabImage(tc.shell).save(name("114-game-screenshots-loading"))
                tc.shell.destroy()
                wait(100)
            }
            host.width = 1280
            host.height = 720
        }
    }
}
