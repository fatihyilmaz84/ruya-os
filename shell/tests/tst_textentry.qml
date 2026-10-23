import QtQuick
import QtTest
import RuyaShell

// On-screen keyboard. TextEntry is hosted directly in the test window, over a "page" item
// that must never see a key while the keyboard is open. The controller tests use only
// arrows, Return (Accept), Escape (Back), Menu (Start) and PageUp/PageDown (LB/RB); the
// helper goTo() walks the D-pad from the current key to a target key.
Item {
    id: host
    width: 1280
    height: 720

    // Stands in for whatever page opened the keyboard.
    Rectangle {
        id: page
        objectName: "page"
        anchors.fill: parent
        color: "#223"
        focus: true
        property int keysSeen: 0
        Keys.onPressed: event => { page.keysSeen++; event.accepted = true }
    }

    TextEntry {
        id: entry
        objectName: "entry"
        anchors.fill: parent
        u: host.height / 1080
    }

    SignalSpy { id: acceptedSpy; target: entry; signalName: "accepted" }
    SignalSpy { id: cancelledSpy; target: entry; signalName: "cancelled" }

    TestCase {
        id: tc
        name: "TextEntry"
        when: windowShown

        function init() {
            DeviceSettings.language = "en"
            entry.shown = false
            entry.text = ""
            acceptedSpy.clear()
            cancelledSpy.clear()
            page.keysSeen = 0
            page.forceActiveFocus()
            verify(page.activeFocus)
        }

        function openEntry(title, initial, options) {
            entry.open(title, initial, options)
            verify(entry.shown)
            tryVerify(() => entry.activeFocus, 2000, "the keyboard takes focus")
        }

        // Position of the first key with this value (or kind) on the current page.
        function find(value) {
            for (let r = 0; r < entry.rows.length; ++r) {
                const c = entry.rows[r].keys.findIndex(k => k.value === value || k.kind === value)
                if (c >= 0)
                    return { row: r, col: c }
            }
            return null
        }

        // Walks the D-pad to the key; fails the test if it cannot get there.
        function goTo(value) {
            const target = find(value)
            verify(target !== null, "key '" + value + "' exists on this page")
            for (let step = 0; step < 60; ++step) {
                if (entry.focusRow === target.row && entry.focusCol === target.col)
                    return
                if (entry.focusRow !== target.row) {
                    keyClick(entry.focusRow < target.row ? Qt.Key_Down : Qt.Key_Up)
                } else {
                    const n = entry.rows[target.row].keys.length
                    const right = (target.col - entry.focusCol + n) % n
                    keyClick(right <= n - right ? Qt.Key_Right : Qt.Key_Left)
                }
            }
            fail("could not reach '" + value + "'")
        }

        function pressKey(value) {
            goTo(value)
            keyClick(Qt.Key_Return)
        }

        function test_dpad_typing() {
            openEntry("Profile name", "")
            pressKey("shift")
            pressKey("a")                              // "A"
            pressKey("d")
            pressKey("a")
            pressKey("space")
            pressKey("2")
            compare(entry.text, "Ada 2")
            compare(acceptedSpy.count, 0)
            pressKey("done")
            compare(acceptedSpy.count, 1)
            compare(acceptedSpy.signalArguments[0][0], "Ada 2")
            compare(cancelledSpy.count, 0)
            verify(!entry.shown)
            compare(page.keysSeen, 0, "no key leaked to the page")
        }

        function test_back_semantics() {
            openEntry("Name", "ab")
            keyClick(Qt.Key_Escape)
            compare(entry.text, "a")
            compare(cancelledSpy.count, 0)
            keyClick(Qt.Key_Escape)
            compare(entry.text, "")
            compare(cancelledSpy.count, 0)
            verify(entry.shown, "still open on an empty field")
            keyClick(Qt.Key_Escape)
            compare(cancelledSpy.count, 1)
            compare(acceptedSpy.count, 0)
            verify(!entry.shown)
            keyClick(Qt.Key_Escape)                    // goes to the page now, not the keyboard
            compare(cancelledSpy.count, 1, "cancelled() is emitted exactly once")
        }

        function test_shift_one_shot() {
            openEntry("Name", "")
            compare(entry.shift, false)
            pressKey("shift")
            compare(entry.shift, true)
            pressKey("q")
            compare(entry.text, "Q")
            compare(entry.shift, false, "shift turns itself off")
            pressKey("w")
            compare(entry.text, "Qw")

            pressKey("shift")                          // pressing it twice cancels it
            pressKey("shift")
            compare(entry.shift, false)
            pressKey("e")
            compare(entry.text, "Qwe")
        }

        function test_max_length() {
            openEntry("Code", "", { maxLength: 3 })
            pressKey("1")
            pressKey("2")
            pressKey("3")
            compare(entry.text, "123")
            pressKey("4")                              // grid: rejected
            compare(entry.text, "123")
            keyClick("x")                              // physical keyboard: rejected
            compare(entry.text, "123")
            keyClick(Qt.Key_Backspace)
            compare(entry.text, "12")
            keyClick("y")
            compare(entry.text, "12y")
            keyClick("z")
            compare(entry.text, "12y")

            entry.shown = false
            openEntry("Code", "abcdef", { maxLength: 4 })
            compare(entry.text, "abcd", "initial text is cut to maxLength")
        }

        function test_mask() {
            openEntry("Wi-Fi password", "", { mask: true })
            pressKey("s")
            pressKey("e")
            pressKey("1")
            compare(entry.text, "se1")
            compare(entry.displayText, "•••")
            const shownText = findChild(entry, "entryDisplay")
            compare(shownText.text, "•••", "the field shows dots")
            pressKey("done")
            compare(acceptedSpy.count, 1)
            compare(acceptedSpy.signalArguments[0][0], "se1", "accepted carries the real text")
        }

        function test_vertical_navigation_nearest() {
            openEntry("Name", "")
            // Hand-checked cases (letters page): the rows are staggered.
            entry.focusRow = 1; entry.focusCol = 0         // q
            keyClick(Qt.Key_Down)
            compare(entry.focusedKey.value, "a")
            entry.focusRow = 1; entry.focusCol = 1         // w: a and s are equally near; left wins
            keyClick(Qt.Key_Down)
            compare(entry.focusedKey.value, "a")
            entry.focusRow = 2; entry.focusCol = 0         // a -> Shift (nearest centre)
            keyClick(Qt.Key_Down)
            compare(entry.focusedKey.kind, "shift")
            entry.focusRow = 2; entry.focusCol = 1         // s -> z (same centre)
            keyClick(Qt.Key_Down)
            compare(entry.focusedKey.value, "z")
            entry.focusRow = 3; entry.focusCol = 5         // b -> Space
            keyClick(Qt.Key_Down)
            compare(entry.focusedKey.kind, "space")

            // Every key in the top row, checked against a brute-force nearest search.
            const top = entry.rows[0].keys
            for (let c = 0; c < top.length; ++c) {
                entry.focusRow = 0
                entry.focusCol = c
                keyClick(Qt.Key_Down)
                compare(entry.focusRow, 1)
                const below = entry.rows[1].keys
                let best = 0
                for (let i = 1; i < below.length; ++i) {
                    if (Math.abs(below[i].cx - top[c].cx) < Math.abs(below[best].cx - top[c].cx) - 1e-9)
                        best = i
                }
                compare(entry.focusCol, best, "Down from top-row key " + c)
            }

            // Up from the top row stays put; Left/Right wrap within the row.
            entry.focusRow = 0; entry.focusCol = 0
            keyClick(Qt.Key_Up)
            compare(entry.focusRow, 0)
            keyClick(Qt.Key_Left)
            compare(entry.focusCol, 9, "wraps to the end of the row")
            keyClick(Qt.Key_Right)
            compare(entry.focusCol, 0, "and back to the start")
            compare(page.keysSeen, 0)
        }

        function test_modal_and_focus_restore() {
            openEntry("Name", "")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_HomePage)                  // Guide is swallowed too
            keyClick(Qt.Key_VolumeUp)
            keyClick(Qt.Key_Tab)
            compare(page.keysSeen, 0, "the page sees nothing while the keyboard is open")
            verify(!page.activeFocus)
            pressKey("a")
            pressKey("done")
            verify(!entry.shown)
            tryVerify(() => page.activeFocus, 2000, "focus returns to the page's item")
            compare(page.keysSeen, 0)

            openEntry("Name", "x")                     // the cancel path restores it as well
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            verify(!entry.shown)
            tryVerify(() => page.activeFocus)
            compare(cancelledSpy.count, 1)
            compare(page.keysSeen, 0)
        }

        function test_controller_shortcuts() {
            openEntry("Name", "")
            keyClick(Qt.Key_PageUp)                    // LB: Backspace
            compare(entry.focusedKey.kind, "back")
            keyClick(Qt.Key_PageDown)                  // RB: Space
            compare(entry.focusedKey.kind, "space")
            keyClick(Qt.Key_Return)
            compare(entry.text, " ")

            keyClick(Qt.Key_PageUp)
            keyClick(Qt.Key_Return)                    // Backspace key
            compare(entry.text, "")

            keyClick(Qt.Key_Menu)                      // Start = Done, but not while empty
            compare(acceptedSpy.count, 0)
            verify(entry.shown, "Done does nothing on an empty field")

            pressKey("k")
            keyClick(Qt.Key_Menu)
            compare(acceptedSpy.count, 1)
            compare(acceptedSpy.signalArguments[0][0], "k")
        }

        function test_done_disabled_when_empty() {
            openEntry("Name", "")
            pressKey("done")                           // Accept on a dimmed Done: no-op
            compare(acceptedSpy.count, 0)
            verify(entry.shown)
            verify(!entry.canFinish)
            pressKey("a")
            verify(entry.canFinish)
        }

        function test_physical_keyboard() {
            openEntry("Name", "")
            keyClick("h")
            keyClick("i")
            keyClick(" ")
            keyClick("!")
            compare(entry.text, "hi !")
            keyClick(Qt.Key_Backspace)
            keyClick(Qt.Key_Backspace)
            compare(entry.text, "hi")
            keyClick(Qt.Key_Enter)                     // keypad Enter = Done
            compare(acceptedSpy.count, 1)
            compare(acceptedSpy.signalArguments[0][0], "hi")

            openEntry("Name", "")                      // typed on a keyboard: Return = Done
            keyClick("o")
            keyClick("k")
            keyClick(Qt.Key_Return)
            compare(acceptedSpy.count, 2)
            compare(acceptedSpy.signalArguments[1][0], "ok")

            openEntry("Name", "")                      // typed on a keyboard: Escape = Cancel
            keyClick("n")
            keyClick("o")
            keyClick(Qt.Key_Escape)
            compare(cancelledSpy.count, 1)
            verify(!entry.shown)

            openEntry("Name", "")                      // a D-pad key switches back to controller mode
            keyClick("a")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                    // presses the focused key, not Done
            verify(entry.shown)
            compare(entry.text.length, 2)
            compare(page.keysSeen, 0)
        }

        function test_layouts_and_symbols() {
            openEntry("Address", "", { layout: "email" })
            verify(find("@") !== null)
            verify(find(".com") !== null)
            pressKey("a")
            pressKey("@")
            pressKey("b")
            pressKey(".com")
            compare(entry.text, "a@b.com")

            entry.shown = false
            openEntry("Address", "", { layout: "url" })
            verify(find("/") !== null)
            verify(find(".com") !== null)
            verify(find("@") === null, "no @ key on the letters page of a url layout")
            pressKey("/")
            compare(entry.text, "/")

            entry.shown = false
            openEntry("Name", "", { layout: "bogus" })
            compare(entry.layout, "text")
            verify(find(".com") === null)

            pressKey("symbols")                        // symbols page
            verify(entry.symbols)
            verify(find("!") !== null)
            verify(find("q") === null)
            pressKey("#")
            compare(entry.text, "#")
            pressKey("symbols")                        // and back
            verify(!entry.symbols)
            verify(find("q") !== null)
        }

        function test_turkish_layout() {
            openEntry("Ad", "")
            verify(find("ç") === null, "English layout has no Turkish letters")
            DeviceSettings.language = "tr"
            for (const c of "çğıöşü")
                verify(find(c) !== null, "Turkish layout has " + c)
            for (const row of entry.rows) {
                let width = 0
                for (const k of row.keys)
                    width += k.w
                const lead = row.keys[0].x
                compare(Math.round((width + 2 * lead) * 1000) / 1000, 10, "every row stays 10 key units")
            }
            pressKey("ç")
            pressKey("ı")
            pressKey("shift")
            pressKey("i")                              // Shift + i -> İ
            pressKey("shift")
            pressKey("ı")                              // Shift + ı -> I
            compare(entry.text, "çıİI")
            DeviceSettings.language = "en"
            verify(find("ç") === null, "back to the English layout")
            verify(find("q") !== null)
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openEntry("Profile name", "Ada")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Right)
            wait(600)
            grabImage(host).save(shotsDir + "/9-text-entry.png")
            DeviceSettings.language = "tr"
            wait(600)
            grabImage(host).save(shotsDir + "/16b-keyboard-tr.png")
        }
    }
}
