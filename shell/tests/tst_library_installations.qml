import QtQuick
import QtTest
import RuyaShell

// One game, several installations (RUY-137, Library1 games): with the mock's "installations" scenario a
// .play "Turbo Racer" sits next to the Flatpak one. Two games with one title until the player links them
// (the "Same game as" row); then one game whose "Choose installation" list says which one Play starts;
// "Separate" splits it again. The menu opens on Home's Recent card, and the focus is back on that card
// after each row. The game page says how many installations there are and which one Play uses. Signs in as
// "Ada" (p2).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: launchSpy; target: Library; signalName: "launchRequested" }
    SignalSpy { id: answerSpy; target: Library; signalName: "installationCallFinished" }
    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }

    Component {
        id: appComponent
        Item {
            property string appId: "play.com.example.racer"
            property int pid: 0
            objectName: "standInApp"
            Keys.onPressed: event => { event.accepted = true }
        }
    }

    TestCase {
        id: tc
        name: "LibraryInstallations"
        when: windowShown

        readonly property string racer: "flatpak:org.example.Racer"
        readonly property string play: "flatpak:play.com.example.racer"
        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        function menu() { return find("optionsMenu") }
        function rowIds() { return menu().rows.map(r => r.id) }
        function rowLabel(id) { return menu().rows.find(r => r.id === id)?.label ?? "" }
        function game() { return Library.item(racer) }
        function installIds() { return (game().installations ?? []).map(i => i.id) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.language = "en"
            Library.resetMockForTests("installations")
            Session.mockReset()
            Store.mockReset()
            launchSpy.clear()
            answerSpy.clear()
            launchedSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            Library.resetMockForTests("")
            DeviceSettings.language = "en"
        }

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
            tryVerify(() => Library.items.length === 11)
            tryVerify(() => Store.available)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            wait(50)                                    // the Return that signed in has been released
            launchSpy.clear()
            keyClick(Qt.Key_Down)
            tryVerify(() => find("recentRow").activeFocus, 2000)
            compare(tc.shell.heroItem.id, racer, "the Flatpak Turbo Racer is the first Recent card")
        }

        // Opens the card's menu and runs the row `id` (the focus moves down to it).
        function runRow(id) {
            keyClick(Qt.Key_Menu)
            verify(menu().shown)
            const at = rowIds().indexOf(id)
            verify(at >= 0, id + " in " + rowIds())
            for (let i = 0; i < at; ++i)
                keyClick(Qt.Key_Down)
            compare(menu().currentId, id)
            const n = answerSpy.count
            keyClick(Qt.Key_Return)
            return n
        }

        function focusOnTheCard() {
            verify(!menu().shown)
            verify(find("recentRow").activeFocus, "the focus is back on the card")
            compare(tc.shell.heroItem.id, racer, "on the same game")
        }

        function link() {
            const n = runRow("link:" + play)
            tryCompare(answerSpy, "count", n + 1)
            compare(answerSpy.signalArguments[n][1], "ok")
            tryVerify(() => Library.items.length === 10, 2000)
            focusOnTheCard()
        }

        function test_one_title_two_ids_are_two_games_and_a_question() {
            start()
            compare(Library.item(play).title, "Turbo Racer")
            compare(game().confidence, "single")
            compare(game().suggestions, [play])
            compare(Library.item(play).suggestions, [racer])
            keyClick(Qt.Key_Menu)
            compare(rowIds(), ["play", "details", "activity", "link:" + play, "uninstall"])
            compare(rowLabel("link:" + play), "Same game as the .play version?")
            keyClick(Qt.Key_Escape)
            focusOnTheCard()
        }

        function test_a_suggestion_links_and_the_library_shows_one_game() {
            start()
            link()
            compare(installIds(), [play, racer], "Library1's order: .play first")
            compare(game().confidence, "confirmed")
            compare(game().suggestions, [])
            compare(Library.item(play).id, undefined, "no game of its own any more")
            compare(game().launch, racer, "a link never changes what Play starts")
            keyClick(Qt.Key_Menu)
            compare(rowIds(), ["play", "details", "activity", "installations", "separate:" + play, "uninstall"])
            compare(rowLabel("separate:" + play), "Separate .play")
            keyClick(Qt.Key_Return)                     // Play
            tryCompare(launchSpy, "count", 1)
            compare(launchSpy.signalArguments[0][1], racer)
        }

        function test_choose_installation_lists_both_and_changes_what_play_launches() {
            start()
            link()
            runRow("installations")
            verify(menu().shown, "the list opens where the menu was")
            verify(menu().activeFocus)
            compare(menu().title, "Turbo Racer")
            compare(rowIds(), ["prefer:" + play, "prefer:" + racer])
            compare(menu().rows.map(r => r.label), [".play · 1.4.2", "Flatpak"])
            compare(menu().rows.map(r => r.icon), ["", "check_circle"], "the preferred one is checked")
            const n = answerSpy.count                   // the .play row, the first
            keyClick(Qt.Key_Return)
            tryCompare(answerSpy, "count", n + 1)
            compare(answerSpy.signalArguments[n][0], "SetPreferredInstallation")
            compare(answerSpy.signalArguments[n][1], "ok")
            focusOnTheCard()
            tryVerify(() => game().launch === play, 2000)
            compare(game().installations.map(i => i.preferred), [true, false])
            runRow("installations")
            compare(menu().rows.map(r => r.icon), ["check_circle", ""])
            keyClick(Qt.Key_Escape)
            focusOnTheCard()
            runRow("play")
            tryCompare(launchSpy, "count", 1)
            compare(launchSpy.signalArguments[0][1], play, "Play launches the chosen one")
        }

        function test_separate_splits_the_game_again() {
            start()
            link()
            const n = runRow("separate:" + play)
            tryCompare(answerSpy, "count", n + 1)
            compare(answerSpy.signalArguments[n][0], "UnlinkInstallation")
            tryVerify(() => Library.items.length === 11, 2000)
            focusOnTheCard()
            compare(installIds(), [racer])
            compare(game().suggestions, [play], "the question again")
            compare(Library.item(play).installations.length, 1)
        }

        function test_the_game_page_says_which_installation_play_uses() {
            start()
            keyClick(Qt.Key_Up)
            tryVerify(() => find("homePlay").activeFocus)
            keyClick(Qt.Key_Right)                      // Details
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appDetail")
            const line = () => find("detailDeveloper")
            tryVerify(() => line() !== null)
            verify(line().text.indexOf("installations") < 0, "one installation: no line: " + line().text)
            Library.linkInstallations(racer, play)
            tryVerify(() => line().text.endsWith("2 installations, Play uses Flatpak"), 2000, line().text)
            Library.setPreferredInstallation(racer, play)
            tryVerify(() => line().text.endsWith("2 installations, Play uses .play"), 2000, line().text)
            DeviceSettings.language = "tr"
            tryVerify(() => line().text.endsWith("2 kurulum, Oyna: .play"), 2000, line().text)
        }

        function test_a_refused_change_toasts_and_leaves_the_focus() {
            start()
            const n = answerSpy.count
            tc.shell.runOption("recent", racer, "separate:flatpak:org.example.Puzzle")
            tryCompare(answerSpy, "count", n + 1)
            compare(answerSpy.signalArguments[n][1], "invalid")
            tryVerify(() => Notifications.model.count > 0)
            compare(Notifications.model.get(0).text, "Could not change Turbo Racer. Try again.")
            focusOnTheCard()
        }

        // The runner calls name the .play installation even when the game's id is the Flatpak one's.
        function test_the_runner_calls_follow_the_preferred_installation() {
            start()
            Library.linkInstallations(racer, play)
            tryVerify(() => Library.items.length === 10, 2000)
            Library.setPreferredInstallation(racer, play)
            tryVerify(() => game().play === true, 2000, "the .play is preferred: the game has its keys")
            const spy = createTemporaryObject(signalSpyComponent, tc, { target: Library, signalName: "runnerChoiceAnswered" })
            Library.runnerChoice(racer)
            tryCompare(spy, "count", 1)
            compare(spy.signalArguments[0][0], racer, "answered under the game's id")
            compare(spy.signalArguments[0][1], "ok", "asked for the .play")
        }

        Component { id: signalSpyComponent; SignalSpy {} }

        // ---- a game that runs from an installation Play does not use (Shell.gameAppIn) ----

        function runningFromThePlay() {
            start()
            link()                                      // Play uses the Flatpak
            const n = launchedSpy.count
            Session.launch("play.com.example.racer", "p2")
            tryCompare(launchedSpy, "count", n + 1)
            const instance = launchedSpy.signalArguments[n][3]
            tryVerify(() => Session.running.some(r => r.instance === instance && r.state === "running"), 2000)
            return instance
        }

        function test_itemForApp_finds_the_game_by_an_installation_play_does_not_use() {
            start()
            link()
            compare(Library.itemForApp("org.example.Racer").id, racer)
            compare(Library.itemForApp("play.com.example.racer").id, racer, "the other installation")
            compare(Library.sessionAppIds(racer), ["org.example.Racer", "play.com.example.racer"], "Play's first")
        }

        function test_a_running_installation_play_does_not_use_reads_as_running_everywhere() {
            runningFromThePlay()
            const card = find("recentRow").currentItem
            tryVerify(() => card.running, 2000, "the Recent card")
            verify(tc.shell.heroRunning, "the hero")
            compare(find("homePlay").text, "Resume")
            keyClick(Qt.Key_Menu)
            compare(rowIds(), ["close", "details", "activity"], "no Play, and the game cannot change while it runs")
            keyClick(Qt.Key_Escape)
            focusOnTheCard()
            keyClick(Qt.Key_Up)
            tryVerify(() => find("homePlay").activeFocus)
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                     // Games: its first card is the game
            tryCompare(tc.shell, "currentPage", "games")
            tryVerify(() => find("gamesGrid").activeFocus, 2000)
            wait(50)                                    // the Return that opened it is released
            keyClick(Qt.Key_Menu)
            compare(menu().title, "Turbo Racer")
            compare(rowIds(), ["close", "details", "activity"], "the Games card too")
            keyClick(Qt.Key_Escape)
        }

        // Play's installation is a Steam game the shell cannot start (no session app id), while the .play
        // runs: the hero still shows Resume (lead review of round 2, Shell.qml primaryShown).
        function test_the_hero_shows_resume_when_play_uses_an_installation_the_shell_cannot_start() {
            start()
            link()
            const steam = "steam:367520"
            let n = answerSpy.count
            Library.linkInstallations(racer, steam)
            tryCompare(answerSpy, "count", n + 1)
            compare(answerSpy.signalArguments[n][1], "ok")
            n = answerSpy.count
            Library.setPreferredInstallation(racer, steam)
            tryCompare(answerSpy, "count", n + 1)
            compare(answerSpy.signalArguments[n][1], "ok")
            tryVerify(() => Library.sessionAppId(racer) === "", 2000, "Play uses the Steam installation")
            const started = launchedSpy.count
            Session.launch("play.com.example.racer", "p2")
            tryCompare(launchedSpy, "count", started + 1)
            tryVerify(() => tc.shell.runningAppIds.includes("play.com.example.racer"), 2000)
            tryCompare(tc.shell.heroItem, "id", racer)
            verify(tc.shell.heroRunning, "the game runs from its .play")
            tryVerify(() => find("homePlay").visible, 2000, "the hero's button is shown")
            compare(find("homePlay").text, "Resume")
        }

        function test_resume_brings_back_the_running_installation_and_starts_no_second() {
            const instance = runningFromThePlay()
            const app = createTemporaryObject(appComponent, host, { pid: Session.mockPidOf(instance) })
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000)
            app.focus = false
            tc.shell.forceActiveFocus()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
            const panel = find("systemPanel")
            for (let i = 0; i < 30 && panel.currentKey !== "home"; ++i)
                keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("recentRow").activeFocus, 2000)
            keyClick(Qt.Key_Menu)
            compare(rowIds(), ["resume", "close", "details", "activity"])
            const n = launchedSpy.count
            keyClick(Qt.Key_Return)                     // Resume
            tryVerify(() => app.activeFocus, 2000, "the .play's window is back")
            compare(launchedSpy.count, n, "no second installation started")
        }

        function test_same_game_is_not_offered_while_the_other_game_runs() {
            start()
            const n = launchedSpy.count
            Session.launch("play.com.example.racer", "p2")
            tryCompare(launchedSpy, "count", n + 1)
            tryVerify(() => tc.shell.runningAppIds.includes("play.com.example.racer"), 2000)
            // The running .play game comes first in the Recent row; the Flatpak game's card is further on.
            for (let i = 0; i < 8 && tc.shell.heroItem.id !== racer; ++i)
                keyClick(Qt.Key_Right)
            compare(tc.shell.heroItem.id, racer)
            keyClick(Qt.Key_Menu)
            compare(rowIds(), ["play", "details", "activity", "uninstall"], "no Same game while the other game runs")
            keyClick(Qt.Key_Escape)
        }

        function settle() { wait(900) }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            for (const v of [[1280, 720, "720p"], [1920, 1080, "1080p"]]) {
                host.width = v[0]
                host.height = v[1]
                for (const lang of ["en", "tr"]) {
                    Library.resetMockForTests("installations")
                    DeviceSettings.language = lang
                    const tag = v[2] + "-" + lang
                    start()
                    keyClick(Qt.Key_Menu)               // two games, one title: the question
                    tryVerify(() => menu().opacity >= 1, 2000)
                    settle()
                    grabImage(tc.shell).save(shotsDir + "/137-installations-question-" + tag + ".png")
                    keyClick(Qt.Key_Escape)
                    link()
                    runRow("installations")             // the list, the .play checked
                    tryVerify(() => menu().opacity >= 1, 2000)
                    settle()
                    grabImage(tc.shell).save(shotsDir + "/137-installations-menu-" + tag + ".png")
                    keyClick(Qt.Key_Escape)
                    keyClick(Qt.Key_Menu)               // the linked game's rows
                    tryVerify(() => menu().opacity >= 1, 2000)
                    settle()
                    grabImage(tc.shell).save(shotsDir + "/137-installations-rows-" + tag + ".png")
                    keyClick(Qt.Key_Escape)
                    keyClick(Qt.Key_Up)
                    keyClick(Qt.Key_Right)              // Details: the game page's line
                    keyClick(Qt.Key_Return)
                    tryCompare(tc.shell, "currentPage", "appDetail")
                    settle()
                    grabImage(tc.shell).save(shotsDir + "/137-installations-page-" + tag + ".png")
                    tc.shell.destroy()
                    wait(100)
                }
            }
            host.width = 1280
            host.height = 720
        }
    }
}
