import QtQuick
import QtTest
import RuyaShell

// The Ruya Hub pauses the game (T-457, 02 §1.6, ADR-033 point 3): opening the Hub over an app asks
// Session1 to freeze it; Resume, B and Guide thaw it; Home leaves it frozen (its Running card thaws
// it); Close game thaws, then stops; "Switch to" thaws the chosen app and leaves the old one frozen;
// with the setting off nothing is frozen or thawed; a failed freeze leaves the Hub open with no
// "Paused". The mock Session logs every freeze, thaw and stop that reaches an app (mockCalls).
// Signs in as "Ada" (p2), controller keys only.
Item {
    id: host
    width: 1280
    height: 720

    // A 1080p screen inside the 720p test window (the fit test): the menu sizes itself from its parent.
    Item {
        id: bigHost
        width: 1920
        height: 1080
    }

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A window of an app that takes every key, like a game.
    Component {
        id: appComponent
        Item {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            Keys.onPressed: event => event.accepted = true
        }
    }

    // A "game" with something to look at behind the Hub (screenshots).
    Component {
        id: pictureAppComponent
        Rectangle {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            color: "steelblue"
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: parent.height / 3; color: "darkgreen" }
            Rectangle { x: parent.width * 0.55; y: parent.height * 0.2; width: parent.width * 0.2; height: width; radius: width / 2; color: "gold" }
        }
    }

    // The Hub alone, at the size Shell gives it in this window (u = height / 1080), over a paused game
    // with a title that takes two lines.
    Component {
        id: menuComponent
        QuickMenu {
            anchors.fill: parent
            u: height / 1080
            marginX: 40
            marginY: 40
            open: true
            app: ({ appId: "org.example.Racer", title: "Turbo Racer Championship Edition: The Long Road Home",
                    picture: "", started: Date.now() / 1000 - 12 * 60, instance: "x", frozen: true })
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }
    SignalSpy { id: freezeSpy; target: Session; signalName: "freezeFinished" }
    SignalSpy { id: frozenSpy; target: Session; signalName: "frozenChanged" }

    TestCase {
        id: tc
        name: "HubPause"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function start() {
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
            tryVerify(() => Library.available)
            tryVerify(() => Library.items.length === 10)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.pauseGamesInHub = true
            Library.resetMockForTests("")
            Session.mockReset()
            launchedSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
            freezeSpy.clear()
            frozenSpy.clear()
        }

        function cleanup() {
            DeviceSettings.pauseGamesInHub = true
            Session.mockFailFreeze(false)
            Session.mockFailThaw(false)
        }

        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text)
            return out
        }

        // From the picker (the focus on the profile list), Ada (p2, no PIN) signs in.
        function signInAda() {
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has the focus")
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Left)                    // to the first profile, whichever the picker kept
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
        }

        // The running record of `instance`, or undefined.
        function recordOf(instance) {
            return Session.running.find(r => r.instance === instance)
        }

        // Play on the hero, the app running and its window: returns { app, instance }, the app focused.
        function playRacer(component) {
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            const instance = launchedSpy.signalArguments[0][3]
            verify(instance !== "")
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            const app = createTemporaryObject(component ?? appComponent, host)
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")
            return { app: app, instance: instance }
        }

        function openHub() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
        }

        // Opens the Hub over the app and waits until the service says it is frozen ("Paused" shows).
        function openHubAndPause(instance) {
            openHub()
            tryVerify(() => recordOf(instance).frozen === true, 2000, "the game is frozen")
            tryVerify(() => find("hubCardState").text.startsWith("Paused"), 2000, "the game card says Paused")
            compare(Session.mockCalls(), ["freeze " + instance])
            verify(find("quickMenuItem_resume").focused, "the focus starts on Resume")
        }

        function focusedKey() {
            return find("systemPanel").currentKey
        }

        function goTo(key) {
            const menu = find("systemPanel")
            const list = find("systemActions")
            if (key === "switch" && !menu.powerMode) {
                // Switch profile is the last choice of the Power panel (T-471)
                goTo("panel:power")
                keyClick(Qt.Key_Return)
                tryCompare(menu, "powerMode", true)
            }
            // Up/Down to the control's row, then Left/Right along it (T-471: a row may hold several controls).
            for (let i = 0; i < 30 && menu.currentKey !== key; ++i)
                keyClick(menu.itemKeys.indexOf(menu.rowKeyOf(key)) > list.currentIndex ? Qt.Key_Down
                         : menu.itemKeys.indexOf(menu.rowKeyOf(key)) < list.currentIndex ? Qt.Key_Up
                         : menu.columnOf(key) > menu.currentColumn ? Qt.Key_Right : Qt.Key_Left)
            compare(focusedKey(), key)
            verify(find("quickMenuItem_" + key).focused, key + " has the focus ring")
        }

        // The Hub's open time goes to the journal like a page's (T-455): one line per open that settles,
        // none for an open that is closed before it has.
        function test_the_hub_writes_its_open_time() {
            start()
            const probe = find("pageProbe")
            const lines = probe.lineCount
            keyClick(Qt.Key_HomePage)                        // Guide
            tryCompare(probe, "lineCount", lines + 1, 3000, "the open settled and was written")
            verify(probe.lastLine.indexOf("page-open hub ") === 0, probe.lastLine)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("systemPanel").open)
            keyClick(Qt.Key_HomePage)
            keyClick(Qt.Key_Escape)                          // closed before the slide ended
            tryVerify(() => !find("systemPanel").open)
            compare(probe.pendingKey, "", "an open that did not settle is not measured")
        }

        function test_opening_the_hub_freezes_the_game_and_resume_thaws_it() {
            start()
            const run = playRacer()
            verify(!recordOf(run.instance).frozen)
            openHubAndPause(run.instance)
            compare(find("hubCardState").text, "Paused", "under a minute: Paused alone")
            verify(find("hubGameCard").paused)
            keyClick(Qt.Key_Return)                          // Resume
            tryVerify(() => run.app.activeFocus, 2000, "Resume gives the game the focus back")
            verify(!find("systemPanel").open)
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance])
            tryVerify(() => recordOf(run.instance).frozen === false, 2000, "the game runs again")
        }

        function test_b_and_guide_thaw_the_game() {
            start()
            const run = playRacer()
            openHubAndPause(run.instance)
            keyClick(Qt.Key_Escape)                          // B
            tryVerify(() => run.app.activeFocus, 2000, "B returns to the game")
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance])
            tryVerify(() => recordOf(run.instance).frozen === false)

            keyClick(Qt.Key_HomePage)                        // Guide again: frozen again
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens again")
            tryVerify(() => recordOf(run.instance).frozen === true)
            keyClick(Qt.Key_HomePage)                        // Guide closes it
            tryVerify(() => run.app.activeFocus, 2000, "Guide returns to the game")
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance,
                                          "freeze " + run.instance, "thaw " + run.instance])
            tryVerify(() => recordOf(run.instance).frozen === false)
        }

        function test_home_keeps_the_game_frozen_until_its_card_resumes_it() {
            start()
            const run = playRacer()
            openHubAndPause(run.instance)
            goTo("home")
            keyClick(Qt.Key_Return)
            tryVerify(() => !tc.shell.appOpen, 2000, "Home is in front")
            tryVerify(() => find("recentRow").activeFocus, 2000, "the focus is on the game's card")
            compare(Session.mockCalls(), ["freeze " + run.instance], "Home does not thaw")
            verify(recordOf(run.instance).frozen, "the game stays frozen behind Home")
            keyClick(Qt.Key_Return)                          // Accept on the Running card: resume
            tryVerify(() => run.app.activeFocus, 2000, "the card resumes the game")
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance])
            tryVerify(() => recordOf(run.instance).frozen === false)
        }

        function test_close_game_thaws_the_game_then_stops_it() {
            start()
            const run = playRacer()
            openHubAndPause(run.instance)
            goTo("closeGame")
            keyClick(Qt.Key_Return)
            tryVerify(() => !tc.shell.appOpen, 2000, "Home is in front")
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance, "stop " + run.instance])
            tryVerify(() => recordOf(run.instance) === undefined, 2000, "the game quit")
        }

        function test_switch_to_thaws_the_chosen_game_and_leaves_the_old_one_frozen() {
            start()
            const racer = playRacer()
            const n = launchedSpy.count
            Session.launch("org.example.Puzzle", "p2")
            tryCompare(launchedSpy, "count", n + 1)
            const puzzleInstance = launchedSpy.signalArguments[n][3]
            tryVerify(() => recordOf(puzzleInstance) !== undefined && recordOf(puzzleInstance).state === "running")
            const puzzle = createTemporaryObject(appComponent, host, { appId: "org.example.Puzzle" })
            tc.shell.addApp(puzzle, "p2")
            tryVerify(() => puzzle.activeFocus, 2000, "the newest window is in front")

            openHubAndPause(puzzleInstance)
            goTo("to:org.example.Racer")
            keyClick(Qt.Key_Return)
            tryVerify(() => racer.app.activeFocus, 2000, "Turbo Racer is in front")
            compare(Session.mockCalls(), ["freeze " + puzzleInstance], "Turbo Racer was not frozen: nothing to thaw")
            verify(recordOf(puzzleInstance).frozen, "the old game stays frozen")

            openHub()                                        // over Turbo Racer now
            tryVerify(() => recordOf(racer.instance).frozen === true)
            goTo("to:org.example.Puzzle")
            keyClick(Qt.Key_Return)
            tryVerify(() => puzzle.activeFocus, 2000, "Block Puzzle is in front")
            compare(Session.mockCalls(), ["freeze " + puzzleInstance, "freeze " + racer.instance,
                                          "thaw " + puzzleInstance], "the chosen game is thawed, the old one is not")
            tryVerify(() => recordOf(puzzleInstance).frozen === false)
            verify(recordOf(racer.instance).frozen, "Turbo Racer stays frozen")
        }

        function test_with_the_setting_off_the_hub_neither_freezes_nor_thaws() {
            start()
            DeviceSettings.pauseGamesInHub = false
            const run = playRacer()
            openHub()
            wait(50)                                         // a freeze would be asked synchronously
            compare(Session.mockCalls(), [])
            verify(!find("hubCardState").text.startsWith("Paused"))
            keyClick(Qt.Key_Escape)
            tryVerify(() => run.app.activeFocus, 2000, "B returns to the game")
            compare(Session.mockCalls(), [], "no Thaw either")
            openHub()
            goTo("closeGame")
            keyClick(Qt.Key_Return)
            tryVerify(() => !tc.shell.appOpen, 2000)
            compare(Session.mockCalls(), ["stop " + run.instance], "Close game only stops")
        }

        function test_a_failed_freeze_leaves_the_hub_open_and_shows_no_paused() {
            start()
            const run = playRacer()
            Session.mockFailFreeze(true)
            openHub()
            tryCompare(freezeSpy, "count", 1)
            compare(freezeSpy.signalArguments[0][0], run.instance)
            compare(freezeSpy.signalArguments[0][1], "failed")
            verify(find("systemPanel").open, "the Hub stays open")
            verify(find("systemActions").activeFocus, "with the focus")
            verify(find("quickMenuItem_resume").focused)
            compare(find("hubCardState").text, "Just started", "nothing is shown as paused")
            verify(!recordOf(run.instance).frozen, "the game keeps running")
            compare(frozenSpy.count, 0)
            keyClick(Qt.Key_Escape)
            tryVerify(() => run.app.activeFocus, 2000)
            compare(Session.mockCalls(), ["freeze " + run.instance], "no Thaw for a game that was never frozen")
        }

        function test_the_setting_is_in_system_settings_and_on_by_default() {
            start()
            verify(DeviceSettings.pauseGamesInHub, "on by default")
            keyClick(Qt.Key_Up)                              // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                          // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus, 2000, "category list has focus")
            for (let i = 0; i < 20 && list.currentItem.objectName !== "category_system"; ++i)
                keyClick(Qt.Key_Down)
            compare(list.currentItem.objectName, "category_system")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneSystem").activeFocus, 2000, "System pane has focus")
            const row = find("rowPauseGames")
            for (let i = 0; i < 20 && !row.activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(row.activeFocus, "the row is reachable with Down")
            compare(row.label, "Pause games when Ruya Hub opens")
            verify(row.checked)
            keyClick(Qt.Key_Return)
            tryVerify(() => !DeviceSettings.pauseGamesInHub, 2000, "Accept turns it off")
            verify(!row.checked)
            verify(row.activeFocus, "the focus stays on the row")
            keyClick(Qt.Key_Return)
            tryVerify(() => DeviceSettings.pauseGamesInHub, 2000, "and on again")
            verify(row.checked)
            keyClick(Qt.Key_Escape)                          // Back leaves the pane
            tryVerify(() => list.activeFocus, 2000, "Back returns to the categories")
        }

        // RUY-401: the Hub never scrolls at 100, 125 and 150 % UI size (u = the 1080p unit x the size): the game
        // card's art and the strip's tiles shrink, the rows lie inside the list, with the focus on any row.
        // At 150 % a game with two other apps is more than a 1080p screen holds at the UI size's text (the text
        // and the pills keep their size): the art is at its smallest there and the list scrolls (the next test).
        function test_fits_at_every_ui_size_data() {
            return [{ tag: "100 %", scale: 1, others: 2 }, { tag: "125 %", scale: 1.25, others: 2 },
                    { tag: "150 %", scale: 1.5, others: 0 }]
        }
        function hubAt(scale, others) {
            const u = scale                                   // 1080p: the unit is 1 at 100 %
            const list = [{ appId: "org.example.A", title: "Alpha", picture: "", hasWindow: true },
                          { appId: "org.example.B", title: "Beta", picture: "", hasWindow: true }]
            const menu = createTemporaryObject(menuComponent, bigHost, {
                u: u, marginX: 54, marginY: 54, bottomReserve: (Theme.glyphSize + Theme.spaceM) * u,
                app: ({ appId: "org.example.Racer", title: "Turbo Racer", picture: "", started: Date.now() / 1000 - 12 * 60,
                        instance: "x", frozen: true }),
                others: list.slice(0, others) })
            verify(menu)
            menu.present()
            tryCompare(menu, "settled", true)
            return menu
        }
        function test_fits_at_every_ui_size(data) {
            const menu = hubAt(data.scale, data.others)
            const list = findChild(menu, "systemActions")
            const more = findChild(menu, "hubMoreBelow")
            tryCompare(list, "count", data.others > 0 ? 5 : 4)
            for (let step = 0; step < list.count; ++step) {     // the focus on every row: the name line is open in two of them
                tryVerify(() => list.contentHeight <= list.height + 0.5, 3000,
                          "the rows fit at row " + step + ": " + list.contentHeight + " in " + list.height)
                verify(!more.needed, "no scroll cue at row " + step)
                for (let i = 0; i < list.count; ++i) {
                    const row = list.itemAtIndex(i)
                    verify(row, "row " + i + " is built")
                    // (the name line opens over focusMs: the row and the list settle together)
                    tryVerify(() => row.mapToItem(list, 0, 0).y >= -0.5 && row.mapToItem(list, 0, 0).y + row.height <= list.height + 0.5,
                              2000, menu.itemKeys[i] + " lies inside the list at row " + step)
                }
                keyClick(Qt.Key_Down)
            }
            if (data.scale > 1)
                verify(menu.artFit < 1, "the art shrank at " + data.tag)
            else
                compare(menu.artFit, 1, "nothing changes at 100 %")
            verify(findChild(menu, "hubCardArt").width <= 256 * data.scale + 0.5)
        }

        // RUY-401: where even the smallest art does not make the rows fit, the art is at its smallest and the
        // list scrolls as before: the focused row is reachable (the game with two other apps at 150 %).
        function currentRowInView(list) {
            const r = list.itemAtIndex(list.currentIndex)
            return r && r.mapToItem(list, 0, 0).y + r.height <= list.height + 0.5
        }
        function test_the_art_is_at_its_smallest_where_the_rows_do_not_fit() {
            const menu = hubAt(1.5, 2)
            const list = findChild(menu, "systemActions")
            tryCompare(menu, "artFit", menu.artFitMin)
            for (let step = 0; step < 4; ++step)
                keyClick(Qt.Key_Down)
            compare(menu.currentRow, "panels")
            tryVerify(() => currentRowInView(list), 3000, "the icon row is in view")
        }

        // RUY-401: the line for the focused item's name takes no height while neither row has the focus.
        function test_the_name_line_is_closed_until_a_row_has_focus() {
            const menu = createTemporaryObject(menuComponent, host, {
                others: [{ appId: "org.example.A", title: "Alpha", picture: "", hasWindow: true },
                         { appId: "org.example.B", title: "Beta", picture: "", hasWindow: true }] })
            verify(menu)
            menu.present()
            tryCompare(menu, "settled", true)
            tryVerify(() => findChild(menu, "hubIconRow") !== null && findChild(menu, "hubRunningStrip") !== null, 2000)
            const strip = findChild(menu, "hubRunningStrip")
            const icons = findChild(menu, "hubIconRow")
            compare(menu.currentKey, "resume", "the game card has the focus")
            compare(strip.nameLine, 0)
            compare(icons.nameLine, 0)
            compare(strip.height, strip.view.height, "no gap under the tiles")
            compare(icons.height, icons.button, "no gap under the icons")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            compare(menu.currentRow, "running")
            tryVerify(() => strip.nameLine > 0 && strip.nameLine === strip.nameFull, 2000, "the strip shows the name")
            verify(findChild(menu, "hubRunningName").visible)
            compare(icons.nameLine, 0)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            compare(menu.currentRow, "panels")
            tryCompare(icons, "nameLine", icons.nameFull, 2000)
            tryCompare(strip, "nameLine", 0, 2000)
            verify(findChild(menu, "hubIconName").visible)
            keyClick(Qt.Key_Escape)
        }

        // RUY-401: Up from the strip into Home | Close game lands on the nearest column, not the remembered one:
        // the leftmost tile on Home, the rightmost (of two or three) on Close game; with one app, Home. With
        // two apps the rightmost tile is the middle slot of the three-slot grid (a tie of the half width).
        function test_up_from_the_strip_lands_on_the_nearest_column_data() {
            const rows = []
            for (const scale of [0.667, 1, 1.5])
                for (const n of [1, 2, 3])
                    rows.push({ tag: n + " apps at u " + scale, scale: scale, n: n })
            return rows
        }
        function test_up_from_the_strip_lands_on_the_nearest_column(data) {
            const all = [{ appId: "org.example.A", title: "Alpha", picture: "", hasWindow: true },
                         { appId: "org.example.B", title: "Beta", picture: "", hasWindow: true },
                         { appId: "org.example.C", title: "Gamma", picture: "", hasWindow: true }]
            const menu = createTemporaryObject(menuComponent, bigHost, {
                u: data.scale, marginX: 54, marginY: 54, bottomReserve: (Theme.glyphSize + Theme.spaceM) * data.scale,
                others: all.slice(0, data.n) })
            verify(menu)
            menu.present()
            tryCompare(menu, "settled", true)
            tryVerify(() => findChild(menu, "hubRunningStrip") !== null, 2000)
            const last = "to:org.example." + "ABC"[data.n - 1]
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Right)                          // Close game is the remembered column
            compare(menu.currentKey, "closeGame")
            keyClick(Qt.Key_Down)
            compare(menu.currentRow, "running")
            compare(menu.currentKey, "to:org.example.A")
            keyClick(Qt.Key_Up)
            compare(menu.currentKey, "home", "the leftmost tile goes up to Home")
            keyClick(Qt.Key_Down)
            for (let i = 1; i < data.n; ++i)
                keyClick(Qt.Key_Right)
            compare(menu.currentKey, last)                  // the rightmost tile
            keyClick(Qt.Key_Up)
            compare(menu.currentKey, data.n === 1 ? "home" : "closeGame",
                    data.n === 1 ? "the only tile is the leftmost" : "the rightmost tile goes up to Close game")
            keyClick(Qt.Key_Escape)
        }

        // RUY-401: B still resumes, but the hint bar over the game card names Resume once.
        function test_the_game_card_hint_lists_resume_once() {
            const menu = createTemporaryObject(menuComponent, host)
            verify(menu)
            menu.present()
            compare(menu.currentKey, "resume")
            compare(menu.hints.map(h => h.button + " " + h.text), ["A Resume"])
            let closed = 0
            menu.closeRequested.connect(() => ++closed)
            keyClick(Qt.Key_Escape)
            compare(closed, 1, "B still resumes")
        }

        // A two-line title over "Paused · 12 min" is taller than the art: the game card grows (T-471), so its text
        // never runs into the next row (Home | Close game).
        function test_a_long_title_and_paused_fit_in_the_header() {
            const menu = createTemporaryObject(menuComponent, host)
            verify(menu)
            menu.present()
            const card = findChild(menu, "hubGameCard")
            verify(card, "the game card is the first row")
            const info = findChild(menu, "hubCardInfo")
            const title = findChild(menu, "hubCardTitle")
            const state = findChild(menu, "hubCardState")
            const art = findChild(menu, "hubCardArt")
            tryVerify(() => title.lineCount === 2, 2000, "the title takes two lines")
            compare(state.text, "Paused · 12 min")
            tryVerify(() => info.height >= title.height + state.height, 2000, "the text is laid out")   // the Column lays out on the next polish
            verify(card.height >= info.height + 2 * card.pad, "the card holds all of its text")
            verify(card.height >= art.height + 2 * card.pad, "and its art")
            verify(art.width > 200 * menu.u, "the art is larger than the old header's (200 u)")
            tryVerify(() => findChild(menu, "quickMenuItem_leave") !== null, 2000, "the list has built its next row")
            const next = findChild(menu, "quickMenuItem_leave")
            // The panel centres itself again as its rows are built: compare both positions at the same moment.
            tryVerify(() => menu.settled && next.mapToItem(menu, 0, 0).y >= state.mapToItem(menu, 0, state.height).y, 2000,
                      "the state ends above Home | Close game")
            verify(next.mapToItem(menu, 0, 0).y >= state.mapToItem(menu, 0, state.height).y,
                   "the state ends above Home | Close game (" + state.mapToItem(menu, 0, state.height).y + " > " + next.mapToItem(menu, 0, 0).y + ")")
        }

        // Review (T-457 round 2): Switch profile from the Hub over a frozen game, then the same profile
        // signs in again: the game is in front and runs (a Thaw was seen), not frozen without "Paused".
        function test_switch_profile_from_the_hub_then_signing_back_in_thaws_the_game() {
            start()
            const run = playRacer()
            openHubAndPause(run.instance)
            goTo("switch")
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "")
            signInAda()
            tryVerify(() => run.app.activeFocus, 2000, "the game is in front again")
            tryVerify(() => recordOf(run.instance).frozen === false, 2000, "and runs")
            verify(Session.mockCalls().includes("thaw " + run.instance), "a Thaw was sent")
        }

        // Review (T-457 round 2): a game left frozen when the shell restarted (nobody in the new shell
        // asked for it) is thawed as soon as its profile signs in, so it can end or be resumed.
        function test_a_game_left_frozen_before_a_shell_restart_is_thawed_at_sign_in() {
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            const n = launchedSpy.count
            Session.launch("org.example.Racer", "p2")
            tryCompare(launchedSpy, "count", n + 1)
            const instance = launchedSpy.signalArguments[n][3]
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            Session.freeze(instance)                         // the old shell's Hub
            tryVerify(() => recordOf(instance).frozen === true)
            start()                                          // a new shell: locks, then Ada signs in
            tryVerify(() => recordOf(instance).frozen === false, 2000, "thawed after the sign-in")
            compare(Session.mockCalls(), ["freeze " + instance, "thaw " + instance])
        }

        // Review (T-457 round 2): a refused Thaw says so, the game stays frozen, and the next Hub over it
        // thaws it when it closes.
        function test_a_failed_thaw_toasts_and_the_next_close_tries_again() {
            start()
            const run = playRacer()
            openHubAndPause(run.instance)
            Session.mockFailThaw(true)
            keyClick(Qt.Key_Escape)
            tryVerify(() => run.app.activeFocus, 2000)
            tryVerify(() => toastTexts().includes("Could not resume the game. Open Ruya Hub and choose Resume."), 2000,
                      "a warning toast")
            verify(recordOf(run.instance).frozen, "still frozen")
            Session.mockFailThaw(false)
            openHub()
            tryVerify(() => find("hubCardState").text.startsWith("Paused"), 2000, "the game card says Paused again")   // a reply, not an instant (T-463: flaky at the short motion scale)
            keyClick(Qt.Key_Escape)
            tryVerify(() => recordOf(run.instance).frozen === false, 2000, "the second close thaws it")
            compare(Session.mockCalls(), ["freeze " + run.instance, "thaw " + run.instance, "thaw " + run.instance],
                    "the second Freeze is a no-op (the game is frozen already), two Thaws")
        }

        // ---- A frozen game stays frozen behind another one (T-464) ------------------------------------

        // The Racer frozen by the Hub and left behind Home: returns { app, instance }.
        function racerFrozenBehindHome() {
            const run = playRacer()
            openHubAndPause(run.instance)
            goTo("home")
            keyClick(Qt.Key_Return)
            tryVerify(() => !tc.shell.appOpen, 2000, "Home is in front")
            tryVerify(() => find("recentRow").activeFocus, 2000, "the focus is on the game card")
            verify(recordOf(run.instance).frozen, "the game stays frozen behind Home")
            return run
        }

        // Launches `appId` through Play's path; returns the instance once it runs.
        function launchOther(appId, title) {
            const n = launchedSpy.count
            tc.shell.launchApp(appId, title, "")
            tryCompare(launchedSpy, "count", n + 1)
            const instance = launchedSpy.signalArguments[n][3]
            verify(instance !== "")
            tryVerify(() => recordOf(instance) !== undefined && recordOf(instance).state === "running")
            return instance
        }

        // The study on the Dell: pygame closes its first window and opens a second. The frozen game
        // behind Home was the last shown app, so it became the front app, was thawed, and ran on unseen.
        function test_a_recreated_window_does_not_thaw_the_frozen_game_behind_it() {
            start()
            const racer = racerFrozenBehindHome()
            const puzzleInstance = launchOther("org.example.Puzzle", "Block Puzzle")
            const first = createTemporaryObject(appComponent, host, { appId: "org.example.Puzzle" })
            tc.shell.addApp(first, "p2")
            tryVerify(() => first.activeFocus, 2000, "the first window is in front")
            tc.shell.removeApp(first)                        // the window goes before the second one opens
            first.destroy()
            tryVerify(() => !tc.shell.appOpen, 2000, "the frozen game is not the front app: Home shows")
            verify(tc.shell.focusedApp === null)
            verify(!racer.app.activeFocus, "the frozen game has no focus")
            tryVerify(() => find("recentRow").activeFocus || find("homePlay").activeFocus, 2000, "the focus is on Home")
            wait(100)
            verify(recordOf(racer.instance).frozen, "the game is still frozen")
            compare(Session.mockCalls(), ["freeze " + racer.instance], "no Thaw was sent")

            const second = createTemporaryObject(appComponent, host, { appId: "org.example.Puzzle" })
            tc.shell.addApp(second, "p2")
            tryVerify(() => second.activeFocus, 2000, "the second window is in front")
            verify(tc.shell.appOpen)
            wait(100)
            verify(recordOf(racer.instance).frozen, "the game is still frozen behind it")
            compare(Session.mockCalls(), ["freeze " + racer.instance])
            verify(recordOf(puzzleInstance) !== undefined)
        }

        function test_a_game_that_crashes_at_start_leaves_the_frozen_game_frozen_and_shows_home() {
            start()
            const racer = racerFrozenBehindHome()
            tc.shell.launchApp("crashy", "Crashy", "")
            const app = createTemporaryObject(appComponent, host, { appId: "crashy" })
            tc.shell.addApp(app, "p2")                       // its window comes, and the game dies
            tryVerify(() => toastTexts().includes("crashy stopped unexpectedly"), 3000)
            tc.shell.removeApp(app)
            app.destroy()
            tryVerify(() => !tc.shell.appOpen, 2000, "Home shows, not the frozen game")
            tryVerify(() => find("recentRow").activeFocus || find("homePlay").activeFocus, 2000)
            wait(100)
            verify(recordOf(racer.instance).frozen, "the game is still frozen")
            compare(Session.mockCalls(), ["freeze " + racer.instance], "no Thaw was sent")
        }

        function test_a_game_that_cannot_start_leaves_the_frozen_game_frozen_and_shows_home() {
            start()
            const racer = racerFrozenBehindHome()
            tc.shell.launchApp("nolaunch", "No Launch", "")
            tryVerify(() => find("launchSplash").shown)
            tryCompare(find("launchSplash"), "shown", false)
            tryVerify(() => toastTexts().includes("No Launch could not start"), 2000)
            verify(!tc.shell.appOpen, "Home shows")
            wait(100)
            verify(recordOf(racer.instance).frozen, "the game is still frozen")
            compare(Session.mockCalls(), ["freeze " + racer.instance])
        }

        function test_the_player_can_still_resume_the_frozen_game_from_its_card() {
            start()
            const racer = racerFrozenBehindHome()
            launchOther("org.example.Puzzle", "Block Puzzle")
            const first = createTemporaryObject(appComponent, host, { appId: "org.example.Puzzle" })
            tc.shell.addApp(first, "p2")
            tc.shell.removeApp(first)
            first.destroy()
            tryVerify(() => !tc.shell.appOpen, 2000)
            tc.shell.focusApp(racer.app)                     // what Accept on the Running card does
            tryVerify(() => racer.app.activeFocus, 2000, "the card brings the game back")
            tryVerify(() => recordOf(racer.instance).frozen === false, 2000, "and it runs again")
            compare(Session.mockCalls(), ["freeze " + racer.instance, "thaw " + racer.instance])
        }

        // The belt: something else thaws the frozen game while another game is in front.
        function test_a_frozen_game_thawed_by_something_else_is_frozen_again_while_another_is_in_front() {
            start()
            const racer = racerFrozenBehindHome()
            launchOther("org.example.Puzzle", "Block Puzzle")
            const puzzle = createTemporaryObject(appComponent, host, { appId: "org.example.Puzzle" })
            tc.shell.addApp(puzzle, "p2")
            tryVerify(() => puzzle.activeFocus, 2000, "Block Puzzle is in front")
            Session.thaw(racer.instance)                     // not HubPause: a stray Thaw
            tryVerify(() => Session.mockCalls().filter(c => c === "freeze " + racer.instance).length === 2, 2000,
                      "frozen again")
            tryVerify(() => recordOf(racer.instance).frozen === true, 2000)
            verify(puzzle.activeFocus)
            compare(Session.mockCalls(), ["freeze " + racer.instance, "thaw " + racer.instance, "freeze " + racer.instance])
        }

        // The belt does not undo a Thaw HubPause sends itself (the Running card's Resume).
        function test_the_belt_leaves_a_resumed_game_alone() {
            start()
            const racer = racerFrozenBehindHome()
            keyClick(Qt.Key_Return)                          // the Running card resumes it
            tryVerify(() => racer.app.activeFocus, 2000)
            tryVerify(() => recordOf(racer.instance).frozen === false, 2000)
            wait(100)
            compare(Session.mockCalls(), ["freeze " + racer.instance, "thaw " + racer.instance])
        }

        // The setting survives a restart (tst_main.cpp, an ini file in a temporary directory).
        function test_the_setting_survives_a_restart() {
            compare(pausePersistence, "")
        }

        // ---- Screenshots (dev.ps1 shots) ------------------------------------------------------------

        function test_zz_screenshots_hub_over_a_paused_game() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            const run = playRacer(pictureAppComponent)
            openHubAndPause(run.instance)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/hub-5-paused.png")
        }

        // RUY-401: the Hub at 100 and 150 % (a game with two others; at 150 % a game alone, the strip's name open).
        function test_zz_screenshots_hub_at_ui_sizes() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            bigHost.transformOrigin = Item.TopLeft
            bigHost.scale = host.height / bigHost.height          // the 1080p screen, shown whole in the 720p window
            const sizes = [{ name: "100", scale: 1, others: 2 }, { name: "125", scale: 1.25, others: 2 }, { name: "150", scale: 1.5, others: 0 }]
            for (const size of sizes) {
                const menu = hubAt(size.scale, size.others)
                if (size.others > 0) {
                    keyClick(Qt.Key_Down)
                    keyClick(Qt.Key_Down)                     // the strip: its name line is open
                }
                wait(500)
                grabImage(host).save(shotsDir + "/hub-6-ui-" + size.name + ".png")
                menu.destroy()
            }
            bigHost.scale = 1
        }

        function test_zz_screenshots_settings_pause_row() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            keyClick(Qt.Key_Up)                              // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                          // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus, 2000)
            for (let i = 0; i < 20 && list.currentItem.objectName !== "category_system"; ++i)
                keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneSystem").activeFocus, 2000)
            const row = find("rowPauseGames")
            for (let i = 0; i < 20 && !row.activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(row.activeFocus)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/hub-6-settings-pause-row.png")
        }
    }
}
