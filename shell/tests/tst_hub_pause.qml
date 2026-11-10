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
                    picture: "", started: Date.now() / 1000, instance: "x", frozen: true })
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
            freezeSpy.clear()
            frozenSpy.clear()
        }

        function cleanup() {
            DeviceSettings.pauseGamesInHub = true
            Session.mockFailFreeze(false)
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
            tryVerify(() => find("quickMenuPaused").visible, 2000, "the header says Paused")
            compare(Session.mockCalls(), ["freeze " + instance])
            verify(find("quickMenuItem_resume").focused, "the focus starts on Resume")
        }

        function focusedKey() {
            const list = find("systemActions")
            return list.model[list.currentIndex]
        }

        function goTo(key) {
            for (let i = 0; i < 20 && focusedKey() !== key; ++i)
                keyClick(Qt.Key_Down)
            compare(focusedKey(), key)
            verify(find("quickMenuItem_" + key).focused, key + " has the focus ring")
        }

        function test_opening_the_hub_freezes_the_game_and_resume_thaws_it() {
            start()
            const run = playRacer()
            verify(!recordOf(run.instance).frozen)
            openHubAndPause(run.instance)
            compare(find("quickMenuPaused").text, "Paused")
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
            verify(!find("quickMenuPaused").visible)
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
            verify(!find("quickMenuPaused").visible, "nothing is shown as paused")
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

        // A two-line title over "Paused" is taller than the art: the header grows, so "Paused" never runs
        // into the first row below it.
        function test_a_long_title_and_paused_fit_in_the_header() {
            const menu = createTemporaryObject(menuComponent, host)
            verify(menu)
            const header = findChild(menu, "quickMenuApp")
            const info = findChild(menu, "quickMenuAppInfo")
            const title = findChild(menu, "quickMenuTitle")
            const paused = findChild(menu, "quickMenuPaused")
            const list = findChild(menu, "systemActions")
            tryVerify(() => title.lineCount === 2, 2000, "the title takes two lines")
            verify(paused.visible)
            const art = findChild(menu, "quickMenuArt")
            tryVerify(() => info.height > art.height, 2000, "the text is taller than the art here")   // the Column lays out on the next polish
            verify(header.height >= info.height, "the header holds all of its text")
            const pausedBottom = paused.mapToItem(menu, 0, paused.height).y
            const listTop = list.mapToItem(menu, 0, 0).y
            verify(pausedBottom <= listTop, "Paused ends above the first row (" + pausedBottom + " > " + listTop + ")")
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
    }
}
