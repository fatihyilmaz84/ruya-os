import QtQuick
import QtTest
import RuyaShell

// The notification centre (RUY-413): the mock of Notifications1 behind NotificationCentre, the bell
// in the status cluster, the centre sheet and the quiet rules of the toasts. Driven with the
// controller keys only (Up/Down/Left/Right, Return = A, Escape = B, Menu = Start). Signs in as Ada
// (p2, no PIN). The mock is reset before every test.
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
        name: "Notifications"
        when: windowShown

        property Shell shell: null
        // A fixed instant (2026-11-13 15:00 UTC) for the times of the rows.
        readonly property double t0: Date.UTC(2026, 10, 13, 15, 0, 0)

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            IdleClock.stage = "active"
            Notifications.durationMs = 60000
            NotificationCentre.mockReset()
            tryCompare(NotificationCentre, "quiet", false)
            tryCompare(NotificationCentre, "dontInterruptGames", true)
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            tryCompare(NotificationCentre, "profile", "p2")
            tryCompare(NotificationCentre, "loaded", true)
            tryCompare(NotificationCentre, "dontInterruptGames", true)
            clearToasts()
        }

        function cleanup() {
            Update.mockAnnounceRestart(0)
            Notifications.durationMs = Theme.toastMs
            Notifications.appInFront = false
            Notifications.overlayOpen = false
            IdleClock.stage = "active"
            DeviceSettings.language = "en"
            clearToasts()
            NotificationCentre.mockReset()
            NotificationCentre.mockSetNow(-1)
        }

        function clearToasts() {
            const keys = Object.keys(Notifications.keyed)      // the lasting states a test left (they follow every sign-in)
            for (let i = 0; i < keys.length; ++i)
                Notifications.remove(keys[i])
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        // Up from Play to the nav, Right to the gear, Right to the bell.
        function toBell() {
            keyClick(Qt.Key_Up)
            tryVerify(() => find("sectionNav").activeFocus, 2000, "the nav has focus")
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            tryCompare(find("sectionNav"), "currentIndex", 4)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("notificationBell").activeFocus, 2000, "Right from the gear reaches the bell")
        }

        function openCentre() {
            toBell()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("notificationSheet").shown, 2000, "A on the bell opens the centre")
            tryVerify(() => find("notificationSheet").opacity >= 1, 2000, "the centre has faded in")
        }

        function sheet() { return find("notificationSheet") }
        function rowOf(id) { return findChild(sheet(), "centreRow_" + id) }
        function itemTitled(title) { return NotificationCentre.items.find(i => i.title === title) }
        function idOf(title) {
            const it = itemTitled(title)
            return it ? it.id : 0
        }
        // The row with that title has the focus (the list has it and the row is the focused one).
        function rowFocused(title) {
            const s = sheet()
            return find("centreList").activeFocus && s.stop === "row" && s.focusKey === "n:" + idOf(title)
        }
        function hintText() {
            return find("hintBar").hints.map(h => (h.button ?? h.buttons.join("+")) + " " + h.text).join(", ")
        }

        // Posts through the one entry point, with the mock's clock at `at`.
        function post(title, at, options, detail) {
            NotificationCentre.mockSetNow(at)
            Notifications.show(title, "info", "", "", detail ?? "", options ?? {})
            tryVerify(() => itemTitled(title) !== undefined, 2000, title + " is kept")
        }

        // ---- screenshot helpers (above the tests: dev.ps1 shots gives a shotsDir line to the test before it) ----

        // The toasts only: the keyed states stay (the pinned restart notice is part of the picture).
        function dropToasts() {
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        // t: the words of the items in the shot's language (the test's own qsTr has no translation).
        function fill(t) {
            NotificationCentre.mockSetNow(tc.t0 - 25 * 3600000)
            Notifications.show(t.wallpaper, "success")
            NotificationCentre.mockSetNow(tc.t0 - 3 * 3600000)
            Notifications.show(t.battery, "warning", "", "pad_dualsense", "DualSense · 12%", { source: "devices" })
            tryVerify(() => NotificationCentre.count === 2)
            NotificationCentre.markRead()
            tryVerify(() => NotificationCentre.unreadCount === 0)
            NotificationCentre.mockSetNow(tc.t0 - 600000)
            Notifications.showSticky("update-restart", t.restart, "warning", "", t.restartDetail, "", "",
                                     { source: "updates", urgency: "critical", pinned: true,
                                       actions: [{ id: "restart", label: t.restartNow }] })
            NotificationCentre.mockSetNow(tc.t0 - 120000)
            Notifications.show(t.drive, "info", "", "usb", "SANDISK 64GB",
                               { source: "devices", actions: [{ id: "settings:storage", label: t.openSettings }] })
            NotificationCentre.mockSetNow(tc.t0)
            NotificationCentre.mockAppNotify({ appId: "org.example.Game", title: t.match, body: t.matchDetail,
                                                 kind: "success", actions: [{ id: "accept", label: t.join }, { id: "later", label: t.later }] })
            tryVerify(() => NotificationCentre.count === 5, 2000)
            dropToasts()
        }

        function settle() {
            tryVerify(() => find("centreSlide").x === tc.shell.width - sheet().sheetWidth && sheet().opacity >= 1, 3000, "the sheet is at rest")
            waitForRendering(tc.shell)
        }

        // dir: shotsDir + "/" (passed by the test, which is how dev.ps1 shots finds it).
        function shots(dir, suffix, t) {
            // The bell with a badge on Home, then focused.
            fill(t)
            tryVerify(() => findChild(find("notificationBell"), "bellBadge").visible)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "93-bell-badge" + suffix + ".png")
            toBell()
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "93b-bell-focused" + suffix + ".png")
            // The full centre, the focus on the pinned row with its action.
            keyClick(Qt.Key_Return)
            tryVerify(() => sheet().shown)
            settle()
            grabImage(tc.shell).save(dir + "94-centre-full" + suffix + ".png")
            keyClick(Qt.Key_Down)                    // the app's item: two actions
            tryVerify(() => rowFocused(t.match))
            keyClick(Qt.Key_Right)
            tryVerify(() => sheet().pick === 1)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "94b-centre-actions" + suffix + ".png")
            // Quiet mode on, then everything cleared but the pinned item, then the empty centre.
            NotificationCentre.setQuiet(true)
            tryCompare(NotificationCentre, "quiet", true)
            NotificationCentre.dismissAll()
            tryVerify(() => NotificationCentre.count === 1)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "94c-centre-quiet" + suffix + ".png")
            Notifications.remove("update-restart")
            tryVerify(() => NotificationCentre.count === 0)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "94d-centre-empty" + suffix + ".png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet().shown && sheet().opacity === 0, 3000)
            waitForRendering(tc.shell)
            grabImage(tc.shell).save(dir + "93c-bell-quiet" + suffix + ".png")
            NotificationCentre.setQuiet(false)
            tryCompare(NotificationCentre, "quiet", false)
        }

        // ---- the mock and the badge ----

        function test_badge_counts() {
            const bell = find("notificationBell")
            const badge = findChild(bell, "bellBadge")
            compare(NotificationCentre.unreadCount, 0)
            verify(!badge.visible, "no badge at 0")
            verify(bell.Accessible.name.indexOf("0 unread") >= 0, bell.Accessible.name)
            post("One", tc.t0)
            tryCompare(NotificationCentre, "unreadCount", 1)
            verify(badge.visible)
            compare(findChild(bell, "bellBadgeText").text, "1")
            for (let i = 2; i <= 9; ++i)
                post("Item " + i, tc.t0 + i)
            tryCompare(NotificationCentre, "unreadCount", 9)
            compare(findChild(bell, "bellBadgeText").text, "9")
            post("Ten", tc.t0 + 10)
            tryCompare(NotificationCentre, "unreadCount", 10)
            compare(findChild(bell, "bellBadgeText").text, "9+", "above nine it says 9+")
            compare(badge.height, 32 * tc.shell.u)
            verify(bell.Accessible.name.indexOf("10 unread") >= 0, bell.Accessible.name)
        }

        function test_opening_marks_read() {
            post("Drive inserted", tc.t0 - 120000)
            post("Update ready", tc.t0)
            tryCompare(NotificationCentre, "unreadCount", 2)
            const calls = NotificationCentre.mockCalls("markread")
            openCentre()
            tryCompare(NotificationCentre, "unreadCount", 0)
            compare(NotificationCentre.mockCalls("markread"), calls + 1)
            verify(!findChild(find("notificationBell"), "bellBadge").visible, "the badge empties")
            compare(findChild(sheet(), "centreNewCount").text, "2 new")
            verify(findChild(sheet(), "centreNewCount").visible, "it fits before Clear all in English")
            tryVerify(() => rowOf(idOf("Update ready")) !== null)
            verify(findChild(rowOf(idOf("Update ready")), "notificationDot").visible, "a new item keeps its dot")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet().shown)
            tryVerify(() => find("notificationBell").activeFocus, 2000, "Back returns the focus to the bell")
        }

        function test_list_order_and_pinning() {
            post("Three hours ago", tc.t0 - 3 * 3600000)
            post("Yesterday's", tc.t0 - 25 * 3600000)
            post("Two minutes ago", tc.t0 - 120000)
            NotificationCentre.mockSetNow(tc.t0 - 600000)
            Notifications.showSticky("update-restart", "Restarting in 2 minutes", "warning", "", "To finish the update",
                                     "Press any button to wait", "A",
                                     { source: "updates", urgency: "critical", pinned: true,
                                       actions: [{ id: "restart", label: "Restart now" }] })
            post("Just now", tc.t0)
            tryCompare(NotificationCentre, "count", 5)
            compare(NotificationCentre.items.map(i => i.title),
                    ["Restarting in 2 minutes", "Just now", "Two minutes ago", "Three hours ago", "Yesterday's"],
                    "pinned first, then newest first")
            verify(NotificationCentre.items[0].pinned)
            openCentre()
            const keys = sheet().keys
            compare(keys[0], "cap:pinned")
            compare(keys[1], "n:" + idOf("Restarting in 2 minutes"))
            compare(keys[2], "cap:new")
            tryVerify(() => rowFocused("Restarting in 2 minutes"), 2000, "the focus lands on the first pinned item")
            const pinned = rowOf(idOf("Restarting in 2 minutes"))
            verify(findChild(pinned, "notificationPin").visible, "a pinned item shows the pin")
            verify(!findChild(pinned, "notificationDot").visible)
            verify(hintText().indexOf("Clear") < 0, "no Clear on a pinned item: " + hintText())
            compare(findChild(rowOf(idOf("Just now")), "notificationTime").text, "Just now")
            compare(findChild(rowOf(idOf("Two minutes ago")), "notificationTime").text, "2 min ago")
            compare(findChild(rowOf(idOf("Three hours ago")), "notificationTime").text, TimeZone.formatClock(tc.t0 - 3 * 3600000))
            compare(findChild(rowOf(idOf("Yesterday's")), "notificationTime").text, "Yesterday")
            // The pinned item cannot be cleared: Start does nothing to it.
            keyClick(Qt.Key_Menu)
            wait(50)
            compare(NotificationCentre.count, 5)
            verify(rowFocused("Restarting in 2 minutes"))
            // The source ends it: it goes, and the focus moves on to the next row.
            Notifications.remove("update-restart")
            tryVerify(() => itemTitled("Restarting in 2 minutes") === undefined, 2000, "withdrawn")
            tryVerify(() => rowFocused("Just now"), 2000, "the focus moves to the next row")
        }

        function test_actions_run_and_clear() {
            post("Older", tc.t0 - 60000)
            post("Drive inserted", tc.t0, { source: "devices", actions: [{ id: "settings:storage", label: "Open Settings" }] }, "STICK")
            openCentre()
            tryVerify(() => rowFocused("Drive inserted"))
            const row = findChild(rowOf(idOf("Drive inserted")), "notificationRow")
            verify(row.expanded, "the focused row shows its actions")
            compare(findChild(row, "notificationAction_0").color, Theme.primaryFill)
            compare(hintText(), "A Select, Start Clear, B Close")
            const invoked = NotificationCentre.mockCalls("invoke")
            keyClick(Qt.Key_Return)
            tryVerify(() => !sheet().shown, 2000, "an action that leaves closes the centre")
            tryCompare(tc.shell, "currentPage", "settings")
            compare(tc.shell.currentParams.category, "storage", "Open Settings opens the Storage pane")
            compare(NotificationCentre.mockCalls("invoke"), invoked + 1)
            tryVerify(() => itemTitled("Drive inserted") === undefined, 2000, "running the action clears the item")
            verify(itemTitled("Older") !== undefined)
        }

        // Review round 2: "Restart now" never restarts on one press. The centre closes and the power
        // confirmation asks, Cancel focused; Cancel leaves the item, Restart now restarts and records it.
        function test_restart_now_asks_first() {
            Notifications.show("Update ready. Restart to finish.", "info", "", "download_done", "",
                               { source: "updates", actions: [{ id: "restart", label: "Restart now" }] })
            tryVerify(() => idOf("Update ready. Restart to finish.") > 0)
            clearToasts()
            const restarts = Power.actionCount
            const invoked = NotificationCentre.mockCalls("invoke")
            openCentre()
            tryVerify(() => rowFocused("Update ready. Restart to finish."))
            keyClick(Qt.Key_Return)
            const confirm = find("overlayPowerConfirm")
            tryVerify(() => confirm.shown, 2000, "A asks first")
            tryVerify(() => !sheet().shown, 2000, "the centre closed")
            tryVerify(() => findChild(confirm, "powerCancel").activeFocus, 2000, "Cancel has the focus")
            compare(Power.actionCount, restarts, "nothing restarted yet")
            compare(hintText(), "A Select, B Cancel")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !confirm.shown)
            tryVerify(() => find("notificationBell").activeFocus, 2000, "Cancel: the focus is back on the bell")
            compare(Power.actionCount, restarts)
            compare(NotificationCentre.mockCalls("invoke"), invoked, "a cancelled restart is not recorded")
            verify(itemTitled("Update ready. Restart to finish.") !== undefined, "and the item stays")
            // Again, and confirm this time.
            keyClick(Qt.Key_Return)
            tryVerify(() => sheet().shown)
            tryVerify(() => rowFocused("Update ready. Restart to finish."))
            keyClick(Qt.Key_Return)
            tryVerify(() => findChild(confirm, "powerCancel").activeFocus)
            keyClick(Qt.Key_Right)
            tryVerify(() => findChild(confirm, "powerConfirm").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(Power, "actionCount", restarts + 1)
            compare(Power.lastAction, "restart")
            tryCompare(NotificationCentre, "count", 0, 2000, "confirmed: the item ran and went")
            compare(NotificationCentre.mockCalls("invoke"), invoked + 1)
        }

        // Review round 2: an app's action ids are never console actions. An app that names its actions
        // "restart" or "settings:storage" only has them handed back (Invoke); nothing restarts or opens.
        function test_app_actions_never_run_console_actions() {
            const restarts = Power.actionCount
            NotificationCentre.mockSetNow(tc.t0)
            NotificationCentre.mockAppNotify({ appId: "org.example.Evil", title: "Click me", body: "",
                                                 actions: [{ id: "restart", label: "Restart" }, { id: "settings:storage", label: "Storage" }] })
            NotificationCentre.mockSetNow(tc.t0 - 1000)
            NotificationCentre.mockAppNotify({ appId: "org.example.Evil", title: "And me", body: "",
                                                 actions: [{ id: "restart", label: "Restart" }, { id: "settings:storage", label: "Storage" }] })
            tryVerify(() => NotificationCentre.count === 2)
            clearToasts()
            const invoked = NotificationCentre.mockCalls("invoke")
            openCentre()
            tryVerify(() => rowFocused("Click me"))
            keyClick(Qt.Key_Return)                          // its "restart"
            tryVerify(() => itemTitled("Click me") === undefined, 2000, "handed back to the app: the item went")
            compare(NotificationCentre.mockCalls("invoke"), invoked + 1)
            verify(!find("overlayPowerConfirm").shown, "no power confirmation")
            compare(Power.actionCount, restarts, "no restart")
            verify(sheet().shown, "the centre stays")
            tryVerify(() => rowFocused("And me"))
            keyClick(Qt.Key_Right)                           // its "settings:storage"
            tryCompare(sheet(), "pick", 1)
            keyClick(Qt.Key_Return)
            tryVerify(() => itemTitled("And me") === undefined, 2000, "handed back too")
            compare(NotificationCentre.mockCalls("invoke"), invoked + 2)
            compare(tc.shell.currentPage, "", "no Settings page opened")
            verify(sheet().shown)
            tryVerify(() => find("centreQuiet").activeFocus)
        }

        // Review round 2: a pinned item's title is a safety notice: it wraps to two lines, never cut.
        function test_pinned_title_wraps() {
            const longTitle = "Restarting in 2 minutes to finish"      // the real title is shorter; this one needs two lines
            NotificationCentre.mockSetNow(tc.t0)
            Notifications.keep("update-restart", longTitle, "warning", "restart_alt", "To finish the update",
                               { source: "updates", urgency: "critical", pinned: true })
            post("Plain " + longTitle, tc.t0 - 1000)
            dropToasts()                                         // the toasts only: the keyed state stays
            openCentre()
            tryVerify(() => rowFocused(longTitle))
            const pinned = findChild(rowOf(idOf(longTitle)), "notificationRow")
            const title = findChild(pinned, "notificationTitle")
            tryVerify(() => title.lineCount === 2, 2000, "two lines: " + title.lineCount)
            verify(!title.truncated, "a pinned title is not cut")
            verify(pinned.height > 112 * tc.shell.u, "the row grew: " + pinned.height)
            const plainTitle = findChild(findChild(rowOf(idOf("Plain " + longTitle)), "notificationRow"), "notificationTitle")
            compare(plainTitle.lineCount, 1, "an ordinary row stays one line")
            verify(plainTitle.truncated, "and elides")
        }

        function test_app_item_actions_pick_and_toast() {
            post("Older", tc.t0 - 60000)
            NotificationCentre.mockSetNow(tc.t0)
            NotificationCentre.mockAppNotify({ appId: "org.example.Game", title: "Match found", body: "Ready in 30 s",
                                                 actions: [{ id: "accept", label: "Join" }, { id: "later", label: "Later" }] })
            clearToasts()                                        // Older's own toast
            tryVerify(() => itemTitled("Match found") !== undefined, 2000, "the bridge's item is kept")
            compare(itemTitled("Match found").source, "app")
            tryVerify(() => Notifications.model.count === 1 && Notifications.model.get(0).text === "Match found", 2000,
                      "an app's item is toasted when it arrives")
            compare(Notifications.model.get(0).footer, "Join is in Notifications", "the toast says where its actions are")
            compare(Notifications.model.get(0).footerIcon, "notifications")
            clearToasts()
            openCentre()
            tryVerify(() => rowFocused("Match found"))
            compare(hintText(), "A Select, Left/Right Choose, Start Clear, B Close")
            const row = findChild(rowOf(idOf("Match found")), "notificationRow")
            compare(row.pick, 0)
            keyClick(Qt.Key_Right)
            tryCompare(row, "pick", 1)
            keyClick(Qt.Key_Right)
            compare(row.pick, 1, "the pick stops at the last action")
            keyClick(Qt.Key_Return)
            tryVerify(() => itemTitled("Match found") === undefined, 2000, "Join or Later runs and clears the item")
            verify(sheet().shown, "an app's action leaves the centre open")
            tryVerify(() => rowFocused("Older"), 2000, "the focus moves to the next row")
        }

        function test_x_clears_one_and_the_focus_moves() {
            post("C", tc.t0 - 3000)
            post("B", tc.t0 - 2000)
            post("A", tc.t0 - 1000)
            openCentre()
            tryVerify(() => rowFocused("A"))
            keyClick(Qt.Key_Down)
            tryVerify(() => rowFocused("B"), 2000, "Down: the next row")
            keyClick(Qt.Key_Menu)                    // Start clears
            tryVerify(() => itemTitled("B") === undefined, 2000, "Start clears the focused item")
            tryVerify(() => rowFocused("C"), 2000, "the focus moves to the next row")
            keyClick(Qt.Key_Menu)
            tryVerify(() => itemTitled("C") === undefined)
            tryVerify(() => rowFocused("A"), 2000, "no next row: the previous one")
            keyClick(Qt.Key_Menu)
            tryVerify(() => NotificationCentre.count === 0)
            tryVerify(() => find("centreQuiet").activeFocus, 2000, "no row left: Quiet mode")
            verify(findChild(sheet(), "centreEmpty").visible, "the empty state")
            verify(!find("centreClearAll").visible)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet().shown && find("notificationBell").activeFocus, 2000, "Back closes, the bell has the focus")
        }

        function test_clear_all_keeps_pinned() {
            post("One", tc.t0 - 2000)
            post("Two", tc.t0 - 1000)
            Notifications.keep("thermal-critical", "The console is too hot", "error", "device_thermostat", "",
                               { urgency: "critical", pinned: true })
            tryVerify(() => itemTitled("The console is too hot") !== undefined)
            openCentre()
            tryVerify(() => rowFocused("The console is too hot"))
            keyClick(Qt.Key_Up)
            tryVerify(() => find("centreQuiet").activeFocus, 2000, "Up from the first row: Quiet mode")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("centreClearAll").activeFocus, 2000, "then Clear all")
            compare(hintText(), "A Clear all, B Close")
            keyClick(Qt.Key_Return)
            tryVerify(() => NotificationCentre.count === 1, 2000, "Clear all clears")
            compare(NotificationCentre.items[0].title, "The console is too hot", "the pinned item stays")
            tryVerify(() => !find("centreClearAll").visible, 2000, "only pinned items left: no Clear all")
            tryVerify(() => rowFocused("The console is too hot"), 2000, "the focus moves to the first row")
            Notifications.remove("thermal-critical")
            tryVerify(() => NotificationCentre.count === 0)
            tryVerify(() => find("centreQuiet").activeFocus, 2000, "the last row went: Quiet mode")
        }

        function test_caps_50_and_7_days() {
            Notifications.keep("pin", "Pinned", "warning", "", "", { pinned: true })
            for (let i = 0; i < 55; ++i) {
                NotificationCentre.mockSetNow(tc.t0 + i * 1000)
                NotificationCentre.post({ title: "N" + i, kind: "info", source: "system" })
            }
            tryVerify(() => NotificationCentre.count === 50, 5000, "at most 50 items")
            verify(itemTitled("Pinned") !== undefined, "a pinned item is never dropped")
            verify(itemTitled("N5") === undefined && itemTitled("N4") === undefined && itemTitled("N0") === undefined, "the oldest went first")
            verify(itemTitled("N6") !== undefined && itemTitled("N54") !== undefined)
            // Eight days on: everything older than seven days goes, the pinned item stays.
            NotificationCentre.mockSetNow(tc.t0 + 55000 + 8 * 86400000)
            NotificationCentre.mockRefreshDelayed(0)
            tryVerify(() => NotificationCentre.count === 1, 2000, "items older than 7 days go")
            compare(NotificationCentre.items[0].title, "Pinned")
            NotificationCentre.post({ title: "Fresh", kind: "info", source: "system" })
            tryVerify(() => NotificationCentre.count === 2)
        }

        function test_contract_statuses() {
            post("Plain", tc.t0)
            const id = idOf("Plain")
            let answers = []
            const record = (op, itemId, status) => answers.push(op + ":" + status)
            NotificationCentre.finished.connect(record)
            NotificationCentre.invoke(id, "nope")
            tryVerify(() => answers.indexOf("invoke:invalid") >= 0, 2000, "an action the item does not offer")
            NotificationCentre.dismiss(424242)
            tryVerify(() => answers.indexOf("dismiss:unknown") >= 0, 2000, "an unknown id")
            Notifications.keep("pinned-key", "Pinned", "warning", "", "", { pinned: true })
            tryVerify(() => idOf("Pinned") > 0)
            NotificationCentre.dismiss(idOf("Pinned"))
            tryVerify(() => answers.indexOf("dismiss:pinned") >= 0, 2000, "a pinned item is not dismissed")
            NotificationCentre.finished.disconnect(record)
            let posted = ""
            const onPosted = (key, status, newId) => posted = status
            NotificationCentre.posted.connect(onPosted)
            NotificationCentre.post({ title: "", kind: "info" })
            tryVerify(() => posted === "invalid", 2000, "an empty title is invalid")
            posted = ""
            NotificationCentre.post({ title: "x", kind: "loud" })
            tryVerify(() => posted === "invalid", 2000, "an unknown kind is invalid")
            NotificationCentre.posted.disconnect(onPosted)
        }

        // An app's words are plain text in the centre: the title, the detail and the action labels (T-286).
        function test_app_text_is_plain() {
            const markup = "<b>x</b><img src=\"qrc:/none.png\">"
            NotificationCentre.mockSetNow(tc.t0)
            NotificationCentre.mockAppNotify({ appId: "org.example.Game", title: markup, body: markup,
                                                 actions: [{ id: "a", label: markup }] })
            tryVerify(() => itemTitled(markup) !== undefined)
            clearToasts()
            openCentre()
            tryVerify(() => rowFocused(markup))
            const row = rowOf(idOf(markup))
            for (const name of ["notificationTitle", "notificationBody"]) {
                const t = findChild(row, name)
                compare(t.textFormat, Text.PlainText, name)
                compare(t.text, markup)
            }
            const pill = findChild(row, "notificationAction_0")
            verify(pill !== null)
            compare(pill.Accessible.name, markup)
            compare(findChild(row, "notificationActionLabel_0").textFormat, Text.PlainText, "the action's label")
            compare(findChild(row, "notificationActionLabel_0").text, markup)
        }

        // ---- the quiet rules ----

        function test_quiet_mode() {
            openCentre()
            tryVerify(() => find("centreQuiet").activeFocus, 2000, "nothing kept: the focus is on Quiet mode")
            compare(hintText(), "A Toggle, B Close")
            keyClick(Qt.Key_Return)
            tryCompare(NotificationCentre, "quiet", true, 2000, "A on Quiet mode turns it on")
            verify(find("centreQuiet").checked)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet().shown)
            const bell = find("notificationBell")
            compare(findChild(bell, "bellIcon").name, "notifications_paused", "the bell shows quiet mode")
            verify(findChild(bell, "bellIcon").filled)
            verify(bell.Accessible.name.indexOf("quiet mode on") >= 0, bell.Accessible.name)
            const cues = Sfx.notificationCount + Sfx.warningCount
            const quieted = Notifications.quietedCount
            Notifications.show("Controller connected", "success")
            Notifications.show("Low battery", "warning")
            compare(Notifications.model.count, 0, "no toast")
            compare(Notifications.pendingCount, 0, "and none waits for later")
            compare(Sfx.notificationCount + Sfx.warningCount, cues, "no cue")
            compare(Notifications.quietedCount, quieted + 2)
            tryCompare(NotificationCentre, "unreadCount", 2, 2000, "the items are kept and counted")
            verify(findChild(bell, "bellBadge").visible)
            NotificationCentre.setQuiet(false)
            tryCompare(NotificationCentre, "quiet", false)
            compare(findChild(bell, "bellIcon").name, "notifications")
            Notifications.show("Back to normal", "info")
            compare(Notifications.model.count, 1, "toasts again")
        }

        // Review round 2: quiet mode keeps the pinned restart notice in the centre (counted), holds its
        // sticky toast and shows it again when quiet mode ends while the restart is still pending.
        function test_quiet_keeps_pinned_and_brings_the_sticky_back() {
            NotificationCentre.setQuiet(true)
            tryCompare(NotificationCentre, "quiet", true)
            Update.mockAnnounceRestart(Math.floor(Date.now() / 1000) + 120)
            tryVerify(() => NotificationCentre.items.some(i => i.pinned && i.source === "updates"), 2000,
                      "the restart notice is kept, pinned")
            tryCompare(NotificationCentre, "unreadCount", 1, 2000, "and the badge counts it")
            verify(findChild(find("notificationBell"), "bellBadge").visible)
            compare(Notifications.model.count, 0, "no toast in quiet mode")
            NotificationCentre.setQuiet(false)
            tryCompare(NotificationCentre, "quiet", false)
            tryVerify(() => Notifications.model.count === 1 && Notifications.model.get(0).key === "update-restart", 2000,
                      "quiet mode over, the restart notice is on screen again")
            // Quiet mode while it is on screen: it leaves, and comes back.
            NotificationCentre.setQuiet(true)
            tryCompare(NotificationCentre, "quiet", true)
            tryCompare(Notifications.model, "count", 0)
            NotificationCentre.setQuiet(false)
            tryVerify(() => Notifications.model.count === 1 && Notifications.model.get(0).key === "update-restart")
            // The restart is called off during quiet mode: nothing comes back.
            NotificationCentre.setQuiet(true)
            tryCompare(NotificationCentre, "quiet", true)
            Update.mockAnnounceRestart(0)
            tryVerify(() => !NotificationCentre.items.some(i => i.pinned), 2000, "withdrawn")
            NotificationCentre.setQuiet(false)
            tryCompare(NotificationCentre, "quiet", false)
            wait(50)
            compare(Notifications.model.count, 0, "a state that ended does not come back")
        }

        function test_dont_interrupt_games() {
            Notifications.appInFront = true
            const cues = Sfx.notificationCount + Sfx.warningCount
            Notifications.show("Sound moved to TV", "info")
            Notifications.show("Could not switch the audio output.", "warning")
            compare(Notifications.model.count, 0, "with an app in front nothing but critical items shows")
            compare(Notifications.pendingCount, 2, "they wait")
            compare(Sfx.notificationCount + Sfx.warningCount, cues, "and make no sound")
            Notifications.show("Controller battery low", "warning", "", "", "Pad · 5%", { source: "devices", urgency: "critical" })
            compare(Notifications.model.count, 1, "a critical item breaks through")
            compare(Notifications.model.get(0).text, "Controller battery low")
            verify(find("toastLayer").compact, "as the compact toast")
            tryCompare(find("toastList"), "width", 480 * find("toastLayer").u)
            tryCompare(NotificationCentre, "count", 3, 2000, "all three are kept")
            // The Hub over the game: its warnings show (the player is looking at the shell).
            Notifications.overlayOpen = true
            tryVerify(() => Notifications.model.count === 2, 2000, "the warning shows over the Hub")
            Notifications.overlayOpen = false
            clearToasts()
            // Off: warnings and errors show over the app again, the rest waits.
            NotificationCentre.setDontInterruptGames(false)
            tryCompare(NotificationCentre, "dontInterruptGames", false)
            Notifications.show("Could not resume the game.", "warning")
            Notifications.show("Just info", "info")
            compare(Notifications.model.count, 1)
            compare(Notifications.model.get(0).text, "Could not resume the game.")
            Notifications.appInFront = false
            tryVerify(() => Notifications.model.count === 2, 2000, "the info shows when the shell is in front")
            NotificationCentre.setDontInterruptGames(true)
            tryCompare(NotificationCentre, "dontInterruptGames", true)
        }

        // The only controller's low battery is critical; with two pads it is not.
        function test_low_battery_of_the_only_controller_is_critical() {
            Notifications.appInFront = true
            Batteries.mockClear()
            Batteries.mockSet("pad-1", 30, "discharging", "controller", "Pad One")
            Batteries.mockSet("pad-1", 10, "discharging", "controller", "Pad One")
            tryVerify(() => itemTitled("Controller battery low") !== undefined, 2000, "the low battery is kept")
            compare(itemTitled("Controller battery low").urgency, Bluetooth.gamepads.length <= 1 ? "critical" : "normal")
            compare(itemTitled("Controller battery low").source, "devices")
            if (Bluetooth.gamepads.length <= 1)
                tryVerify(() => Notifications.model.count === 1, 2000, "it breaks through over the game")
            Batteries.mockReset()
        }

        function test_saver_holds_toasts() {
            IdleClock.stage = "saver"
            Notifications.show("Drive inserted", "info")
            compare(Notifications.model.count, 0, "nothing is drawn over the saver")
            compare(Notifications.pendingCount, 1, "the toast waits")
            compare(IdleClock.stage, "saver", "and it does not wake the screen")
            tryCompare(NotificationCentre, "unreadCount", 1, 2000, "the item is kept")
            IdleClock.stage = "active"
            tryCompare(Notifications.model, "count", 1, 2000, "the screen is back: the toast shows")
            compare(Notifications.model.get(0).text, "Drive inserted")
        }

        // ---- the centre's focus and keys ----

        function test_centre_focus() {
            // Empty: the focus is on Quiet mode, Up and Down go nowhere, Back closes.
            openCentre()
            tryVerify(() => find("centreQuiet").activeFocus, 2000, "empty: Quiet mode")
            keyClick(Qt.Key_Up)
            verify(find("centreQuiet").activeFocus, "nothing to clear: Up stays")
            keyClick(Qt.Key_Down)
            verify(find("centreQuiet").activeFocus, "no rows: Down stays")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet().shown && find("notificationBell").activeFocus, 2000, "Back from Quiet mode")
            // With rows: the newest has the focus; Up, Up, Down, Down walks Quiet mode and Clear all.
            post("Old", tc.t0 - 1000)
            post("New", tc.t0)
            keyClick(Qt.Key_Return)
            tryVerify(() => sheet().shown)
            tryVerify(() => rowFocused("New"), 2000, "the newest item has the focus")
            keyClick(Qt.Key_Down)
            tryVerify(() => rowFocused("Old"))
            keyClick(Qt.Key_Down)
            verify(rowFocused("Old"), "the last row: Down stays")
            keyClick(Qt.Key_Up)
            tryVerify(() => rowFocused("New"))
            keyClick(Qt.Key_Up)
            tryVerify(() => find("centreQuiet").activeFocus)
            keyClick(Qt.Key_Up)
            tryVerify(() => find("centreClearAll").activeFocus)
            keyClick(Qt.Key_Up)
            verify(find("centreClearAll").activeFocus, "the top: Up stays")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet().shown && find("notificationBell").activeFocus, 2000, "Back from Clear all")
            keyClick(Qt.Key_Return)
            tryVerify(() => rowFocused("New"), 2000, "every opening starts on the first row")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet().shown && find("notificationBell").activeFocus, 2000, "Back from a row")
            // Nothing leaks: the page under the centre did not move.
            compare(tc.shell.currentPage, "")
            // The bell's own keys: Left back to the gear, Down into Home.
            keyClick(Qt.Key_Left)
            tryVerify(() => find("sectionNav").activeFocus && find("sectionNav").currentIndex === 4, 2000, "Left: the gear")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("notificationBell").activeFocus)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Down: Home")
            compare(tc.shell.focusRepairs, 0)
        }

        function test_bell_on_section_pages() {
            keyClick(Qt.Key_Up)
            tryVerify(() => find("sectionNav").activeFocus, 2000)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                 // the gear: Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000, "the page has the focus")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("sectionNav").activeFocus && find("sectionNav").currentIndex === 4, 2000, "Up: the gear")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("notificationBell").activeFocus, 2000, "the bell on a section page")
            keyClick(Qt.Key_Return)
            tryVerify(() => sheet().shown)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !sheet().shown && find("notificationBell").activeFocus)
            keyClick(Qt.Key_Escape)                 // Back on the bell closes the page, as in the nav
            tryCompare(tc.shell, "currentPage", "")
        }

        // Locking (or a switch) closes the centre: the next profile never sees this one's list.
        function test_locking_closes_the_centre() {
            post("Ada's", tc.t0)
            openCentre()
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => !sheet().shown, 2000, "the centre closed with the profile")
            compare(NotificationCentre.count, 0, "and the list is nobody's")
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has the focus")
        }

        // A list reply that was on its way before a clear lands after it: it is dropped, the item stays
        // gone and the focus stays where the clear put it.
        function test_late_reply_guard() {
            post("Second", tc.t0 - 1000)
            post("First", tc.t0)
            openCentre()
            tryVerify(() => rowFocused("First"))
            NotificationCentre.mockRefreshDelayed(400)            // an answer with both items, held back
            compare(NotificationCentre.mockPendingReplies() > 0, true)
            keyClick(Qt.Key_Menu)
            tryVerify(() => itemTitled("First") === undefined, 2000, "the newer list (without First) arrived")
            tryVerify(() => rowFocused("Second"))
            tryVerify(() => NotificationCentre.mockPendingReplies() === 0, 3000, "the late reply has landed")
            compare(itemTitled("First"), undefined, "the late reply did not bring the cleared item back")
            verify(rowFocused("Second"), "nor did it move the focus")
        }

        function test_toast_link_and_overflow_chip() {
            Notifications.show("Update ready. Restart to finish.", "info", "", "download_done", "",
                               { source: "updates", actions: [{ id: "restart", label: "Restart now" }] })
            compare(Notifications.model.get(0).footer, "Restart now is in Notifications")
            const list = find("toastList")
            tryVerify(() => list.itemAtIndex(0) !== null)
            verify(findChild(list.itemAtIndex(0), "toastFooterIcon").visible, "the bell glyph before the link")
            compare(findChild(list.itemAtIndex(0), "toastFooterIcon").name, "notifications")
            for (let i = 0; i < 4; ++i)
                Notifications.show("More " + i, "info")
            tryVerify(() => find("toastOverflow").visible)
            compare(find("toastOverflowText").text, "2 more in Notifications")
        }

        // ---- screenshots ----

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            shots(shotsDir + "/", "", { wallpaper: "Wallpaper added", battery: "Controller battery low", restart: "Restarting in 2 minutes",
                        restartDetail: "To finish the update", restartNow: "Restart now", drive: "Drive inserted",
                        openSettings: "Open Settings", match: "Match found", matchDetail: "Ready in 30 s", join: "Join",
                        later: "Later" })
        }

        function test_zz_screenshots_tr() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.language = "tr"
            shots(shotsDir + "/", "-tr", { wallpaper: "Duvar kağıdı eklendi", battery: "Kumanda pili zayıf", restart: "2 dakikada yeniden başlıyor",
                           restartDetail: "Güncellemeyi bitirmek için", restartNow: "Şimdi yeniden başlat", drive: "Sürücü takıldı",
                           openSettings: "Ayarları aç", match: "Maç bulundu", matchDetail: "30 sn içinde hazır", join: "Katıl",
                           later: "Sonra" })
            DeviceSettings.language = "en"
        }
    }
}
