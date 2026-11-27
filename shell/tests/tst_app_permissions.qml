import QtQuick
import QtTest
import RuyaShell

// App permissions (RUY-744, 02 §1.2, 03 §4.4): Settings -> Privacy lists the installed apps, each opening a
// page with a row per permission; an admin withdraws what the service can withdraw (switches), everyone else
// reads it (facts); Reset to the app's defaults; the game page's Permissions row opens the same page. Against
// the Store mock: Block Puzzle (sound, controllers), Open Chess (sound) and Text Editor (home folder, withdrawn
// from the start) are installed; Game Streamer (network, sound, controllers, all devices) is installed by the
// tests that need it. Signs in as Player One (admin, PIN 1234) unless a test says otherwise.
Item {
    id: host
    width: 1920
    height: 1080

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "AppPermissions"
        when: windowShown

        property Shell shell: null

        readonly property string stream: "org.example.Stream"
        readonly property string editor: "org.example.Editor"
        readonly property string puzzle: "org.example.Puzzle"
        // The .play game of the Library mock's "play" scenario (RUY-854): its Flatpak is play.<package id>.
        readonly property string hopper: "play.com.example.starhopper"

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            host.width = 1920
            host.height = 1080
            DeviceSettings.language = "en"
            Store.mockReset()
            Session.mockReset()
            tryVerify(() => Store.installed.length === 3)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has focus on start")
        }

        function cleanup() {
            Store.mockReset()
            Session.mockReset()
            Library.resetMockForTests("")
            Profiles.lock()
            DeviceSettings.language = "en"
        }

        function signIn(id, pin) {
            Profiles.switchTo(id, pin)
            tryCompare(Profiles, "activeProfile", id)
            tryVerify(() => find("homePlay").activeFocus, 2000, "home after the sign-in")
        }
        function signInAdmin() { signIn("p1", "1234") }

        function installStream() {
            Store.install(stream)
            tryVerify(() => Store.installed.some(a => a.id === tc.stream), 5000, "Game Streamer installed")
        }

        // Settings on Privacy, the focus in the pane.
        function openPane() {
            tc.shell.openPage("settings", { category: "privacy" })
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000)
            compare(find("page_settings").current.key, "privacy")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("panePrivacy").activeFocus, 2000, "the pane has the focus")
            return find("panePrivacy")
        }

        function appRow(id) { return find("rowPrivacyApp_" + id) }

        // From the Privacy pane, with the keys only, to an app's page; the focus on its first row.
        function openApp(id) {
            openPane()
            for (let i = 0; i < 8 && !appRow(id).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(appRow(id).activeFocus, "on the app's row")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appPermissions")
            compare(tc.shell.currentParams.appId, id)
            tryVerify(() => find("page_appPermissions").answered, 2000, "the permissions were read")
            return find("page_appPermissions")
        }

        function row(name) { return find(name) }
        function focusedName() {
            const f = Window.window ? Window.window.activeFocusItem : null
            return f ? f.objectName : ""
        }

        function test_privacy_is_a_category_after_notifications() {
            signInAdmin()
            tc.shell.openPage("settings", {})
            tryCompare(tc.shell, "currentPage", "settings")
            const keys = find("page_settings").categories.map(c => c.key)
            compare(keys.indexOf("privacy"), keys.indexOf("notifications") + 1, "after Notifications")
            compare(keys.indexOf("storage"), keys.indexOf("privacy") + 1, "before Storage")
            compare(find("page_settings").labelFor("privacy"), "Privacy")
        }

        function test_the_pane_lists_the_installed_apps_by_name() {
            signInAdmin()
            const pane = openPane()
            compare(pane.focusableRows().map(r => r.objectName),
                    ["rowPrivacyApp_org.example.Puzzle", "rowPrivacyApp_org.example.Chess", "rowPrivacyApp_org.example.Editor"])
            verify(appRow(puzzle).activeFocus, "the first app has the focus")
            compare(appRow(puzzle).label, "Block Puzzle")
            compare(appRow(puzzle).kind, "page")
            tryCompare(appRow(editor), "value", "1 withdrawn")
            compare(appRow(puzzle).value, "", "nothing withdrawn: no value")
            verify(!find("rowPrivacyNoApps").visible)
            // An app installed meanwhile joins the list, in its place by name.
            installStream()
            tryVerify(() => appRow(stream) !== null && appRow(stream).visible)
            compare(pane.focusableRows().map(r => r.label), ["Block Puzzle", "Game Streamer", "Open Chess", "Text Editor"])
            keyClick(Qt.Key_Left)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Left returns to the category list")
        }

        function test_an_admin_withdraws_the_network_and_the_row_says_when_it_applies() {
            signInAdmin()
            installStream()
            const page = openApp(stream)
            const network = row("permSwitch_network")
            tryVerify(() => network.activeFocus, 2000, "the first permission has the focus")
            verify(network.visible)
            verify(network.checked, "allowed")
            compare(network.label, "Uses the network")
            verify(!row("permFact_network").visible, "the switch, not the fact")
            verify(!row("permNote_network").visible, "nothing pending yet")
            compare(page.hints.map(h => h.action + " " + h.text), ["accept Toggle", "back Back"])

            keyClick(Qt.Key_Return)
            tryVerify(() => Store.permissions(tc.stream).withdrawn.indexOf("network") >= 0, 2000, "the service withdrew it")
            tryVerify(() => row("permNote_network").visible, 2000, "the note after the re-read")
            compare(row("permNote_network").text, "Takes effect next time you open it.")
            verify(!network.checked)
            verify(network.activeFocus, "the focus stays on the switch")
            tryCompare(page, "busyKey", "")

            // Back to how it was: nothing waits for the next start any more.
            keyClick(Qt.Key_Return)
            tryVerify(() => Store.permissions(tc.stream).withdrawn.length === 0, 2000)
            tryVerify(() => !row("permNote_network").visible)
            verify(network.checked)
        }

        function test_all_devices_keeps_the_controllers() {
            signInAdmin()
            installStream()
            openApp(stream)
            const devices = row("permSwitch_all-devices")
            verify(devices.visible)
            compare(devices.detail, "High risk")
            devices.forceActiveFocus()
            keyClick(Qt.Key_Return)
            tryVerify(() => Store.permissions(tc.stream).withdrawn.indexOf("all-devices") >= 0, 2000)
            verify(Store.permissions(tc.stream).effective.indexOf("gamepad") >= 0, "the controllers stay")
            verify(row("permFact_gamepad").visible)
            compare(row("permFact_gamepad").value, "Allowed")
            compare(row("permFact_gamepad").detail, "Always allowed: a console needs its controllers")
        }

        // The colour the detail line is drawn in.
        function detailColour(control) { return findChild(control, "detail").color }

        // 04 §5: a settings row carries no badge; its risk mark is the words "High risk" leading its detail, in
        // the detail's own colour (warningText misses 4.5:1 for a caption on glass and on focusFill).
        function test_a_risk_mark_is_the_words_leading_the_detail() {
            // A switch (an admin): "High risk" is its detail; the note says what stays.
            signInAdmin()
            installStream()
            openApp(stream)
            const devices = row("permSwitch_all-devices")
            compare(devices.detail, "High risk")
            verify(Qt.colorEqual(detailColour(devices), Theme.text), String(detailColour(devices)))
            compare(row("permNote_all-devices").text, "Controllers and graphics stay available.")
            compare(row("permSwitch_network").detail, "", "a key that is not high risk has no mark")
            verify(!row("permNote_network").visible, "and no note before a change")
            // A fact (not an admin): the words lead, the reason follows.
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            Store.install("org.example.Tools")
            tryVerify(() => Store.installed.some(a => a.id === "org.example.Tools"), 5000, "Dev Tools installed")
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            signIn("p2", "")
            openApp("org.example.Tools")
            const bus = row("permFact_session-bus")
            verify(bus.visible)
            compare(bus.detail, "High risk · Can't be withdrawn yet: apps break without it")
            verify(Qt.colorEqual(detailColour(bus), Theme.text), String(detailColour(bus)))
            compare(row("permFact_network").detail, "", "a key that is not high risk has no mark")
            // Back to the list (Dev Tools comes before Game Streamer), then to Game Streamer's page with the keys.
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => appRow("org.example.Tools").activeFocus, 2000)
            for (let i = 0; i < 8 && !appRow(tc.stream).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(appRow(tc.stream).activeFocus, "on Game Streamer's row")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appPermissions")
            tryVerify(() => find("page_appPermissions").answered && find("page_appPermissions").appId === tc.stream, 2000)
            const fact = row("permFact_all-devices")
            verify(fact.visible)
            compare(fact.detail, "High risk")
            verify(Qt.colorEqual(detailColour(fact), Theme.text), String(detailColour(fact)))
            verify(!row("permNote_all-devices").visible, "the switch's note goes with the switch")
        }

        function test_what_cannot_be_withdrawn_says_why() {
            signInAdmin()
            const page = openApp(puzzle)
            verify(!row("permSwitch_audio").visible)
            verify(!row("permSwitch_gamepad").visible)
            const audio = row("permFact_audio")
            verify(audio.visible)
            compare(audio.label, "Sound and microphone")
            compare(audio.value, "Allowed")
            compare(audio.detail, "Not controllable yet: sound and microphone share one connection")
            tryVerify(() => audio.activeFocus, 2000, "a fact takes the focus so its reason can be read")
            compare(page.hints.map(h => h.action), ["back"], "nothing to select")
            verify(!row("permReset").visible, "nothing withdrawn: no reset")
            verify(row("permServicesNote").visible)
            compare(row("permServicesNote").text, "Apps can't reach the console's own services.")
        }

        // RUY-1234: the page's model holds keys only and every text is a binding, so an open page follows a change of the
        // UI language: an admin's switch, its warning and Reset ...
        function test_an_open_page_follows_the_language_for_an_admin() {
            signInAdmin()
            openApp(editor)
            compare(row("permSwitch_home-files").label, "Reads and writes files in your home folder")
            compare(row("permNote_home-files").text, "The app may lose its saves or settings outside its own folder.")
            DeviceSettings.language = "tr"
            tryCompare(row("permSwitch_home-files"), "label", "Ana klasörünüzdeki dosyaları okur ve yazar")
            compare(row("permNote_home-files").text, "Uygulama, kendi klasörü dışındaki kayıtlarını veya ayarlarını kaybedebilir.")
            compare(row("permReset").label, "Uygulamanın varsayılanlarına sıfırla")
            compare(row("permServicesNote").text, "Uygulamalar konsolun kendi hizmetlerine erişemez.")
            verify(row("permSwitch_home-files").activeFocus, "focus stays on its row")
            DeviceSettings.language = "en"
            tryCompare(row("permSwitch_home-files"), "label", "Reads and writes files in your home folder")
            compare(row("permReset").label, "Reset to the app's defaults")
        }

        // ... and a Standard profile's fact rows, their reason and the admin note.
        function test_an_open_page_follows_the_language_for_a_standard_profile() {
            signIn("p2", "")
            openApp(puzzle)
            const audio = row("permFact_audio")
            compare(audio.value, "Allowed")
            compare(audio.detail, "Not controllable yet: sound and microphone share one connection")
            DeviceSettings.language = "tr"
            tryCompare(audio, "value", "İzin verildi")
            compare(audio.label, "Ses ve mikrofon")
            compare(audio.detail, "Henüz denetlenemiyor: ses ve mikrofon aynı bağlantıyı kullanıyor")
            compare(row("permAdminNote").text, "Bunları yalnızca bir yönetici değiştirebilir.")
            verify(audio.activeFocus, "focus stays on its row")
        }

        function test_reset_gives_everything_back() {
            signInAdmin()
            openApp(editor)
            const home = row("permSwitch_home-files")
            verify(home.visible)
            verify(!home.checked, "withdrawn from the start")
            compare(row("permNote_home-files").text, "The app may lose its saves or settings outside its own folder.",
                    "the warning, nothing pending")
            verify(row("permReset").visible)
            keyClick(Qt.Key_Down)
            verify(row("permReset").activeFocus, "Down reaches Reset")
            compare(row("permReset").label, "Reset to the app's defaults")
            keyClick(Qt.Key_Return)
            tryVerify(() => Store.permissions(tc.editor).withdrawn.length === 0, 2000, "the override is gone")
            tryVerify(() => !row("permReset").visible)
            tryVerify(() => home.activeFocus, 2000, "the focus goes to the row before Reset")
            verify(home.checked)
            compare(row("permNote_home-files").text,
                    "The app may lose its saves or settings outside its own folder. Takes effect next time you open it.")
        }

        function test_a_standard_profile_sees_everything_read_only() {
            signIn("p2", "")
            compare(Profiles.active.role, "standard")
            const page = openApp(editor)
            verify(!row("permSwitch_home-files").visible, "no switch")
            const fact = row("permFact_home-files")
            verify(fact.visible)
            compare(fact.value, "Withdrawn")
            tryVerify(() => fact.activeFocus, 2000)
            verify(!row("permReset").visible)
            verify(row("permAdminNote").visible)
            compare(row("permAdminNote").text, "Only an admin can change these.")
            // The service refuses the change itself, whatever a client tries.
            Store.mockPermissionsCallerAdmin(false)
            const spy = createTemporaryObject(spyComponent, tc, { target: Store, signalName: "permissionChanged" })
            Store.withdrawPermission(tc.editor, "home-files")
            tryCompare(spy, "count", 1)
            compare(spy.signalArguments[0][2], "forbidden")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => appRow(tc.editor).activeFocus, 2000, "Back returns to the app's row")
        }

        function test_a_refused_change_flips_the_switch_back() {
            signInAdmin()
            installStream()
            openApp(stream)
            Store.mockPermissionsCallerAdmin(false)    // the profile stopped being an admin on the service's side
            const network = row("permSwitch_network")
            tryVerify(() => network.activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => row("permError").visible, 2000)
            compare(row("permError").text, "Only an admin can change this.")
            tryVerify(() => network.checked, 2000, "back to what is true")
            verify(!row("permNote_network").visible)
        }

        function test_a_running_app_applies_after_a_restart() {
            signInAdmin()
            installStream()
            Session.launch(tc.stream, "p1")
            tryVerify(() => Session.running.some(r => r.appId === tc.stream), 2000)
            openApp(stream)
            tryVerify(() => row("permSwitch_network").activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => row("permNote_network").visible, 2000)
            compare(row("permNote_network").text, "Takes effect after the app is closed and opened again.")
        }

        function test_a_late_reply_does_not_undo_a_newer_one() {
            signInAdmin()
            installStream()
            const page = openApp(stream)
            // A slow read of the state before the change, then the change and its own (fast) read.
            Store.mockPermissionsDelayed(300)
            Store.loadPermissions(tc.stream)
            compare(Store.mockPendingPermissionReplies(), 1)
            tryVerify(() => row("permSwitch_network").activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => !row("permSwitch_network").checked && row("permNote_network").visible, 2000)
            tryVerify(() => Store.mockPendingPermissionReplies() === 0, 3000, "the slow reply has landed")
            verify(Store.permissions(tc.stream).withdrawn.indexOf("network") >= 0, "the old answer was dropped")
            verify(!row("permSwitch_network").checked)
            verify(row("permNote_network").visible)
        }

        // A .play game is a Flatpak of the system installation: the service lists it once it is asked (here after
        // the pane is shown, as `ruya-play` installs it behind the Store's back) and the list names it by its title.
        function installHopper() {
            Library.resetMockForTests("play")
            tryVerify(() => Library.item("flatpak:" + tc.hopper).play === true)
            Store.mockInstallOutside(tc.hopper, "starhopper", ["network", "audio", "gamepad"])
        }

        function test_a_play_game_is_in_the_list_under_its_title_and_an_admin_withdraws_its_network() {
            signInAdmin()
            installHopper()
            const pane = openPane()
            tryVerify(() => appRow(tc.hopper) !== null && appRow(tc.hopper).visible, 3000, "the game joined the list")
            compare(pane.focusableRows().map(r => r.label), ["Block Puzzle", "Open Chess", "Star Hopper", "Text Editor"])
            for (let i = 0; i < 8 && !appRow(tc.hopper).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(appRow(tc.hopper).activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appPermissions")
            const page = find("page_appPermissions")
            tryVerify(() => page.answered, 2000)
            compare(page.title, "Star Hopper")
            const network = row("permSwitch_network")
            tryVerify(() => network.activeFocus, 2000, "the first permission has the focus")
            verify(network.checked)
            keyClick(Qt.Key_Return)
            tryVerify(() => Store.permissions(tc.hopper).withdrawn.indexOf("network") >= 0, 2000, "withdrawn from the game")
            tryVerify(() => row("permNote_network").visible, 2000)
            compare(row("permNote_network").text, "Takes effect next time you open it.")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => appRow(tc.hopper).activeFocus, 2000, "Back returns to the game's row")
            compare(appRow(tc.hopper).value, "1 withdrawn")
        }

        // A pane that is not shown reads nothing, whatever the Library or the Store do meanwhile; a shown one reads
        // the counts of every app with one call, not one read per app (RUY-1190).
        function test_a_hidden_pane_asks_for_no_permissions() {
            signInAdmin()
            openPane()
            tryVerify(() => Store.mockWithdrawnCountReads() >= 1, 2000, "shown: the batch")
            wait(200)
            compare(Store.mockWithdrawnCountReads(), 1, "one batch for the visit")
            compare(Store.mockPermissionReads(), 0, "no read per app")
            keyClick(Qt.Key_Left)
            tryVerify(() => find("categoryList").activeFocus, 2000)
            keyClick(Qt.Key_Up)                            // Notifications: Privacy is hidden now
            tryCompare(find("page_settings").current, "key", "notifications")
            tryVerify(() => !find("panePrivacy").visible)
            wait(100)
            const before = Store.mockWithdrawnCountReads()
            installHopper()                                // a new app and a new Library item
            Store.refreshInstalled()
            tryVerify(() => Store.installed.some(a => a.id === tc.hopper))
            wait(300)
            compare(Store.mockWithdrawnCountReads(), before, "no call while hidden")
            keyClick(Qt.Key_Down)                          // Privacy again: every app, the new one too
            tryVerify(() => find("panePrivacy").visible)
            tryVerify(() => Store.mockWithdrawnCountReads() === before + 1, 2000, "shown again: one batch")
            wait(200)
            compare(Store.mockWithdrawnCountReads(), before + 1, "and no second one when the list grew")
            compare(Store.mockPermissionReads(), 0, "still no read per app")
        }

        // The page of an app opened right after the pane: the pane's one batch and the page's one read of its app.
        function test_an_app_page_opened_from_the_pane_costs_one_batch_and_one_read() {
            signInAdmin()
            openApp(puzzle)
            wait(300)
            compare(Store.mockWithdrawnCountReads(), 1, "one batch call in all")
            compare(Store.mockPermissionReads(), 1, "one GetPermissions, the page's own")
        }

        function test_the_row_counts_the_withdrawn_keys_of_each_app() {
            signInAdmin()
            installStream()
            Store.withdrawPermission(tc.stream, "network")
            tryVerify(() => (Store.permissions(tc.stream).withdrawn ?? []).indexOf("network") >= 0, 2000)
            Store.withdrawPermission(tc.stream, "all-devices")
            tryVerify(() => (Store.permissions(tc.stream).withdrawn ?? []).indexOf("all-devices") >= 0, 2000)
            openPane()
            tryCompare(appRow(stream), "value", "2 withdrawn")
            compare(appRow(editor).value, "1 withdrawn")
            compare(appRow(puzzle).value, "", "none withdrawn: no value")
        }

        // The batch asked first answers last: it must not undo what a newer one (and an app's own answer) said.
        function test_a_late_batch_reply_does_not_undo_a_newer_one() {
            signInAdmin()
            openPane()
            tryCompare(appRow(editor), "value", "1 withdrawn")
            Store.mockWithdrawnCountsDelayed(300)
            Store.loadWithdrawnCounts()                    // reads the editor's one withdrawn key, lands late
            compare(Store.mockPendingWithdrawnCountReplies(), 1)
            Store.resetPermissions(tc.editor)
            tryCompare(appRow(editor), "value", "")        // the app's own answer after the reset
            Store.loadWithdrawnCounts()                    // reads none, lands at once
            tryVerify(() => Store.mockPendingWithdrawnCountReplies() === 0, 3000, "the slow reply has landed")
            compare(Store.withdrawnCount(tc.editor), 0, "the old answer was dropped")
            compare(appRow(editor).value, "")
        }

        function test_the_play_game_page_has_the_permissions_row() {
            signInAdmin()
            installHopper()
            tc.shell.openPage("appDetail", { id: "flatpak:" + tc.hopper })
            tryCompare(tc.shell, "currentPage", "appDetail")
            const detail = find("page_appDetail")
            tryVerify(() => detail.isPlay, 2000)
            compare(detail.title, "Star Hopper")
            const perms = find("detailPermissionsRow")
            tryVerify(() => perms.visible, 2000, "no Store record needed")
            for (let i = 0; i < 20 && !perms.activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(perms.activeFocus, "Down reaches Permissions")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appPermissions")
            compare(tc.shell.currentParams.appId, tc.hopper)
            tryVerify(() => find("page_appPermissions").answered, 2000)
            tryVerify(() => row("permSwitch_network").activeFocus, 2000)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => perms.activeFocus, 2000, "Back returns to the Permissions row")
        }

        function test_a_standard_profile_reads_a_play_games_permissions_only() {
            signIn("p2", "")
            installHopper()
            Store.refreshInstalled()
            tryVerify(() => Store.installed.some(a => a.id === tc.hopper))
            tc.shell.openPage("appPermissions", { appId: tc.hopper })
            tryCompare(tc.shell, "currentPage", "appPermissions")
            tryVerify(() => find("page_appPermissions").answered, 2000)
            verify(row("permFact_network").visible)
            verify(!row("permSwitch_network").visible, "a fact, not a switch")
            compare(row("permFact_network").value, "Allowed")
        }

        function test_the_game_page_opens_the_same_page() {
            signInAdmin()
            tc.shell.openPage("appDetail", { appId: tc.editor })
            tryCompare(tc.shell, "currentPage", "appDetail")
            const detail = find("page_appDetail")
            tryVerify(() => detail.detailsReady, 2000)
            const perms = find("detailPermissionsRow")
            verify(perms.visible)
            compare(perms.label, "Permissions")
            compare(perms.kind, "page")
            for (let i = 0; i < 20 && !perms.activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(perms.activeFocus, "Down reaches Permissions")
            keyClick(Qt.Key_Down)
            verify(find("detailUninstall").activeFocus, "then Uninstall")
            keyClick(Qt.Key_Up)
            verify(perms.activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appPermissions")
            compare(tc.shell.currentParams.appId, tc.editor)
            tryVerify(() => row("permSwitch_home-files") !== null && row("permSwitch_home-files").activeFocus, 2000)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => perms.activeFocus, 2000, "Back returns to the Permissions row")
            compare(tc.shell.focusRepairs, 0)
        }

        function test_no_permissions_row_for_an_app_that_is_not_installed() {
            signInAdmin()
            tc.shell.openPage("appDetail", { appId: tc.stream })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("page_appDetail").detailsReady, 2000)
            verify(!find("detailPermissionsRow").visible)
        }

        function test_uninstall_drops_the_withdrawals() {
            signInAdmin()
            installStream()
            Store.withdrawPermission(tc.stream, "network")
            tryVerify(() => (Store.permissions(tc.stream).withdrawn ?? []).indexOf("network") >= 0, 2000)
            Store.uninstall(tc.stream, false)
            tryVerify(() => !Store.installed.some(a => a.id === tc.stream), 5000)
            installStream()
            Store.loadPermissions(tc.stream)
            tryVerify(() => Store.permissions(tc.stream).status === "ok"
                      && Store.permissions(tc.stream).withdrawn.length === 0, 2000, "installed again with its defaults")
        }

        Component {
            id: spyComponent
            SignalSpy {}
        }

        // ---- screenshots (dev.ps1 shots): the pane, an app with switches and one read-only, EN and TR ----
        function settle() {
            wait(600)
            grabImage(tc.shell)                          // the first grab lays the pane out
            wait(400)
        }

        function shots(dir, lang) {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.language = lang
            signInAdmin()
            installStream()
            openPane()
            settle()
            grabImage(tc.shell).save(dir + "privacy-pane-" + lang + ".png")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)                      // Game Streamer
            tryCompare(tc.shell, "currentPage", "appPermissions")
            tryVerify(() => row("permSwitch_network") !== null && row("permSwitch_network").activeFocus, 2000)
            keyClick(Qt.Key_Return)                      // withdraw the network: its note
            tryVerify(() => row("permNote_network").visible, 2000)
            settle()
            grabImage(tc.shell).save(dir + "app-permissions-admin-" + lang + ".png")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => appRow(tc.stream).activeFocus, 2000)
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Return)                      // Block Puzzle: only what stays
            tryCompare(tc.shell, "currentPage", "appPermissions")
            settle()
            grabImage(tc.shell).save(dir + "app-permissions-fixed-" + lang + ".png")
        }

        // The shots runner picks the functions that save to `shotsDir + "/` themselves (dev.ps1).
        function test_zz_screenshots() { shots(shotsDir + "/", "en") }
        function test_zz_screenshots_tr() { shots(shotsDir + "/", "tr") }

        // A .play game in the list and its permissions page (RUY-854).
        function test_zz_screenshots_play() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            signInAdmin()
            installHopper()
            openPane()
            tryVerify(() => appRow(tc.hopper) !== null && appRow(tc.hopper).visible, 3000)
            settle()
            grabImage(tc.shell).save(shotsDir + "/privacy-pane-play-en.png")
            for (let i = 0; i < 8 && !appRow(tc.hopper).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appPermissions")
            tryVerify(() => row("permSwitch_network") !== null && row("permSwitch_network").activeFocus, 2000)
            settle()
            grabImage(tc.shell).save(shotsDir + "/app-permissions-play-en.png")
            tc.shell.openPage("appDetail", { id: "flatpak:" + tc.hopper })
            tryCompare(tc.shell, "currentPage", "appDetail")
            const perms = find("detailPermissionsRow")
            tryVerify(() => perms.visible, 2000)
            for (let i = 0; i < 20 && !perms.activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(perms.activeFocus)
            settle()
            grabImage(tc.shell).save(shotsDir + "/game-page-play-permissions-en.png")
        }

        function test_zz_screenshots_read_only() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            signIn("p2", "")
            openApp(editor)
            settle()
            grabImage(tc.shell).save(shotsDir + "/app-permissions-read-only-en.png")
        }
    }
}
