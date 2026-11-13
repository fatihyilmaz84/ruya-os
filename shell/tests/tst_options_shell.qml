import QtQuick
import QtTest
import RuyaShell

// The Options menu on game and app cards (02 §1.7, RUY-16): Home's Recent row, the hero's Play and
// Details pills and the Games grid. The Menu key and a long press on Accept open it; Accept acts on
// release on these items (a stray release does nothing); the rows per condition and what each does;
// the anchor keeps its lift without the ring; the hint bar; focus after Back. The component's own
// numbers are in tst_options_menu. Signs in as "Ada" (p2, standard) unless a test says Guest.
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
        Item {
            property string appId: "org.example.Racer"
            property int pid: 0
            objectName: "standInApp"
            Keys.onPressed: event => { event.accepted = true }
        }
    }

    SignalSpy { id: launchSpy; target: Library; signalName: "launchRequested" }
    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }
    SignalSpy { id: pidSpy; target: Session; signalName: "instanceOfPidFinished" }

    TestCase {
        id: tc
        name: "OptionsShell"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            Library.resetMockForTests("")
            Session.mockReset()
            Store.mockReset()
            launchSpy.clear()
            launchedSpy.clear()
            pidSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            Display.setUiScale(0)
        }

        // profileSteps: Right presses on the picker (1: Ada, 2: Guest).
        function start(profileSteps, profileId) {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            for (let i = 0; i < (profileSteps ?? 1); ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", profileId ?? "p2")
            tryVerify(() => Library.available)
            tryVerify(() => Library.items.length === 10)
            tryVerify(() => Store.available)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            // the Return that signed in has been released
            wait(50)
            launchSpy.clear()
        }

        function menu() { return find("optionsMenu") }
        function rowIds() { return menu().rows.map(r => r.id) }

        function toRecent() {
            keyClick(Qt.Key_Down)
            tryVerify(() => find("recentRow").activeFocus, 2000)
        }

        function openGames() {
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Right)
            compare(find("sectionNav").currentKey, "games")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "games")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            wait(50)                                    // the Return that opened it is released
            launchSpy.clear()
        }

        function hintVerbs() {
            const bar = find("hintBar")
            if (!bar.visible)
                return ""
            const parts = []
            for (const b of ["A", "B", "Start", "LBRB"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text)
            return out
        }

        function recordOf(instance) { return Session.running.find(r => r.instance === instance) }

        function launchBare(appId) {
            const n = launchedSpy.count
            Session.launch(appId, "p2")
            tryCompare(launchedSpy, "count", n + 1)
            const instance = launchedSpy.signalArguments[n][3]
            verify(instance !== "")
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            return instance
        }

        function addWindow(props) {
            const n = pidSpy.count
            const app = createTemporaryObject(appComponent, host, props ?? {})
            verify(app)
            tc.shell.addApp(app, "p2")
            if ((app.pid ?? 0) > 0)
                tryCompare(pidSpy, "count", n + 1)
            return app
        }

        function goHome(app) {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
            const panel = find("systemPanel")
            for (let i = 0; i < 30 && panel.currentKey !== "home"; ++i)
                keyClick(Qt.Key_Down)
            compare(panel.currentKey, "home")
            keyClick(Qt.Key_Return)
            tryVerify(() => !tc.shell.appOpen, 2000, "Home is in front")
            tryVerify(() => find("recentRow").activeFocus, 2000)
        }

        // ---- opening ----

        function test_menu_opens_on_a_recent_card_and_back_returns_to_it() {
            start()
            toRecent()
            const row = find("recentRow")
            const card = row.currentItem
            verify(card.focused)
            compare(findChild(card, "cardRing").border.width, Theme.focusRingWidth * tc.shell.u)
            keyClick(Qt.Key_Menu)
            verify(menu().shown, "Menu opens it at once")
            verify(menu().activeFocus)
            compare(menu().title, "Turbo Racer")
            compare(rowIds(), ["play", "details", "activity"])
            compare(menu().current, 0, "on the first row")
            compare(menu().placedSide, "right")
            // the anchor keeps its lift but not its ring: exactly one ring on screen
            verify(card.anchored)
            compare(findChild(card, "cardRing").border.width, 0)
            tryCompare(card, "scale", Theme.focusScale)
            compare(hintVerbs(), "A Select|B Close")
            keyClick(Qt.Key_Escape)
            verify(!menu().shown)
            verify(row.activeFocus, "the focus is back on the card")
            tryVerify(() => !card.anchored)
            compare(findChild(card, "cardRing").border.width, Theme.focusRingWidth * tc.shell.u)
            compare(launchSpy.count, 0)
        }

        function test_menu_key_closes_it_too() {
            start()
            toRecent()
            keyClick(Qt.Key_Menu)
            verify(menu().shown)
            keyClick(Qt.Key_Menu)
            verify(!menu().shown)
            verify(find("recentRow").activeFocus)
        }

        function test_menu_opens_beside_a_hero_pill_and_back_returns_to_it() {
            start()
            const play = find("homePlay")
            keyClick(Qt.Key_Menu)
            verify(menu().shown)
            compare(menu().title, "Turbo Racer", "the hero's item")
            compare(menu().placedSide, "right")
            verify(play.anchored)
            tryCompare(findChild(play, "focusRing"), "opacity", 0, 2000, "the pill loses only its ring")
            verify(!find("hintBar").activeFocus)
            keyClick(Qt.Key_Escape)
            verify(play.activeFocus)
            tryCompare(findChild(play, "focusRing"), "opacity", 1)
            // Details: the same menu, the pill keeps its focused fill
            keyClick(Qt.Key_Right)
            const details = find("homeDetails")
            verify(details.activeFocus)
            keyClick(Qt.Key_Menu)
            verify(menu().shown)
            verify(details.anchored)
            verify(details.lit)
            keyClick(Qt.Key_Escape)
            verify(details.activeFocus)
        }

        function test_menu_opens_on_a_games_card() {
            start()
            openGames()
            const grid = find("gamesGrid")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Menu)
            verify(menu().shown)
            compare(menu().title, "Counter Strike")
            compare(rowIds(), ["activity"], "a Steam game: no launch path, no Store record")
            const card = grid.currentItem
            verify(card.anchored)
            compare(findChild(card, "cardRing").border.width, 0)
            keyClick(Qt.Key_Escape)
            verify(grid.activeFocus)
            compare(tc.shell.currentPage, "games", "Back closed the menu only")
        }

        function test_nothing_happens_where_there_is_no_menu() {
            start()
            keyClick(Qt.Key_Up)                      // the section nav
            keyClick(Qt.Key_Menu)
            verify(!menu().shown)
        }

        // ---- the hold ring, the long press, accept on release ----

        function test_a_tap_plays_on_release_and_shows_no_ring() {
            start()
            toRecent()
            const card = find("recentRow").currentItem
            keyPress(Qt.Key_Return)
            compare(launchSpy.count, 0, "nothing on the press")
            verify(!card.holdShown)
            keyRelease(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
            compare(launchSpy.signalArguments[0][0], "flatpak:org.example.Racer")
            verify(!card.holdShown)
            verify(!menu().shown)
        }

        function test_the_hero_play_acts_on_release_too() {
            start()
            keyPress(Qt.Key_Return)
            compare(launchSpy.count, 0)
            keyRelease(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
        }

        function test_a_hold_on_a_card_shows_the_ring_then_opens_the_menu() {
            start()
            toRecent()
            const card = find("recentRow").currentItem
            const ring = findChild(card, "cardHoldRing")
            keyPress(Qt.Key_Return)
            tryVerify(() => card.holdShown, 2000, "the ring comes after holdRingDelayMs")
            tryVerify(() => ring.visible, 2000)
            const art = card.mapToItem(null, card.width / 2, card.height / 2)
            const at = ring.mapToItem(null, ring.width / 2, ring.height / 2)
            verify(Math.abs(at.x - art.x) < 1 && Math.abs(at.y - art.y) < 1, "centred on the art")
            tryVerify(() => menu().shown, 3000, "the menu opens at longPressMs")
            verify(!card.holdShown, "and the disc goes")
            keyRelease(Qt.Key_Return)
            compare(launchSpy.count, 0, "the release does nothing")
            verify(menu().shown)
        }

        function test_a_hold_on_the_hero_button_replaces_its_label_with_the_ring() {
            start()
            const play = find("homePlay")
            const label = findChild(play, "buttonLabel")
            const ring = findChild(play, "buttonHoldRing")
            verify(label.visible)
            keyPress(Qt.Key_Return)
            tryVerify(() => ring.visible, 2000)
            verify(!label.visible, "the label is hidden while the ring shows")
            const centre = play.mapToItem(null, play.width / 2, play.height / 2)
            const at = ring.mapToItem(null, ring.width / 2, ring.height / 2)
            verify(Math.abs(at.x - centre.x) < 1 && Math.abs(at.y - centre.y) < 1, "centred on the pill")
            keyRelease(Qt.Key_Return)                 // before the menu: a tap, the ring is cut
            verify(!ring.visible)
            verify(label.visible, "the label is back on release")
            tryCompare(launchSpy, "count", 1)
            // a full hold: the label is back when the menu opens
            launchSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
        }

        function test_a_full_hold_on_the_hero_opens_the_menu_and_brings_the_label_back() {
            start()
            const play = find("homePlay")
            keyPress(Qt.Key_Return)
            tryVerify(() => menu().shown, 3000)
            verify(findChild(play, "buttonLabel").visible, "the label is back when the menu opens")
            keyRelease(Qt.Key_Return)
            compare(launchSpy.count, 0)
            verify(menu().shown)
            keyClick(Qt.Key_Escape)
            verify(play.activeFocus)
        }

        // The press that opened Games is released on the grid: it must not play the first card.
        function test_a_stray_release_on_games_does_nothing() {
            start()
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Right)
            compare(find("sectionNav").currentKey, "games")
            keyPress(Qt.Key_Return)                  // opens Games on the press
            tryCompare(tc.shell, "currentPage", "games")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            keyRelease(Qt.Key_Return)
            wait(Theme.longPressMs + 200)
            compare(launchSpy.count, 0, "the release did not play the first game")
            verify(!menu().shown, "and started no hold")
            verify(!find("gamesGrid").currentItem.holdShown)
        }

        // The press that moved the focus onto the hero (Home on the nav) is released there.
        function test_a_stray_release_on_the_hero_does_nothing() {
            start()
            keyClick(Qt.Key_Up)
            compare(find("sectionNav").currentKey, "home")
            keyPress(Qt.Key_Return)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            keyRelease(Qt.Key_Return)
            wait(Theme.longPressMs + 200)
            compare(launchSpy.count, 0)
            verify(!menu().shown)
            verify(!findChild(find("homePlay"), "buttonHoldRing").visible)
        }

        // A press that began on one card does not act on another after the focus moved along the row.
        function test_moving_the_focus_during_a_press_cancels_it() {
            start()
            toRecent()
            keyPress(Qt.Key_Return)
            keyClick(Qt.Key_Right)
            keyRelease(Qt.Key_Return)
            wait(100)
            compare(launchSpy.count, 0)
        }

        function test_games_tap_plays_on_release() {
            start()
            openGames()
            keyPress(Qt.Key_Return)
            compare(launchSpy.count, 0)
            keyRelease(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
            compare(launchSpy.signalArguments[0][0], "flatpak:org.example.Racer")
        }

        function test_games_hold_opens_the_menu() {
            start()
            openGames()
            keyPress(Qt.Key_Return)
            tryVerify(() => find("gamesGrid").currentItem.holdShown, 2000)
            tryVerify(() => menu().shown, 3000)
            keyRelease(Qt.Key_Return)
            compare(launchSpy.count, 0)
            compare(menu().title, "Turbo Racer")
        }

        // ---- rows per condition ----

        function test_a_game_that_runs_has_resume_and_close_and_no_play() {
            start()
            const racer = launchBare("org.example.Racer")
            const app = addWindow({ pid: Session.mockPidOf(racer) })
            tryVerify(() => app.activeFocus, 2000)
            goHome(app)
            keyClick(Qt.Key_Menu)
            verify(menu().shown)
            compare(rowIds(), ["resume", "close", "details", "activity"])
            compare(menu().rows[1].label, "Close game")
            keyClick(Qt.Key_Return)                  // Resume: the window comes back
            tryVerify(() => app.activeFocus, 2000)
            compare(launchedSpy.count, 1, "no second launch")
        }

        function test_a_running_game_without_a_window_has_only_close() {
            start()
            launchBare("org.example.Racer")
            toRecent()
            keyClick(Qt.Key_Menu)
            verify(menu().shown)
            compare(rowIds(), ["close", "details", "activity"])
        }

        function test_close_game_runs_the_hubs_closing_screen() {
            start()
            const racer = launchBare("org.example.Racer")
            const app = addWindow({ pid: Session.mockPidOf(racer) })
            tryVerify(() => app.activeFocus, 2000)
            goHome(app)
            Session.mockStopDelay(400)
            keyClick(Qt.Key_Menu)
            keyClick(Qt.Key_Down)
            compare(menu().rows[menu().current].id, "close")
            keyClick(Qt.Key_Return)
            tryVerify(() => tc.shell.closingScreen, 2000, "the closing screen is up")
            verify(tc.shell.closeState.instance === racer)
            verify(Session.mockCalls().some(c => c.startsWith("stop")), "Session.stop was asked")
            tryVerify(() => !tc.shell.closingScreen, 5000, "it ends when the game has ended")
            tryVerify(() => find("recentRow").activeFocus, 2000, "the focus is where Close left it: the card")
        }

        function test_close_app_for_an_app() {
            start()
            const player = launchBare("org.example.Player")
            verify(player !== "")
            toRecent()
            const row = find("recentRow")
            for (let i = 0; i < 8 && row.currentItem.itemId !== "flatpak:org.example.Player"; ++i)
                keyClick(Qt.Key_Right)
            compare(row.currentItem.itemId, "flatpak:org.example.Player")
            keyClick(Qt.Key_Menu)
            compare(menu().rows[0].label, "Close app")
        }

        function test_guest_has_no_activity_and_a_steam_game_has_an_empty_menu() {
            start(2, "p3")
            verify(tc.shell.signedIn)
            toRecent()
            keyClick(Qt.Key_Menu)
            compare(rowIds(), ["play", "details"], "no Your activity for Guest")
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Right)                   // Counter Strike
            compare(find("recentRow").currentItem.itemId, "steam:730")
            compare(hintVerbs(), "A Select|LBRB Sections", "no Options hint for an empty menu")
            keyClick(Qt.Key_Menu)
            verify(menu().shown, "the options button still opens the empty menu")
            compare(rowIds(), [])
            verify(findChild(menu(), "optionsEmpty").visible)
            compare(hintVerbs(), "B Close")
            keyClick(Qt.Key_Escape)
            verify(find("recentRow").activeFocus)
        }

        function test_a_steam_game_has_only_the_activity_row_for_a_profile() {
            start()
            toRecent()
            keyClick(Qt.Key_Right)
            compare(find("recentRow").currentItem.itemId, "steam:730")
            compare(hintVerbs(), "A Select|Start Options|LBRB Sections")
            keyClick(Qt.Key_Menu)
            compare(rowIds(), ["activity"])
        }

        function test_the_options_hint_on_home_and_games() {
            start()
            compare(hintVerbs(), "A Select|Start Options|LBRB Sections")
            keyClick(Qt.Key_Up)
            compare(hintVerbs(), "A Select|LBRB Sections", "none on the nav")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "games")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            compare(hintVerbs(), "A Select|B Back|Start Options|LBRB Sections")
            keyClick(Qt.Key_Right)
            compare(hintVerbs(), "A Select|B Back|Start Options|LBRB Sections", "a Steam game's activity row is a menu")
        }

        function test_the_store_down_leaves_out_details_and_shows_the_note() {
            start()
            toRecent()
            Store.mockServiceLost()
            tryVerify(() => !Store.available)
            keyClick(Qt.Key_Menu)
            compare(rowIds(), ["play", "activity"])
            const note = findChild(menu(), "optionsNote")
            verify(note.visible)
            compare(note.text, "Store options are unavailable right now.")
            // it answers again while the menu is open: Details comes back in place
            Store.mockServiceRegained()
            tryVerify(() => Store.available)
            tryCompare(menu().rows, "length", 3)
            compare(rowIds(), ["play", "details", "activity"])
            verify(!note.visible)
        }

        function test_no_store_record_leaves_out_details() {
            start()
            Store.mockSetAppText("org.example.Racer", "Turbo Racer", "x", "y")      // still a record
            toRecent()
            keyClick(Qt.Key_Menu)
            verify(rowIds().indexOf("details") >= 0)
        }

        function test_rows_follow_the_game_while_the_menu_is_open() {
            start()
            toRecent()
            keyClick(Qt.Key_Menu)
            keyClick(Qt.Key_Down)
            compare(menu().rows[menu().current].id, "details")
            const racer = launchBare("org.example.Racer")
            addWindow({ pid: Session.mockPidOf(racer) })
            tryVerify(() => rowIds().indexOf("resume") >= 0, 2000, "the rows are rebuilt in place")
            compare(rowIds(), ["resume", "close", "details", "activity"])
            compare(menu().rows[menu().current].id, "details", "the focus stays on the same action")
        }

        function test_the_menu_closes_when_its_item_goes_away() {
            start()
            toRecent()
            keyClick(Qt.Key_Menu)
            verify(menu().shown)
            Library.resetMockForTests("empty")
            tryVerify(() => !menu().shown, 2000)
        }

        function test_guide_closes_the_menu_and_opens_the_hub() {
            start()
            toRecent()
            keyClick(Qt.Key_Menu)
            verify(menu().shown)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemPanel").open, 2000)
            verify(!menu().shown)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("systemPanel").open, 2000)
            tryVerify(() => find("recentRow").activeFocus, 2000, "Home gives the focus back to the card")
        }

        // ---- the rows' actions ----

        function test_play_row_launches() {
            start()
            toRecent()
            keyClick(Qt.Key_Menu)
            keyClick(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
            compare(launchSpy.signalArguments[0][0], "flatpak:org.example.Racer")
        }

        function test_details_row_opens_the_app_page() {
            start()
            toRecent()
            keyClick(Qt.Key_Menu)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appDetail")
            compare(tc.shell.currentParams.appId, "org.example.Racer")
        }

        function test_activity_row_opens_the_activity_page() {
            start()
            toRecent()
            keyClick(Qt.Key_Menu)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "activityGame")
            compare(tc.shell.currentParams.appId, "org.example.Racer")
        }

        function test_games_page_rows_open_pages_over_games() {
            start()
            openGames()
            keyClick(Qt.Key_Menu)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appDetail")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "games")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
        }

        // ---- placement on the real screens ----

        function test_last_games_column_flips_the_menu_to_the_left() {
            start()
            openGames()
            const grid = find("gamesGrid")
            keyClick(Qt.Key_Menu)
            compare(menu().placedSide, "right", "column 1")
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(grid.currentIndex, 3)
            keyClick(Qt.Key_Menu)
            compare(menu().placedSide, "left", "column 4")
            keyClick(Qt.Key_Escape)
        }

        function test_at_ui_size_200_the_menu_goes_to_the_screen_edge() {
            start()
            Display.setUiScale(200)
            tryCompare(Theme, "uiScale", 2)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            toRecent()
            keyClick(Qt.Key_Menu)
            verify(menu().shown)
            compare(menu().placedSide, "edge", "the card is too wide for a side")
            keyClick(Qt.Key_Escape)
        }
    }
}
