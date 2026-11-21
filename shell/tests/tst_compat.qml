import QtQuick
import QtTest
import RuyaShell

// A .play game's Compatibility page (RUY-905, 05 §6.2): the game page's Compatibility row opens it; the Runner
// row stores the signed-in profile's choice at once (Package default, Bundled only with a bundled copy,
// System) and the rows below preview it (Starts with, Tested with, the Versions). After a crash on the system
// runner "Try the bundled runner" comes first; a refusal and a choice that falls back are worded by Library1's
// code and flag; Library1 not answering gives Try again. Against the Library mock's "play" scenario: Star
// Hopper, a Proton game with a bundled GE-Proton10-9 that the image's GE-Proton11-12 runs by default. Signs
// in as Player One (admin, p1).
Item {
    id: host
    width: 1920
    height: 1080

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: launchSpy; target: Library; signalName: "launchRequested" }

    TestCase {
        id: tc
        name: "Compatibility"
        when: windowShown

        property Shell shell: null

        readonly property string hopper: "flatpak:play.com.example.starhopper"
        readonly property string hopperApp: "play.com.example.starhopper"
        readonly property string today: "2026-11-21"

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            host.width = 1920
            host.height = 1080
            DeviceSettings.language = "en"
            Session.mockReset()
            Usage.mockReset()
            Library.resetMockForTests("play")
            tryVerify(() => Library.item(tc.hopper).play === true)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has focus on start")
            launchSpy.clear()
        }

        function cleanup() {
            Session.mockReset()
            Usage.mockReset()
            Library.resetMockForTests("")
            Profiles.lock()
            DeviceSettings.language = "en"
        }

        function signIn() {
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => find("homePlay").activeFocus, 2000, "home after the sign-in")
            tryCompare(Library, "profile", "p1")
        }

        // The game page, with the focus moved down to its Compatibility row.
        function openGamePage() {
            tc.shell.openPage("appDetail", { id: tc.hopper })
            tryCompare(tc.shell, "currentPage", "appDetail")
            const row = find("detailCompatRow")
            tryVerify(() => row.visible, 2000, "a .play game has the row")
            for (let i = 0; i < 20 && !row.activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(row.activeFocus, "Down reaches Compatibility")
            return row
        }

        // The page, opened from the game page's row; waits for Library1's answers.
        function openCompat() {
            openGamePage()
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "playCompatibility")
            const page = find("page_playCompatibility")
            tryVerify(() => !page.loading, 2000, "Library1 answered")
            return page
        }

        function focusedName() {
            const f = tc.shell.Window.activeFocusItem
            return f ? f.objectName : ""
        }

        function crashedLastTime() {
            Usage.mockSetData("p1", [{ appId: tc.hopperApp, day: tc.today, start: 1763700000, seconds: 600, reason: "crashed" }],
                              tc.today)
        }

        function toasts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text)
            return out
        }

        function test_the_row_sits_above_permissions_and_back_returns_to_it() {
            signIn()
            const row = openGamePage()
            tryCompare(row, "value", "Package default", 2000, "the stored choice's word")
            keyClick(Qt.Key_Down)
            verify(find("detailPermissionsRow").activeFocus, "Permissions comes after Compatibility")
            keyClick(Qt.Key_Up)
            verify(row.activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "playCompatibility")
            compare(tc.shell.currentParams.id, tc.hopper)
            const page = find("page_playCompatibility")
            compare(page.title, "Star Hopper")
            tryVerify(() => find("compatRunner").activeFocus, 2000, "the Runner row has the focus")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => row.activeFocus, 2000, "Back returns to the Compatibility row")
        }

        function test_a_plain_game_has_no_compatibility_row() {
            signIn()
            tc.shell.openPage("appDetail", { id: "flatpak:org.example.Puzzle" })
            tryCompare(tc.shell, "currentPage", "appDetail")
            wait(100)
            verify(!find("detailCompatRow").visible)
        }

        function test_the_rows_preview_the_package_default_and_focus_walks_them_in_order() {
            signIn()
            const page = openCompat()
            tryVerify(() => find("compatRunner").activeFocus, 2000)
            compare(find("compatRunner").value, "package")
            compare(find("compatRunner").currentLabel, "Package default")
            compare(find("compatRunner").options.map(o => o.value), ["package", "bundled", "system"])
            verify(!find("compatTry").visible, "no crash, no Try")
            compare(find("compatStartsWith").value, "proton-ge GE-Proton11-12")
            compare(find("compatStartsWith").detail, "System copy")
            compare(find("compatTested").value, "proton-ge GE-Proton10-9")
            verify(find("compatVersions").visible)
            compare(find("compatBundled").value, "proton-ge GE-Proton10-9")
            compare(find("compatSystem").value, "proton-ge GE-Proton11-12")
            verify(!find("compatRunnerNote").visible, "nothing to say")
            verify(!find("compatError").visible)
            const order = ["compatStartsWith", "compatTested", "compatBundled", "compatSystem"]
            for (const name of order) {
                keyClick(Qt.Key_Down)
                tryVerify(() => focusedName() === name, 2000, name)
            }
            keyClick(Qt.Key_Down)
            compare(focusedName(), "compatSystem", "the last row stays")
            keyClick(Qt.Key_Return)
            compare(tc.shell.currentPage, "playCompatibility", "A on a fact does nothing")
            for (let i = order.length - 2; i >= 0; --i) {
                keyClick(Qt.Key_Up)
                compare(focusedName(), order[i])
            }
            keyClick(Qt.Key_Up)
            verify(find("compatRunner").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("compatStartsWith").activeFocus)
            keyClick(Qt.Key_Left)                        // Left on a fact closes the page
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailCompatRow").activeFocus, 2000)
        }

        function storedChoice() {
            let got = null
            const spy = createTemporaryObject(spyComponent, tc, { target: Library, signalName: "runnerChoiceAnswered" })
            Library.runnerChoice(tc.hopper)
            tryCompare(spy, "count", 1)
            got = spy.signalArguments[0][2]
            return got
        }
        Component {
            id: spyComponent
            SignalSpy {}
        }

        function test_left_right_and_a_change_the_choice_and_store_it_at_once() {
            signIn()
            openCompat()
            const runner = find("compatRunner")
            tryVerify(() => runner.activeFocus, 2000)
            keyClick(Qt.Key_Right)
            compare(runner.value, "bundled")
            tryCompare(find("page_playCompatibility"), "saving", "")
            compare(storedChoice(), "bundled", "stored at once")
            tryCompare(find("compatStartsWith"), "value", "proton-ge GE-Proton10-9")
            compare(find("compatStartsWith").detail, "Bundled copy")
            verify(runner.activeFocus, "Right does not leave the row")
            keyClick(Qt.Key_Return)                      // A: the next option
            compare(runner.value, "system")
            tryCompare(find("page_playCompatibility"), "saving", "")
            compare(storedChoice(), "system")
            tryCompare(find("compatStartsWith"), "value", "proton-ge GE-Proton11-12")
            keyClick(Qt.Key_Right)                       // wraps
            compare(runner.value, "package")
            tryCompare(find("page_playCompatibility"), "saving", "")
            compare(storedChoice(), "package")
            keyClick(Qt.Key_Left)                        // Left on the Runner row changes, never closes
            compare(runner.value, "system")
            compare(tc.shell.currentPage, "playCompatibility")
            tryCompare(find("page_playCompatibility"), "saving", "")
            keyClick(Qt.Key_Left)
            compare(runner.value, "bundled")
            tryCompare(find("page_playCompatibility"), "saving", "")
            compare(storedChoice(), "bundled")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailCompatRow").activeFocus, 2000)
            compare(find("detailCompatRow").value, "Bundled", "the game page's row reads the change")
        }

        // The package's bundled copy is what the bundled choice gets; without one Library1 answers the package
        // default, flagged, and Bundled is not offered (05 §6.2), not even after a crash.
        function test_without_a_bundled_copy_bundled_is_not_offered() {
            Library.mockSetResolution(tc.hopper, "bundled", { playRunner: "proton-ge GE-Proton11-12", playRunnerSource: "system",
                                                              playRunnerTested: "GE-Proton10-9", playFallback: true })
            crashedLastTime()
            signIn()
            openCompat()
            tryVerify(() => find("compatRunner").activeFocus, 2000)
            compare(find("compatRunner").options.map(o => o.value), ["package", "system"])
            compare(find("compatBundled").value, "None")
            verify(!find("compatTry").visible, "no bundled runner to try")
            verify(!find("compatRunnerNote").visible)
        }

        function test_a_refusal_is_worded_by_its_code_and_hides_tested() {
            Library.mockSetResolution(tc.hopper, "system", {
                playResolveError: "The OS runner is GE-Proton11-12, a major version above the allowed 10.",
                playResolveCode: "resolve.system_too_new" })
            signIn()
            openCompat()
            const runner = find("compatRunner")
            tryVerify(() => runner.activeFocus, 2000)
            keyClick(Qt.Key_Left)                        // System
            compare(runner.value, "system")
            tryCompare(find("compatStartsWith"), "value", "Can't start")
            compare(find("compatStartsWith").detail, "")
            verify(find("compatRefusal").visible)
            compare(find("compatRefusal").text, "The system runner is newer than this game allows.")
            verify(Qt.colorEqual(find("compatRefusal").color, Theme.errorText), "in the error colour")
            verify(!find("compatTested").visible, "nothing to compare with")
            DeviceSettings.language = "tr"
            tryCompare(find("compatRefusal"), "text", "Sistemdeki çalıştırıcı bu oyunun izin verdiğinden yeni.")
            compare(find("compatStartsWith").value, "Başlatılamaz")
        }

        function test_each_code_has_its_sentence() {
            compare(RunnerText.refusal("resolve.no_system_runner"), "This console has no runner for this game.")
            compare(RunnerText.refusal("resolve.system_too_old"), "The system runner is older than this game needs.")
            compare(RunnerText.refusal("resolve.no_bundled"), "This game has no bundled runner to fall back on.")
            compare(RunnerText.refusal("launch.runner_missing"), "The system runner can't be found.")
            compare(RunnerText.refusal("launch.runner_kind"), "The system runner is the wrong kind for this game.")
            compare(RunnerText.refusal("package.hash_mismatch"), "This game's files are damaged. Reinstall it.")
        }

        function test_a_choice_that_falls_back_says_so() {
            Library.mockSetResolution(tc.hopper, "system", { playRunner: "proton-ge GE-Proton10-9", playRunnerSource: "bundled",
                                                             playRunnerTested: "GE-Proton10-9", playFallback: true })
            signIn()
            openCompat()
            const runner = find("compatRunner")
            tryVerify(() => runner.activeFocus, 2000)
            keyClick(Qt.Key_Left)                        // System
            tryVerify(() => find("compatRunnerNote").visible, 2000)
            compare(find("compatRunnerNote").text,
                    "The system runner can't be used for this game, so it uses the package default.")
            compare(find("compatStartsWith").value, "proton-ge GE-Proton10-9")
            compare(find("compatStartsWith").detail, "Bundled copy")
        }

        function test_a_change_while_the_game_runs_takes_effect_next_time() {
            signIn()
            Session.launch(tc.hopperApp, "p1")
            tryVerify(() => Session.running.some(r => r.appId === tc.hopperApp), 3000)
            const page = openCompat()
            tryVerify(() => find("compatRunner").activeFocus, 2000)
            verify(!find("compatRunnerNote").visible, "nothing changed yet")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("compatRunnerNote").visible, 2000)
            compare(find("compatRunnerNote").text, "Takes effect the next time the game starts.")
        }

        // A stored Bundled for a package without a copy (a package updated since) keeps the option, so the row never
        // shows an empty value, and says why it uses the package default (RUY-905 deviation 3, accepted).
        function test_a_stored_bundled_choice_without_a_copy_keeps_the_option_and_says_so() {
            Library.mockSetResolution(tc.hopper, "bundled", { playRunner: "proton-ge GE-Proton11-12", playRunnerSource: "system",
                                                              playRunnerTested: "GE-Proton10-9", playFallback: true })
            signIn()
            Library.setRunnerChoice(tc.hopper, "bundled")
            tryCompare(Library.item(tc.hopper), "playRunnerSource", "system")
            tryVerify(() => storedChoice() === "bundled", 2000)
            openCompat()
            const runner = find("compatRunner")
            tryVerify(() => runner.activeFocus, 2000)
            compare(runner.value, "bundled")
            compare(runner.currentLabel, "Bundled")
            compare(runner.options.map(o => o.value), ["package", "bundled", "system"])
            tryVerify(() => find("compatRunnerNote").visible, 2000)
            compare(find("compatRunnerNote").text, "This game has no bundled runner, so it uses the package default.")
            DeviceSettings.language = "tr"
            tryCompare(find("compatRunnerNote"), "text", "Bu oyunla gelen bir çalıştırıcı yok, paket varsayılanı kullanılır.")
            keyClick(Qt.Key_Right)                       // System: Bundled is offered no more
            tryCompare(runner, "value", "system")
            tryVerify(() => runner.options.map(o => o.value).join() === "package,system", 2000)
        }

        // While the game runs, Try would start it again: the row is not there (a crash on the system runner).
        function test_try_is_not_offered_while_the_game_runs() {
            crashedLastTime()
            signIn()
            Session.launch(tc.hopperApp, "p1")
            tryVerify(() => Session.running.some(r => r.appId === tc.hopperApp), 3000)
            const page = openCompat()
            tryVerify(() => find("compatRunner").activeFocus, 2000, "the focus goes to Runner")
            verify(page.crashedLast)
            verify(!find("compatTry").visible, "running: no Try")
            Session.mockReset()
            tryVerify(() => find("compatTry").visible, 2000, "Try returns once the game is not running")
        }

        // A dimmed Runner row cannot be changed: Left and Right do nothing, A says why.
        function test_the_unreachable_runner_row_does_not_change() {
            Library.mockFailRunnerCalls(["get", "resolve"])
            signIn()
            openGamePage()
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "playCompatibility")
            tryVerify(() => find("page_playCompatibility").failed, 2000)
            tryVerify(() => find("compatRetry").activeFocus, 2000)
            keyClick(Qt.Key_Up)
            const runner = find("compatRunner")
            verify(runner.activeFocus)
            const before = toasts().length
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            compare(runner.currentLabel, "Not available")
            verify(runner.activeFocus, "Left and Right stay on the row")
            compare(tc.shell.currentPage, "playCompatibility")
            compare(toasts().length, before, "no notice for Left and Right")
            keyClick(Qt.Key_Return)
            tryVerify(() => toasts().length === before + 1, 2000, "A explains why")
        }

        function test_after_a_crash_try_the_bundled_runner_comes_first_and_starts_the_game() {
            crashedLastTime()
            signIn()
            openCompat()
            const tryRow = find("compatTry")
            tryVerify(() => tryRow.visible && tryRow.activeFocus, 2000, "Try has the focus")
            compare(tryRow.value, "It stopped unexpectedly last time.")
            keyClick(Qt.Key_Down)
            verify(find("compatRunner").activeFocus, "Runner comes next")
            keyClick(Qt.Key_Up)
            verify(tryRow.activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(launchSpy, "count", 1)
            compare(launchSpy.signalArguments[0][0], tc.hopper)
            compare(storedChoice(), "bundled", "stored before the launch")
        }

        function test_a_store_that_fails_goes_back_and_says_so() {
            signIn()
            openCompat()
            const runner = find("compatRunner")
            tryVerify(() => runner.activeFocus, 2000)
            Library.mockFailRunnerCalls(["set"])
            keyClick(Qt.Key_Right)
            tryCompare(runner, "value", "package")
            tryVerify(() => find("compatError").visible, 2000)
            compare(find("compatError").text, "The choice could not be saved. Try again.")
            compare(find("compatStartsWith").value, "proton-ge GE-Proton11-12")
            Library.mockFailRunnerCalls([])
            compare(storedChoice(), "package")
        }

        function test_unreachable_library_offers_try_again() {
            Library.mockFailRunnerCalls(["get", "resolve"])
            signIn()
            openGamePage()
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "playCompatibility")
            const page = find("page_playCompatibility")
            tryVerify(() => page.failed, 2000)
            const retry = find("compatRetry")
            tryVerify(() => retry.visible && retry.activeFocus, 2000, "Try again has the focus")
            const runner = find("compatRunner")
            verify(runner.visible && runner.dimmed)
            compare(runner.currentLabel, "Not available")
            compare(find("compatError").text, "Runner details can't be read right now.")
            for (const name of ["compatStartsWith", "compatTested", "compatVersions", "compatBundled", "compatSystem"])
                verify(!find(name).visible, name)
            keyClick(Qt.Key_Up)
            verify(runner.activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => toasts().indexOf("Runner: the library isn't responding.") >= 0, 2000)
            keyClick(Qt.Key_Down)
            verify(retry.activeFocus)
            Library.mockFailRunnerCalls([])
            keyClick(Qt.Key_Return)
            tryVerify(() => page.loaded, 2000)
            tryVerify(() => runner.activeFocus, 2000, "the focus goes to the Runner row")
            verify(!retry.visible)
            compare(find("compatStartsWith").value, "proton-ge GE-Proton11-12")
        }

        // At 720p the same layout at u = 2/3, and Turkish fits: no value elides.
        function test_turkish_at_720p_elides_nothing() {
            host.width = 1280
            host.height = 720
            DeviceSettings.language = "tr"
            Library.mockSetResolution(tc.hopper, "system", { playRunner: "proton-ge GE-Proton10-9", playRunnerSource: "bundled",
                                                             playRunnerTested: "GE-Proton10-9", playFallback: true })
            signIn()
            openCompat()
            keyClick(Qt.Key_Left)
            tryVerify(() => find("compatRunnerNote").visible, 2000)
            compare(find("compatRunner").label, "Çalıştırıcı")
            for (const name of ["compatRunner", "compatStartsWith", "compatTested", "compatBundled", "compatSystem"]) {
                const label = findChild(find(name), "label")
                verify(label, name)
                verify(!label.truncated, name + " label elides: " + label.text)
            }
            for (const name of ["compatStartsWith", "compatTested", "compatBundled", "compatSystem"]) {
                const value = findChild(find(name), "value")
                verify(value, name)
                verify(!value.truncated, name + " value elides: " + value.text)
            }
        }

        // ---- screenshots (dev.ps1 shots): default, a refusal, after a crash, a fallback, a change while it runs, unreachable; EN and TR ----
        function settle() {
            wait(600)
            grabImage(tc.shell)                          // the first grab lays the pane out
            wait(400)
        }

        function shots(dir, lang) {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.language = lang
            Library.mockSetResolution(tc.hopper, "system", {
                playResolveError: "The OS runner is GE-Proton11-12, a major version above the allowed 10.",
                playResolveCode: "resolve.system_too_new" })
            signIn()
            openCompat()
            tryVerify(() => find("compatRunner").activeFocus, 2000)
            settle()
            grabImage(tc.shell).save(dir + "compat-default-" + lang + ".png")
            keyClick(Qt.Key_Left)                        // System: refused
            tryVerify(() => find("compatRefusal").visible, 2000)
            settle()
            grabImage(tc.shell).save(dir + "compat-error-" + lang + ".png")
            keyClick(Qt.Key_Right)                       // back to Package default
            tryCompare(find("page_playCompatibility"), "saving", "")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            crashedLastTime()
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "playCompatibility")
            tryVerify(() => find("compatTry").activeFocus, 2000)
            settle()
            grabImage(tc.shell).save(dir + "compat-crash-" + lang + ".png")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            // The system runner can't be used: the answer is the package default, flagged.
            Library.mockSetResolution(tc.hopper, "system", { playRunner: "proton-ge GE-Proton10-9", playRunnerSource: "bundled",
                                                             playRunnerTested: "GE-Proton10-9", playFallback: true })
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "playCompatibility")
            tryVerify(() => find("compatTry").activeFocus, 2000)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Left)                        // System: falls back
            tryVerify(() => find("compatRunnerNote").visible, 2000)
            settle()
            grabImage(tc.shell).save(dir + "compat-fallback-" + lang + ".png")
            // The game runs: no Try, and a change waits for the next start.
            Session.launch(tc.hopperApp, "p1")
            tryVerify(() => Session.running.some(r => r.appId === tc.hopperApp), 3000)
            tryVerify(() => !find("compatTry").visible, 2000)
            keyClick(Qt.Key_Right)                       // Package default
            tryCompare(find("page_playCompatibility"), "saving", "")
            tryCompare(find("compatRunnerNote"), "text", lang === "en" ? "Takes effect the next time the game starts."
                                                                       : "Oyun bir sonraki açılışında geçerli olur.")
            settle()
            grabImage(tc.shell).save(dir + "compat-nextstart-" + lang + ".png")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            Session.mockReset()
            Library.mockFailRunnerCalls(["get", "resolve"])
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "playCompatibility")
            tryVerify(() => find("compatRetry").activeFocus, 2000)
            settle()
            grabImage(tc.shell).save(dir + "compat-unreachable-" + lang + ".png")
        }

        // The shots runner picks the functions that save to `shotsDir + "/` themselves (dev.ps1).
        function test_zz_screenshots() { shots(shotsDir + "/", "en") }
        function test_zz_screenshots_tr() { shots(shotsDir + "/", "tr") }
    }
}
