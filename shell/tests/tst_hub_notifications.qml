import QtQuick
import QtTest
import RuyaShell

// The Hub's Notifications panel and Settings > Notifications (RUY-414, 02 §1.2/§1.6, T-245): the panel's
// rows and keys (focus lands on Quiet mode, A and Start on items, Clear all, See all opens the centre above
// the Hub over the frozen game, Back returns), quiet hours on a fake clock, the per-source switches, the
// settings rows (Show each for drives the toast time, Clear history asks first). Mock backends; signs in as
// Ada (p2); controller keys only. The fit of the panel at 720p and 1080p is in tst_quickmenu.
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
            Keys.onPressed: event => event.accepted = true
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: parent.height / 3; color: "darkgreen" }
            Rectangle { x: parent.width * 0.55; y: parent.height * 0.2; width: parent.width * 0.2; height: width; radius: width / 2; color: "gold" }
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }
    SignalSpy { id: settingSpy; target: NotificationCentre; signalName: "settingFinished" }

    TestCase {
        id: tc
        name: "HubNotifications"
        when: windowShown

        property Shell shell: null
        // 2026-11-13 15:00 UTC: a fixed day for the ages and the quiet hours.
        readonly property double t0: Date.UTC(2026, 10, 13, 15, 0, 0)

        function find(name) { return findChild(tc.shell, name) }
        function menu() { return find("systemPanel") }
        function sheet() { return find("notificationSheet") }
        function focusedKey() { return menu().currentKey }

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
            tryCompare(NotificationCentre, "profile", "p2")
            tryCompare(NotificationCentre, "loaded", true)
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.language = "en"
            DeviceSettings.pauseGamesInHub = true
            Library.resetMockForTests("")
            Session.mockReset()
            NotificationCentre.mockReset()
            NotificationCentre.mockSetNow(-1)
            TimeZone.mockSetNow(-1)
            tryCompare(NotificationCentre, "quiet", false)
            launchedSpy.clear()
            clearToasts()
        }

        function cleanup() {
            Notifications.appInFront = false
            Notifications.overlayOpen = false
            DeviceSettings.language = "en"
            NotificationCentre.mockReset()
            NotificationCentre.mockSetNow(-1)
            TimeZone.mockSetNow(-1)
            clearToasts()
        }

        function clearToasts() {
            const keys = Object.keys(Notifications.keyed)
            for (let i = 0; i < keys.length; ++i)
                Notifications.remove(keys[i])
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        // The toasts only: the keyed states (the pinned item) stay.
        function dropToasts() {
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function playRacer(component) {
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1 && Session.running[0].state === "running")
            const app = createTemporaryObject(component ?? appComponent, host)
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")
            return app
        }

        function openHub() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
            tryCompare(menu(), "settled", true)
        }

        // Down/Up (and Left/Right along a row) to a control of the Hub or the open panel.
        function goTo(key) {
            const m = menu()
            const list = find("systemActions")
            for (let i = 0; i < 30 && m.currentKey !== key; ++i) {
                const at = m.itemKeys.indexOf(m.rowKeyOf(key))
                keyClick(at > list.currentIndex ? Qt.Key_Down : at < list.currentIndex ? Qt.Key_Up
                         : m.columnOf(key) > m.currentColumn ? Qt.Key_Right : Qt.Key_Left)
            }
            compare(focusedKey(), key)
        }

        function openPanel() {
            goTo("panel:notifications")
            keyClick(Qt.Key_Return)
            tryCompare(menu(), "panelId", "notifications")
            tryCompare(menu(), "swap", 1)
        }

        function itemTitled(title) { return NotificationCentre.items.find(i => i.title === title) }
        function post(title, at, options, detail) {
            NotificationCentre.mockSetNow(at)
            Notifications.show(title, "info", "", "", detail ?? "", options ?? {})
            tryVerify(() => itemTitled(title) !== undefined, 2000, title + " is kept")
        }
        function hintText() {
            return find("hintBar").hints.map(h => (h.action ?? h.actions.join("_")) + " " + h.text).join(", ")
        }

        // The minute of the day `hhmm` in the console's zone, on the day of t0 (the zone is whatever the mock has).
        function clockAt(hhmm) {
            for (let m = 0; m < 1440; ++m) {
                const ms = tc.t0 - 12 * 3600000 + m * 60000
                if (TimeZone.formatClock(ms) === hhmm)
                    return ms
            }
            return -1
        }
        function setClock(hhmm) {
            const ms = clockAt(hhmm)
            verify(ms > 0, hhmm + " exists")
            NotificationCentre.mockSetNow(ms)
            TimeZone.mockSetNow(ms)
            tryCompare(Notifications, "clockNow", hhmm)
        }
        function setQuietHours(on, from, to) {
            NotificationCentre.setSetting("QuietHours", ({ enabled: on, from: from, to: to }))
            tryVerify(() => NotificationCentre.quietHours.enabled === on && NotificationCentre.quietHours.from === from, 2000)
        }

        // ---- the panel ----------------------------------------------------------------------------------

        function test_hub_panel_focus() {
            start()
            // Four items: a pinned one first, then the newest; one with an action (an app's), one plain.
            post("Old plain", tc.t0 - 3 * 60000)
            NotificationCentre.mockSetNow(tc.t0 - 2 * 60000)
            Notifications.showSticky("update-restart", "Restarting soon", "warning", "", "To finish the update", "", "",
                                     { source: "updates", pinned: true })
            NotificationCentre.mockSetNow(tc.t0 - 60000)
            NotificationCentre.mockAppNotify({ appId: "org.example.Game", title: "Match found", body: "Ready in 30 s", kind: "success",
                                               actions: [{ id: "accept", label: "Join" }, { id: "later", label: "Later" }] })
            post("Newest plain", tc.t0)
            tryCompare(NotificationCentre, "count", 4)
            dropToasts()
            playRacer()
            openHub()
            // Every Hub open shows the game as paused (the panel is opened over the frozen game).
            tryVerify(() => Session.running.length === 1 && Session.running[0].frozen === true, 2000, "the game is frozen")
            verify(find("hubIconDot_panel:notifications").visible, "unread items: the icon carries a dot")
            // A: the panel opens, the focus lands on Quiet mode.
            openPanel()
            compare(focusedKey(), "notifications:quiet", "focus lands on Quiet mode")
            verify(find("quickMenuItem_notifications:quiet").focused)
            compare(find("hubPanelTitle").text, "Notifications")
            const order = NotificationCentre.items.map(i => "notifications:n:" + i.id)
            compare(menu().itemKeys, ["notifications:quiet", ...order, "notifications:clear", "notifications:all"],
                    "Quiet mode, the items (pinned first), Clear all, See all")
            compare(NotificationCentre.items[0].title, "Restarting soon", "pinned first")
            compare(hintText(), "accept Toggle, back Back")
            // Quiet mode toggles by A.
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "quiet", true)
            compare(findChild(find("quickMenuItem_notifications:quiet"), "hubValueText").text, "On")
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "quiet", false)
            // Down to the pinned item: no Start (it cannot be cleared), A has nothing to run: the hint says only Back.
            keyClick(Qt.Key_Down)
            compare(focusedKey(), order[0])
            verify(find("quickMenuItem_" + order[0]).focused)
            compare(hintText(), "back Back", "a pinned item without an action: nothing to press")
            keyClick(Qt.Key_Menu)
            wait(50)
            compare(NotificationCentre.count, 4, "Start does not clear a pinned item")
            // The next item is the newest plain one: its detail carries the age; Start (the options button) clears it.
            keyClick(Qt.Key_Down)
            compare(focusedKey(), order[1])
            compare(find("quickMenuItem_" + order[1]).Accessible.name, "Newest plain, Just now")
            compare(hintText(), "accept Clear, options Clear, back Back")
            keyClick(Qt.Key_Menu)
            tryCompare(NotificationCentre, "count", 3)
            tryVerify(() => itemTitled("Newest plain") === undefined)
            compare(focusedKey(), order[2], "the focus stays in place: the next row took the cleared row's place")
            verify(find("quickMenuItem_" + order[2]).focused)
            // The app's item: A runs its first action (the item goes: Invoke), the age reads "1 min ago".
            compare(find("quickMenuItem_" + order[2]).Accessible.name, "Match found, 1 min ago · Ready in 30 s")
            compare(hintText(), "accept Join, options Clear, back Back")
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "count", 2)
            compare(NotificationCentre.mockCalls("invoke"), 1)
            tryVerify(() => itemTitled("Match found") === undefined)
            // The plain old one: A (no action, no app) clears it.
            tryVerify(() => focusedKey() === order[3], 2000, "the focus moves on to the old item")
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "count", 1)
            // Only the pinned one is left: Clear all is gone, the focus is on the row that took its place.
            tryVerify(() => menu().itemKeys.indexOf("notifications:clear") < 0, 2000, "nothing to clear: no Clear all")
            compare(focusedKey(), "notifications:all", "the last row takes the focus")
            compare(find("quickMenuItem_notifications:all").Accessible.name, "See all (1)")
            // See all: the centre opens above the Hub, the game stays frozen, the Hub stays open.
            keyClick(Qt.Key_Return)
            tryVerify(() => sheet().shown, 2000, "See all opens the centre")
            tryVerify(() => sheet().opacity >= 1, 2000)
            verify(menu().open, "the Hub stays open under the sheet")
            compare(find("modalLayer").z, 15, "the modal layer is not raised (RUY-638)")
            verify(sheet().z > menu().z, "the sheet is above the Hub: " + sheet().z + " over " + menu().z)
            verify(sheet().parent !== find("modalLayer"), "the sheet is not in the modal layer")
            verify(Session.running[0].frozen === true, "the game stays frozen")
            tryVerify(() => find("centreList").activeFocus, 2000, "the sheet has the focus")
            compare(hintText(), "back Close", "the sheet says its own buttons (a pinned row without an action)")
            // Back closes the sheet only; the focus is on See all again.
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet().shown, 2000, "Back closes the sheet")
            verify(menu().open, "the Hub is still open")
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub has the focus back")
            compare(focusedKey(), "notifications:all", "on See all")
            verify(find("quickMenuItem_notifications:all").focused)
            compare(menu().panelId, "notifications")
            verify(Session.running[0].frozen === true)
            // Back: the panel closes to the icon row on its icon; Back: the Hub closes and the game is thawed.
            keyClick(Qt.Key_Escape)
            tryCompare(menu(), "panelId", "")
            compare(focusedKey(), "panel:notifications")
            keyClick(Qt.Key_Escape)
            tryCompare(menu(), "open", false)
            tryVerify(() => Session.running[0].frozen === false, 2000, "the game thaws")
            compare(tc.shell.focusRepairs, 0)
        }

        function test_clear_all_keeps_pinned_and_hides_when_nothing_to_clear() {
            start()
            post("One", tc.t0 - 60000)
            post("Two", tc.t0)
            Notifications.showSticky("update-restart", "Restarting soon", "warning", "", "", "", "", { source: "updates", pinned: true })
            tryCompare(NotificationCentre, "count", 3)
            openHub()
            openPanel()
            goTo("notifications:clear")
            compare(hintText(), "accept Clear all, back Back")
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "count", 1)
            compare(NotificationCentre.items[0].pinned, true)
            tryVerify(() => menu().itemKeys.indexOf("notifications:clear") < 0)
            compare(focusedKey(), "notifications:all")
            compare(tc.shell.focusRepairs, 0)
        }

        function test_empty_panel_has_no_see_all() {
            start()
            openHub()
            verify(!find("hubIconDot_panel:notifications").visible, "nothing unread: no dot")
            openPanel()
            compare(menu().itemKeys, ["notifications:quiet", "notifications:none"], "No notifications, and no See all (0)")
            tryVerify(() => find("quickMenuItem_notifications:none") !== null, 2000)
            compare(find("quickMenuItem_notifications:all"), null)
            compare(focusedKey(), "notifications:quiet")
            keyClick(Qt.Key_Down)
            compare(focusedKey(), "notifications:none", "the reading can be reached")
            keyClick(Qt.Key_Escape)
            tryCompare(menu(), "panelId", "")
        }

        function test_back_from_the_sheet_returns_to_see_all() {
            start()
            post("One", tc.t0 - 60000)
            post("Two", tc.t0)
            dropToasts()
            openHub()
            openPanel()
            goTo("notifications:all")
            keyClick(Qt.Key_Return)
            tryVerify(() => sheet().shown && find("centreList").activeFocus, 2000)
            // Clear the focused item in the sheet (Start): the Hub's rows are rebuilt under it.
            keyClick(Qt.Key_Menu)
            tryCompare(NotificationCentre, "count", 1)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet().shown, 2000)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub has the focus back")
            compare(focusedKey(), "notifications:all", "Back lands on See all")
            verify(find("quickMenuItem_notifications:all").focused)
            // Clear the rest in the sheet: See all itself goes, the focus lands on a row that exists.
            keyClick(Qt.Key_Return)
            tryVerify(() => sheet().shown && find("centreList").activeFocus, 2000)
            keyClick(Qt.Key_Menu)
            tryCompare(NotificationCentre, "count", 0)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet().shown, 2000)
            tryVerify(() => find("systemActions").activeFocus, 2000)
            verify(menu().itemKeys.indexOf(focusedKey() === "" ? "x" : menu().rowKeyOf(focusedKey())) >= 0, "the focus is on a row")
            compare(menu().itemKeys.indexOf("notifications:all"), -1)
            compare(tc.shell.focusRepairs, 0)
        }

        function test_a_on_a_pinned_item_with_nothing_to_run_is_silent() {
            start()
            Notifications.showSticky("update-restart", "Restarting soon", "warning", "", "To finish", "", "", { source: "updates", pinned: true })
            tryCompare(NotificationCentre, "count", 1)
            dropToasts()
            openHub()
            openPanel()
            keyClick(Qt.Key_Down)
            compare(focusedKey(), "notifications:n:" + NotificationCentre.items[0].id)
            compare(hintText(), "back Back", "no A hint")
            const selects = Sfx.selectCount
            keyClick(Qt.Key_Return)
            wait(100)
            compare(Sfx.selectCount, selects, "no select cue")
            compare(NotificationCentre.count, 1)
            verify(menu().open)
        }

        function test_a_on_an_item_with_an_app_and_no_action_opens_the_app() {
            start()
            NotificationCentre.mockAppNotify({ appId: "org.example.Racer", title: "Race starts", kind: "info" })
            tryCompare(NotificationCentre, "count", 1)
            dropToasts()
            openHub()
            openPanel()
            keyClick(Qt.Key_Down)
            compare(hintText(), "accept Open, options Clear, back Back")
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryCompare(menu(), "open", false)
            tryCompare(NotificationCentre, "count", 0)
        }

        function test_a_settings_action_from_the_hub_leaves_the_hub_for_settings() {
            start()
            post("Drive inserted", tc.t0, { source: "devices", actions: [{ id: "settings:storage", label: "Open Settings" }] }, "STICK")
            dropToasts()
            openHub()
            openPanel()
            keyClick(Qt.Key_Down)
            compare(hintText(), "accept Open Settings, options Clear, back Back")
            keyClick(Qt.Key_Return)
            tryCompare(menu(), "open", false)
            tryCompare(tc.shell, "currentPage", "settings")
            tryCompare(NotificationCentre, "count", 0)
        }

        function test_the_minute_timer_runs_only_with_quiet_hours_on() {
            start()
            compare(Notifications.clockTimer.running, false, "no schedule: no timer")
            setQuietHours(true, "22:00", "07:00")
            tryCompare(Notifications.clockTimer, "running", true)
            setQuietHours(false, "22:00", "07:00")
            tryCompare(Notifications.clockTimer, "running", false)
        }

        function test_an_item_arriving_while_the_panel_is_open() {
            start()
            openHub()
            openPanel()
            compare(menu().itemKeys.length, 2)
            post("Late", tc.t0)
            tryVerify(() => menu().itemKeys.length === 4, 2000, "the item replaced \"No notifications\"; Clear all and See all came")
            compare(focusedKey(), "notifications:quiet", "the focus stays where it was")
            compare(tc.shell.focusRepairs, 0)
        }

        // ---- quiet hours (a fake clock) -----------------------------------------------------------------

        function test_quiet_hours_function() {
            const night = { enabled: true, from: "22:00", to: "07:00" }
            verify(Notifications.quietNow(night, "23:30"), "over midnight: the evening")
            verify(Notifications.quietNow(night, "00:00"))
            verify(Notifications.quietNow(night, "06:59"))
            verify(!Notifications.quietNow(night, "07:00"), "to is not in")
            verify(!Notifications.quietNow(night, "12:00"))
            verify(Notifications.quietNow(night, "22:00"), "from is in")
            const day = { enabled: true, from: "09:00", to: "17:00" }
            verify(Notifications.quietNow(day, "09:00") && Notifications.quietNow(day, "16:59"))
            verify(!Notifications.quietNow(day, "17:00") && !Notifications.quietNow(day, "08:59") && !Notifications.quietNow(day, "23:00"))
            verify(!Notifications.quietNow({ enabled: false, from: "00:00", to: "23:59" }, "12:00"), "off")
            verify(!Notifications.quietNow({ enabled: true, from: "10:00", to: "10:00" }, "10:00"), "an empty span")
            verify(!Notifications.quietNow({ enabled: true, from: "bad", to: "10:00" }, "10:00"), "a bad time")
        }

        function test_quiet_hours() {
            start()
            setClock("12:00")
            setQuietHours(true, "22:00", "07:00")
            compare(Notifications.inQuietHours, false)
            compare(Notifications.quiet, false)
            // Outside the span a toast shows.
            Notifications.show("Day toast", "info")
            tryCompare(Notifications.model, "count", 1)
            clearToasts()
            // Inside it (before midnight): no toast, the item is kept and counted, the manual flag stays off.
            setClock("23:15")
            tryCompare(Notifications, "inQuietHours", true)
            compare(Notifications.quiet, true)
            compare(NotificationCentre.quiet, false, "quiet hours never write the manual flag")
            const quieted = Notifications.quietedCount
            Notifications.show("Night toast", "info")
            tryVerify(() => itemTitled("Night toast") !== undefined, 2000, "the item is kept")
            compare(Notifications.model.count, 0, "no toast")
            compare(Notifications.quietedCount, quieted + 1)
            // After midnight, still inside; the one timer is armed for the next minute.
            setClock("03:00")
            compare(Notifications.inQuietHours, true)
            verify(Notifications.clockTimer.running, "the single-shot timer is armed")
            compare(Notifications.clockTimer.interval, TimeZone.msToNextTick(NotificationCentre.nowMs()))
            // The end of the span: toasts again.
            setClock("07:00")
            tryCompare(Notifications, "inQuietHours", false)
            Notifications.show("Morning toast", "info")
            tryCompare(Notifications.model, "count", 1)
            // Switching the schedule off, and a span that changes under a running clock.
            setClock("23:15")
            tryCompare(Notifications, "inQuietHours", true)
            setQuietHours(false, "22:00", "07:00")
            tryCompare(Notifications, "inQuietHours", false)
            setQuietHours(true, "23:00", "23:30")
            tryCompare(Notifications, "inQuietHours", true)
            setQuietHours(true, "00:00", "01:00")
            tryCompare(Notifications, "inQuietHours", false)
            // RUY-709: a time with a trailing line feed is not a time ("$" alone would accept it).
            settingSpy.clear()
            NotificationCentre.setSetting("QuietHours", ({ enabled: true, from: "22:00\n", to: "07:00" }))
            tryCompare(settingSpy, "count", 1)
            compare(settingSpy.signalArguments[0][1], "invalid")
            compare(NotificationCentre.quietHours.from, "00:00")
        }

        function test_quiet_hours_in_the_hub_and_settings() {
            start()
            setClock("23:15")
            setQuietHours(true, "22:00", "07:00")
            tryCompare(Notifications, "inQuietHours", true)
            openHub()
            openPanel()
            compare(findChild(find("quickMenuItem_notifications:quiet"), "hubValueText").text, "Quiet hours until 07:00",
                    "the manual flag is off; the row says the schedule holds")
            compare(NotificationCentre.quiet, false)
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "quiet", true)
            compare(findChild(find("quickMenuItem_notifications:quiet"), "hubValueText").text, "On")
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            tryCompare(menu(), "open", false)
        }

        // ---- the sources --------------------------------------------------------------------------------

        function test_sources() {
            start()
            // A source that is off makes no toast and keeps no item (the shell's own post).
            NotificationCentre.setSetting("SourcesEnabled", ({ devices: false }))
            tryVerify(() => NotificationCentre.sourcesEnabled.devices === false, 2000)
            Notifications.show("Drive inserted", "info", "", "usb", "", { source: "devices" })
            Notifications.show("System note", "info")
            tryVerify(() => itemTitled("System note") !== undefined, 2000)
            compare(itemTitled("Drive inserted"), undefined, "a device item is not kept")
            compare(Notifications.model.count, 1, "only the system toast shows")
            compare(Notifications.model.get(0).text, "System note")
            // A lasting state of a source that is off is dropped too.
            Notifications.showSticky("devices-state", "Pad missing", "warning", "", "", "", "", { source: "devices" })
            compare(Notifications.keyed["devices-state"], undefined)
            // An app's item (through the bridge, the mock's post path) is dropped when its app is off.
            NotificationCentre.setSetting("SourcesEnabled", ({ devices: false, "app:org.example.Game": false }))
            tryVerify(() => NotificationCentre.sourcesEnabled["app:org.example.Game"] === false, 2000)
            NotificationCentre.mockAppNotify({ appId: "org.example.Game", title: "Match found", kind: "info" })
            NotificationCentre.mockAppNotify({ appId: "org.example.Other", title: "Other app", kind: "info" })
            tryVerify(() => itemTitled("Other app") !== undefined, 2000, "another app still posts")
            compare(itemTitled("Match found"), undefined, "the app that is off is dropped")
            // On again: it is kept.
            NotificationCentre.setSetting("SourcesEnabled", ({ devices: true }))
            tryVerify(() => NotificationCentre.sourcesEnabled.devices === true, 2000)
            Notifications.show("Drive inserted", "info", "", "usb", "", { source: "devices" })
            tryVerify(() => itemTitled("Drive inserted") !== undefined, 2000, "a source that is on keeps its items")
        }

        // ---- Settings > Notifications -------------------------------------------------------------------

        function openPane() {
            tc.shell.openPage("settings", { category: "notifications" })
            tryVerify(() => find("paneNotifications") !== null, 3000, "the pane is built")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneNotifications").activeFocus, 2000, "Right enters the pane")
        }
        function rowFocus(name) {
            for (let i = 0; i < 30 && !find(name).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(find(name).activeFocus, name + " has the focus")
        }

        function test_settings_rows() {
            start()
            openPane()
            // The category sits after Audio.
            const keys = findChild(tc.shell, "categoryList").model.map(c => c.key)
            compare(keys[keys.indexOf("audio") + 1], "notifications", "after Audio")
            compare(find("rowNotifQuiet").activeFocus, true, "the first row has the focus")
            // Quiet mode, Don't interrupt games, Notification sounds toggle the settings.
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "quiet", true)
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "quiet", false)
            rowFocus("rowNotifDontInterrupt")
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "dontInterruptGames", false)
            rowFocus("rowNotifSounds")
            compare(NotificationCentre.sounds, true)
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "sounds", false)
            // With the sound off a toast makes no notification cue.
            const cues = Sfx.notificationCount
            Notifications.show("Quiet cue", "info")
            tryCompare(Notifications.model, "count", 1)
            compare(Sfx.notificationCount, cues, "no cue with Notification sounds off")
            clearToasts()
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "sounds", true)
            Notifications.show("Cue", "info")
            tryCompare(Notifications.model, "count", 1)
            compare(Sfx.notificationCount, cues + 1, "and a cue with it on")
        }

        // Named to run first: the file never assigns `durationMs`, so the product's own binding is what is read.
        function test_a_show_each_for_drives_the_toast_time() {
            start()
            compare(Notifications.durationMs, 4000, "the default is 4 s")
            openPane()
            rowFocus("rowNotifToastSeconds")
            compare(find("rowNotifToastSeconds").valueText.text, "4 s")
            keyClick(Qt.Key_Right)
            tryCompare(NotificationCentre, "toastSeconds", 6)
            tryCompare(Notifications, "durationMs", 6000)
            keyClick(Qt.Key_Right)
            tryCompare(NotificationCentre, "toastSeconds", 8)
            keyClick(Qt.Key_Right)
            tryCompare(NotificationCentre, "toastSeconds", 12)
            tryCompare(Notifications, "durationMs", 12000)
            keyClick(Qt.Key_Right)
            tryCompare(NotificationCentre, "toastSeconds", 4, 2000, "wraps")
            keyClick(Qt.Key_Left)
            tryCompare(NotificationCentre, "toastSeconds", 12)
            compare(find("rowNotifToastSeconds").valueText.text, "12 s")
        }

        function test_quiet_hours_rows() {
            start()
            openPane()
            rowFocus("rowNotifQuietHours")
            verify(!find("rowNotifQuietFrom").visible && !find("rowNotifQuietTo").visible, "off: no times")
            keyClick(Qt.Key_Right)
            tryCompare(NotificationCentre.quietHours, "enabled", true)
            tryVerify(() => find("rowNotifQuietFrom").visible && find("rowNotifQuietTo").visible, 2000, "on: from and to")
            compare(find("rowNotifQuietFrom").valueText.text, "22:00")
            compare(find("rowNotifQuietTo").valueText.text, "07:00")
            rowFocus("rowNotifQuietFrom")
            keyClick(Qt.Key_Right)
            tryCompare(NotificationCentre.quietHours, "from", "23:00")
            rowFocus("rowNotifQuietTo")
            keyClick(Qt.Key_Left)
            tryCompare(NotificationCentre.quietHours, "to", "06:00")
            compare(NotificationCentre.quietHours.enabled, true)
            // The span is read by the toasts: inside, quiet; and the pane says so.
            setClock("23:30")
            tryCompare(Notifications, "inQuietHours", true)
            tryVerify(() => find("notifQuietHoursNote").visible, 2000)
            compare(find("notifQuietHoursNote").text, "Quiet hours until 06:00")
            compare(find("rowNotifQuiet").checked, false, "the manual switch stays off")
        }

        function test_source_rows_and_apps() {
            start()
            NotificationCentre.mockAppNotify({ appId: "org.example.Game", title: "Match found", kind: "info" })
            tryCompare(NotificationCentre, "count", 1)
            openPane()
            tryVerify(() => find("rowNotifSource_app:org.example.Game") !== null, 2000, "an app that sent one has a row")
            for (const k of ["system", "updates", "devices", "store"])
                verify(find("rowNotifSource_" + k) !== null, k)
            rowFocus("rowNotifSource_devices")
            compare(find("rowNotifSource_devices").checked, true)
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre.sourcesEnabled, "devices", false)
            compare(find("rowNotifSource_devices").checked, false)
            rowFocus("rowNotifSource_app:org.example.Game")
            keyClick(Qt.Key_Return)
            tryVerify(() => NotificationCentre.sourcesEnabled["app:org.example.Game"] === false, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => NotificationCentre.sourcesEnabled["app:org.example.Game"] === true, 2000)
        }

        function test_clear_history_asks_first() {
            start()
            post("One", tc.t0 - 60000)
            Notifications.showSticky("update-restart", "Restarting soon", "warning", "", "", "", "", { source: "updates", pinned: true })
            tryCompare(NotificationCentre, "count", 2)
            openPane()
            verify(find("notifClearConfirm") === null, "the confirmation is built on the first opening")
            rowFocus("rowNotifClearHistory")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("notifClearConfirm") !== null && find("notifClearConfirm").shown, 2000)
            compare(find("notifClearConfirm").confirmName, "Clear history", "the confirm button names the action")
            compare(NotificationCentre.count, 2, "nothing is cleared before the answer")
            // Cancel is focused: B and A both leave the history alone.
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("notifClearConfirm").shown, 2000)
            compare(NotificationCentre.count, 2)
            tryVerify(() => find("rowNotifClearHistory").activeFocus, 2000, "the focus returns to the row")
            // Confirm: right to the confirm button, A.
            keyClick(Qt.Key_Return)
            tryVerify(() => find("notifClearConfirm").shown, 2000)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "count", 1)
            compare(NotificationCentre.items[0].pinned, true, "pinned stays")
            tryVerify(() => find("rowNotifClearHistory").activeFocus, 2000)
        }

        // ---- screenshots --------------------------------------------------------------------------------

        function fill(t) {
            NotificationCentre.mockSetNow(tc.t0 - 25 * 3600000)
            Notifications.show(t.wallpaper, "success")
            NotificationCentre.mockSetNow(tc.t0 - 3 * 3600000)
            Notifications.show(t.battery, "warning", "", "pad_dualsense", "DualSense · 12%", { source: "devices" })
            NotificationCentre.mockSetNow(tc.t0 - 600000)
            Notifications.showSticky("update-restart", t.restart, "warning", "", t.restartDetail, "", "",
                                     { source: "updates", urgency: "critical", pinned: true,
                                       actions: [{ id: "restart", label: t.restartNow }] })
            NotificationCentre.mockSetNow(tc.t0 - 120000)
            Notifications.show(t.drive, "info", "", "usb", "SANDISK 64GB", { source: "devices" })
            NotificationCentre.mockSetNow(tc.t0)
            NotificationCentre.mockAppNotify({ appId: "org.example.Game", title: t.match, body: t.matchDetail, kind: "success",
                                               actions: [{ id: "accept", label: t.join }, { id: "later", label: t.later }] })
            tryCompare(NotificationCentre, "count", 5, 2000)
            dropToasts()
        }

        function shots(dir, suffix, t) {
            start()
            fill(t)
            // Settings > Notifications first (the game comes later and would keep the keys).
            NotificationCentre.setSetting("QuietHours", ({ enabled: true, from: "22:00", to: "07:00" }))
            tryCompare(NotificationCentre.quietHours, "enabled", true)
            openPane()
            wait(400)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "settings-notifications-1" + suffix + ".png")
            rowFocus("rowNotifSource_devices")
            wait(300)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "settings-notifications-2-sources" + suffix + ".png")
            rowFocus("rowNotifClearHistory")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("notifClearConfirm") !== null && find("notifClearConfirm").shown, 2000)
            wait(400)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "settings-notifications-3-clear" + suffix + ".png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("notifClearConfirm").shown, 2000)
            keyClick(Qt.Key_Escape)                     // the category list
            keyClick(Qt.Key_Escape)                     // Home
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homePlay").activeFocus, 3000, "Home has the focus again")
            NotificationCentre.setSetting("QuietHours", ({ enabled: false, from: "22:00", to: "07:00" }))
            // The Hub over a game.
            playRacer(pictureAppComponent)
            openHub()
            tryVerify(() => Session.running.length === 1 && Session.running[0].frozen === true, 2000)
            goTo("panel:notifications")
            wait(300)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "hub-notifications-1-icon" + suffix + ".png")
            keyClick(Qt.Key_Return)
            tryCompare(menu(), "panelId", "notifications")
            tryCompare(menu(), "swap", 1)
            wait(500)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "hub-notifications-2-panel" + suffix + ".png")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            wait(300)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "hub-notifications-3-item" + suffix + ".png")
            goTo("notifications:all")
            keyClick(Qt.Key_Return)
            tryVerify(() => sheet().shown && sheet().opacity >= 1, 3000)
            tryVerify(() => find("centreSlide").x === tc.shell.width - sheet().sheetWidth, 3000)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "hub-notifications-4-sheet" + suffix + ".png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet().shown, 2000)
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            tryCompare(menu(), "open", false)
            // The empty panel: "No notifications", no See all (RUY-638).
            NotificationCentre.dismissAll()
            tryVerify(() => NotificationCentre.items.every(i => i.pinned), 2000)
            Notifications.remove("update-restart")
            tryCompare(NotificationCentre, "count", 0, 3000)
            openHub()
            openPanel()
            wait(400)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "hub-notifications-5-empty" + suffix + ".png")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            shots(shotsDir + "/", "", { wallpaper: "Wallpaper added", battery: "Controller battery low", restart: "Restarting in 2 minutes",
                        restartDetail: "To finish the update", restartNow: "Restart now", drive: "Drive inserted",
                        match: "Match found", matchDetail: "Ready in 30 s", join: "Join", later: "Later" })
        }

        function test_zz_screenshots_tr() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.language = "tr"
            shots(shotsDir + "/", "-tr", { wallpaper: "Duvar kağıdı eklendi", battery: "Kumanda pili zayıf", restart: "2 dakikada yeniden başlıyor",
                           restartDetail: "Güncellemeyi bitirmek için", restartNow: "Şimdi yeniden başlat", drive: "Sürücü takıldı",
                           match: "Maç bulundu", matchDetail: "30 sn içinde hazır", join: "Katıl", later: "Sonra" })
            DeviceSettings.language = "en"
        }
    }
}
