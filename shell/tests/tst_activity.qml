import QtQuick
import QtTest
import RuyaShell

// The Activity pages (T-247): what the active profile played, on the mock ledger, with the
// controller keys only (arrows, Return = Accept, Escape = Back). The date is fixed
// (2026-11-07, a Saturday) so the numbers are exact. Own file: it fills and clears the mock ledger
// and changes the language, and each file gets a fresh mock.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    SignalSpy { id: clearSpy; target: Usage; signalName: "clearFinished" }

    // An item in the shell's modal layer, as a PIN pad or the keyboard puts there.
    Component {
        id: modalStandIn
        Item { width: 10; height: 10 }
    }

    TestCase {
        id: tc
        name: "Activity"
        when: windowShown

        property Shell shell: null

        readonly property string today: "2026-11-07"
        readonly property string racer: "org.example.Racer"
        readonly property string puzzle: "org.example.Puzzle"
        readonly property string quest: "org.example.Quest"
        readonly property string chess: "org.example.Chess"

        function find(name) { return findChild(tc.shell, name) }
        // The dialog's own buttons (the Power page and the Guide overlay have dialogs of the same names).
        function confirmButton(name) { return findChild(find("activityClearConfirm"), name) }
        function labelOf(name) { return findChild(find(name), "label").text }
        function valueOf(name) { return findChild(find(name), "value").text }

        // One session: `ago` days before today, at hour:minute UTC, `secs` of play.
        function mk(app, ago, hour, minute, secs) {
            const d = new Date(Date.UTC(2026, 10, 7 - ago, hour, minute))
            return { appId: app, start: d.getTime() / 1000, seconds: secs, reason: "quit",
                     day: d.toISOString().slice(0, 10) }
        }

        // The day rows by hand, so the tests do not trust the mock's own sums:
        //   today  Racer 1800 + 2400            week (ago 0..6): 17 700 s
        //   -1     Puzzle 2400 (19:40), Racer 600     the week before (ago 7..13): 4 500 s
        //   -3     Racer 3600      -4  Quest 5700      -6  Racer 1200
        //   -9     Racer 3600      -10 Quest 900       -45 Racer 1000      -70 Chess 3300
        function sessions() {
            return [
                mk(racer, 0, 18, 0, 1800), mk(racer, 0, 20, 0, 2400),
                mk(puzzle, 1, 19, 40, 2400), mk(racer, 1, 12, 0, 600),
                mk(racer, 3, 17, 0, 3600),
                mk(quest, 4, 15, 0, 5700),
                mk(racer, 6, 16, 0, 1200),
                mk(racer, 9, 18, 0, 3600), mk(quest, 10, 14, 0, 900),
                mk(racer, 45, 18, 0, 1000),
                mk(chess, 70, 16, 0, 3300)
            ]
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            Usage.mockReset()
            Usage.mockRefreshDelayed(0)
            DeviceSettings.language = "en"
            clearSpy.clear()
        }

        function cleanup() {
            Store.mockPauseJobs(false)                   // a job started by a test (an update of Chess) ends
            Store.mockReset()
            Usage.mockRefreshDelayed(0)
            DeviceSettings.language = "en"
            DeviceSettings.reducedMotion = false
        }

        function startShell() {
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => find("profileList") !== null && find("profileList").activeFocus, 2000, "picker has focus")
        }

        function signInAda() {
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function goToRow(name) {
            for (let i = 0; i < 60; ++i) {
                const row = find(name)
                if (row && row.activeFocus)
                    return
                keyClick(Qt.Key_Down)
            }
            verify(false, "could not reach " + name)
        }

        // Home -> Settings -> My profile -> Activity, with the keys; the data is set before.
        function openActivity(data) {
            Usage.mockSetData("p2", data, today)
            startShell()
            signInAda()
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList") !== null && find("categoryList").activeFocus)
            keyClick(Qt.Key_Right)                       // into the My profile pane (Ada is a standard profile)
            tryVerify(() => find("paneMyProfile").focusableRows().some(r => r.activeFocus), 2000, "a row has focus")
            goToRow("rowActivity")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "activity")
            tryCompare(Usage, "ready", true)
        }

        // ---- the words ----

        // The hints drawn by the bar, "A Select|B Cancel" (T-285).
        function barHints() {
            const bar = find("hintBar")
            const parts = []
            for (const b of ["Left/Right", "A", "B", "Start"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        function test_durations_in_plain_words() {
            compare(DurationText.plain(0), "0 min")
            compare(DurationText.plain(20), "Under 1 min")
            compare(DurationText.plain(30), "1 min")
            compare(DurationText.plain(2700), "45 min")
            compare(DurationText.plain(3600), "1 h")
            compare(DurationText.plain(4800), "1 h 20 min")
            compare(DurationText.plain(7260), "2 h 1 min")
            compare(DurationText.plain(3599), "1 h", "rounds to the nearest minute")
            compare(DurationText.plain(-5), "0 min")
        }

        function test_durations_follow_turkish_word_order_and_units() {
            DeviceSettings.language = "tr"
            compare(DurationText.plain(4800), "1 sa 20 dk")
            compare(DurationText.plain(2700), "45 dk")
            compare(DurationText.plain(7200), "2 sa")
            compare(DurationText.dayWord(1, "2026-11-06"), "Dün")
            DeviceSettings.language = "en"
            compare(DurationText.plain(4800), "1 h 20 min")
        }

        // ---- the numbers (no UI) ----

        function test_the_week_the_top_list_and_the_highlights_are_computed_from_the_rows() {
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            Usage.mockSetData("p2", sessions(), today)
            Usage.refresh()
            tryCompare(Usage, "ready", true)
            const w = Usage.week
            compare(w.days.map(d => d.seconds), [1200, 0, 5700, 3600, 0, 3000, 4200])
            compare(w.days.map(d => d.day)[6], "2026-11-07")
            compare(w.days.map(d => d.today), [false, false, false, false, false, false, true])
            compare(w.days.map(d => d.dow), [7, 1, 2, 3, 4, 5, 6])
            compare(w.total, 17700)
            compare(w.previous, 4500)
            compare(w.activeDays, 5)
            // The top five of the last 30 days: Racer 13 200, Quest 6 600, Puzzle 2 400. The old
            // Chess games (70 days ago) and the Racer session 45 days ago are outside the window.
            compare(Usage.top.map(t => t.appId), [racer, quest, puzzle])
            compare(Usage.top.map(t => t.seconds), [13200, 6600, 2400])
            const h = Usage.highlights
            compare(h.longestMonth.appId, quest)
            compare(h.longestMonth.seconds, 5700)
            compare(h.streak, 2)
            compare(h.lapsed.length, 1)
            compare(h.lapsed[0].appId, chess)
            compare(h.lapsed[0].days, 70)
        }

        function test_history_is_grouped_by_day_newest_first() {
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            Usage.mockSetData("p2", sessions(), today)
            Usage.refresh()
            tryCompare(Usage, "ready", true)
            const hist = Usage.history
            compare(hist[0].kind, "day")
            compare(hist[0].day, "2026-11-07")
            compare(hist[0].seconds, 4200)
            compare(hist[1].kind, "session")
            compare(hist[1].appId, racer)
            compare(hist[1].seconds, 2400, "the later session of the day first")
            compare(hist[2].seconds, 1800)
            compare(hist[3].kind, "day")
            compare(hist[3].day, "2026-11-06")
            compare(hist[3].seconds, 3000)
            compare(hist[4].appId, puzzle, "19:40 comes before 12:00")
            compare(hist[5].appId, racer)
            const days = hist.filter(x => x.kind === "day").map(x => x.day)
            compare(days.slice(0, 5), ["2026-11-07", "2026-11-06", "2026-11-04", "2026-11-03", "2026-11-01"])
            compare(hist.filter(x => x.kind === "session").length, 11)
        }

        function test_one_games_numbers() {
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            Usage.mockSetData("p2", sessions(), today)
            Usage.refresh()
            tryCompare(Usage, "ready", true)
            const g = Usage.game(racer)
            compare(g.total, 14200)
            compare(g.sessions, 7)
            compare(g.longest, 3600)
            compare(g.average, 2028)
            compare(g.playedDays, 6)
            compare(g.first, mk(racer, 45, 18, 0, 1000).start)
            compare(g.last, mk(racer, 0, 20, 0, 2400).start + 2400)
            compare(g.strip.length, 30)
            compare(g.strip[29], 4200, "today is the last bar")
            compare(g.strip[28], 600)
            compare(g.strip[26], 3600)
            compare(g.strip.reduce((a, b) => a + b, 0), 13200, "the strip holds the last 30 days only")
            compare(Usage.game("org.example.Nothing").total, 0)
            compare(Usage.game("org.example.Nothing").average, 0)
        }

        // ---- the page, with the keys ----

        function test_the_week_chart_and_its_text_alternative() {
            openActivity(sessions())
            tryVerify(() => find("activityWeek").activeFocus, 2000, "the chart row has focus first")
            const chart = find("chart")
            compare(chart.values, [1200, 0, 5700, 3600, 0, 3000, 4200])
            compare(chart.labels, ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"])
            compare(chart.summary, "Sun 20 min, Mon 0 min, Tue 1 h 35 min, Wed 1 h, Thu 0 min, Fri 50 min, Sat 1 h 10 min")
            compare(find("activityWeek").accessibleValue.indexOf("4 h 55 min, 3 h 40 min more than the week before. Sun 20 min"), 0)
            compare(findChild(find("activityWeek"), "chartHeadline").text, "4 h 55 min")
            compare(findChild(find("activityWeek"), "chartCaption").text, "3 h 40 min more than the week before.")
            compare(chart.highlightIndex, 6)
            compare(findChild(chart, "chartBar_6").color, Theme.primaryFill, "today is highlighted")
            compare(findChild(chart, "chartBar_5").color, Theme.text)
            compare(findChild(chart, "chartBar_5").opacity, 0.7, "bars are text at 70 %, today at full")
            compare(findChild(chart, "chartBar_6").opacity, 1)
            compare(findChild(chart, "chartLabel_5").color, Theme.text, "labels are text, not textDim (glass)")
            // Heights follow the values (after the bars have grown).
            tryVerify(() => findChild(chart, "chartBar_2").height > findChild(chart, "chartBar_3").height
                            && findChild(chart, "chartBar_3").height > findChild(chart, "chartBar_0").height
                            && findChild(chart, "chartBar_0").height > findChild(chart, "chartBar_1").height)
            compare(findChild(chart, "chartBar_1").height, findChild(chart, "chartBar_4").height, "zero bars are equal stubs")
        }

        function test_the_chart_reads_a_bar_with_left_and_right() {
            openActivity(sessions())
            tryVerify(() => find("activityWeek").activeFocus)
            const chart = find("chart")
            compare(chart.currentIndex, 6, "starts on today")
            compare(findChild(chart, "chartReadout").text, "Sat 1 h 10 min")
            keyClick(Qt.Key_Left)
            compare(chart.currentIndex, 5)
            compare(findChild(chart, "chartReadout").text, "Fri 50 min")
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            compare(findChild(chart, "chartReadout").text, "Wed 1 h")
            keyClick(Qt.Key_Right)
            compare(findChild(chart, "chartReadout").text, "Thu 0 min")
            for (let i = 0; i < 5; ++i)
                keyClick(Qt.Key_Right)
            compare(chart.currentIndex, 6, "clamped at today")
            for (let i = 0; i < 10; ++i)
                keyClick(Qt.Key_Left)
            compare(chart.currentIndex, 0, "clamped at the first day")
            verify(find("activityWeek").activeFocus, "Left and Right never leave the row")
            compare(tc.shell.currentPage, "activity", "and never go back")
            keyClick(Qt.Key_Down)
            verify(find("activityTop_0").activeFocus)
            keyClick(Qt.Key_Up)
            verify(find("activityWeek").activeFocus)
            compare(chart.currentIndex, 6, "back on the row it starts on today again")
        }

        function test_most_played_in_order_and_the_game_page() {
            openActivity(sessions())
            tryVerify(() => find("activityWeek").activeFocus)
            compare(find("activityTop_2") !== null, true)
            compare(find("activityTop_3"), null, "only three games were played in 30 days")
            compare(labelOf("activityTop_0"), "Turbo Racer")
            compare(labelOf("activityTop_1"), "Quest")
            compare(labelOf("activityTop_2"), Store.app(puzzle).name)
            compare(valueOf("activityTop_0"), "3 h 40 min, last played today")
            compare(valueOf("activityTop_1"), "1 h 50 min, last played Tue 3 Nov")
            keyClick(Qt.Key_Down)
            verify(find("activityTop_0").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "activityGame")
            compare(tc.shell.currentParams.appId, racer)
            tryVerify(() => find("gameTotal") !== null && find("gameTotal").visible)
            compare(valueOf("gameTotal"), "3 h 57 min")
            compare(valueOf("gameSessions"), "7")
            compare(valueOf("gameLongest"), "1 h")
            compare(valueOf("gameAverage"), "34 min")
            compare(valueOf("gameLast"), "Today")
            verify(find("gameStrip").visible)
            verify(findChild(find("gameHeadStrip"), "groupLabelText"), "Last 30 days is a GroupLabel")
            verify(find("gameTotal").activeFocus, "the first row has focus")
            compare(barHints(), "B Back", "a fact row only reads")
            for (const n of ["gameTotal", "gameSessions", "gameFirst", "gameLast", "gameLongest", "gameAverage"])
                compare(find(n).kind, "info", n)
            find("gameStrip").forceActiveFocus()
            tryVerify(() => find("gameStrip").activeFocus)
            compare(barHints(), "Left/Right Browse|B Back", "the 30-day strip is read with Left and Right (T-285)")
            const strip = findChild(find("gameStrip"), "chart")
            compare(strip.values.length, 30)
            compare(strip.highlightIndex, 29)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "activity")
            tryVerify(() => find("activityTop_0").activeFocus, 2000, "focus is back on the game that was opened")
        }

        function test_highlights_and_history_rows() {
            openActivity(sessions())
            tryVerify(() => find("activityWeek").activeFocus)
            compare(labelOf("activityLongest"), "Longest session this month")
            compare(find("activityLongest").kind, "info")
            compare(find("activityStreak").kind, "info")
            compare(find("activityClear").kind, "action")
            compare(find("activityTop_0").kind, "page")
            verify(findChild(find("activityHeadTop"), "groupLabelText"), "Most played is a GroupLabel")
            verify(findChild(find("activityHeadHighlights"), "groupLabelText"), "Highlights is a GroupLabel")
            compare(valueOf("activityLongest"), "Quest, 1 h 35 min")
            compare(labelOf("activityStreak"), "You have played 2 days in a row.")
            compare(labelOf("activityLapsed_0"), "You have not played Open Chess for 70 days.")
            compare(findChild(tc.shell, "activityDay_2026-11-07").text, "Today, 1 h 10 min")
            compare(findChild(tc.shell, "activityDay_2026-11-06").text, "Yesterday, 50 min")
            const puzzleStart = mk(puzzle, 1, 19, 40, 2400).start
            const row = find("activitySession_" + puzzle + "_" + puzzleStart)
            verify(row !== null, "the Puzzle session of yesterday is a row")
            compare(findChild(row, "value").text, TimeZone.formatClock(puzzleStart * 1000) + ", 40 min")
            // The same row opens the game's page.
            goToRow("activitySession_" + puzzle + "_" + puzzleStart)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "activityGame")
            compare(tc.shell.currentParams.appId, puzzle)
        }

        function test_one_day_in_a_row_is_not_a_streak_and_nothing_old_is_not_a_lapse() {
            openActivity([mk(racer, 0, 18, 0, 1800), mk(racer, 2, 18, 0, 1800)])
            tryVerify(() => find("activityWeek").activeFocus)
            compare(Usage.highlights.streak, 0)
            verify(!find("activityStreak").visible)
            verify(!find("activityLapsed_0"))
            verify(!find("activityHeadHighlights").visible || find("activityLongest").visible)
            compare(findChild(find("activityWeek"), "chartCaption").text, "Nothing played the week before.")
        }

        function test_empty_state_for_a_new_profile() {
            openActivity([])
            verify(Usage.empty)
            verify(find("activityMessage").visible)
            verify(find("activityMessage").text.indexOf("Nothing here yet") === 0)
            verify(!find("activityWeek").visible)
            verify(!find("activityClear").visible)
            compare(find("activityTop_0"), null)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
        }

        function test_a_failed_read_says_so_and_back_still_works() {
            Usage.mockSetData("p2", sessions(), today)
            startShell()
            signInAda()
            Usage.mockFailNextRefresh("failed")
            tc.shell.openPage("activity", {})
            tryCompare(tc.shell, "currentPage", "activity")
            tryCompare(Usage, "status", "failed")
            verify(!Usage.ready)
            verify(find("activityMessage").visible)
            compare(find("activityMessage").text, "Your activity could not be read.")
            verify(!find("activityWeek").visible, "no stale numbers")
            keyClick(Qt.Key_Escape)
            tryVerify(() => tc.shell.currentPage !== "activity")
        }

        function test_clear_my_activity_asks_first_and_clears_only_this_profile() {
            Usage.mockSetData("p1", [mk(racer, 0, 10, 0, 900)], today)
            openActivity(sessions())
            goToRow("activityClear")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("activityClearConfirm").shown)
            verify(confirmButton("powerCancel").activeFocus, "Cancel has focus first")
            // Back keeps everything.
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("activityClearConfirm").shown)
            verify(find("activityClear").activeFocus, "focus is back on the row")
            compare(clearSpy.count, 0)
            verify(!Usage.empty)
            // Accept on the confirm button clears.
            keyClick(Qt.Key_Return)
            tryVerify(() => find("activityClearConfirm").shown)
            keyClick(Qt.Key_Right)
            verify(confirmButton("powerConfirm").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(clearSpy, "count", 1)
            compare(clearSpy.signalArguments[0][0], "ok")
            tryVerify(() => Usage.empty)
            tryVerify(() => find("activityMessage").visible)
            verify(!find("activityClear").visible)
            compare(tc.shell.currentPage, "activity", "stays on the page")
            // The other profile's ledger was not touched.
            Profiles.lock()
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            Usage.refresh()
            tryVerify(() => Usage.ready && !Usage.empty)
            compare(Usage.top.length, 1)
        }

        function test_a_refused_clear_keeps_the_data_and_says_so() {
            openActivity(sessions())
            Usage.mockFailNextClear("failed")
            goToRow("activityClear")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("activityClearConfirm").shown)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(clearSpy, "count", 1)
            compare(clearSpy.signalArguments[0][0], "failed")
            verify(!Usage.empty, "the data is still there")
            verify(find("activityClear").visible)
        }

        // ---- the app page ----

        function test_the_app_page_has_a_your_activity_button() {
            Usage.mockSetData("p2", sessions(), today)
            startShell()
            signInAda()
            tryVerify(() => Store.catalogue.length > 0)
            tc.shell.openPage("appDetail", { appId: chess })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
            verify(find("detailActivity").visible)
            keyClick(Qt.Key_Down)
            verify(find("detailUninstall").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("detailActivity").activeFocus)
            keyClick(Qt.Key_Up)
            verify(find("detailUninstall").activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "activityGame")
            compare(tc.shell.currentParams.appId, chess)
            tryCompare(Usage, "ready", true)
            tryVerify(() => find("gameTotal").visible)
            compare(valueOf("gameTotal"), "55 min")
            compare(valueOf("gameLast"), "29 Aug 2026")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailActivity").activeFocus, 2000, "focus is back on the button")
        }

        // The item with the active focus and its parents, for failure messages.
        function describeFocus() {
            const f = tc.shell.Window.window.activeFocusItem
            let s = ""
            for (let p = f; p; p = p.parent)
                s += (p.objectName || String(p)) + (p.visible ? "" : "[hidden]") + (p.enabled ? "" : "[disabled]") + " < "
            return s || "nothing"
        }

        function slotFaded(key) {
            const s = find("pageSlot_" + key)
            return s !== null && !s.visible
        }

        // Once the page below has faded out (its items hide then, T-356): the active focus is a
        // visible item of the page on top.
        function verifyFocusOnTop(below, what) {
            tryVerify(() => slotFaded(below), 2000, below + " has faded out")
            const top = tc.shell.slots[tc.shell.slots.length - 1]
            const f = tc.shell.Window.window.activeFocusItem
            let inside = false
            for (let p = f; p; p = p.parent)
                inside = inside || p === top.page
            verify(inside && f.visible && f.enabled, what + ": " + describeFocus())
        }

        // The owner's path on the Dell (2026-11-09): Store -> an installed game without stats ->
        // "Your activity". The app page, covered by the activity page, hid its buttons when its fade-out
        // ended, and their handler forced the focus back into the covered page: every key was lost.
        function test_the_store_path_to_a_game_page_keeps_the_focus() {
            Usage.mockSetData("p2", [], today)
            startShell()
            signInAda()
            tryVerify(() => Store.catalogue.length > 0)
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Store
            tryCompare(tc.shell, "currentPage", "store")
            tryVerify(() => find("storeCards_featured") && find("storeCards_featured").activeFocus, 2000)
            const installed = find("storeCards_installed")
            for (let i = 0; i < 10 && !installed.activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(installed.activeFocus, describeFocus())
            compare(installed.model[installed.currentIndex], puzzle)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary").activeFocus, 2000)
            verifyFocusOnTop("store", "the app page over the Store")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("detailActivity").activeFocus, describeFocus())
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "activityGame")
            tryVerify(() => find("gameMessage").visible)
            verifyFocusOnTop("appDetail", "the activity page over the app page")
            compare(tc.shell.Window.window.activeFocusItem, find("gameBody"), "no row to focus: the pane holds it")
            keyClick(Qt.Key_Down)                        // nothing to move to
            verify(find("gameBody").activeFocus, describeFocus())
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailActivity").activeFocus, 2000, "focus is back on the button")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "store")
            tryVerify(() => installed.activeFocus, 2000, "and on the card")
            compare(tc.shell.focusRepairs, 0, "the pages kept the focus themselves")
        }

        // "Your activity" hides while the activity page covers the app page (an update started): Back
        // lands on the primary button, not on the hidden one that had the focus.
        function test_back_to_the_app_page_skips_a_button_hidden_meanwhile() {
            Usage.mockSetData("p2", sessions(), today)
            startShell()
            signInAda()
            tryVerify(() => Store.catalogue.length > 0)
            tc.shell.openPage("appDetail", { appId: chess })
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("detailActivity").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "activityGame")
            verifyFocusOnTop("appDetail", "the game page")
            Store.update(chess)
            tryVerify(() => Store.jobs[chess] !== undefined, 2000, "progress arrived")
            Store.mockPauseJobs(true)                    // the update stands still
            tryVerify(() => !find("detailActivity").visible)
            verify(find("gameBody").activeFocus, "the covered page leaves the focus alone: " + describeFocus())
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            verify(!find("detailActivity").visible)
            tryVerify(() => find("detailPrimary").activeFocus, 2000, "the primary button: " + describeFocus())
            compare(tc.shell.focusRepairs, 0)
        }

        // A failed read hides every row of the Activity page: the pane holds the focus itself (never a
        // hidden row), and Back leaves.
        function test_the_activity_page_after_a_failed_read_holds_the_focus_and_leaves() {
            Usage.mockSetData("p2", sessions(), today)
            startShell()
            signInAda()
            Usage.mockFailNextRefresh("failed")
            tc.shell.openPage("activity")
            tryCompare(tc.shell, "currentPage", "activity")
            tryCompare(Usage, "status", "failed")
            verify(!find("activityWeek").visible)
            tryVerify(() => tc.shell.Window.window.activeFocusItem === find("activityBody"), 2000,
                      "the pane, not a hidden row: " + describeFocus())
            keyClick(Qt.Key_Down)
            verify(find("activityBody").activeFocus, describeFocus())
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homePlay").activeFocus, 2000, "back on Home")
            compare(tc.shell.focusRepairs, 0)
        }

        // The shell's safety net: a covered page that takes the focus anyway loses it again to the
        // page on top, and the keys work.
        function test_a_covered_page_that_takes_the_focus_gives_it_back() {
            openActivity(sessions())
            tc.shell.openPage("activityGame", { appId: chess })
            tryCompare(tc.shell, "currentPage", "activityGame")
            verifyFocusOnTop("activity", "the game page")
            compare(tc.shell.focusRepairs, 0)
            find("activityBody").forceActiveFocus()      // the Activity page below grabs it
            tryVerify(() => find("gameBody").activeFocus, 2000, "the shell gives it back")
            compare(tc.shell.focusRepairs, 1)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "activity")
        }

        // Found on the Dell (2026-11-09): app page -> "Your activity" of an app with no stats at all,
        // then neither the pad's B nor Esc left the page (the Guide overlay did, and closing it
        // gave the keys back): the page must own the focus whatever the data is.
        function test_the_app_page_to_a_game_with_no_stats_and_back() {
            Usage.mockSetData("p2", [], today)
            startShell()
            signInAda()
            tryVerify(() => Store.catalogue.length > 0)
            tc.shell.openPage("appDetail", { appId: chess })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("detailActivity").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "activityGame")
            tryVerify(() => find("gameMessage").visible)
            tryVerify(() => find("gameBody").activeFocus, 2000, "the page owns the focus although it has no rows")
            verifyFocusOnTop("appDetail", "and keeps it once the app page has faded out")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailActivity").activeFocus, 2000, "focus is back on the button")
            compare(tc.shell.focusRepairs, 0, "the pages kept the focus themselves")
        }

        // The same path while the usage service answers late or with an error: the page has no rows
        // at all, and Back must still leave it.
        function test_the_game_page_leaves_with_back_while_the_usage_service_is_slow_or_failing() {
            Usage.mockSetData("p2", sessions(), today)
            startShell()
            signInAda()
            tryVerify(() => Store.catalogue.length > 0)
            Usage.mockRefreshDelayed(400)
            tc.shell.openPage("appDetail", { appId: chess })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "activityGame")
            tryVerify(() => find("gameBody").activeFocus, 2000, "the page owns the focus before the data arrives")
            verifyFocusOnTop("appDetail", "and once the app page has faded out")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailActivity").activeFocus, 2000, "focus is back on the button")
            Usage.mockFailNextRefresh("failed")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "activityGame")
            tryVerify(() => find("gameBody").activeFocus, 2000, "and after a failed read")
            verifyFocusOnTop("appDetail", "and once the app page has faded out again")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "appDetail")
            compare(tc.shell.focusRepairs, 0, "the pages kept the focus themselves")
        }

        // The safety net stays out while anything in the modal layer shows (a PIN pad, the keyboard,
        // a dialog: the focus is that modal's business, even between two steps of a flow).
        function test_the_safety_net_stays_out_while_a_modal_shows() {
            openActivity(sessions())
            tc.shell.openPage("activityGame", { appId: chess })
            tryCompare(tc.shell, "currentPage", "activityGame")
            verifyFocusOnTop("activity", "the game page")
            const modal = createTemporaryObject(modalStandIn, find("modalLayer"))
            verify(modal && modal.visible)
            find("activityBody").forceActiveFocus()      // the covered page takes it (as between two modal steps)
            verify(!tc.shell.focusIsLost(), "a modal shows: not lost")
            modal.visible = false
            verify(tc.shell.focusIsLost(), "no modal: lost")
            find("activityWeek").forceActiveFocus()      // a focus change runs the check
            tryVerify(() => find("gameBody").activeFocus, 2000, "repaired once no modal shows")
            compare(tc.shell.focusRepairs, 1)
        }

        function test_a_game_never_played_says_so() {
            openActivity(sessions())
            tc.shell.openPage("activityGame", { appId: "org.example.Editor" })
            tryCompare(tc.shell, "currentPage", "activityGame")
            tryVerify(() => find("gameMessage").visible)
            verify(find("gameMessage").text.indexOf("You have not played this yet") === 0)
            verify(!find("gameTotal").visible)
            verify(!find("gameStrip").visible)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "activity")
        }

        // ---- privacy and late replies ----

        function test_another_profiles_history_never_shows() {
            Usage.mockSetData("p2", sessions(), today)
            Usage.mockSetData("p1", [mk(chess, 0, 9, 0, 600)], today)
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            Usage.refresh()
            tryCompare(Usage, "ready", true)
            compare(Usage.top.length, 3)
            // Switching forgets everything at once: nothing of the old profile stays on screen.
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryCompare(Usage, "ready", false)
            compare(Usage.top.length, 0)
            compare(Usage.week.total, 0)
            verify(Usage.empty)
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            Usage.refresh()
            tryCompare(Usage, "ready", true)
            compare(Usage.top.map(t => t.appId), [chess])
        }

        // The reply of a read for p2 lands while nobody is active: it must show nothing. (Without the
        // profile check in Usage::onLoaded, p2's reply is accepted as the newest and fills the page.)
        function test_a_reply_for_the_old_profile_is_dropped_when_nobody_is_active() {
            Usage.mockSetData("p2", sessions(), today)
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            Usage.mockRefreshDelayed(300)
            Usage.refresh()
            verify(Usage.mockPendingReplies() > 0)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryCompare(Usage, "ready", false)
            tryVerify(() => Usage.mockPendingReplies() === 0, 3000, "the late reply has landed")
            wait(100)
            verify(!Usage.ready, "p2's reply did not make the page ready")
            compare(Usage.top.length, 0)
            compare(Usage.week.total, 0)
            verify(Usage.empty)
        }

        // p2's reply lands (after 100 ms) while p1 is active and p1's own read is still on its way
        // (800 ms): p2's play must not show in between.
        function test_a_reply_for_the_old_profile_is_dropped_after_a_switch() {
            Usage.mockSetData("p2", sessions(), today)
            Usage.mockSetData("p1", [mk(chess, 0, 9, 0, 600)], today)
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            Usage.mockRefreshDelayed(100)
            Usage.refresh()
            Usage.mockRefreshDelayed(800)
            Profiles.lock()
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            wait(400)                                   // p2's reply has landed, p1's has not
            verify(Usage.mockPendingReplies() > 0, "p1's read is still pending")
            verify(!Usage.ready, "nothing shows before p1's own reply")
            compare(Usage.top.length, 0)
            tryCompare(Usage, "ready", true, 3000)
            compare(Usage.top.map(t => t.appId), [chess], "only the active profile's data shows")
            compare(Usage.mockPendingReplies(), 0)
        }

        function test_a_late_reply_does_not_replace_a_newer_one() {
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            Usage.mockSetData("p2", [mk(racer, 0, 9, 0, 600)], today)
            Usage.mockRefreshDelayed(400)
            Usage.refresh()                                     // the old data, slow
            Usage.mockSetData("p2", [mk(racer, 0, 9, 0, 3600)], today)
            Usage.mockRefreshDelayed(0)
            Usage.refresh()                                     // the new data, quick
            tryCompare(Usage, "ready", true)
            tryVerify(() => Usage.week.total === 3600)
            wait(600)                                           // the slow reply lands and is dropped
            compare(Usage.week.total, 3600)
            compare(Usage.mockPendingReplies(), 0)
        }

        function test_the_ledger_is_read_again_when_the_service_says_it_changed() {
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
            Usage.mockSetData("p2", [mk(racer, 0, 9, 0, 600)], today)
            Usage.refresh()
            tryVerify(() => Usage.week.total === 600)
            Usage.mockSetData("p2", [mk(racer, 0, 9, 0, 1200)], today)
            Usage.mockTouch("p1")                               // someone else's: ignored
            wait(50)
            compare(Usage.week.total, 600)
            Usage.mockTouch("p2")                               // UsageChanged
            tryVerify(() => Usage.week.total === 1200)
        }

        // ---- the shell tells the service who is in front ----

        function test_presence_is_reported_on_every_change() {
            startShell()
            const presence = find("usagePresence")
            verify(presence, "the shell has a presence reporter")
            compare(presence.attention, "locked", "nobody is signed in")
            tryCompare(presence, "attention", "locked")
            signInAda()
            tryVerify(() => Usage.mockLastPresence().attention === "active")
            compare(Usage.mockLastPresence().profile, "p2")
            compare(Usage.mockLastPresence().instance, "", "the shell is in front")
            // An app comes to the front: its instance is reported.
            Session.launch("org.example.Racer", "p2")
            tryVerify(() => Session.instanceOf("org.example.Racer", "p2").state === "running")
            const instance = Session.instanceOf("org.example.Racer", "p2").instance
            const item = createTemporaryObject(appStandIn, host)
            tc.shell.addApp(item)
            tryVerify(() => Usage.mockLastPresence().instance === instance)
            // The Guide overlay covers the app: it is not in front any more.
            keyClick(Qt.Key_HomePage)
            tryVerify(() => tc.shell.foregroundInstance === "")
            tryVerify(() => Usage.mockLastPresence().instance === "")
            keyClick(Qt.Key_Escape)
            tryVerify(() => Usage.mockLastPresence().instance === instance)
            // Locking says "locked".
            Profiles.lock()
            tryVerify(() => Usage.mockLastPresence().attention === "locked")
            tc.shell.removeApp(item)
            Session.stop(instance)
        }

        function test_no_input_for_a_while_is_reported_as_idle_and_input_ends_it() {
            startShell()
            signInAda()
            const presence = find("usagePresence")
            tryVerify(() => Usage.mockLastPresence().attention === "active")
            presence.idleSeconds = 600
            const start = Date.now()
            let fake = start
            IdleClock.now = () => fake
            IdleClock.reset()
            // The clock moves a minute at a time, as the real timer looks at it (a bigger gap is a sleep).
            for (let s = 60; s <= 540; s += 60) {
                fake = start + s * 1000
                presence.check()
            }
            fake = start + 599000
            presence.check()
            compare(presence.attention, "active", "599 s of silence is not idle yet")
            fake = start + 601000
            presence.check()
            compare(presence.attention, "idle")
            IdleClock.now = () => MonotonicClock.ms()
            tryVerify(() => Usage.mockLastPresence().attention === "idle")
            keyClick(Qt.Key_Left)                              // any input
            tryCompare(presence, "attention", "active")
            tryVerify(() => Usage.mockLastPresence().attention === "active")
        }

        function test_presence_is_repeated_while_nothing_changes() {
            startShell()
            signInAda()
            const presence = find("usagePresence")
            const beat = findChild(presence, "presenceBeat")
            verify(beat.running)
            compare(beat.interval, 20000, "less than the service's 75 s freshness window")
            const before = Usage.mockPresenceCount()
            beat.triggered()
            compare(Usage.mockPresenceCount(), before + 1)
        }

        // ---- screenshots (dev.ps1 shots) ----

        function settle() {
            wait(800)
            grabImage(tc.shell)                              // the first grab can be of the frame before the last change
            wait(400)
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            // The final state of the picture, not a fade: without animations it does not depend on how fast the window renders.
            DeviceSettings.reducedMotion = true
            openActivity(sessions())
            tryVerify(() => find("activityWeek").activeFocus)
            keyClick(Qt.Key_Left)                            // reading Friday
            settle()
            grabImage(tc.shell).save(shotsDir + "/90-activity-week-en.png")
            goToRow("activityLongest")
            settle()
            grabImage(tc.shell).save(shotsDir + "/90-activity-highlights-en.png")
            goToRow("activityClear")
            settle()
            grabImage(tc.shell).save(shotsDir + "/90-activity-history-en.png")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("activityClearConfirm").shown)
            tryCompare(find("activityClearConfirm"), "opacity", 1, 10000)
            settle()
            grabImage(tc.shell).save(shotsDir + "/90-activity-clear-confirm-en.png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("activityClearConfirm").shown)
            tc.shell.openPage("activityGame", { appId: racer })
            tryCompare(tc.shell, "currentPage", "activityGame")
            tryVerify(() => find("gameStrip").visible)
            keyClick(Qt.Key_Down)
            settle()
            grabImage(tc.shell).save(shotsDir + "/90-activity-game-en.png")
            goToRow("gameStrip")
            settle()
            grabImage(tc.shell).save(shotsDir + "/90-activity-game-strip-en.png")
            DeviceSettings.language = "tr"
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "activity")
            tryVerify(() => find("activityWeek").visible)
            for (let i = 0; i < 60 && !find("activityWeek").activeFocus; ++i)
                keyClick(Qt.Key_Up)
            verify(find("activityWeek").activeFocus)
            settle()
            grabImage(tc.shell).save(shotsDir + "/90-activity-week-tr.png")
            tc.shell.openPage("activityGame", { appId: racer })
            tryCompare(tc.shell, "currentPage", "activityGame")
            settle()
            grabImage(tc.shell).save(shotsDir + "/90-activity-game-tr.png")
            DeviceSettings.language = "en"
        }

        function test_zz_screenshots_empty() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.reducedMotion = true
            openActivity([])
            settle()
            grabImage(tc.shell).save(shotsDir + "/90-activity-empty-en.png")
        }

        function test_zz_screenshots_app_page() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.reducedMotion = true
            Usage.mockSetData("p2", sessions(), today)
            startShell()
            signInAda()
            tryVerify(() => Store.catalogue.length > 0)
            tc.shell.openPage("appDetail", { appId: chess })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("detailActivity").activeFocus)
            settle()
            grabImage(tc.shell).save(shotsDir + "/90-activity-app-page-en.png")
        }

        Component {
            id: appStandIn
            Item { focus: true }
        }
    }
}
