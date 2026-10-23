pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Modal on-screen keyboard, fully controller-driven. Use it for every text input; never a
// raw TextInput without it.
//
//   entry.open("Profile name", "", { maxLength: 24, mask: false, layout: "text" })
//   onAccepted: text => ...      onCancelled: ...
//
// Controller (keys from ruya-inputd): D-pad moves over the keys (wraps within a row, moves
// to the nearest key by x-position between rows), Accept presses the focused key, Back
// deletes a character (and cancels when the field is empty), Start/Menu is Done, LB/RB jump
// to Backspace/Space. Physical keyboard: printable keys insert, Backspace deletes, Enter is
// Done. A controller's Accept/Back arrive as Return/Escape, the same keys a keyboard sends,
// so after the user has typed on a physical keyboard (until the next D-pad key) Return means
// Done and Escape means Cancel.
// The layout is data (layoutFor): rows of keys with a width in key units.
FocusScope {
    id: entry

    property real u: 1

    property string title
    property string text
    property bool mask: false
    property string layout: "text"        // "text" | "email" | "url"
    property int maxLength: 0             // 0 = unlimited
    property bool shown: false

    property bool shift: false            // one-shot: applies to the next character
    property bool symbols: false          // symbols page instead of letters
    property int focusRow: 1
    property int focusCol: 0
    property bool keyboardMode: false     // last input came from a physical keyboard

    readonly property var rows: layoutFor(symbols, layout, DeviceSettings.language)
    readonly property var focusedKey: rows[focusRow].keys[focusCol]
    readonly property string displayText: mask ? "•".repeat(text.length) : text
    readonly property bool canFinish: text.length > 0

    // Geometry, in design px (times u).
    readonly property real keyUnit: 98
    readonly property real keyGap: 10
    readonly property real keyHeight: 84

    signal accepted(string text)
    signal cancelled()

    property Item previousFocus: null

    function open(title, initialText, options) {
        const o = options ?? {}
        entry.title = title ?? ""
        entry.maxLength = o.maxLength ?? 0
        entry.mask = o.mask ?? false
        entry.layout = ["text", "email", "url"].includes(o.layout) ? o.layout : "text"
        entry.text = maxLength > 0 ? (initialText ?? "").slice(0, maxLength) : (initialText ?? "")
        shift = false
        symbols = false
        keyboardMode = false
        focusRow = 1
        focusCol = 0
        previousFocus = Window.activeFocusItem
        shown = true
        forceActiveFocus()
    }

    function close() {
        shown = false
        const back = previousFocus
        previousFocus = null
        if (back && back.visible && back.enabled)
            back.forceActiveFocus()
    }

    function finish() {
        if (!canFinish) {
            Sfx.back()
            return
        }
        Sfx.select()
        const result = text
        close()
        accepted(result)
    }

    function cancel() {
        Sfx.back()
        close()
        cancelled()
    }

    function insert(s) {
        if (maxLength > 0 && text.length + s.length > maxLength) {
            Sfx.back()
            return false
        }
        text += s
        return true
    }

    function backspace() {
        text = text.slice(0, -1)
    }

    // Rows of keys with geometry in key units: x (left edge) and cx (centre). The row
    // widths are 10 units on every page, so the columns line up across rows.
    //
    // Letters per language: a language is one data entry (add one for each in DeviceSettings.isValidLanguage).
    // Rows with more keys than fit are narrowed so every row stays 10 units; `upper` lists the
    // shift mappings that toUpperCase() gets wrong (Turkish dotted/dotless i).
    readonly property var letterSets: ({
        en: { top: "qwertyuiop", home: "asdfghjkl", bottom: "zxcvbnm", upper: {} },
        tr: { top: "qwertyuıopğü", home: "asdfghjklşi", bottom: "zxcvbnmöç", upper: { "i": "İ", "ı": "I" } },
    })

    function layoutFor(onSymbols, kind, lang) {
        const chr = (label, w) => ({ kind: "char", label: label, value: label, w: w ?? 1 })
        const chars = s => Array.from(s).map(c => chr(c))
        const act = (type, label, w) => ({ kind: type, label: label, value: type, w: w })
        const space = w => act("space", qsTr("Space"), w)
        const done = act("done", qsTr("Done"), 2)
        const back = act("back", qsTr("Del"), 1.5)
        const set = letterSets[lang] ?? letterSets.en
        // A row of letters filling 10 units: keys are 1 unit wide, narrower when there are more
        // than fit; a short row is centred. `sides` is the number of action keys around it.
        const fitted = (letters, sides, before, after) => {
            const n = letters.length
            const actW = n > 7 ? 1.25 : 1.5
            const w = Math.min(1, (10 - (sides ? 2 * actW : 0)) / n)
            const indent = sides ? 0 : (10 - n * w) / 2
            const keys = Array.from(letters).map(c => chr(c, w))
            return { indent: indent, keys: sides ? before(actW).concat(keys, after(actW)) : keys }
        }

        let bottom
        if (kind === "email")
            bottom = [act("symbols", onSymbols ? qsTr("ABC") : qsTr("#+="), 1.5), chr("@"), chr("."), chr(".com", 1.5), space(3), done]
        else if (kind === "url")
            bottom = [act("symbols", onSymbols ? qsTr("ABC") : qsTr("#+="), 1.5), chr("/"), chr("."), chr(".com", 1.5), space(3), done]
        else
            bottom = [act("symbols", onSymbols ? qsTr("ABC") : qsTr("#+="), 2), space(6), done]

        const spec = onSymbols ? [
            { indent: 0, keys: chars("1234567890") },
            { indent: 0, keys: chars("!@#$%^&*()") },
            { indent: 0, keys: chars("-_=+[]{};:") },
            { indent: 0, keys: [chr("'", 1.5)].concat(chars(",.?/|~\""), [back]) },
            { indent: 0, keys: bottom },
        ] : [
            { indent: 0, keys: chars("1234567890") },
            fitted(set.top, 0),
            fitted(set.home, 0),
            fitted(set.bottom, 2, w => [act("shift", qsTr("Shift"), w)], w => [act("back", qsTr("Del"), w)]),
            { indent: 0, keys: bottom },
        ]
        return spec.map(r => {
            let x = r.indent
            const keys = r.keys.map(k => {
                const placed = Object.assign({}, k, { x: x, cx: x + k.w / 2 })
                x += k.w
                return placed
            })
            return { keys: keys }
        })
    }

    function upper(c) {
        const set = letterSets[DeviceSettings.language] ?? letterSets.en
        return set.upper[c] ?? c.toUpperCase()
    }

    function labelFor(key) {
        return key.kind === "char" && shift && key.label.length === 1 ? upper(key.label) : key.label
    }

    function clampFocus() {
        focusRow = Math.min(rows.length - 1, Math.max(0, focusRow))
        focusCol = Math.min(rows[focusRow].keys.length - 1, Math.max(0, focusCol))
    }
    onRowsChanged: clampFocus()

    function focusKind(kind) {
        for (let r = 0; r < rows.length; ++r) {
            const c = rows[r].keys.findIndex(k => k.kind === kind)
            if (c >= 0) {
                focusRow = r
                focusCol = c
                Sfx.navigate()
                return
            }
        }
    }

    function moveHorizontal(delta) {
        const n = rows[focusRow].keys.length
        focusCol = (focusCol + delta + n) % n
        Sfx.navigate()
    }

    // Vertical moves land on the key whose centre is nearest in x (ties go left). No wrap.
    function moveVertical(delta) {
        const target = focusRow + delta
        if (target < 0 || target >= rows.length)
            return
        const cx = focusedKey.cx
        let best = 0
        let bestDistance = Infinity
        rows[target].keys.forEach((k, i) => {
            const d = Math.abs(k.cx - cx)
            if (d < bestDistance - 1e-9) {
                best = i
                bestDistance = d
            }
        })
        focusRow = target
        focusCol = best
        Sfx.navigate()
    }

    function pressKey(key) {
        pressedRow = focusRow
        pressedCol = focusCol
        pressTimer.restart()
        switch (key.kind) {
        case "char":
            Sfx.select()
            if (insert(labelFor(key)))
                shift = false
            break
        case "space":
            Sfx.select()
            insert(" ")
            break
        case "back":
            Sfx.select()
            backspace()
            break
        case "shift":
            Sfx.select()
            shift = !shift
            break
        case "symbols":
            Sfx.select()
            symbols = !symbols
            break
        case "done":
            finish()
            break
        }
    }

    // Back: delete one character; cancel when there is nothing left to delete.
    function back() {
        if (text.length > 0) {
            Sfx.back()
            backspace()
        } else {
            cancel()
        }
    }

    property int pressedRow: -1
    property int pressedCol: -1
    Timer {
        id: pressTimer
        interval: Math.max(1, Theme.focusMs)
        onTriggered: {
            entry.pressedRow = -1
            entry.pressedCol = -1
        }
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.OutCubic } }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    Column {
        id: content
        anchors.centerIn: parent
        spacing: 24 * entry.u

        Text {
            objectName: "entryTitle"
            anchors.horizontalCenter: parent.horizontalCenter
            text: entry.title
            color: Theme.text
            font.pixelSize: 40 * entry.u
        }

        // The text field: shows the end of the text, with a caret after it.
        Rectangle {
            id: field
            objectName: "entryField"
            anchors.horizontalCenter: parent.horizontalCenter
            width: (10 * (entry.keyUnit + entry.keyGap) - entry.keyGap) * entry.u
            height: 84 * entry.u
            radius: 20 * entry.u
            color: Theme.glass
            border.width: Math.max(1, entry.u)
            border.color: Theme.glassBorder
            clip: true

            Row {
                id: fieldRow
                anchors.verticalCenter: parent.verticalCenter
                x: Math.min(28 * entry.u, field.width - 28 * entry.u - width)
                Text {
                    objectName: "entryDisplay"
                    text: entry.displayText
                    color: Theme.text
                    font.pixelSize: 38 * entry.u
                }
                Rectangle {
                    id: caret
                    objectName: "entryCaret"
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(2, 3 * entry.u)
                    height: 46 * entry.u
                    color: Theme.text
                    SequentialAnimation on opacity {
                        id: blink
                        onRunningChanged: if (!running) caret.opacity = 1
                        running: entry.shown && Theme.ambientMotion
                        loops: Animation.Infinite
                        NumberAnimation { to: 0; duration: Theme.caretMs }
                        NumberAnimation { to: 1; duration: Theme.caretMs }
                    }
                }
            }
        }

        Column {
            id: grid
            objectName: "entryKeys"
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: entry.keyGap * entry.u

            Repeater {
                model: entry.rows

                Item {
                    id: rowItem
                    required property int index
                    required property var modelData

                    width: field.width
                    height: entry.keyHeight * entry.u

                    Repeater {
                        model: rowItem.modelData.keys

                        Item {
                            id: keyItem
                            required property int index
                            required property var modelData

                            readonly property bool focused: entry.shown && entry.focusRow === rowItem.index && entry.focusCol === index
                            readonly property bool pressed: entry.pressedRow === rowItem.index && entry.pressedCol === index
                            readonly property bool dimmed: modelData.kind === "done" && !entry.canFinish
                            readonly property bool active: modelData.kind === "shift" && entry.shift

                            x: modelData.x * (entry.keyUnit + entry.keyGap) * entry.u
                            width: (modelData.w * (entry.keyUnit + entry.keyGap) - entry.keyGap) * entry.u
                            height: rowItem.height
                            z: focused ? 1 : 0
                            scale: pressed ? 0.92 : focused ? 1.06 : 1.0
                            Behavior on scale { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.OutCubic } }

                            Rectangle {
                                anchors.fill: parent
                                radius: 16 * entry.u
                                color: keyItem.focused ? Theme.entryKeyFocusFill
                                     : keyItem.active ? Theme.entryKeyActiveFill : Theme.glass
                                border.width: keyItem.focused ? 4 * entry.u : Math.max(1, entry.u)
                                border.color: keyItem.focused ? Theme.focusRing : Theme.glassBorder
                                opacity: keyItem.dimmed ? 0.4 : 1

                                Text {
                                    anchors.centerIn: parent
                                    text: entry.labelFor(keyItem.modelData)
                                    color: Theme.text
                                    font.pixelSize: (keyItem.modelData.kind === "char" && keyItem.modelData.label.length === 1 ? 36 : 28) * entry.u
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Keys.onPressed: event => {
        switch (event.key) {
        case Qt.Key_Left:
            keyboardMode = false
            moveHorizontal(-1)
            break
        case Qt.Key_Right:
            keyboardMode = false
            moveHorizontal(1)
            break
        case Qt.Key_Up:
            keyboardMode = false
            moveVertical(-1)
            break
        case Qt.Key_Down:
            keyboardMode = false
            moveVertical(1)
            break
        case Qt.Key_PageUp:             // LB
            keyboardMode = false
            focusKind("back")
            break
        case Qt.Key_PageDown:           // RB
            keyboardMode = false
            focusKind("space")
            break
        case Qt.Key_Return:             // Accept (A) -- or Enter on a physical keyboard
            if (keyboardMode)
                finish()
            else
                pressKey(focusedKey)
            break
        case Qt.Key_Enter:
        case Qt.Key_Menu:               // Start
            finish()
            break
        case Qt.Key_Escape:             // Back (B) -- or Esc on a physical keyboard
        case Qt.Key_Back:
            if (keyboardMode)
                cancel()
            else
                back()
            break
        case Qt.Key_Backspace:
            keyboardMode = true
            Sfx.back()
            backspace()
            break
        default:
            if (event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
                keyboardMode = true
                if (insert(event.text))
                    Sfx.select()
            }
        }
        event.accepted = true           // modal: nothing reaches the page underneath
    }
}
