import QtQuick
import QtTest
import RuyaShell

// Install from USB (05 §7.3, 04 §5.4, RUY-98): the sources list, the package page for every mock fixture (trust
// badge, permission words, why Install is dimmed), the confirm sheet, the admin's PIN for a profile that is not
// an admin's, the progress and the result (toast, dialog), a job that outlives its page, developer mode, the
// entry points and the hint bar of every screen. The mock service has eleven packages on one drive ("STICK").
// Signs in as Player One (p1, admin, PIN 1234) unless a test says it is Ada (p2, standard, no PIN).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // The status the service last gave the developer-mode call, every remove call it answered, and every job
    // the facade saw end: { key, status, kind, name }.
    property string devAnswer: ""
    property var removeAnswers: []
    property var finishedJobs: []
    Connections {
        target: Play
        function onAnswered(op, key, status) {
            if (op === "developer-mode")
                host.devAnswer = status
            else if (op === "remove")
                host.removeAnswers = host.removeAnswers.concat([{ key: key, status: status }])
        }
        function onJobFinished(key, status, kind, name) {
            host.finishedJobs = host.finishedJobs.concat([{ key: key, status: status, kind: kind, name: name }])
        }
    }

    TestCase {
        id: tc
        name: "InstallUsb"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text + (Notifications.model.get(i).detail !== "" ? ": " + Notifications.model.get(i).detail : ""))
            return out
        }
        function page() { return find("page_installPackage") }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
            host.removeAnswers = []
            host.finishedJobs = []
            Play.mockReset()
            Store.mockReset()
            Profiles.lock()
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => Play.sources.length === 13)
        }

        function cleanup() {
            Play.mockPauseJobs(false)
        }

        function start(who) {
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            Profiles.switchTo(who === "ada" ? "p2" : "p1", who === "ada" ? "" : "1234")
            tryCompare(Profiles, "activeProfile", who === "ada" ? "p2" : "p1")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        // The hints as "accept Select|back Back", read from the bar's own delegates (what is drawn).
        function shown() {
            const bar = find("hintBar")
            if (!bar.visible)
                return ""
            const parts = []
            for (const b of ["left_right", "accept", "back", "done", "view", "tabPrev_tabNext", "options"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        function openPackage(fixture) {
            tc.shell.openPage("installPackage", { path: Play.mockPath(fixture) })
            tryCompare(tc.shell, "currentPage", "installPackage")
            tryVerify(() => page().info !== null, 3000, "Inspect answered")
            tryVerify(() => page().mainButton() !== null && page().mainButton().activeFocus, 3000, "the main button has the focus")
        }

        // A closed page fades out before its slot goes: wait until it is gone, so find() cannot return the old one.
        function closePackage() {
            tc.shell.closePage()
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("page_installPackage") === null, 5000, "the old page is gone")
        }

        function enterPin(pin) {
            for (const ch of pin)
                keyClick(Qt.Key_0 + Number(ch))
            keyClick(Qt.Key_Enter)
        }

        // ---- The list of packages ----

        function test_sources_list_focus_and_open() {
            start("admin")
            tc.shell.openPage("installSources", {})
            tryCompare(tc.shell, "currentPage", "installSources")
            const list = find("sourcesList")
            tryVerify(() => list.count === 13, 2000)
            tryVerify(() => list.activeFocus, 2000, "the list has the focus")
            compare(list.currentIndex, 0)
            compare(find("sourcesDrive").text.indexOf("STICK"), 0, "the drive's label heads its rows")
            compare(find("sourceName").text, "starhopper")
            compare(shown(), "accept Select|back Back")
            keyClick(Qt.Key_Down)
            compare(list.currentIndex, 1)
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "installPackage")
            compare(page().path, Play.mockPath("starhopper"))
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "installSources")
            tryVerify(() => find("sourcesList").activeFocus, 2000, "Back lands on the list")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
        }

        function test_sources_for_one_drive_and_empty_state() {
            start("admin")
            tc.shell.openPage("installSources", { drive: "vol-other" })
            tryCompare(tc.shell, "currentPage", "installSources")
            tryVerify(() => find("sourcesEmpty").visible, 2000, "no packages on that drive")
            verify(!find("sourcesList").visible)
            compare(shown(), "back Back", "nothing to select")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            // The same page with no drive plugged in, then SourcesChanged brings the packages.
            Play.mockSetDriveMounted(false)
            tc.shell.openPage("installSources", {})
            tryCompare(tc.shell, "currentPage", "installSources")
            tryVerify(() => find("sourcesEmpty").visible, 2000)
            compare(find("sourcesEmptyHelp").text, "Copy a .play folder, or a .zip of one, to a USB drive, then plug it in.")
            Play.mockSetDriveMounted(true)
            tryVerify(() => find("sourcesList").visible && find("sourcesList").count === 13, 2000, "the list fills in")
            tryVerify(() => find("sourcesList").activeFocus, 2000, "and takes the focus")
        }

        function test_entry_points() {
            start("admin")
            tc.shell.openPage("store")
            tryCompare(tc.shell, "currentPage", "store")
            tryVerify(() => find("storeInstallUsb") && find("storeInstallUsb").visible, 2000)
            compare(find("storeInstallUsb").kind, "page")
            find("storeShowAll").forceActiveFocus()
            keyClick(Qt.Key_Right)
            verify(find("storeInstallUsb").activeFocus, "Right from Show all apps")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "installSources")
            compare(find("page_installSources").drive, "", "from the Store: every drive")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "store")
            tryVerify(() => find("storeInstallUsb").activeFocus, 2000, "Back lands on the Store's entry")
            // The closed page is destroyed after its exit animation; until then find() can return it in
            // place of the next one (lead-30: 1 in 4 runs failed "only that drive" on the old page).
            tryVerify(() => find("page_installSources") === null, 2000, "the Store's Install from USB page is gone")
            tc.shell.closePage()
            // Settings -> Storage: a row per mounted removable drive.
            Storage.mockReset()
            Storage.mockPlugStick()
            tryVerify(() => Storage.volumes.some(v => v.id === "vol-stick"), 2000)
            tc.shell.openPage("settings", { category: "storage" })
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("paneStorage") !== null && find("paneStorage").visible, 3000, "the Storage pane is shown: " + find("page_settings").params.category)
            tryVerify(() => find("storagePackages_vol-stick") !== null, 3000, "Packages on this drive: " + find("paneStorage").focusableRows().map(r => r.objectName))
            compare(find("storagePackages_vol-stick").label, "Packages on this drive")
            verify(find("storagePackages_vol-internal") === null, "not the console's own disk")
            find("storagePackages_vol-stick").forceActiveFocus()
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "installSources")
            compare(find("page_installSources").drive, "vol-stick", "only that drive")
            tryVerify(() => find("sourcesList").count === 13, 2000)
        }

        // ---- The package page ----

        function test_each_fixture_shows_its_badge_and_permission_words() {
            start("admin")
            const cases = [
                { fixture: "starhopper", badge: "Developer", kind: "warning", words: {
                    "input:controllers+keyboard-mouse": "Uses controllers, keyboard and mouse",
                    "network": "Uses the network", "removable_media:read": "Reads files on USB drives",
                    "multiarch": "Runs 32-bit programs", "gamemode": "Asks the system to prioritise it" } },
                { fixture: "pixelforest.play.zip", badge: "Official", kind: "success", words: { "input:controllers": "Uses controllers" } },
                { fixture: "homebrew", badge: "Unverified", kind: "error", words: {} },
                { fixture: "tampered", badge: "Changed since signed", kind: "error", words: {} },
                { fixture: "oldbad", badge: "Removed for safety", kind: "error", words: { "network": "Uses the network" } },
                { fixture: "rawaccess.play.zip", badge: "Developer", kind: "warning", words: {
                    "input:all-devices": "Accesses all devices", "devel": "Can inspect other programs" } }
            ]
            for (const c of cases) {
                openPackage(c.fixture)
                const badge = find("installTrustBadge")
                compare(badge.text, c.badge, c.fixture)
                compare(badge.kind, c.kind, c.fixture)
                verify(badge.solid, "a trust badge is always solid, " + c.fixture)
                verify(findChild(find("installPermissionList"), "permission_always") !== null, "every game plays sound and uses graphics, " + c.fixture)
                for (const key of Object.keys(c.words)) {
                    const row = findChild(find("installPermissionList"), "permission_" + key)
                    verify(row !== null, c.fixture + " lists " + key)
                    compare(findChild(row, "permissionWords").text, c.words[key], c.fixture + " " + key)
                }
                closePackage()
            }
            openPackage("rawaccess.play.zip")
            verify(findChild(find("installPermissionList"), "riskFlag_devel").visible, "a high-risk permission carries the flag")
            verify(!findChild(find("installPermissionList"), "riskFlag_network").visible)
        }

        function test_the_trust_row_opens_the_signer_sheet() {
            start("admin")
            openPackage("starhopper")
            verify(find("installButton").activeFocus, "Install has the focus on entry")
            keyClick(Qt.Key_Up)
            verify(find("installTrustRow").activeFocus, "the trust row is above Install")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installSigner").shown, 2000)
            compare(shown(), "back Close")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("installSigner").shown, 2000)
            tryVerify(() => find("installTrustRow").activeFocus, 2000, "Back returns to the trust row")
            // A changed package has no signer to show: the row is not a stop.
            closePackage()
            openPackage("tampered")
            verify(!find("installTrustRow").activeFocus)
            keyClick(Qt.Key_Up)
            verify(find("installButton").activeFocus, "nothing above Install to go to")
        }

        function test_the_corrupted_package_says_how_to_fix_it() {
            start("admin")
            openPackage("broken")
            verify(find("installButton").dimmed, "Install is dimmed")
            verify(find("installBlocked").visible)
            compare(find("installBlocked").text, "This package is damaged or incomplete. Copy it to the USB drive again.")
            keyClick(Qt.Key_Return)
            verify(!find("installConfirm").shown, "Accept on a dimmed Install opens nothing")
            verify(find("installButton").activeFocus)
            closePackage()
            openPackage("tampered")
            compare(find("installBlocked").text, "It can't be installed. Get a fresh copy from the developer.")
            closePackage()
            openPackage("oldbad")
            verify(find("installButton").dimmed)
            compare(find("installBlocked").text, "This game was removed for safety and can't be installed.")
            closePackage()
            openPackage("future")
            compare(find("installBlocked").text, "This game needs a newer RuyaOS. Update the system, then try again.")
        }

        function test_a_package_above_its_ceiling_is_not_called_damaged() {
            start("admin")
            openPackage("rawunverified")
            verify(find("installButton").dimmed, "Install is dimmed")
            compare(find("installBlocked").text,
                    "This game is not signed, so it may not have this permission: Can inspect other programs. Ask the developer for a signed version.")
            closePackage()
            openPackage("broken")
            compare(find("installBlocked").text, "This package is damaged or incomplete. Copy it to the USB drive again.")
        }

        function test_the_unverified_package_is_blocked_until_developer_mode_is_on() {
            start("admin")
            openPackage("homebrew")
            verify(find("installButton").dimmed)
            compare(find("installBlocked").text, "Unsigned packages need developer mode. An admin can turn it on in Settings.")
            keyClick(Qt.Key_Return)
            verify(!find("installConfirm").shown)
            Play.mockSetDeveloperMode(true)
            tryVerify(() => !find("installButton").dimmed, 3000, "developer mode makes it installable")
            verify(!find("installBlocked").visible)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            compare(find("installConfirmBadge").text, "Unverified", "the red badge shows on the confirm sheet too")
            compare(find("installConfirmBadge").kind, "error")
        }

        // ---- Confirm, the admin's PIN ----

        function test_a_standard_profile_asks_for_an_admins_pin_when_a_permission_is_high_risk() {
            start("ada")
            openPackage("rawaccess.play.zip")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            tryVerify(() => find("installConfirmInstall").activeFocus, 2000, "Install has the focus")
            compare(shown(), "accept Select|back Cancel")
            compare(find("installConfirmPin").text, "A high-risk permission needs an admin's PIN.")
            compare(find("installConfirmTitle").text, "Install Raw Access?")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installPinPad").shown, 2000, "the admin's PIN pad")
            tryVerify(() => find("installPinPad").activeFocus, 2000)
            enterPin("0000")
            tryVerify(() => findChild(find("installPinPad"), "pinMessage").text.indexOf("Wrong PIN") === 0, 2000,
                      "a wrong PIN shows the pad's message")
            verify(find("installPinPad").shown, "the pad stays for another try")
            compare(Object.keys(Play.jobs).length, 0)
            verify(!page().working, "nothing was installed")
            enterPin("1234")
            tryVerify(() => page().working, 3000, "the right PIN starts the job")
            tryVerify(() => !find("installPinPad").shown, 2000)
        }

        function test_back_from_the_pin_pad_cancels_and_focus_returns_to_install() {
            start("ada")
            openPackage("rawaccess.play.zip")
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installPinPad").shown, 2000)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("installPinPad").shown, 2000)
            tryVerify(() => find("installButton").activeFocus, 2000, "back on Install")
            verify(!page().working)
        }

        function test_an_admin_needs_no_pin_and_a_standard_profile_asks_even_for_low_risk() {
            start("admin")
            openPackage("rawaccess.play.zip")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            verify(!find("installConfirmPin").visible, "an admin is not warned")
            keyClick(Qt.Key_Return)
            tryVerify(() => page().working, 3000, "the install starts at once")
            verify(!find("installPinPad").shown)
            Play.mockPauseJobs(false)
            tryVerify(() => !page().working, 10000)
            closePackage()
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell.destroy()
            start("ada")
            openPackage("pixelforest.play.zip")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            compare(find("installConfirmPin").text, "An admin's PIN is needed to install this app.",
                    "only an admin installs from USB (05 §18 item 4), so a Standard profile always enters the PIN")
        }

        function test_the_confirm_sheet_says_what_is_installed() {
            start("admin")
            openPackage("starhopper")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            compare(find("installConfirmBadge").text, "Developer")
            compare(find("installConfirmSigner").text, "Example Games · key 3f9a…f312")
            verify(find("installConfirmNeeds").text.indexOf("Needs 5 GB · ") === 0, find("installConfirmNeeds").text)
            // Up to four permission rows, then "And n more".
            const more = findChild(find("installConfirmPermissions"), "permissionMore")
            tryVerify(() => more.visible, 2000)
            compare(more.text, "And 3 more", "the always row, five requests and the high-risk pair (RUY-864) make seven rows")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("installConfirm").shown, 2000)
            tryVerify(() => find("installButton").activeFocus, 2000, "Cancel returns to Install")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            keyClick(Qt.Key_Right)
            verify(find("installConfirmCancel").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => !find("installConfirm").shown, 2000)
            verify(!page().working, "Cancel installs nothing")
        }

        // ---- Progress and the result ----

        function test_install_runs_to_the_result() {
            start("admin")
            openPackage("starhopper")
            Play.mockPauseAtPercent(30)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => page().working, 3000)
            tryVerify(() => find("installCancel").visible && find("installCancel").activeFocus, 3000, "Cancel has the focus")
            tryVerify(() => Play.jobs[Play.mockPath("starhopper")] !== undefined && Play.jobs[Play.mockPath("starhopper")].percent >= 30, 5000)
            compare(shown(), "accept Cancel|back Back")
            verify(find("installProgress").visible)
            verify(find("installPhase").text.indexOf("Checking the signature · ") === 0, find("installPhase").text)
            verify(!find("installButton").visible)
            Play.mockPauseJobs(false)
            // From committing on there is no Cancel and the line says Installing.
            tryVerify(() => find("installPhase").text.indexOf("Installing · ") === 0, 8000)
            verify(!find("installCancel").visible, "no Cancel from committing on")
            tryVerify(() => !page().working, 10000, "the job finished")
            tryVerify(() => find("installInstalledBadge").visible, 3000, "the page shows Installed")
            tryVerify(() => find("installPlay").visible && find("installPlay").activeFocus, 3000, "and Play, focused")
            verify(toastTexts().indexOf("Installed: Star Hopper") >= 0, "a success toast with the name: " + toastTexts())
        }

        function test_the_list_gives_the_focus_to_the_next_package_after_an_install() {
            start("admin")
            tc.shell.openPage("installSources", {})
            tryCompare(tc.shell, "currentPage", "installSources")
            tryVerify(() => find("sourcesList").activeFocus, 2000)
            keyClick(Qt.Key_Return)                     // starhopper
            tryCompare(tc.shell, "currentPage", "installPackage")
            tryVerify(() => page().info !== null, 3000)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => page().working, 3000)
            tryVerify(() => find("installInstalledBadge").visible, 15000, "installed")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "installSources")
            tryVerify(() => find("sourcesList").activeFocus, 2000)
            compare(find("sourcesList").currentIndex, 1, "the focus is on the next package")
        }

        function test_leaving_the_page_mid_install_keeps_the_job() {
            start("admin")
            openPackage("starhopper")
            const key = Play.mockPath("starhopper")
            Play.mockPauseAtPercent(30)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => Play.jobs[key] !== undefined && Play.jobs[key].percent >= 30, 5000)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("page_installPackage") === null, 5000, "the old page is gone")
            verify(Play.jobs[key] !== undefined, "closing the page does not cancel")
            // Back on the page the progress is there at once.
            openPackage("starhopper")
            tryVerify(() => page().working, 2000)
            verify(find("installProgress").visible)
            Play.mockPauseJobs(false)
            tryVerify(() => !page().working, 10000)
            tryVerify(() => find("installInstalledBadge").visible, 3000)
        }

        function test_cancel_is_explicit() {
            start("admin")
            openPackage("starhopper")
            Play.mockPauseAtPercent(30)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installCancel").visible && find("installCancel").activeFocus, 5000)
            keyClick(Qt.Key_Return)
            tryVerify(() => !page().working, 5000, "the job ended")
            verify(toastTexts().indexOf("Install cancelled") >= 0, "an info toast: " + toastTexts())
            tryVerify(() => find("installButton").visible && find("installButton").activeFocus, 3000, "Install is back, focused")
            verify(!find("installInstalledBadge").visible)
        }

        function test_a_failed_install_shows_its_sentence_in_a_dialog() {
            const cases = [
                { fixture: "flaky", text: "The install didn't finish. Try again." },
                { fixture: "hugegame.play.zip", text: "There isn't enough space. Free 60.0 GB, then try again." }
            ]
            start("admin")
            for (const c of cases) {
                openPackage(c.fixture)
                keyClick(Qt.Key_Return)
                tryVerify(() => find("installConfirm").shown, 2000, c.fixture)
                keyClick(Qt.Key_Return)
                tryVerify(() => find("installResult").shown, 15000, c.fixture + " ends in the dialog")
                tryVerify(() => find("installResultOk").activeFocus, 2000)
                compare(find("installResultTitle").text, "Not installed")
                verify(find("installResultSentence").text.indexOf(c.text.slice(0, 18)) === 0, find("installResultSentence").text)
                compare(shown(), "accept OK")
                keyClick(Qt.Key_Return)
                tryVerify(() => !find("installResult").shown, 2000)
                tryVerify(() => find("installButton").activeFocus, 3000, "OK returns to Install")
                verify(!find("installInstalledBadge").visible)
                closePackage()
            }
        }

        function test_install_statuses_have_their_own_sentences() {
            start("admin")
            const expected = {
                "invalid-package": "This package is damaged or incomplete. Copy it to the USB drive again.",
                "bad-signature": "This package was changed after it was signed. Get a fresh copy from the developer.",
                "different-developer": "This isn't the same developer as the installed game. An admin can forget this game's data and key in Options.",
                "needs-developer-mode": "Unsigned packages need developer mode. An admin can turn it on in Settings.",
                "revoked": "This game was removed for safety and can't be installed.",
                "unsupported": "This game needs a newer RuyaOS. Update the system, then try again.",
                "failed": "The install didn't finish. Try again."
            }
            for (const status of Object.keys(expected))
                compare(PlayCopy.jobStatusText(status, ""), expected[status], status)
            compare(PlayCopy.jobStatusText("disk-full", "2.0 GB"), "There isn't enough space. Free 2.0 GB, then try again.")
            const methods = {
                "forbidden": "Only an admin can install from USB.",
                "busy": "Another install is running. Try again when it ends.",
                "unknown-source": "The USB drive was removed. Plug it in, then try again.",
                "too-late": "It's too late to cancel. The install is finishing.",
                "invalid": "Something went wrong. Try again."
            }
            for (const status of Object.keys(methods))
                compare(PlayCopy.methodStatusText(status), methods[status], status)
        }

        function test_a_refused_install_is_an_error_toast() {
            start("admin")
            openPackage("starhopper")
            Play.mockFailNext()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().indexOf("Something went wrong. Try again.") >= 0, 3000)
            verify(!page().working, "the page is not left working")
            tryVerify(() => find("installButton").activeFocus, 3000)
        }

        // ---- Developer mode ----

        function test_developer_mode_is_an_admins_switch_in_settings_and_off_by_default() {
            start("ada")
            tc.shell.openPage("settings", { category: "system" })
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("rowTimezone") !== null, 3000)
            verify(!find("rowDeveloperMode").visible, "a Standard profile does not see it")
            verify(!find("developerModeNote").visible)
        }

        function test_developer_mode_switch_for_an_admin() {
            start("admin")
            tc.shell.openPage("settings", { category: "system" })
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("rowDeveloperMode") !== null && find("rowDeveloperMode").visible, 3000)
            compare(Play.developerMode, false, "off by default")
            compare(find("rowDeveloperMode").checked, false)
            compare(find("rowDeveloperMode").label, "Developer mode")
            compare(find("developerModeNote").text, "Allows unsigned packages. Only turn it on for games you trust.")
            find("rowDeveloperMode").forceActiveFocus()
            keyClick(Qt.Key_Return)
            tryCompare(Play, "developerMode", true)
            tryCompare(find("rowDeveloperMode"), "checked", true)
            keyClick(Qt.Key_Return)
            tryCompare(Play, "developerMode", false)
            tryCompare(find("rowDeveloperMode"), "checked", false)
            // The service refuses a change that does not carry an admin's approval.
            host.devAnswer = ""
            Play.setDeveloperMode(true, false)
            tryCompare(host, "devAnswer", "forbidden")
            compare(Play.developerMode, false, "and nothing changed")
        }

        function test_the_unverified_game_installs_once_developer_mode_is_on() {
            start("admin")
            Play.setDeveloperMode(true, true)
            tryCompare(Play, "developerMode", true)
            openPackage("homebrew")
            verify(!find("installButton").dimmed)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installInstalledBadge").visible, 15000, "the unsigned game installed")
            compare(find("installTrustBadge").text, "Unverified", "and keeps its red badge")
        }

        // ---- Hints of every screen ----

        function test_hints() {
            start("admin")
            tc.shell.openPage("installSources", {})
            tryCompare(tc.shell, "currentPage", "installSources")
            tryVerify(() => find("sourcesList").activeFocus, 2000)
            compare(shown(), "accept Select|back Back", "sources")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "installPackage")
            tryVerify(() => find("installButton").activeFocus, 3000)
            compare(shown(), "accept Select|back Back", "package page")
            keyClick(Qt.Key_Down)                              // the permissions block (no screenshots row on the mock)
            for (let i = 0; i < 6 && shown() !== "back Back"; ++i)
                keyClick(Qt.Key_Down)
            compare(shown(), "back Back", "a block that only reads")
            for (let i = 0; i < 8 && !find("installButton").activeFocus; ++i)
                keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            compare(shown(), "accept Select|back Cancel", "confirm sheet")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("installConfirm").shown, 2000)
            // Escape from every screen leaves it: the page, then the list, then the Store/Home.
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "installSources")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
        }

        // ---- RUY-809: after the page, Back-only hints, a revoked installed game, no ruya-play ----

        // Starts an install, lets it reach `percent` and leaves the page; the job goes on.
        function installAndLeave(fixture, percent) {
            openPackage(fixture)
            Play.mockPauseAtPercent(percent)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            keyClick(Qt.Key_Return)
            const key = Play.mockPath(fixture)
            tryVerify(() => Play.jobs[key] !== undefined && Play.jobs[key].percent >= percent, 5000)
            closePackage()
            return key
        }

        function test_an_install_that_ends_after_the_page_closed_gives_a_toast() {
            start("admin")
            const key = installAndLeave("starhopper", 30)
            compare(toastTexts().length, 0, "nothing yet")
            Play.mockPauseJobs(false)
            tryVerify(() => toastTexts().length > 0, 15000)
            compare(toastTexts(), ["Installed: Star Hopper"])
            wait(300)
            compare(toastTexts().length, 1, "one toast")
            verify(Play.jobs[key] === undefined)
        }

        function test_a_failed_install_after_the_page_closed_gives_an_error_toast_with_the_sentence() {
            start("admin")
            installAndLeave("flaky", 30)
            Play.mockPauseJobs(false)
            tryVerify(() => toastTexts().length > 0, 15000)
            compare(toastTexts(), ["Not installed: The install didn't finish. Try again."])
            compare(Notifications.model.get(0).kind, "error")
        }

        function test_a_cancelled_install_after_the_page_closed_gives_no_toast() {
            start("admin")
            const key = installAndLeave("starhopper", 30)
            Play.cancel(key)
            Play.mockPauseJobs(false)
            tryVerify(() => Play.jobs[key] === undefined, 5000)
            wait(300)
            compare(toastTexts().length, 0)
        }

        function test_an_install_that_ends_with_the_page_open_gives_no_second_toast() {
            start("admin")
            openPackage("flaky")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installResult").shown, 15000)
            wait(300)
            compare(toastTexts().length, 0, "the page shows a dialog, the Shell stays quiet")
            keyClick(Qt.Key_Return)
            closePackage()
            openPackage("starhopper")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installInstalledBadge").visible, 15000)
            wait(300)
            compare(toastTexts(), ["Installed: Star Hopper"])
        }

        function test_hints_are_back_only_while_install_is_dimmed_or_past_cancel() {
            start("admin")
            openPackage("homebrew")                  // needs developer mode: Install is dimmed
            verify(find("installButton").dimmed)
            verify(find("installButton").activeFocus)
            compare(shown(), "back Back", "dimmed Install")
            closePackage()
            openPackage("tampered")
            compare(shown(), "back Back", "dimmed Install (changed)")
            closePackage()
            openPackage("starhopper")
            compare(shown(), "accept Select|back Back", "Install works")
            closePackage()
            // Past committing the job has no Cancel.
            installAndLeave("starhopper", 60)
            tc.shell.openPage("installPackage", { path: Play.mockPath("starhopper") })
            tryCompare(tc.shell, "currentPage", "installPackage")
            tryVerify(() => page().info !== null, 3000, "Inspect answered")
            tryCompare(page(), "mode", "busy")
            verify(!find("installCancel").visible)
            // The focus may not have settled on a stop yet: then (and on any stop that only reads) it is Back only.
            if (!find("installTrustRow").activeFocus)
                compare(shown(), "back Back", "no Cancel from committing on")
            find("installTrustRow").forceActiveFocus()
            compare(shown(), "accept Select|back Back", "the trust row opens the signer sheet")
            find("installPermissions").forceActiveFocus()
            compare(shown(), "back Back", "past Cancel, nothing to select")
            Play.mockPauseJobs(false)
        }

        function test_an_installed_game_that_was_revoked_offers_remove_not_play() {
            start("admin")
            Play.mockSetInstalled("com.example.oldbad", 7)
            openPackage("oldbad")
            tryCompare(page(), "mode", "remove")
            verify(find("installRemove").visible)
            verify(!find("installPlay").visible)
            verify(!find("installButton").visible)
            verify(find("installRemove").activeFocus, "Remove is the main button")
            verify(find("installBlocked").visible)
            compare(find("installBlocked").text, "It won't start. You can still remove it.")
            compare(shown(), "accept Select|back Back")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("uninstallConfirm").shown, 2000, "Remove opens the Uninstall dialog")
            compare(find("uninstallConfirm").appId, "play.com.example.oldbad")
            keyClick(Qt.Key_Escape)
            // Not installed: the page is as before (Install dimmed with the reason).
            closePackage()
            Play.mockSetInstalled("com.example.oldbad", 0)
            openPackage("oldbad")
            verify(find("installButton").visible && !find("installRemove").visible)
        }

        // ---- Removing an installed game (RUY-816) ----

        // Pick Uninstall in the open dialog: Cancel has the focus, Right reaches the danger pill.
        function confirmUninstall() {
            tryVerify(() => find("uninstallConfirm").shown, 2000, "the Uninstall dialog")
            tryVerify(() => find("uninstallCancel").activeFocus, 2000, "it starts on Cancel")
            keyClick(Qt.Key_Right)
            verify(find("uninstallGo").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => !find("uninstallConfirm").shown, 2000)
        }

        function test_removing_an_installed_game_asks_play_and_the_page_inspects_again() {
            start("admin")
            Play.mockSetInstalled("com.example.oldbad", 7)
            openPackage("oldbad")
            tryCompare(page(), "mode", "remove")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("uninstallConfirm").shown, 2000)
            tryVerify(() => find("uninstallLine").visible, 2000, "the card is drawn")
            verify(!find("uninstallDeleteData").visible, "Play keeps the saved data: no toggle")
            compare(find("uninstallLine").text, "Saved data stays on this console.")
            keyClick(Qt.Key_Up)
            verify(find("uninstallCancel").activeFocus, "Up has nowhere to go without the toggle")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Up)
            verify(find("uninstallGo").activeFocus, "nor from the danger pill")
            keyClick(Qt.Key_Return)
            tryVerify(() => !find("uninstallConfirm").shown, 2000)
            tryVerify(() => host.removeAnswers.length === 1, 2000)
            compare(host.removeAnswers[0], { key: "play.com.example.oldbad", status: "ok" })
            // The job ends; the page asks Inspect again: no Remove, no "won't start" line, Install is back.
            tryCompare(page(), "mode", "install", 15000)
            verify(!find("installRemove").visible)
            verify(find("installButton").visible)
            tryVerify(() => page().mainButton() !== null && page().mainButton().activeFocus, 3000, "the focus is on the page's main button")
            const ended = host.finishedJobs.filter(j => j.kind === "remove")
            compare(ended.length, 1)
            compare(ended[0].status, "ok")
            tryVerify(() => toastTexts().length > 0, 2000)
            compare(toastTexts(), ["Old Bad Game was uninstalled."], "the Shell's removal toast, and no Installed")
            compare(Play.jobs["play.com.example.oldbad"], undefined)
        }

        function test_a_failed_removal_keeps_the_page_as_it_was() {
            start("admin")
            Play.mockSetInstalled("com.example.oldbad", 7)
            openPackage("oldbad")
            tryCompare(page(), "mode", "remove")
            keyClick(Qt.Key_Return)
            Play.mockFailNext()
            confirmUninstall()
            tryVerify(() => host.removeAnswers.length === 1, 2000)
            compare(host.removeAnswers[0].status, "failed")
            wait(300)
            compare(page().mode, "remove", "still installed")
            verify(find("installRemove").visible)
        }

        function test_the_dialog_asks_play_for_a_play_app_and_the_store_for_any_other() {
            start("admin")
            const dialog = find("uninstallConfirm")
            verify(!Play.isPlayApp("org.example.Puzzle"))
            verify(!Play.isPlayApp("play."), "no id")
            verify(Play.isPlayApp("play.com.example.oldbad"))
            // A Flatpak of the Store.
            dialog.open("org.example.Puzzle", "Block Puzzle")
            tryVerify(() => find("uninstallDeleteData").visible, 2000, "the Store's toggle")
            compare(dialog.keepsData, false)
            tryVerify(() => find("uninstallCancel").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryVerify(() => !dialog.shown, 2000)
            wait(300)
            compare(host.removeAnswers.length, 0, "Play was not asked")
            // A .play app, from a card's options (Home), with the Shell's own context.
            Play.mockSetInstalled("com.example.oldbad", 7)
            dialog.open("play.com.example.oldbad", "Old Bad Game", { itemId: "none", surface: "hero", title: "Old Bad Game", index: 0 })
            compare(dialog.keepsData, true)
            confirmUninstall()
            tryVerify(() => host.removeAnswers.length === 1, 2000)
            compare(host.removeAnswers[0], { key: "play.com.example.oldbad", status: "ok" })
            tryVerify(() => host.finishedJobs.some(j => j.kind === "remove" && j.status === "ok"), 15000)
            tryVerify(() => toastTexts().indexOf("Old Bad Game was uninstalled.") >= 0, 2000)
        }

        function test_a_verify_job_does_not_toast_installed() {
            start("admin")
            Play.mockSetInstalled("com.example.oldbad", 7)
            Play.verify("play.com.example.oldbad")
            tryVerify(() => host.finishedJobs.some(j => j.kind === "verify"), 15000)
            compare(host.finishedJobs[0].kind, "verify")
            compare(host.finishedJobs[0].status, "ok")
            wait(300)
            compare(toastTexts().length, 0, "a verify has no toast of the Shell's")
        }

        function test_a_toast_after_a_shell_restart_carries_the_name_from_the_job_table() {
            start("admin")
            const key = installAndLeave("starhopper", 30)
            // The shell restarts mid-install: it knows nothing of the job but what the service's table says.
            tc.shell.playInspected = ({})
            Play.mockRestartShell()
            tryVerify(() => Play.jobs[key] !== undefined, 3000, "the table brings the running job back")
            Play.mockPauseJobs(false)
            tryVerify(() => toastTexts().length > 0, 15000)
            compare(toastTexts(), ["Installed: Star Hopper"])
            const ended = host.finishedJobs.filter(j => j.key === key)
            compare(ended[ended.length - 1].kind, "install")
            compare(ended[ended.length - 1].name, "Star Hopper")
        }

        function test_install_from_usb_is_hidden_without_ruya_play() {
            start("admin")
            tc.shell.openPage("store")
            tryCompare(tc.shell, "currentPage", "store")
            tryVerify(() => find("storeInstallUsb") && find("storeInstallUsb").visible, 2000)
            Storage.mockReset()
            Storage.mockPlugStick()
            Play.mockServiceLost()
            tryCompare(Play, "available", false)
            tryVerify(() => !find("storeInstallUsb").visible, 2000, "the Store's entry")
            tc.shell.closePage()
            tryCompare(tc.shell, "currentPage", "")
            tc.shell.openPage("settings", { category: "storage" })
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("paneStorage") !== null && find("paneStorage").visible, 3000)
            tryVerify(() => find("storageVol_vol-stick") !== null, 3000, "the drive is listed")
            verify(find("storagePackages_vol-stick") === null, "Settings -> Storage")
            Play.mockServiceRegained()
            tryCompare(Play, "available", true)
            tryVerify(() => find("storagePackages_vol-stick") !== null, 3000, "and it is back with the service")
        }

        // ---- Screenshots (dev.ps1 shots) ----

        function settle() { wait(300) }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            // A toast of an earlier step must not sit in the next picture (120-tr and 128 once showed "Installed").
            const clearToasts = () => {
                while (Notifications.model.count > 0)
                    Notifications.dismiss(Notifications.model.get(0).toastId)
                Notifications.pending = []
                Notifications.held = []
            }
            const shot = name => {
                clearToasts()
                wait(600)                       // the toast's fade-out (Theme.pageMs) ends before the picture
                clearToasts()
                tryCompare(Notifications.model, "count", 0)
                grabImage(tc.shell).save(shotsDir + "/" + name + ".png")
            }
            for (const lang of ["en", "tr"]) {
                DeviceSettings.language = lang
                Play.mockReset()
                clearToasts()
                start("admin")
                tc.shell.openPage("installSources", {})
                tryCompare(tc.shell, "currentPage", "installSources")
                tryVerify(() => find("sourcesList").count === 13, 2000)
                clearToasts()
                settle()
                shot("120-install-sources-" + lang)
                closePackage()

                openPackage("starhopper")
                settle()
                shot("121-install-package-wine-" + lang)
                keyClick(Qt.Key_Up)
                keyClick(Qt.Key_Return)
                tryVerify(() => find("installSigner").shown, 2000)
                settle()
                shot("122-install-signer-" + lang)
                keyClick(Qt.Key_Escape)
                tryVerify(() => !find("installSigner").shown, 2000)
                keyClick(Qt.Key_Down)
                keyClick(Qt.Key_Return)
                tryVerify(() => find("installConfirm").shown, 2000)
                settle()
                shot("123-install-confirm-" + lang)
                Play.mockPauseAtPercent(30)
                keyClick(Qt.Key_Return)
                tryVerify(() => find("installCancel").visible && find("installCancel").activeFocus, 5000)
                tryVerify(() => Play.jobs[Play.mockPath("starhopper")] !== undefined && Play.jobs[Play.mockPath("starhopper")].percent >= 30, 5000)
                settle()
                shot("124-install-progress-" + lang)
                Play.mockPauseJobs(false)
                tryVerify(() => find("installInstalledBadge").visible, 15000)
                settle()
                shot("125-install-done-" + lang)
                closePackage()

                openPackage("homebrew")
                settle()
                shot("126-install-package-unverified-" + lang)
                closePackage()

                openPackage("tampered")
                settle()
                shot("127-install-package-changed-" + lang)
                closePackage()

                openPackage("rawunverified")
                settle()
                shot("127b-install-package-refused-" + lang)
                closePackage()

                openPackage("flaky")
                keyClick(Qt.Key_Return)
                tryVerify(() => find("installConfirm").shown, 2000)
                keyClick(Qt.Key_Return)
                tryVerify(() => find("installResult").shown, 15000)
                clearToasts()
                settle()
                shot("128-install-failed-" + lang)
                keyClick(Qt.Key_Return)
                closePackage()

                // Past committing: no Cancel, the hint bar says Back only. A fresh mock: starhopper is installed by now.
                Play.mockReset()
                openPackage("starhopper")
                Play.mockPauseAtPercent(60)
                keyClick(Qt.Key_Return)
                tryVerify(() => find("installConfirm").shown, 2000)
                keyClick(Qt.Key_Return)
                tryVerify(() => Play.jobs[Play.mockPath("starhopper")] !== undefined && Play.jobs[Play.mockPath("starhopper")].percent >= 60, 5000)
                tryVerify(() => !find("installCancel").visible, 3000)
                // Off the trust row (Select opens the signer sheet) onto a block that only reads: Back is the one hint.
                for (let i = 0; i < 6 && shown().indexOf("accept") >= 0; ++i)
                    keyClick(Qt.Key_Down)
                verify(shown().indexOf("accept") < 0, "Back only: " + shown())
                settle()
                shot("130-install-busy-hint-" + lang)
                Play.mockPauseJobs(false)
                tryVerify(() => find("installInstalledBadge").visible, 15000)
                closePackage()

                // An installed game that was put on the block list: Remove and the line.
                Play.mockReset()
                Play.mockSetInstalled("com.example.oldbad", 7)
                openPackage("oldbad")
                clearToasts()
                settle()
                shot("131-install-revoked-installed-" + lang)
                // Remove: the Uninstall dialog of a .play app has no data toggle (Play keeps the saved data), and
                // the page after the job: Remove and its line are gone.
                keyClick(Qt.Key_Return)
                tryVerify(() => find("uninstallConfirm").shown && find("uninstallLine").visible, 2000)
                settle()
                shot("131a-uninstall-play-app-" + lang)
                keyClick(Qt.Key_Right)
                keyClick(Qt.Key_Return)
                tryCompare(page(), "mode", "install", 15000)
                tryVerify(() => page().mainButton() !== null && page().mainButton().activeFocus, 3000)
                clearToasts()
                settle()
                shot("131b-install-after-remove-" + lang)
                closePackage()

                // An update of an installed build that adds two high-risk requests (RUY-853): the page's line, then the sheet.
                Play.mockReset()
                Play.mockSetInstalled("com.example.rawaccess", 4)
                openPackage("rawaccess.play.zip")
                clearToasts()
                settle()
                shot("132-install-update-adds-" + lang)
                keyClick(Qt.Key_Return)
                tryVerify(() => find("installConfirm").shown, 2000)
                tryVerify(() => find("installConfirm").opacity === 1, 2000)
                settle()
                shot("133-install-update-confirm-" + lang)
                keyClick(Qt.Key_Escape)
                tryVerify(() => !find("installConfirm").shown, 2000)
                closePackage()

                Profiles.lock()
                tryCompare(Profiles, "activeProfile", "")
                tc.shell.destroy()
                Play.mockReset()            // the update shots above left rawaccess installed: 129 is a new package
                start("ada")
                openPackage("rawaccess.play.zip")
                keyClick(Qt.Key_Return)
                tryVerify(() => find("installConfirm").shown, 2000)
                settle()
                shot("129-install-confirm-pin-" + lang)
                Profiles.lock()
                tryCompare(Profiles, "activeProfile", "")
                tc.shell.destroy()
            }
            DeviceSettings.language = "en"
        }
    }
}
