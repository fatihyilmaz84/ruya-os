import QtQuick
import QtTest
import RuyaShell

// Settings page and the reusable controls. Driven with controller keys only (arrows,
// Return = Accept, Escape = Back). Signs in as "Ada" (p2, no PIN) and opens the Settings
// tile. DeviceSettings is in-memory under test and restored after every test.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test-1.2.3"; focus: true }
    }

    // Controls under test, standalone (no pane around them).
    Component { id: toggleComponent; ToggleRow { label: "Toggle"; width: 700 } }
    Component {
        id: choiceComponent
        ChoiceRow {
            label: "Choice"
            width: 700
            options: [{ value: "a", label: "A" }, { value: "b", label: "B" }, { value: "c", label: "C" }]
            value: "a"
        }
    }
    Component { id: sliderComponent; SliderRow { label: "Slider"; width: 700; from: 0; to: 3; stepSize: 1; value: 1 } }
    Component { id: plainComponent; SettingRow { label: "Plain"; width: 700; value: "x" } }
    // A bare pane of six rows, the last two hidden (T-190): "late" rows appear below the focus.
    Component {
        id: barePaneComponent
        SettingsPane {
            width: 700
            height: 384                          // four rows (84) and three gaps (16)
            SettingRow { objectName: "r0"; label: "Row 0" }
            SettingRow { objectName: "r1"; label: "Row 1" }
            SettingRow { objectName: "r2"; label: "Row 2" }
            SettingRow { objectName: "r3"; label: "Row 3" }
            SettingRow { objectName: "r4"; label: "Row 4"; visible: false }
            SettingRow { objectName: "r5"; label: "Row 5"; visible: false }
        }
    }

    // The row kinds (RUY-512), standalone.
    Component { id: factComponent; SettingRow { label: "Fact"; kind: "info"; width: 700; value: "x" } }
    Component { id: pageComponent; SettingRow { label: "Page"; kind: "page"; width: 700; value: "Default" } }
    Component { id: actionComponent; SettingRow { label: "Scan for networks"; kind: "action"; width: 700 } }
    Component { id: currentComponent; SettingRow { label: "Analog output"; width: 700; value: "Current" } }
    Component { id: messageComponent; SettingRow { label: "Sleep is not available"; width: 700; enabled: false } }
    // A pane with one row of every kind and a group label (hints, hairlines, Up/Down).
    Component {
        id: kindsPaneComponent
        SettingsPane {
            width: 700
            height: 1400
            SettingRow { objectName: "k_fact1"; label: "Fact 1"; kind: "info"; value: "a" }
            SettingRow { objectName: "k_fact2"; label: "Fact 2"; kind: "info"; value: "b" }
            SettingRow { objectName: "k_item"; label: "Item" }
            SettingRow { objectName: "k_page"; label: "Page"; kind: "page" }
            SettingRow { objectName: "k_action"; label: "Action"; kind: "action" }
            ToggleRow { objectName: "k_toggle"; label: "Toggle" }
            ChoiceRow { objectName: "k_choice"; label: "Choice"; options: [{ value: "a", label: "A" }, { value: "b", label: "B" }]; value: "a" }
            SliderRow { objectName: "k_slider"; label: "Slider"; from: 0; to: 10; value: 3 }
            SettingRow { objectName: "k_verb"; label: "Verb"; hints: [{ button: "A", text: "Connect" }, { button: "B", text: "Back" }] }
            SettingRow { objectName: "k_fact3"; label: "Fact 3"; kind: "info"; value: "c" }
            SettingRow { objectName: "k_message"; label: "Message"; enabled: false }
            SettingRow { objectName: "k_fact4"; label: "Fact 4"; kind: "info"; value: "d" }
            GroupLabel { objectName: "k_group"; text: "Buttons" }
            SettingRow { objectName: "k_last"; label: "Last" }
        }
    }
    Component {
        id: ownHintsPaneComponent
        SettingsPane {
            width: 700
            height: 400
            hints: [{ button: "B", text: "Mine" }]
            ToggleRow { objectName: "o_toggle"; label: "T" }
        }
    }

    SignalSpy { id: spy }

    TestCase {
        id: tc
        name: "Settings"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
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
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function cleanup() {
            host.width = 1280
            host.height = 720
            Bluetooth.mockReset()
            DeviceSettings.reducedMotion = false
            DeviceSettings.language = "en"
            DeviceSettings.theme = "dreamglass"
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.overscan = 0.05
            Display.mockReset()
        }

        function openSettings() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList") !== null && find("categoryList").activeFocus, 2000, "category list has focus")
        }

        function selectCategory(index) {
            const list = find("categoryList")
            for (let i = 0; i < 20 && list.currentIndex < index; ++i)
                keyClick(Qt.Key_Down)
            for (let i = 0; i < 20 && list.currentIndex > index; ++i)
                keyClick(Qt.Key_Up)
            compare(list.currentIndex, index)
        }

        readonly property int displayIndex: 4
        readonly property int storageIndex: 6
        readonly property int accessibilityIndex: 7
        readonly property int aboutIndex: 10

        function test_two_pane_navigation() {
            openSettings()
            const list = find("categoryList")
            compare(list.currentIndex, 0)
            verify(find("paneMyProfile").visible, "My profile has a pane (T-105, T-315)")
            verify(!find("paneComingSoon").visible)
            keyClick(Qt.Key_Down)                        // Network has a pane (T-129)
            compare(list.currentIndex, 1)
            verify(find("paneNetwork").visible)
            verify(!find("paneComingSoon").visible)
            verify(!find("paneMyProfile").visible)
            keyClick(Qt.Key_Down)                        // Bluetooth has a pane (T-136)
            compare(list.currentIndex, 2)
            verify(find("paneBluetooth").visible)
            verify(!find("paneComingSoon").visible)
            verify(!find("paneNetwork").visible)
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Up)

            selectCategory(tc.displayIndex)
            verify(find("paneDisplay").visible)
            verify(!find("paneComingSoon").visible)
            compare(find("paneAbout"), null, "About is not built before it is selected (T-349)")

            keyClick(Qt.Key_Right)                       // enter the pane
            tryVerify(() => find("rowQuality").activeFocus, 2000, "first row takes focus")
            verify(!list.activeFocus)

            keyClick(Qt.Key_Escape)                      // Back returns to the list (Left would cycle the ChoiceRow)
            tryVerify(() => list.activeFocus)
            compare(list.currentIndex, tc.displayIndex)
            compare(tc.shell.currentPage, "settings")

            keyClick(Qt.Key_Return)                      // Accept also enters
            tryVerify(() => find("rowQuality").activeFocus)
            keyClick(Qt.Key_Escape)                      // Back leaves the pane, not the page
            tryVerify(() => list.activeFocus)
            compare(tc.shell.currentPage, "settings")

            selectCategory(tc.storageIndex)              // Storage has a pane (T-137)
            verify(find("paneStorage").visible)
            verify(!find("paneComingSoon").visible)

            selectCategory(tc.accessibilityIndex)        // Accessibility: nothing to enter yet
            verify(find("paneComingSoon").visible)
            keyClick(Qt.Key_Right)
            verify(list.activeFocus, "Right on an empty category stays on the list")

            selectCategory(tc.aboutIndex)
            verify(find("paneAbout").visible)
            keyClick(Qt.Key_Down)                        // clamps at the last category
            compare(list.currentIndex, tc.aboutIndex)

            keyClick(Qt.Key_Escape)                      // Back on the list closes the page
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("sectionNav").activeFocus, 2000, "the nav regains focus")
            compare(find("sectionNav").currentKey, "settings")
        }

        // T-179: Backspace is Back, like Esc (docs/specs/02-shell.md section 4.2).
        function test_backspace_is_back() {
            openSettings()
            const list = find("categoryList")
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus, 2000, "first row takes focus")
            keyClick(Qt.Key_Backspace)                   // pane -> list
            tryVerify(() => list.activeFocus)
            compare(list.currentIndex, tc.displayIndex)
            compare(tc.shell.currentPage, "settings")

            keyClick(Qt.Key_Backspace)                   // list -> Home
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("sectionNav").activeFocus, 2000, "the nav regains focus")
            compare(find("sectionNav").currentKey, "settings")
        }

        function test_pane_rows_navigate_and_clamp() {
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            keyClick(Qt.Key_Up)                          // clamped at the first row
            verify(find("rowQuality").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("rowReducedMotion").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("rowOverscan").activeFocus)
            keyClick(Qt.Key_Down)                        // the Theme row (T-209)
            verify(find("rowTheme").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("rowWallpaper").activeFocus)     // T-208: the wallpaper row follows (its dim row is hidden with the default look)
            keyClick(Qt.Key_Down)
            verify(find("rowResolution").activeFocus)    // T-198: the connected screen's rows come last
            keyClick(Qt.Key_Down)
            verify(find("rowRefreshRate").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("rowUiSize").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("rowResetDisplay").activeFocus)  // always there, with UI size, even without a screen
            keyClick(Qt.Key_Down)                        // clamped at the last row
            verify(find("rowResetDisplay").activeFocus)
            verify(find("homePlay").activeFocus === false)
        }

        // Every row of the pane that is drawn (not wholly above or below the viewport) lies whole
        // inside the viewport, which lies inside the pane. Returns how many rows are wholly above.
        function checkRowsInside(pane) {
            const vp = pane.viewport
            verify(vp.height > 0 && vp.height <= pane.height + 0.5, "the viewport is within the pane")
            let above = 0
            let drawn = 0
            for (const r of pane.laidOutRows()) {
                const y = r.mapToItem(vp, 0, 0).y
                if (y >= vp.height - 0.5)
                    continue                             // below the viewport: clipped away
                if (y + r.height <= 0.5) {
                    ++above
                    continue
                }
                ++drawn
                verify(y >= -0.5, r.objectName + " starts below the top edge (y=" + y + ")")
                verify(y + r.height <= vp.height + 0.5, r.objectName + " ends above the bottom edge")
            }
            verify(drawn > 0)
            return above
        }

        function test_scrolled_pane_draws_only_whole_rows() {
            openSettings()
            for (let scan = 0; scan < 2; ++scan) {       // two scans list every device: more rows than fit
                Bluetooth.startScan()
                tryCompare(Bluetooth, "discovering", true)
                tryCompare(Bluetooth, "discovering", false, 3000)
            }
            selectCategory(2)                            // Bluetooth & controllers
            keyClick(Qt.Key_Right)
            const pane = find("paneBluetooth")
            tryVerify(() => pane.activeFocus && pane.laidOutRows().length > 12, 2000, "the pane is filled")
            // Size the pane so that a row is left half visible: k whole rows plus half a stride.
            const first = pane.laidOutRows()
            const stride = first[1].y - first[0].y
            const gap = stride - first[0].height
            const whole = Math.floor((pane.height + gap) / stride) - 1
            verify(whole >= 3 && whole < first.length - 3, "enough rows to scroll")
            pane.anchors.bottomMargin = pane.height - (whole * stride - gap + stride / 2)
            tryVerify(() => Math.abs(pane.height - (whole * stride - gap + stride / 2)) < 1, 2000, "pane resized")
            const wholeBottom = whole * stride - gap
            tryVerify(() => Math.abs(pane.viewport.height - wholeBottom) < 1, 2000, "the viewport ends at the last whole row")
            verify(pane.viewport.height < pane.height - 1, "a partial row is clipped away")
            const onRowTop = () => pane.laidOutRows().some(r => Math.abs(r.y - pane.scrollY) < 0.5)
            verify(onRowTop())
            checkRowsInside(pane)
            const rows = pane.focusableRows()
            for (let i = 0; i < rows.length + 2; ++i)
                keyClick(Qt.Key_Down)                    // to the last row
            tryVerify(() => pane.focusableRows()[pane.focusableRows().length - 1].activeFocus, 2000, "the last row has focus")
            const last = pane.focusableRows()[pane.focusableRows().length - 1]
            const y = last.mapToItem(pane.viewport, 0, 0).y
            verify(y >= 0 && y + last.height <= pane.viewport.height + 0.5, "the focused row is inside the viewport")
            verify(checkRowsInside(pane) > 0, "the pane did scroll, so the top rows left the view")
            verify(onRowTop(), "the top edge is the top of a row (scrollY=" + pane.scrollY + ")")
            verify(pane.laidOutRows().some(r => Math.abs(r.y + r.height - pane.scrollY - pane.viewport.height) < 0.5),
                   "the viewport ends at the bottom of a row")
            verify(pane.viewport.height <= wholeBottom + 1, "no partial row at the bottom")
            for (let i = 0; i < rows.length + 2; ++i)
                keyClick(Qt.Key_Up)                      // and back to the first
            tryVerify(() => pane.focusableRows()[0].activeFocus, 2000, "the first row has focus")
            compare(checkRowsInside(pane), 0, "scrolled back to the top")
        }

        // Scroll cue (T-185): the first / last visible row is dimmed while rows exist beyond it.
        function fillBluetoothPane() {
            for (let scan = 0; scan < 2; ++scan) {
                Bluetooth.startScan()
                tryCompare(Bluetooth, "discovering", true)
                tryCompare(Bluetooth, "discovering", false, 3000)
            }
            selectCategory(2)                            // Bluetooth & controllers
            keyClick(Qt.Key_Right)
            const pane = find("paneBluetooth")
            tryVerify(() => pane.activeFocus && pane.laidOutRows().length > 12, 2000, "the pane is filled")
            return pane
        }

        // The focused row is whole, undimmed and inside the viewport; returns the dimmed rows.
        function checkFocusedRowClear(pane, label) {
            const row = pane.focusableRows().find(r => r.activeFocus)
            verify(row, label + ": a row has focus")
            tryCompare(row, "opacity", 1, 2000, label + ": the focused row is not dimmed")
            verify(row !== pane.peekAbove && row !== pane.peekBelow, label + ": the focused row is not a peek row")
            const y = row.mapToItem(pane.viewport, 0, 0).y
            verify(y >= -0.5 && y + row.height <= pane.viewport.height + 0.5, label + ": the focused row is inside the viewport")
            return row
        }

        // Every row's settled opacity: peekOpacity for the peek rows, 1 for all others.
        function checkPeekOpacities(pane, label) {
            for (const r of pane.laidOutRows()) {
                const peek = r === pane.peekAbove || r === pane.peekBelow
                tryCompare(r, "opacity", peek ? Theme.peekOpacity : 1, 2000, label + ": " + r.objectName)
            }
        }

        function test_scroll_cue_walks_down_and_up() {
            openSettings()
            const pane = fillBluetoothPane()
            const rows = pane.focusableRows()
            const all = pane.laidOutRows()
            // First row: nothing above it, the last visible row is the peek row.
            checkFocusedRowClear(pane, "first row")
            compare(pane.scrollY, 0)
            compare(pane.peekAbove, null)
            verify(pane.peekBelow !== null, "rows exist below the first screenful")
            verify(pane.peekBelow.mapToItem(pane.viewport, 0, 0).y + pane.peekBelow.height >= pane.viewport.height - 0.5,
                   "the peek row is the last visible one")
            checkPeekOpacities(pane, "top")
            let sawBoth = false
            for (let i = 1; i < rows.length; ++i) {      // down, one row at a time
                keyClick(Qt.Key_Down)
                tryVerify(() => rows[i].activeFocus, 2000, "down to row " + i)
                const f = checkFocusedRowClear(pane, "down " + i)
                const at = all.indexOf(f)
                if (at < all.length - 1) {
                    const next = all[at + 1]
                    verify(next.mapToItem(pane.viewport, 0, 0).y + next.height <= pane.viewport.height + 0.5,
                           "down " + i + ": the next row below is visible too")
                }
                checkPeekOpacities(pane, "down " + i)
                sawBoth = sawBoth || (pane.peekAbove !== null && pane.peekBelow !== null)
            }
            verify(sawBoth, "mid-scroll both edges peek")
            // Last row: nothing below it, no peek below; the row above the viewport peeks.
            compare(pane.peekBelow, null)
            verify(pane.peekAbove !== null)
            checkPeekOpacities(pane, "end")
            for (let i = rows.length - 2; i >= 0; --i) { // and up
                keyClick(Qt.Key_Up)
                tryVerify(() => rows[i].activeFocus, 2000, "up to row " + i)
                const f = checkFocusedRowClear(pane, "up " + i)
                const at = all.indexOf(f)
                if (at > 0)
                    verify(all[at - 1].mapToItem(pane.viewport, 0, 0).y >= -0.5,
                           "up " + i + ": the row above is visible too")
                checkPeekOpacities(pane, "up " + i)
            }
            compare(pane.scrollY, 0)
            compare(pane.peekAbove, null)
        }

        function test_scroll_cue_hidden_when_everything_fits() {
            // No screen known (T-198: the Resolution and Refresh rate rows are only there with one;
            // UI size and Reset display settings are always): this test is about a pane that fits,
            // and with a screen's two more rows the pane scrolls at this size.
            verify(Display.mockUseScenario("none"))
            tryCompare(Display, "available", false)
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            const pane = find("paneDisplay")
            verify(pane.laidOutRows().length > 0)
            compare(pane.peekAbove, null)
            compare(pane.peekBelow, null)
            for (const r of pane.laidOutRows())
                tryCompare(r, "opacity", 1)
            for (let i = 0; i < 4; ++i) {
                keyClick(Qt.Key_Down)
                for (const r of pane.laidOutRows())
                    tryCompare(r, "opacity", 1)
            }
        }

        function test_scroll_cue_has_no_animation_under_reduced_motion() {
            DeviceSettings.reducedMotion = true
            openSettings()
            const pane = fillBluetoothPane()
            verify(pane.peekBelow !== null)
            compare(pane.peekBelow.opacity, Theme.peekOpacity, "dims at once")
            const rows = pane.focusableRows()
            for (let i = 0; i < rows.length + 2; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => rows[rows.length - 1].activeFocus, 2000)
            compare(pane.peekBelow, null)
            for (const r of pane.laidOutRows())
                compare(r.opacity, r === pane.peekAbove ? Theme.peekOpacity : 1, "settled at once: " + r.objectName)
        }

        function test_look_ahead_keeps_whole_rows_and_the_first_and_last_row_reachable() {
            openSettings()
            const pane = fillBluetoothPane()
            const rows = pane.focusableRows()
            for (let i = 0; i < rows.length + 2; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => rows[rows.length - 1].activeFocus, 2000, "the last row takes focus")
            checkFocusedRowClear(pane, "last")
            checkRowsInside(pane)
            for (let i = 0; i < rows.length + 2; ++i)
                keyClick(Qt.Key_Up)
            tryVerify(() => rows[0].activeFocus, 2000, "the first row takes focus")
            checkFocusedRowClear(pane, "first")
            compare(checkRowsInside(pane), 0)
        }

        // The row sits whole inside the pane's viewport.
        function wholeInViewport(pane, row) {
            const y = row.mapToItem(pane.viewport, 0, 0).y
            return y >= -0.5 && y + row.height <= pane.viewport.height + 0.5
        }

        // T-356: a focused row that hides hands the focus to the nearest visible row (the one before,
        // else the next one); with no row left the pane holds it itself, Back still leaves, and the
        // first row that appears takes it.
        function test_a_hidden_focused_row_hands_the_focus_on() {
            const pane = createTemporaryObject(barePaneComponent, host)
            verify(pane)
            const r = n => findChild(pane, "r" + n)
            const holder = () => pane.Window.window.activeFocusItem
            // activeFocus is false everywhere while the window is not the active one (the desktop took
            // it: the one way this test was seen to fail): take it back first, or say so plainly.
            const inactive = windowGuard.ensureActive()
            verify(inactive === "", inactive)
            pane.forceActiveFocus()
            tryVerify(() => r(0).activeFocus, 5000)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            tryVerify(() => r(2).activeFocus, 5000, "two Downs reach the third row")
            r(2).visible = false
            tryCompare(r(1), "activeFocus", true)        // the row before
            r(1).visible = false
            tryCompare(r(0), "activeFocus", true)
            r(0).visible = false
            tryCompare(r(3), "activeFocus", true)        // none before: the next one
            r(3).visible = false                         // r4, r5 are hidden too
            tryVerify(() => holder() === pane, 2000, "no row left: the pane, not a hidden row")
            spy.target = pane
            spy.signalName = "exitRequested"
            spy.clear()
            keyClick(Qt.Key_Escape)
            compare(spy.count, 1, "Back still leaves")
            pane.forceActiveFocus()
            r(4).visible = true                          // data arrives
            tryCompare(r(4), "activeFocus", true)
        }

        // T-356: a pane whose first rows are hidden when it is entered (a page waiting for data) gives
        // the focus to the first visible row, or with none holds it itself.
        function test_a_pane_entered_with_hidden_rows_never_focuses_a_hidden_row() {
            const pane = createTemporaryObject(barePaneComponent, host)
            verify(pane)
            const r = n => findChild(pane, "r" + n)
            r(0).visible = false
            pane.forceActiveFocus()
            tryCompare(r(1), "activeFocus", true)
            const empty = createTemporaryObject(barePaneComponent, host)
            for (let i = 0; i < 4; ++i)
                findChild(empty, "r" + i).visible = false
            empty.forceActiveFocus()
            tryVerify(() => empty.Window.window.activeFocusItem === empty, 2000, "the pane itself")
            verify(!findChild(empty, "r0").activeFocus)
        }

        // T-190: rows that appear below the focused row (a message, devices found) while it is the
        // last row in view bring the next row whole into view.
        // Revert check: dropping the ensureFocusedVisible() call at the end of relayout() fails this.
        function test_rows_inserted_below_the_focus_keep_the_look_ahead() {
            const pane = createTemporaryObject(barePaneComponent, host)
            verify(pane)
            pane.forceActiveFocus()
            const r = n => findChild(pane, "r" + n)
            tryVerify(() => r(0).activeFocus, 2000, "the first row takes focus")
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => r(3).activeFocus, 2000, "the last row has focus")
            compare(pane.peekBelow, null, "four rows fit: no cue yet")
            verify(wholeInViewport(pane, r(3)))

            r(4).visible = true                          // a message appears below the focused row
            tryVerify(() => wholeInViewport(pane, r(4)), 2000, "the row below the focus is whole in view")
            verify(r(3).activeFocus)
            verify(wholeInViewport(pane, r(3)), "the focused row stays whole")
            tryCompare(pane, "peekBelow", null)          // r4 is the last row: nothing beyond it
            tryCompare(pane, "peekAbove", r(1))         // the top row is the peek row
            tryCompare(r(3), "opacity", 1)
            tryCompare(r(4), "opacity", 1)
            tryCompare(r(1), "opacity", Theme.peekOpacity)

            r(5).visible = true                          // one more below the next row
            tryVerify(() => pane.laidOutRows().length === 6, 2000, "six rows")
            keyClick(Qt.Key_Down)
            tryVerify(() => r(4).activeFocus, 2000, "down to row 4")
            tryVerify(() => wholeInViewport(pane, r(5)), 2000, "r5 whole below r4")
            verify(wholeInViewport(pane, r(4)))
        }

        // A pane that gets shorter leaves the focused row the last whole one: look ahead again.
        // Revert check: same call in relayout() (onHeightChanged runs it).
        function test_a_shorter_pane_keeps_the_look_ahead() {
            const pane = createTemporaryObject(barePaneComponent, host)
            verify(pane)
            const r = n => findChild(pane, "r" + n)
            r(4).visible = true
            pane.height = 484                            // five rows
            pane.forceActiveFocus()
            tryVerify(() => r(0).activeFocus, 2000)
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => r(3).activeFocus, 2000, "row 3 has focus")
            tryVerify(() => wholeInViewport(pane, r(4)), 2000, "r4 is the look-ahead row")
            pane.height = 384                            // one row less: row 3 would be the last whole row
            tryVerify(() => Math.abs(pane.viewport.height - 384) < 1, 2000, "four rows in view")
            tryVerify(() => wholeInViewport(pane, r(4)), 2000, "r4 is whole again after the resize")
            verify(wholeInViewport(pane, r(3)))
            verify(r(3).activeFocus)
        }

        // The same in the real pane: Bluetooth discovery lists devices below the focused row.
        function test_bluetooth_discovery_keeps_the_focused_row_and_the_row_below_whole() {
            openSettings()
            selectCategory(2)
            keyClick(Qt.Key_Right)
            const pane = find("paneBluetooth")
            tryVerify(() => pane.activeFocus, 2000)
            const first = pane.laidOutRows()
            const stride = first[1].y - first[0].y
            const gap = stride - first[0].height
            const fit = 6                                // six rows in view: power, add, hint, three devices
            pane.anchors.bottomMargin = pane.height - (fit * stride - gap)
            tryVerify(() => Math.abs(pane.height - (fit * stride - gap)) < 1, 2000, "pane resized")
            keyClick(Qt.Key_Down)                        // "Add a device"
            tryVerify(() => find("rowBtAdd").activeFocus)
            keyClick(Qt.Key_Return)                      // scan: devices are listed below
            tryCompare(Bluetooth, "discovering", true)
            tryCompare(Bluetooth, "discovering", false, 3000)
            tryVerify(() => pane.laidOutRows().length > 10, 2000, "devices were added")
            const row = checkFocusedRowClear(pane, "after the scan")
            compare(row.objectName, "rowBtAdd")
            const all = pane.laidOutRows()
            const next = all[all.indexOf(row) + 1]
            tryVerify(() => wholeInViewport(pane, next), 2000, "the row below the focus is whole")
            checkPeekOpacities(pane, "after the scan")
        }

        // The panes that gained rows lately (Display & motion: theme, wallpaper, dim; System: thermal)
        // squeezed to four rows: Down and Tab keep the focused row whole with its neighbour in view.
        function test_longer_panes_keep_the_look_ahead_with_down_and_tab() {
            openSettings()
            for (const [index, name] of [[tc.displayIndex, "paneDisplay"], [9, "paneSystem"]]) {
                selectCategory(index)
                keyClick(Qt.Key_Right)
                const pane = find(name)
                tryVerify(() => pane.activeFocus && pane.focusableRows().length > 0, 2000, name + " has focus")
                const first = pane.laidOutRows()
                const stride = first[1].y - first[0].y
                const gap = stride - first[0].height
                verify(first.length >= 5, name + " has more than four rows: " + first.length)
                pane.anchors.bottomMargin = pane.height - (4 * stride - gap)
                tryVerify(() => Math.abs(pane.height - (4 * stride - gap)) < 1, 2000, name + " resized")
                const rows = pane.focusableRows()
                for (const key of [Qt.Key_Down, Qt.Key_Tab]) {
                    for (let i = 1; i < rows.length; ++i) {
                        keyClick(key)
                        tryVerify(() => rows[i].activeFocus, 2000, name + ": row " + i + " takes focus")
                        const f = checkFocusedRowClear(pane, name + " " + i)
                        const all = pane.laidOutRows()
                        const at = all.indexOf(f)
                        if (at < all.length - 1)
                            verify(wholeInViewport(pane, all[at + 1]), name + " " + i + ": the next row is whole too")
                        checkPeekOpacities(pane, name + " " + i)
                    }
                    for (let i = rows.length - 2; i >= 0; --i)
                        keyClick(key === Qt.Key_Tab ? Qt.Key_Backtab : Qt.Key_Up)
                    tryVerify(() => rows[0].activeFocus, 2000, name + ": back on the first row")
                }
                keyClick(Qt.Key_Escape)
                tryVerify(() => find("categoryList").activeFocus)
            }
        }

        // T-190: Tab and Shift+Tab move between rows like Down and Up, scrolling and updating the peek rows.
        // Revert check: dropping the Key_Tab / Key_Backtab cases lets the window's focus chain move focus
        // without scrolling, which fails the viewport checks.
        function test_tab_moves_like_down_and_scrolls() {
            openSettings()
            const pane = fillBluetoothPane()
            const rows = pane.focusableRows()
            const all = pane.laidOutRows()
            checkFocusedRowClear(pane, "first row")
            for (let i = 1; i < rows.length; ++i) {
                keyClick(Qt.Key_Tab)
                tryVerify(() => rows[i].activeFocus, 2000, "tab to row " + i)
                const f = checkFocusedRowClear(pane, "tab " + i)
                const at = all.indexOf(f)
                if (at < all.length - 1)
                    verify(wholeInViewport(pane, all[at + 1]), "tab " + i + ": the next row is whole too")
                checkPeekOpacities(pane, "tab " + i)
            }
            compare(pane.peekBelow, null)
            keyClick(Qt.Key_Tab)                         // clamped like Down: no wrap, no leaving the pane
            verify(rows[rows.length - 1].activeFocus)
            verify(pane.activeFocus)
            for (let i = rows.length - 2; i >= 0; --i) {
                keyClick(Qt.Key_Backtab)
                tryVerify(() => rows[i].activeFocus, 2000, "backtab to row " + i)
                const f = checkFocusedRowClear(pane, "backtab " + i)
                const at = all.indexOf(f)
                if (at > 0)
                    verify(wholeInViewport(pane, all[at - 1]), "backtab " + i + ": the row above is whole too")
                checkPeekOpacities(pane, "backtab " + i)
            }
            compare(pane.scrollY, 0)
            keyClick(Qt.Key_Tab)
            tryVerify(() => rows[1].activeFocus)
            keyClick(Qt.Key_Tab, Qt.ShiftModifier)       // some platforms send Tab + Shift instead of Backtab
            tryVerify(() => rows[0].activeFocus)
        }

        function test_pane_remembers_last_row() {
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("rowOverscan").activeFocus)
            keyClick(Qt.Key_Escape)                      // Back leaves the pane
            tryVerify(() => find("categoryList").activeFocus)

            keyClick(Qt.Key_Down)                        // another category
            keyClick(Qt.Key_Up)                          // and back
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowOverscan").activeFocus, 2000, "re-entering restores the last row")
        }

        function test_controls() {
            // ToggleRow: only Accept changes it.
            const toggle = createTemporaryObject(toggleComponent, host)
            toggle.forceActiveFocus()
            verify(toggle.activeFocus)
            spy.target = toggle
            spy.signalName = "toggled"
            spy.clear()
            const selects = Sfx.selectCount
            const ons = Sfx.toggleOnCount
            const offs = Sfx.toggleOffCount
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Up)
            compare(toggle.checked, false)
            keyClick(Qt.Key_Return)
            compare(toggle.checked, true)
            keyClick(Qt.Key_Enter)
            compare(toggle.checked, false)
            compare(spy.count, 2)
            compare(Sfx.toggleOnCount, ons + 1, "switching on takes the toggle-on cue")
            compare(Sfx.toggleOffCount, offs + 1, "switching off takes the toggle-off cue")
            compare(Sfx.selectCount, selects, "a switch no longer uses the select cue")

            // ChoiceRow: Left/Right cycle (wrapping), nothing else changes it.
            const choice = createTemporaryObject(choiceComponent, host)
            choice.forceActiveFocus()
            verify(choice.activeFocus)
            spy.target = choice
            spy.signalName = "edited"
            spy.clear()
            const navs = Sfx.navigateCount
            compare(choice.value, "a")
            keyClick(Qt.Key_Return)
            compare(choice.value, "b", "A steps to the next option (RUY-512)")
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Down)
            compare(choice.value, "a", "Down changes nothing")
            keyClick(Qt.Key_Right)
            compare(choice.value, "b")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(choice.value, "a", "wraps past the last option")
            keyClick(Qt.Key_Left)
            compare(choice.value, "c", "wraps before the first option")
            compare(spy.count, 6)
            compare(Sfx.navigateCount, navs + 6, "changes take the navigate sound path")

            // SliderRow: steps within the bounds and clamps.
            const slider = createTemporaryObject(sliderComponent, host)
            slider.forceActiveFocus()
            verify(slider.activeFocus)
            spy.target = slider
            spy.signalName = "edited"
            spy.clear()
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Up)
            compare(slider.value, 1)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(slider.value, 3)
            keyClick(Qt.Key_Right)
            compare(slider.value, 3, "clamps at the upper bound")
            compare(spy.count, 2, "no signal when nothing changed")
            for (let i = 0; i < 5; ++i)
                keyClick(Qt.Key_Left)
            compare(slider.value, 0, "clamps at the lower bound")

            // SettingRow: Accept emits activated(), nothing else.
            const plain = createTemporaryObject(plainComponent, host)
            plain.forceActiveFocus()
            spy.target = plain
            spy.signalName = "activated"
            spy.clear()
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            compare(spy.count, 0)
            keyClick(Qt.Key_Return)
            compare(spy.count, 1)
        }

        // Hints as "A Select|B Back" from a pane's `hints` (what Settings shows in the bar).
        function hintsOf(pane) { return pane.hints.map(h => h.button + " " + h.text).join("|") }

        // RUY-512: a fact has no pill at rest, a hairline only between two facts, the normal focus ring when
        // focused, and A is silent.
        function test_fact_row() {
            const row = createTemporaryObject(factComponent, host)
            const fill = findChild(row, "rowFill")
            const layers = findChild(row, "rowLayers")
            const rule = findChild(row, "rowRule")
            compare(fill.color.a, 0, "no fill at rest")
            compare(layers.visible, false, "no sheen, rim or grain at rest")
            compare(rule.visible, false, "no hairline with no fact below")
            row.ruleBelow = true
            compare(rule.visible, true, "a hairline when the next row is a fact")
            compare(rule.height, Theme.hairlineAt(1))
            compare(rule.width, row.width - 2 * Theme.spaceL)
            compare(findChild(row, "value").text, "x")
            compare(row.Accessible.role, Accessible.StaticText)
            compare(row.Accessible.name, "Fact, x")

            row.forceActiveFocus()
            verify(row.activeFocus, "a fact can be focused (it scrolls and is read)")
            tryCompare(fill, "color", Theme.focusFill)
            compare(fill.border.width, Theme.focusRingWidth, "the focus ring")
            compare(fill.border.color, Theme.focusRing)
            compare(layers.visible, true, "the focused row is the normal row")
            compare(rule.visible, false, "hairline hidden while focused")

            spy.target = row
            spy.signalName = "activated"
            spy.clear()
            const selects = Sfx.selectCount
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Enter)
            compare(spy.count, 0, "A emits nothing")
            compare(Sfx.selectCount, selects, "A makes no sound")

            // `inert` is the same kind.
            const old = createTemporaryObject(plainComponent, host, { inert: true })
            compare(findChild(old, "rowFill").color.a, 0)
            compare(findChild(old, "rowLayers").visible, false)
            compare(old.hintKind, "info")
        }

        function test_pane_sets_the_hairline_between_facts_only() {
            const pane = createTemporaryObject(kindsPaneComponent, host)
            const rule = name => findChild(pane, name).ruleBelow
            // Fact 1 meets fact 2; fact 2 is followed by the item, fact 3 by a message, fact 4 by a heading.
            tryVerify(() => rule("k_fact1") === true)
            for (const name of ["k_fact2", "k_item", "k_fact3", "k_message", "k_fact4", "k_last"])
                compare(rule(name), false, name)
            // Hide the rows between fact 2 and fact 3: they meet. Hide the message: fact 3 meets fact 4.
            for (const name of ["k_item", "k_page", "k_action", "k_toggle", "k_choice", "k_slider", "k_verb"])
                findChild(pane, name).visible = false
            tryCompare(findChild(pane, "k_fact2"), "ruleBelow", true)
            findChild(pane, "k_message").visible = false
            tryCompare(findChild(pane, "k_fact3"), "ruleBelow", true)
            compare(rule("k_fact4"), false, "never after the last fact of a run")
        }

        function test_page_row_has_a_chevron() {
            const page = createTemporaryObject(pageComponent, host)
            const chevron = findChild(page, "chevron")
            const value = findChild(page, "value")
            verify(chevron.visible)
            compare(chevron.name, "chevron_right")
            fuzzyCompare(chevron.mapToItem(page, chevron.width, 0).x, page.width - Theme.spaceS, 1, "the box ends 16 from the edge")
            fuzzyCompare(value.mapToItem(page, value.width, 0).x, chevron.mapToItem(page, 0, 0).x - Theme.spaceXxs, 1, "the value ends 4 before it")
            compare(page.hintKind, "page")
            for (const other of [factComponent, actionComponent, plainComponent]) {
                const r = createTemporaryObject(other, host)
                compare(findChild(r, "chevron").visible, false)
            }
            page.dimmed = true
            compare(chevron.color.a, Theme.disabledOpacity, "dimmed with the label")
        }

        function test_action_row() {
            const row = createTemporaryObject(actionComponent, host)
            const label = findChild(row, "label")
            fuzzyCompare(label.mapToItem(row, label.width / 2, 0).x, row.width / 2, 1, "the label is centred")
            compare(label.font.weight, Theme.weightDemiBold)
            compare(findChild(row, "value").visible, false, "nothing at the right end")
            compare(findChild(row, "detail").visible, false)
            compare(findChild(row, "rowFill").color, Theme.glass, "an item's fill")

            row.iconName = "settings"
            const icon = findChild(row, "rowIcon")
            verify(icon.visible)
            fuzzyCompare(label.mapToItem(row, label.width / 2, 0).x, row.width / 2, 1, "still centred with an icon")
            fuzzyCompare(icon.mapToItem(row, icon.width, 0).x, label.mapToItem(row, 0, 0).x - Theme.spaceS, 1, "the icon sits 16 before it")

            row.value = "Scanning…"
            const detail = findChild(row, "detail")
            verify(detail.visible)
            compare(detail.text, "Scanning…", "the status is the second line")
            fuzzyCompare(detail.mapToItem(row, detail.width / 2, 0).x, row.width / 2, 1, "centred")
            verify(detail.mapToItem(row, 0, 0).y > label.mapToItem(row, 0, label.height).y - 1, "under the label")
            row.detail = "Other"
            compare(detail.text, "Other", "detail wins over value")
            row.detail = ""
            compare(row.Accessible.name, "Scan for networks, Scanning…")
        }

        function test_primary_action_row() {
            const row = createTemporaryObject(actionComponent, host, { emphasis: "primary" })
            const fill = findChild(row, "rowFill")
            const label = findChild(row, "label")
            compare(fill.color, Theme.primaryFill)
            compare(label.color, Theme.onPrimary)
            compare(fill.border.width, 0, "no rim")
            compare(findChild(row, "rowLayers").visible, false)
            const ring = findChild(row, "rowRingOutside")
            compare(ring.visible, false)
            row.forceActiveFocus()
            verify(row.activeFocus)
            compare(ring.visible, true)
            compare(fill.color, Theme.primaryFill, "focused: the fill stays")
            compare(ring.border.width, Theme.focusRingWidth)
            compare(ring.border.color, Theme.focusRing)
            compare(ring.x, -Theme.focusRingOffset, "the ring is drawn outside the pill")
            compare(ring.width, row.width + 2 * Theme.focusRingOffset)
        }

        function test_current_item() {
            const row = createTemporaryObject(currentComponent, host)
            const mark = findChild(row, "currentMark")
            const label = findChild(row, "label")
            compare(mark.visible, false, "only with current: true")
            compare(label.font.weight, Font.Normal)
            row.current = true
            compare(mark.visible, true)
            compare(mark.name, "check_circle")
            compare(mark.filled, true)
            fuzzyCompare(mark.mapToItem(row, mark.width, 0).x, row.width - Theme.spaceS, 1)
            compare(label.font.weight, Theme.weightDemiBold)
            compare(findChild(row, "value").text, "Current", "its word stays")
            compare(row.Accessible.checked, true)
            compare(findChild(row, "chevron").visible, false)
            row.forceActiveFocus()
            compare(label.font.weight, Theme.weightDemiBold, "focused: check and DemiBold stay")
            compare(mark.visible, true)
        }

        function test_message_row() {
            const row = createTemporaryObject(messageComponent, host)
            const icon = findChild(row, "rowIcon")
            verify(icon.visible)
            compare(icon.name, "info")
            compare(findChild(row, "rowFill").color.a, 0, "flat like a fact")
            compare(findChild(row, "rowRule").visible, false)
            row.forceActiveFocus()
            compare(row.activeFocus, false, "never focused")
            // The row's own icon wins.
            row.iconName = "warning"
            compare(icon.name, "warning")
            // In a pane Down steps over it.
            const pane = createTemporaryObject(kindsPaneComponent, host)
            findChild(pane, "k_fact3").forceActiveFocus()
            keyClick(Qt.Key_Down)
            verify(findChild(pane, "k_fact4").activeFocus, "the message is skipped")
        }

        function test_toggle_look() {
            const toggle = createTemporaryObject(toggleComponent, host)
            const track = findChild(toggle, "switchTrack")
            const knob = findChild(toggle, "switchKnob")
            compare(track.width, 96)
            compare(track.height, 48)
            compare(track.radius, 24)
            compare(track.border.width, 3)
            compare(track.border.color, Theme.text)
            compare(track.color.a, 0, "off: no fill")
            compare(knob.width, 32)
            compare(knob.x, 8)
            compare(knob.y, 8)
            compare(knob.color, Theme.text)
            toggle.checked = true
            tryCompare(track, "color", Theme.primaryFill)
            tryCompare(knob, "x", 56)
            tryCompare(knob, "color", Theme.onPrimary)
            compare(track.border.width, 3)
            compare(track.border.color, Theme.text, "the outline stays in both states")
            toggle.dimmed = true
            compare(track.opacity, Theme.disabledOpacity, "the whole switch dims")
            compare(toggle.hintKind, "toggle")
        }

        function test_choice_look_and_accept() {
            const choice = createTemporaryObject(choiceComponent, host)
            const left = findChild(choice, "arrowLeft")
            const right = findChild(choice, "arrowRight")
            const value = findChild(choice, "value")
            verify(left.visible && right.visible, "two or more options: both arrows")
            compare(left.width, 48)
            compare(left.color, Theme.selectedFill)
            fuzzyCompare(right.mapToItem(choice, right.width, 0).x, choice.width - Theme.spaceS, 1, "the right circle ends 16 from the edge")
            fuzzyCompare(value.mapToItem(choice, value.width, 0).x, right.mapToItem(choice, 0, 0).x - Theme.spaceXs, 1)
            fuzzyCompare(left.mapToItem(choice, left.width, 0).x, value.mapToItem(choice, 0, 0).x - Theme.spaceXs, 1)
            compare(value.text, "A", "the value alone, not wrapped in arrows")
            compare(choice.leftArrow.objectName, "arrowLeft")

            choice.dimmed = true
            compare(left.visible, false, "dimmed: the value alone")
            compare(right.visible, false)
            fuzzyCompare(value.mapToItem(choice, value.width, 0).x, choice.width - Theme.spaceL, 1)
            choice.dimmed = false
            choice.options = [{ value: "a", label: "A" }]
            compare(left.visible, false, "one option: the value alone")
            compare(right.visible, false)
            choice.options = [{ value: "a", label: "A" }, { value: "b", label: "B" }, { value: "c", label: "C" }]
            compare(left.visible, true)

            // A steps to the next option and wraps.
            choice.forceActiveFocus()
            spy.target = choice
            spy.signalName = "edited"
            spy.clear()
            const navs = Sfx.navigateCount
            keyClick(Qt.Key_Return)
            compare(choice.value, "b", "A steps to the next")
            keyClick(Qt.Key_Enter)
            compare(choice.value, "c")
            keyClick(Qt.Key_Return)
            compare(choice.value, "a", "and wraps")
            compare(spy.count, 3)
            compare(Sfx.navigateCount, navs + 3)
            compare(choice.hintKind, "choice")
        }

        function test_slider_look() {
            const slider = createTemporaryObject(sliderComponent, host)
            const track = findChild(slider, "sliderTrack")
            const thumb = findChild(slider, "sliderThumb")
            const fill = findChild(slider, "valueFill")
            compare(track.height, 16)
            compare(track.width, 320)
            compare(track.border.width, 2)
            compare(track.border.color, Theme.text)
            compare(track.color.a, 0, "no fill: an outlined track")
            compare(thumb.width, 32)
            compare(thumb.color, Theme.text)
            // Fractions 0, 0.5 and 1 of 0..3.
            for (const [value, fraction] of [[0, 0], [1.5, 0.5], [3, 1]]) {
                slider.value = value
                const centre = thumb.x + thumb.width / 2
                fuzzyCompare(centre, 16 + 288 * fraction, 0.01, "thumb centre at " + fraction)
                fuzzyCompare(fill.width, centre, 0.01, "the fill runs to the thumb's centre")
                verify(thumb.x >= 0 && thumb.x + thumb.width <= track.width, "the thumb never leaves the track")
            }
            compare(slider.hintKind, "slider")
            // A does nothing.
            slider.forceActiveFocus()
            slider.value = 1
            keyClick(Qt.Key_Return)
            compare(slider.value, 1)
        }

        function test_group_label() {
            const pane = createTemporaryObject(kindsPaneComponent, host)
            const group = findChild(pane, "k_group")
            const text = findChild(group, "groupLabelText")
            compare(text.font.pixelSize, Theme.typeHeadline)
            compare(text.font.weight, Theme.weightDemiBold)
            compare(text.mapToItem(group, 0, 0).x, 0, "flush with the pills")
            compare(text.y, Theme.spaceXl, "48 above its text")
            compare(group.Accessible.role, Accessible.Heading)
            compare(group.Accessible.name, "Buttons")
            compare(group.focus, false)
            compare(group.activeFocusOnTab, false, "never focusable")
            // Up and Down skip it.
            findChild(pane, "k_fact4").forceActiveFocus()
            keyClick(Qt.Key_Down)
            verify(findChild(pane, "k_last").activeFocus, "Down steps over the heading")
            keyClick(Qt.Key_Up)
            verify(findChild(pane, "k_fact4").activeFocus, "and Up")
            // 8 between the heading's text and the next row: the column gap, overlapped.
            const last = findChild(pane, "k_last")
            tryVerify(() => Math.abs(last.y - (group.y + text.y + text.height + Theme.spaceXs)) < 1,
                      2000, "8 between the text and the next row: " + (last.y - group.y - text.y - text.height))
            // Long text elides at the width.
            group.text = "A very long heading that cannot possibly fit in seven hundred design pixels of a pane column at all, never"
            compare(text.truncated, true)
            compare(text.width, group.width)
        }

        // RUY-512: the hint bar follows the focused row's kind.
        function test_hints_follow_the_focused_kind() {
            const pane = createTemporaryObject(kindsPaneComponent, host)
            findChild(pane, "k_fact1").forceActiveFocus()
            tryCompare(pane, "focusedRow", findChild(pane, "k_fact1"))
            compare(hintsOf(pane), "B Back", "fact")
            const cases = [["k_item", "A Select|B Back"], ["k_page", "A Open|B Back"], ["k_action", "A Select|B Back"],
                           ["k_toggle", "A Toggle|B Back"], ["k_choice", "Left/Right Change|A Next|B Back"],
                           ["k_slider", "Left/Right Adjust|B Back"], ["k_verb", "A Connect|B Back"], ["k_fact3", "B Back"]]
            for (const [name, want] of cases) {
                findChild(pane, name).forceActiveFocus()
                tryCompare(pane, "focusedRow", findChild(pane, name))
                compare(hintsOf(pane), want, name)
            }
            // A pane that sets its own hints keeps them.
            const own = createTemporaryObject(ownHintsPaneComponent, host)
            findChild(own, "o_toggle").forceActiveFocus()
            compare(hintsOf(own), "B Mine")
        }

        // Shown in the real bar: Settings > Display opens on its Quality choice row.
        function test_hint_bar_shows_the_row_kind() {
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            const bar = find("hintBar")
            tryVerify(() => findChild(bar, "hint_Left/Right") !== null, 2000, "a choice row offers Left/Right")
            compare(findChild(bar, "hint_A").verb, "Next")
            compare(findChild(bar, "hint_B").verb, "Back")
            keyClick(Qt.Key_Escape)
        }

        // Turkish: the Open hint is the verb "Aç", not the adjective "Açık" (RUY-505).
        function test_hint_verbs_are_turkish() {
            DeviceSettings.language = "tr"
            const pane = createTemporaryObject(kindsPaneComponent, host)
            const cases = [["k_fact1", "B Geri"], ["k_item", "A Seç|B Geri"], ["k_page", "A Aç|B Geri"],
                           ["k_toggle", "A Aç/Kapat|B Geri"], ["k_choice", "Left/Right Değiştir|A İleri|B Geri"],
                           ["k_slider", "Left/Right Ayarla|B Geri"]]
            for (const [name, want] of cases) {
                findChild(pane, name).forceActiveFocus()
                tryCompare(pane, "focusedRow", findChild(pane, name))
                tryVerify(() => hintsOf(pane) === want, 2000, name + ": " + hintsOf(pane))
            }
        }

        function test_choice_row_keeps_focus() {
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            const list = find("categoryList")

            keyClick(Qt.Key_Right)
            compare(find("rowQuality").value, "balanced")
            verify(find("rowQuality").activeFocus, "focus stays on the row")
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            compare(find("rowQuality").value, "performance", "cycles backwards, wrapping")
            verify(find("rowQuality").activeFocus)
            verify(!list.activeFocus, "never leaves the pane")
            compare(tc.shell.currentPage, "settings")
        }

        function test_display_settings_apply_live() {
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)

            keyClick(Qt.Key_Right)
            compare(DeviceSettings.effectsQuality, "balanced")
            compare(Theme.blurMax, 32)
            keyClick(Qt.Key_Right)
            compare(DeviceSettings.effectsQuality, "performance")
            compare(Theme.blurMax, 0)

            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            compare(DeviceSettings.reducedMotion, true)
            compare(Theme.pageMs, 0)
            verify(find("rowReducedMotion").checked)

            keyClick(Qt.Key_Down)
            compare(find("rowOverscan").value, 5)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(DeviceSettings.overscan, 0.07)
            for (let i = 0; i < 10; ++i)
                keyClick(Qt.Key_Right)
            compare(DeviceSettings.overscan, 0.10, "clamps at 10 %")
            for (let j = 0; j < 12; ++j)
                keyClick(Qt.Key_Left)
            compare(DeviceSettings.overscan, 0.0, "clamps at 0 %")
            compare(find("sectionNav").x, 0, "the header follows the setting")

            // Back on the shelf the blur is gone (performance tier).
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("home").visible)
            verify(!find("glassBlur").visible, "the shelf blur is off in the performance tier")
        }

        function test_rows_follow_external_changes() {
            openSettings()
            selectCategory(tc.displayIndex)
            DeviceSettings.effectsQuality = "balanced"
            DeviceSettings.reducedMotion = true
            DeviceSettings.overscan = 0.03
            compare(find("rowQuality").value, "balanced")
            compare(find("rowReducedMotion").checked, true)
            compare(find("rowOverscan").value, 3)
        }

        // The last category (About) with its selected, focused pill ends above the hint bar and
        // clear of every hint glyph, at the test size and at 1920x1080, in both effects tiers.
        // (Unscrolled, the nine rows are 712 px at 1080 and overrun the bar.)
        function test_last_category_clears_the_hint_bar() {
            for (const size of [[1280, 720], [1920, 1080]]) {
                for (const tier of ["high", "performance"]) {
                    const what = size[0] + "x" + size[1] + " " + tier
                    host.width = size[0]
                    host.height = size[1]
                    DeviceSettings.effectsQuality = tier
                    tryCompare(tc.shell, "height", size[1])
                    if (!find("categoryList"))
                        openSettings()
                    const list = find("categoryList")
                    list.forceActiveFocus()
                    selectCategory(tc.aboutIndex)
                    tryVerify(() => list.currentItem && list.currentItem.focused, 2000, "About focused " + what)
                    const bar = find("hintBar")
                    verify(bar.visible, "bar shown " + what)
                    const barTop = bar.mapToItem(tc.shell, 0, 0).y
                    const pill = list.currentItem
                    const pillBottom = pill.mapToItem(tc.shell, 0, pill.height).y
                    verify(pillBottom <= barTop + 0.5, "About pill above the bar, " + what + ": " + pillBottom + " vs " + barTop)
                    // Inside the page's content area, which ends above Page.qml's bottom margin.
                    const areaBottom = list.parent.mapToItem(tc.shell, 0, list.parent.height).y
                    verify(pillBottom <= areaBottom + 0.5, "About pill inside the content area, " + what + ": " + pillBottom + " vs " + areaBottom)
                    for (const b of ["A", "B"]) {
                        const glyph = findChild(bar, "hint_" + b)
                        verify(glyph, "hint glyph " + b + " exists, " + what)
                        verify(pillBottom <= glyph.mapToItem(tc.shell, 0, 0).y + 0.5, "clear of glyph " + b + ", " + what)
                    }
                    // The list shows whole rows only, and the first category is reachable again.
                    const stride = list.stride
                    const rows = (list.height + list.spacing) / stride
                    verify(Math.abs(rows - Math.round(rows)) < 0.01, "whole rows, " + what + ": " + rows)
                    selectCategory(0)
                    tryVerify(() => list.currentItem.mapToItem(tc.shell, 0, 0).y >= list.mapToItem(tc.shell, 0, 0).y - 0.5)
                }
            }
        }

        function test_about_shows_version() {
            openSettings()
            selectCategory(tc.aboutIndex)
            verify(find("paneAbout").visible)
            compare(find("aboutVersion").value, "test-1.2.3")
            compare(find("aboutQt").value, SystemInfo.qtVersion)
            verify(SystemInfo.qtVersion.length > 0)
            compare(find("aboutServices").value, Profiles.mock ? "Mock (in-memory)" : "D-Bus")
            compare(find("aboutLicence").value, "GPL-3.0-or-later; icon font Apache-2.0; Inter typeface OFL-1.1")

            keyClick(Qt.Key_Right)
            tryVerify(() => find("aboutVersion").activeFocus)
            keyClick(Qt.Key_Return)                      // read-only rows: Accept does nothing
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("aboutLicence").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("aboutSystemInfo").activeFocus, "the last row opens System information (T-226)")
            keyClick(Qt.Key_Down)
            verify(find("aboutSystemInfo").activeFocus, "clamps at the last row")
            keyClick(Qt.Key_Left)
            tryVerify(() => find("categoryList").activeFocus)
        }

        function test_guide_overlay_over_settings_pane() {
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            keyClick(Qt.Key_HomePage)                    // the pane leaves Guide alone
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("rowQuality").activeFocus, 2000, "focus returns to the row")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            keyClick(Qt.Key_Down)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/7-settings-display.png")

            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus)
            selectCategory(tc.aboutIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("aboutVersion").activeFocus)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/8-settings-about.png")

            keyClick(Qt.Key_Escape)                      // About selected on the list: the last pill vs the hint bar
            tryVerify(() => find("categoryList").activeFocus)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/8b-settings-about-category.png")
        }

        // A pane longer than the screen at the top, in the middle and at the end (T-185).
        function test_zz_screenshots_scroll_cue() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openSettings()
            const pane = fillBluetoothPane()
            const rows = pane.focusableRows()
            tryVerify(() => rows[0].activeFocus, 2000, "first row")
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/28a-settings-scroll-top.png")
            for (let i = 0; i < Math.floor(rows.length / 2); ++i)
                keyClick(Qt.Key_Down)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/28b-settings-scroll-middle.png")
            for (let i = 0; i < rows.length; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => rows[rows.length - 1].activeFocus, 2000, "last row")
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/28c-settings-scroll-end.png")
            // The peek rows on the lightest dark theme and on the light theme (T-190).
            for (let i = 0; i < Math.floor(rows.length / 2); ++i)
                keyClick(Qt.Key_Up)
            for (const key of ["aurora", "daylight"]) {
                DeviceSettings.theme = key
                tryCompare(Theme, "lightTheme", key === "daylight")
                wait(900)
                grabImage(tc.shell).save(shotsDir + "/28d-settings-scroll-middle-" + key + ".png")
            }
        }
    }
}
