import QtQuick
import QtTest
import RuyaShell

// The Options menu component (04 §5, 02 §1.7, RUY-16) on its own: the sheet's numbers at 1080p (u = 1:
// the menu is a 1920 x 1080 item, the window only shows part of it), placement beside a card or a pill,
// the screen-edge fallback, the keys, the empty and error sheets, rows rebuilt in place; with the Hold
// ring, `ArtCard.anchored` and the input times (04 §3.4). The surfaces that use it are tst_options_shell.
Item {
    id: host
    width: 1280
    height: 720

    // A menu with a parent that records the keys it does not take (Guide goes on to the Shell).
    Component {
        id: wrapComponent
        Item {
            id: wrap
            property alias menu: m
            property var leaked: []
            property var focusTarget: target
            property bool shownAtActivation: true
            property bool focusAtActivation: false
            width: 1920
            height: 1080
            Keys.onPressed: event => { wrap.leaked.push(event.key) }
            FocusScope {
                id: target
                objectName: "returnTarget"
                focus: true
                width: 10
                height: 10
            }
            OptionsMenu {
                id: m
                width: 1920
                height: 1080
                marginX: 96
                marginY: 54
                guideKey: key => key === Qt.Key_HomePage
            }
        }
    }

    Component { id: anchorComponent; Rectangle { color: "red" } }
    Component { id: cardComponent; ArtCard { itemId: "x"; title: "Card" } }
    Component { id: ringComponent; HoldRing { } }
    Component { id: holdComponent; AcceptHold { } }

    SignalSpy { id: activatedSpy; signalName: "activated" }
    SignalSpy { id: closedSpy; signalName: "closed" }
    SignalSpy { id: tapSpy; signalName: "tapped" }
    SignalSpy { id: longSpy; signalName: "longPressed" }

    TestCase {
        id: tc
        name: "OptionsMenu"
        when: windowShown

        property var wrap: null

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
        }

        function menuOf(u) {
            const w = createTemporaryObject(wrapComponent, host)
            verify(w)
            w.menu.u = u ?? 1
            tc.wrap = w
            return w.menu
        }

        function anchorAt(x, y, w, h) {
            return createTemporaryObject(anchorComponent, tc.wrap, { x: x, y: y, width: w, height: h })
        }

        function rowsOf(n, withDivider) {
            const out = []
            for (let i = 0; i < n; ++i)
                out.push({ id: "r" + i, label: "Row " + i, icon: "info", divider: withDivider === true && i === n - 1 })
            return out
        }

        function sheetOf(menu) { return findChild(menu, "optionsSheet") }
        function rowOf(menu, id) { return findChild(menu, "optionsRow_" + id) }

        // RUY-583: one journal line per opening (the VM check `vm-input-check.sh start` greps it), none for
        // a second open() of a menu that is already up (a row rebuilt in place), and none per key.
        function test_one_log_line_per_opening() {
            const menu = menuOf(1)
            const lines = []
            menu.log = text => lines.push(text)
            menu.open(anchorAt(548, 300, 400, 225), "card", "Turbo Racer", rowsOf(3, false), "")
            compare(lines, ["ruya-shell: options menu open (card)"])
            keyClick(Qt.Key_Down)
            menu.open(anchorAt(548, 300, 400, 225), "card", "Turbo Racer", rowsOf(3, false), "")
            compare(lines.length, 1)
            keyClick(Qt.Key_Menu)
            tryVerify(() => !menu.shown)
            menu.open(anchorAt(96, 782, 320, 180), "pill", "Filter", rowsOf(2, false), "")
            compare(lines.length, 2)
            compare(lines[1], "ruya-shell: options menu open (pill)")
        }

        // ---- the sheet's numbers ----

        // 7 rows + 1 divider = 698 u at 1080p; the divider delta is computed from the tokens, never 9.
        function test_seven_rows_and_a_divider_are_698_high() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "Turbo Racer", rowsOf(7, true), "")
            const sheet = sheetOf(menu)
            compare(menu.dividerDelta, 2 * Theme.spaceXs - Theme.spaceXs + Theme.hairlineAt(1))
            compare(menu.dividerDelta, 9)
            // the part that does not depend on the title's font: padding, gap, 7 rows, 6 gaps, the divider
            compare(sheet.height - menu.titleHeight, Theme.spaceL + Theme.spaceS + 7 * Theme.buttonHeight + 6 * Theme.spaceXs + 9 + Theme.spaceS)
            compare(sheet.height, 698)
            compare(sheet.width, 560)
            compare(menu.rowsHeight, 7 * 76 + 6 * 8 + 9)
        }

        function test_six_rows_are_605_high() {
            const menu = menuOf(1)
            menu.open(anchorAt(96, 782, 320, 180), "card", "Turbo Racer", rowsOf(6, false), "")
            compare(sheetOf(menu).height, 605)
        }

        function test_rows_divider_and_title_geometry() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "Turbo Racer", rowsOf(3, true), "")
            const sheet = sheetOf(menu)
            const title = findChild(menu, "optionsTitle")
            compare(title.x, 52, "inset spaceL from the content edge: 52 u from the sheet's edge")
            compare(title.y, 36)
            compare(title.font.pixelSize, Theme.typeHeadline)
            compare(title.text, "Turbo Racer")
            const first = rowOf(menu, "r0")
            const last = rowOf(menu, "r2")
            compare(first.height, 76)
            compare(first.width, 528)
            compare(first.mapToItem(sheet, 0, 0).x, 16, "spaceS at the sides")
            compare(first.mapToItem(sheet, 0, 0).y, 36 + title.height + 16, "spaceS under the title")
            compare(rowOf(menu, "r1").y - first.y, 76 + 8, "spaceXs apart")
            compare(last.y - rowOf(menu, "r1").y, 76 + 8 + 9, "the divider adds its delta")
            const divider = findChild(menu, "optionsDivider_r2")
            verify(divider.visible)
            compare(divider.height, Theme.hairlineAt(1))
            compare(divider.x, 36, "inset spaceL at both ends")
            compare(divider.width, 528 - 72)
            compare(divider.color, Theme.glassBorder)
            // spaceXs above it and below it
            compare(divider.y - (rowOf(menu, "r1").y + 76), 8)
            compare(last.y - (divider.y + divider.height), 8)
            verify(!findChild(menu, "optionsDivider_r1").visible, "only the flagged row has one")
            compare(sheet.radius, Theme.radiusL)
            compare(sheet.color, Theme.glassOpaque)
            verify(findChild(menu, "optionsLayers"), "sheen and lit rim")
            compare(findChild(menu, "optionsLayers").grain, false)
            compare(findChild(menu, "optionsShadow").kind, "panel")
        }

        function test_a_row_has_an_icon_a_label_and_a_ring_only_while_focused() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "Turbo Racer", rowsOf(3, false), "")
            const first = rowOf(menu, "r0")
            const second = rowOf(menu, "r1")
            compare(first.Accessible.role, Accessible.MenuItem)
            compare(first.Accessible.name, "Row 0")
            compare(menu.Accessible.role, Accessible.PopupMenu)
            compare(menu.Accessible.name, "Options for Turbo Racer")
            compare(findChild(first, "optionsRing").border.width, Theme.focusRingWidth)
            compare(findChild(second, "optionsRing").border.width, 0)
            compare(findChild(first, "optionsRing").border.color, Theme.focusRing)
            keyClick(Qt.Key_Down)
            compare(findChild(first, "optionsRing").border.width, 0)
            compare(findChild(second, "optionsRing").border.width, Theme.focusRingWidth)
            compare(findChild(second, "optionsLabel").font.pixelSize, Theme.typeBody)
            tryVerify(() => findChild(menu, "optionsGlide").targetY === second.y, 2000, "the fill glides to the focused row")
        }

        // ---- placement ----

        // Games, column 2 (x 548): beside the card. A 7-row sheet clamps above the hint bar band.
        function test_beside_a_card_in_column_2() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "Turbo Racer", rowsOf(7, true), "")
            compare(menu.placedSide, "right")
            compare(Math.round(menu.placedX), 999)
            compare(Math.round(menu.placedY), 264, "bottom <= 962 (1080 - 54 - 40 - 24)")
        }

        // Column 4 (x 1396): the sheet would pass the right safe-area edge, so it flips to the card's left.
        function test_flips_left_of_a_card_in_the_last_column() {
            const menu = menuOf(1)
            menu.open(anchorAt(1396, 300, 400, 225), "card", "Turbo Racer", rowsOf(7, true), "")
            compare(menu.placedSide, "left")
            compare(Math.round(menu.placedX), 785)
            compare(Math.round(menu.placedY), 264)
        }

        // Home's Recent card 1: x 464, the 6-row sheet is moved up to end at 962.
        function test_home_recent_card_is_clamped_above_the_hint_bar() {
            const menu = menuOf(1)
            menu.open(anchorAt(96, 782, 320, 180), "card", "Turbo Racer", rowsOf(6, false), "")
            compare(menu.placedSide, "right")
            compare(Math.round(menu.placedX), 464)
            compare(Math.round(menu.placedY), 357)
            compare(Math.round(menu.placedY + sheetOf(menu).height), 962)
        }

        // The top follows the card's scaled top (4 % of its height up) when it fits.
        function test_top_follows_the_scaled_card_top() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 200), "card", "Turbo Racer", rowsOf(3, false), "")
            compare(Math.round(menu.placedY * 10) / 10, 300 - 0.04 * 200)
        }

        function test_never_above_the_top_safe_area() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 0, 400, 225), "card", "Turbo Racer", rowsOf(3, false), "")
            compare(menu.placedY, 54)
        }

        // A pill does not scale: no 4 % term; the menu is placed from the pill's right edge.
        function test_beside_a_hero_pill() {
            const menu = menuOf(1)
            menu.open(anchorAt(96, 500, 220, 84), "pill", "Turbo Racer", rowsOf(3, false), "")
            compare(menu.placedSide, "right")
            compare(menu.placedX, 96 + 220 + Theme.focusRingOffset + Theme.focusRingWidth + Theme.spaceM)
            compare(menu.placedY, 500, "the pill's own top")
        }

        // A large UI size: neither side has room, so the sheet sits on the right safe-area edge, centred.
        function test_edge_fallback_at_ui_size_200() {
            const menu = menuOf(2)
            menu.open(anchorAt(548, 300, 800, 450), "card", "Turbo Racer", rowsOf(3, false), "")
            compare(menu.placedSide, "edge")
            const sheet = sheetOf(menu)
            compare(sheet.width, 1120)
            compare(menu.placedX + sheet.width, 1920 - 96, "right edge on the right safe-area edge")
            const bottomLimit = 1080 - 54 - (Theme.glyphSize + Theme.spaceM) * 2
            compare(Math.round(menu.placedY + sheet.height / 2), Math.round((54 + bottomLimit) / 2))
        }

        function test_a_row_always_uses_the_edge() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 80), "row", "Controller", rowsOf(3, false), "")
            compare(menu.placedSide, "edge")
            compare(menu.placedX + 560, 1920 - 96)
        }

        // A list that is still scrolling to the card when the menu opens: the sheet goes where the card ends up.
        function test_the_sheet_follows_a_moving_anchor() {
            const menu = menuOf(1)
            const anchor = anchorAt(548, 300, 400, 225)
            menu.open(anchor, "card", "T", rowsOf(3, false), "")
            compare(Math.round(menu.placedX), 999)
            anchor.x = 96
            tryVerify(() => Math.round(menu.placedX) === 96 + 400 + 16 + 35, 2000, "it follows the card")
            anchor.x = 1396
            tryVerify(() => menu.placedSide === "left", 2000, "and flips when the card reaches the last column")
        }

        // ---- motion ----

        function test_it_fades_in_and_out() {
            const menu = menuOf(1)
            verify(!menu.visible)
            menu.open(anchorAt(548, 300, 400, 225), "card", "T", rowsOf(2, false), "")
            verify(menu.visible)
            tryVerify(() => menu.opacity >= 1, 2000)
            compare(menu.slide, 0)
            menu.close()
            verify(!menu.shown, "closed at once for the keys")
            tryVerify(() => !menu.visible, 2000, "faded out")
        }

        function test_reduced_motion_cuts() {
            DeviceSettings.reducedMotion = true
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "T", rowsOf(2, false), "")
            compare(menu.opacity, 1)
            compare(menu.slide, 0)
            menu.close()
            verify(!menu.visible)
            DeviceSettings.reducedMotion = false
        }

        // ---- keys ----

        function test_up_and_down_stop_at_the_ends() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "T", rowsOf(3, false), "")
            compare(menu.current, 0)
            keyClick(Qt.Key_Up)
            compare(menu.current, 0, "no wrap at the top")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            compare(menu.current, 2)
            keyClick(Qt.Key_Down)
            compare(menu.current, 2, "no wrap at the bottom")
            keyClick(Qt.Key_Up)
            compare(menu.current, 1)
        }

        function test_auto_repeat_moves() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "T", rowsOf(4, false), "")
            keyPress(Qt.Key_Down)
            keyPress(Qt.Key_Down)
            keyRelease(Qt.Key_Down)
            compare(menu.current, 2)
        }

        // Accept: the menu has closed (and the focus is back) when the row's action is told.
        function test_accept_closes_first_and_runs_the_row() {
            const menu = menuOf(1)
            activatedSpy.target = menu
            activatedSpy.clear()
            menu.open(anchorAt(548, 300, 400, 225), "card", "T", rowsOf(3, false), "")
            menu.activated.connect(id => { tc.wrap.shownAtActivation = menu.shown; tc.wrap.focusAtActivation = tc.wrap.focusTarget.activeFocus })
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            compare(activatedSpy.count, 1)
            compare(activatedSpy.signalArguments[0][0], "r1")
            compare(tc.wrap.shownAtActivation, false)
            compare(tc.wrap.focusAtActivation, true)
        }

        function test_back_and_menu_close_with_the_focus_on_the_item() {
            const menu = menuOf(1)
            closedSpy.target = menu
            for (const key of [Qt.Key_Escape, Qt.Key_Menu, Qt.Key_Backspace]) {
                closedSpy.clear()
                tc.wrap.focusTarget.forceActiveFocus()
                menu.open(anchorAt(548, 300, 400, 225), "card", "T", rowsOf(3, false), "")
                verify(menu.activeFocus, "the menu has the focus")
                keyClick(key)
                compare(closedSpy.count, 1)
                verify(!menu.shown)
                verify(tc.wrap.focusTarget.activeFocus, "the focus is back on the item at once")
            }
        }

        function test_every_other_key_is_taken_but_guide() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "T", rowsOf(3, false), "")
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_PageDown)
            keyClick(Qt.Key_X)
            compare(tc.wrap.leaked, [], "nothing reaches the Shell")
            verify(menu.shown)
            keyClick(Qt.Key_HomePage)
            compare(tc.wrap.leaked, [Qt.Key_HomePage], "Guide is not taken: the Shell opens the Hub")
        }

        function test_dismiss_leaves_a_focus_that_moved() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "T", rowsOf(3, false), "")
            const other = createTemporaryObject(anchorComponent, tc.wrap, { focus: true, activeFocusOnTab: true })
            other.forceActiveFocus()
            menu.dismiss()
            verify(!menu.shown)
            verify(other.activeFocus, "the Hub's (here: another item's) focus is kept")
        }

        // ---- empty, error ----

        function test_empty_menu() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "Counter Strike", [], "")
            const empty = findChild(menu, "optionsEmpty")
            verify(empty.visible)
            compare(empty.text, "No options for this yet.")
            compare(empty.font.pixelSize, Theme.typeBody)
            compare(empty.y, 36 + menu.titleHeight + 16)
            compare(sheetOf(menu).height, 36 + menu.titleHeight + 16 + empty.implicitHeight + 36)
            compare(menu.modalHints.length, 1)
            compare(menu.modalHints[0].button, "B")
            verify(menu.activeFocus, "the sheet holds the focus itself")
            keyClick(Qt.Key_Return)
            verify(menu.shown, "Accept does nothing on an empty menu")
            keyClick(Qt.Key_Escape)
            verify(!menu.shown)
        }

        function test_rows_hint_is_select_and_close() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "T", rowsOf(2, false), "")
            compare(menu.modalHints.map(h => h.button + " " + h.text).join("|"), "A Select|B Close")
        }

        function test_the_error_note_ends_the_menu() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "Turbo Racer", rowsOf(2, false), "Store options are unavailable right now.")
            const note = findChild(menu, "optionsNote")
            verify(note.visible)
            compare(note.font.pixelSize, Theme.typeCaption)
            compare(note.x, 52, "inset spaceL")
            compare(note.y, menu.bodyTop + menu.rowsHeight + Theme.spaceS, "spaceS under the last row")
            verify(!findChild(menu, "optionsEmpty").visible)
            compare(sheetOf(menu).height, menu.bodyTop + menu.rowsHeight + Theme.spaceS + note.implicitHeight + Theme.spaceS)
        }

        // No row left: the title, the note and B Close only, without the "No options for this yet." line.
        function test_the_note_without_a_row_has_no_empty_line() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "Turbo Racer", [], "Store options are unavailable right now.")
            verify(findChild(menu, "optionsNote").visible)
            verify(!findChild(menu, "optionsEmpty").visible)
            compare(findChild(menu, "optionsNote").y, menu.bodyTop)
            compare(menu.modalHints.map(h => h.button).join(""), "B")
        }

        function test_a_long_title_is_cut_at_the_end_on_one_line() {
            const menu = menuOf(1)
            const name = "A game whose title is much too long to fit in the 456 wide line of the sheet"
            menu.open(anchorAt(548, 300, 400, 225), "card", name, rowsOf(2, false), "")
            const title = findChild(menu, "optionsTitle")
            verify(title.width <= 456)
            verify(title.text.endsWith("…"))
            compare(title.maximumLineCount, 1)
            compare(title.Accessible.name, name, "the full name is the accessible one")
            compare(title.textFormat, Text.PlainText)
        }

        // ---- rows rebuilt in place ----

        function test_rows_change_keeps_the_focus_on_the_same_action() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "T", [{ id: "play", label: "Play", icon: "play_arrow" },
                { id: "details", label: "Details", icon: "info" }, { id: "activity", label: "Your activity", icon: "bar_chart" }], "")
            keyClick(Qt.Key_Down)
            compare(menu.current, 1)
            // the game started: Play is gone, Resume and Close come first; Details is still there
            menu.rows = [{ id: "resume", label: "Resume", icon: "play_arrow" }, { id: "close", label: "Close game", icon: "close" },
                { id: "details", label: "Details", icon: "info" }, { id: "activity", label: "Your activity", icon: "bar_chart" }]
            compare(menu.current, 2)
            compare(menu.rows[menu.current].id, "details")
        }

        function test_rows_change_without_the_action_focuses_the_row_now_at_that_place() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "T", rowsOf(3, false), "")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            compare(menu.current, 2)
            menu.rows = rowsOf(2, false)
            compare(menu.current, 1, "the last row is the one now at that place")
            menu.rows = [{ id: "z", label: "Z", icon: "info" }]
            compare(menu.current, 0)
            verify(rowOf(menu, "z"))
        }

        function test_every_opening_starts_on_the_first_row() {
            const menu = menuOf(1)
            menu.open(anchorAt(548, 300, 400, 225), "card", "T", rowsOf(3, false), "")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Escape)
            menu.open(anchorAt(548, 300, 400, 225), "card", "T", rowsOf(3, false), "")
            compare(menu.current, 0)
        }

        // ---- the Hold ring and the anchored card ----

        function test_hold_ring_geometry_and_cut() {
            const ring = createTemporaryObject(ringComponent, host, { u: 1 })
            compare(ring.width, Theme.buttonHeight)
            compare(ring.height, Theme.buttonHeight)
            verify(!ring.visible)
            compare(ring.Accessible.ignored, true)
            ring.shown = true
            tryVerify(() => ring.opacity >= 1, 2000, "it fades in")
            ring.progress = 0.5
            const arc = findChild(ring, "holdRingArc")
            compare(arc.strokeWidth, Theme.focusRingWidth)
            compare(arc.strokeColor, Theme.focusRing)
            compare(findChild(ring, "holdRingTrack").strokeColor, Theme.glassBorder)
            ring.shown = false
            compare(ring.opacity, 0, "a release cuts it")
            verify(!ring.visible)
        }

        function test_an_anchored_card_keeps_its_lift_but_not_its_ring() {
            const card = createTemporaryObject(cardComponent, host, { focused: true })
            compare(findChild(card, "cardRing").border.width, Theme.focusRingWidth)
            card.anchored = true
            compare(findChild(card, "cardRing").border.width, 0, "no ring")
            tryCompare(card, "scale", Theme.focusScale)
            compare(findChild(card, "cardLiftShadow").active, true, "the lift stays")
            compare(findChild(card, "cardFocusLayers").focused, true, "and the sheen")
            // the menu took the focus: the card is anchored only
            card.focused = false
            compare(card.scale, Theme.focusScale)
            compare(findChild(card, "cardRing").border.width, 0)
            card.anchored = false
            tryCompare(card, "scale", 1.0)
        }

        // ---- the input times (04 §3.4) ----

        function test_input_times_are_not_scaled_by_motion() {
            compare(Theme.longPressMs, 500)
            compare(Theme.holdRingDelayMs, 200)
            DeviceSettings.reducedMotion = true
            compare(Theme.motionScale, 0)
            compare(Theme.longPressMs, 500, "reduced motion")
            compare(Theme.holdRingDelayMs, 200)
            DeviceSettings.reducedMotion = false
            Theme.motionFactor = 0.1
            compare(Theme.longPressMs, 500, "motionFactor 0.1")
            compare(Theme.holdRingDelayMs, 200)
            compare(Theme.guideHoldMs, 2000)
            verify(Theme.holdRingDelayMs < Theme.longPressMs)
        }

        // ---- AcceptHold ----

        function press(hold, key, repeat) { return hold.press({ key: key ?? Qt.Key_Return, isAutoRepeat: repeat === true }) }
        function release(hold, key, repeat) { return hold.release({ key: key ?? Qt.Key_Return, isAutoRepeat: repeat === true }) }

        function test_a_tap_acts_on_release_and_shows_no_ring() {
            const hold = createTemporaryObject(holdComponent, host)
            tapSpy.target = hold
            longSpy.target = hold
            tapSpy.clear()
            longSpy.clear()
            verify(press(hold))
            verify(hold.pressing)
            compare(tapSpy.count, 0, "nothing on the press")
            verify(!hold.ringShown, "no ring before holdRingDelayMs")
            verify(release(hold))
            compare(tapSpy.count, 1)
            compare(longSpy.count, 0)
            verify(!hold.pressing)
            wait(Theme.holdRingDelayMs + 100)
            verify(!hold.ringShown, "and the ring does not come after a release")
            compare(longSpy.count, 0, "the timer was cancelled")
        }

        function test_a_hold_shows_the_ring_then_opens_and_its_release_does_nothing() {
            const hold = createTemporaryObject(holdComponent, host)
            tapSpy.target = hold
            longSpy.target = hold
            tapSpy.clear()
            longSpy.clear()
            press(hold)
            tryVerify(() => hold.ringShown, 2000, "the ring shows after holdRingDelayMs")
            verify(hold.heldMs >= Theme.holdRingDelayMs)
            verify(hold.ringProgress >= 0 && hold.ringProgress < 1)
            tryCompare(longSpy, "count", 1, 3000)
            verify(!hold.ringShown, "the disc goes when the menu opens")
            release(hold)
            compare(tapSpy.count, 0, "its release does nothing")
        }

        function test_the_arc_runs_linearly_from_the_ring_to_the_long_press() {
            const hold = createTemporaryObject(holdComponent, host)
            longSpy.target = hold
            longSpy.clear()
            press(hold)
            tryVerify(() => hold.ringShown, 2000)
            const early = hold.ringProgress
            tryVerify(() => hold.ringProgress > early + 0.2, 2000, "it grows")
            tryCompare(longSpy, "count", 1, 3000)
            compare(hold.ringProgress, 0)
        }

        // The press must have been seen on this item.
        function test_a_stray_release_does_nothing() {
            const hold = createTemporaryObject(holdComponent, host)
            tapSpy.target = hold
            longSpy.target = hold
            tapSpy.clear()
            longSpy.clear()
            verify(release(hold), "an Accept key is consumed")
            compare(tapSpy.count, 0)
            wait(Theme.longPressMs + 100)
            compare(longSpy.count, 0, "and starts no hold")
        }

        function test_auto_repeat_is_ignored() {
            const hold = createTemporaryObject(holdComponent, host)
            tapSpy.target = hold
            tapSpy.clear()
            press(hold)
            const held = hold.heldMs
            verify(press(hold, Qt.Key_Return, true), "a repeat is consumed")
            verify(hold.pressing)
            release(hold, Qt.Key_Return, true)
            verify(hold.pressing, "a repeat's release is not the release")
            compare(tapSpy.count, 0)
            release(hold)
            compare(tapSpy.count, 1)
            verify(held >= 0)
        }

        function test_cancel_drops_the_hold() {
            const hold = createTemporaryObject(holdComponent, host)
            tapSpy.target = hold
            longSpy.target = hold
            tapSpy.clear()
            longSpy.clear()
            press(hold)
            hold.cancel()
            verify(!hold.pressing)
            release(hold)
            compare(tapSpy.count, 0)
            wait(Theme.longPressMs + 100)
            compare(longSpy.count, 0)
        }

        function test_other_keys_and_an_inactive_hold_are_not_handled() {
            const hold = createTemporaryObject(holdComponent, host)
            verify(!press(hold, Qt.Key_Left))
            verify(!release(hold, Qt.Key_Left))
            hold.active = false
            verify(!press(hold))
            verify(!hold.pressing)
        }

        function test_the_hold_times_are_the_same_under_reduced_motion() {
            DeviceSettings.reducedMotion = true
            const hold = createTemporaryObject(holdComponent, host)
            longSpy.target = hold
            longSpy.clear()
            press(hold)
            verify(!hold.ringShown, "not at once")
            tryVerify(() => hold.ringShown, 2000, "the ring still waits holdRingDelayMs")
            verify(hold.heldMs >= Theme.holdRingDelayMs)
            compare(longSpy.count, 0, "and the menu longPressMs")
            tryCompare(longSpy, "count", 1, 3000)
            DeviceSettings.reducedMotion = false
        }
    }
}
