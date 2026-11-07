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
            DeviceSettings.theme = "dreamglass"
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.overscan = 0.05
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

        readonly property int displayIndex: 3
        readonly property int storageIndex: 5
        readonly property int accessibilityIndex: 6
        readonly property int aboutIndex: 8

        function test_two_pane_navigation() {
            openSettings()
            const list = find("categoryList")
            compare(list.currentIndex, 0)
            verify(find("paneProfiles").visible, "Profiles has a pane (T-105)")
            verify(!find("paneComingSoon").visible)
            keyClick(Qt.Key_Down)                        // Network has a pane (T-129)
            compare(list.currentIndex, 1)
            verify(find("paneNetwork").visible)
            verify(!find("paneComingSoon").visible)
            verify(!find("paneProfiles").visible)
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
            verify(!find("paneAbout").visible)

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
            keyClick(Qt.Key_Down)                        // clamped at the last row
            verify(find("rowWallpaper").activeFocus)
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
            for (const [index, name] of [[tc.displayIndex, "paneDisplay"], [7, "paneSystem"]]) {
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
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Up)
            compare(toggle.checked, false)
            keyClick(Qt.Key_Return)
            compare(toggle.checked, true)
            keyClick(Qt.Key_Enter)
            compare(toggle.checked, false)
            compare(spy.count, 2)
            compare(Sfx.selectCount, selects + 2, "Accept takes the select sound path")

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
            keyClick(Qt.Key_Down)
            compare(choice.value, "a")
            keyClick(Qt.Key_Right)
            compare(choice.value, "b")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(choice.value, "a", "wraps past the last option")
            keyClick(Qt.Key_Left)
            compare(choice.value, "c", "wraps before the first option")
            compare(spy.count, 4)
            compare(Sfx.navigateCount, navs + 4, "changes take the navigate sound path")

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
            verify(find("aboutLicence").activeFocus, "clamps at the last row")
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
