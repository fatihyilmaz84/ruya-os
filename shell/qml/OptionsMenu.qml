pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The Options menu (04 §5, 02 §1.7, designed RUY-4): the context menu of the one focused item. A glass
// sheet 560 u wide in the Shell's modal layer (it takes every key but Guide), placed beside the item
// that opened it (a card or a pill), or at the right screen edge for a row or when neither side has
// room. Its title is the item's name; its rows are `{ id, label, icon, divider }` (`divider: true` draws a
// hairline divider before that row, for a destructive one); at most 8.
//
//   open(anchor, kind, title, rows, note)   kind: "card" | "pill" | "row"
//   rows / note can be set again while it is open (a row's condition changed): the focus stays on the
//   same action if it is still there, else on the row now at that place.
//   activated(id)    a row was chosen; the menu has closed first and the focus is back on the item.
//   closed()         it closed (Back, the options button, a row, or `dismiss()`).
//
// `note` is the error note under the last row ("Store options are unavailable right now."); with no
// row at all the sheet holds the title and the note, or the title and "No options for this yet.".
// The owner (the Shell) fills the rows and the note and does what a row means.
FocusScope {
    id: menu

    property real u: 1
    property real marginX: 0         // the safe area, in pixels
    property real marginY: 0
    property var guideKey: null      // function (key) -> bool: the Guide keys are not taken, the Shell opens the Hub

    property string title
    property var rows: []
    property string note
    property string kind: "card"
    property Item anchor: null

    // True from open() to the moment it closes (the fade-out is still on screen after that).
    property bool shown: false
    // The focused row, by position and by action (kept when `rows` changes).
    property int current: 0
    property string currentId: ""
    // Where the sheet is (its place, without the slide-in): tests read these.
    property real placedX: 0
    property real placedY: 0
    property string placedSide: "right"        // "right" | "left" of the anchor, or "edge"

    // The hint bar (Shell.modalHintsOf): Select only when there is a row to select.
    readonly property var modalHints: rows.length > 0
        ? [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Close") }]
        : [{ button: "B", text: qsTr("Close") }]

    signal activated(string id)
    signal closed()

    // ---- geometry (pixels; every token is in design pixels times u) ----
    readonly property real sheetWidth: 560 * u              // a literal of this component (04 §5)
    readonly property real innerWidth: sheetWidth - 2 * Theme.spaceS * u
    readonly property real rowHeight: Theme.buttonHeight * u
    readonly property real rowGap: Theme.spaceXs * u
    // What a divider adds to the column: the gap before its row becomes `2 x spaceXs + hairline`
    // instead of `spaceXs` (9 u today). Computed, never written as 9.
    readonly property real dividerDelta: 2 * Theme.spaceXs * u - Theme.spaceXs * u + Theme.hairlineAt(u)
    readonly property int rowCount: rows.length
    // A fixed line box (typeHeadline x 1.2, 41 u at 1080p), not the font's metrics: Windows and Fedora's fonts differ by 1 px.
    readonly property real titleHeight: Math.round(Theme.typeHeadline * 1.2 * u)
    readonly property real bodyTop: Theme.spaceL * u + titleHeight + Theme.spaceS * u     // where the rows (or the note) start

    // y of every row inside the rows layer, from the first row's top, dividers included.
    readonly property var rowTops: {
        const tops = []
        let y = 0
        for (let i = 0; i < rows.length; ++i) {
            if (i > 0)
                y += rowHeight + rowGap + (rows[i].divider ? dividerDelta : 0)
            tops.push(y)
        }
        return tops
    }
    readonly property real rowsHeight: rowCount > 0 ? rowTops[rowCount - 1] + rowHeight : 0
    readonly property real noteHeight: note.length > 0 ? noteText.implicitHeight : 0
    readonly property real sheetHeight: {
        if (rowCount > 0)
            return bodyTop + rowsHeight + (note.length > 0 ? Theme.spaceS * u + noteHeight : 0) + Theme.spaceS * u
        const line = note.length > 0 ? noteHeight : emptyText.implicitHeight
        return bodyTop + line + Theme.spaceL * u
    }

    visible: shown || opacity > 0
    opacity: 0
    Accessible.role: Accessible.PopupMenu
    Accessible.name: qsTr("Options for %1").arg(title)

    // ---- opening and closing ----
    property Item returnTo: null
    // Where the one journal line per opening goes (RUY-583, the VM check reads it); tests replace it.
    property var log: text => console.info(text)

    function open(anchorItem, anchorKind, name, newRows, newNote) {
        if (!shown)
            log("ruya-shell: options menu open (" + anchorKind + ")")
        closeAnim.stop()
        openAnim.stop()
        anchor = anchorItem
        kind = anchorKind
        title = name
        note = newNote ?? ""
        rows = newRows
        current = 0
        currentId = rows.length > 0 ? rows[0].id : ""
        returnTo = Window.activeFocusItem
        place()
        shown = true
        const side = placedSide === "edge" ? Theme.pageSlide * u : (placedSide === "right" ? -1 : 1) * Theme.spaceM * u
        slide = side
        opacity = 0
        openAnim.start()
        menu.forceActiveFocus()
    }

    // Closes with the focus back on the item at once; the sheet fades out over `focusMs` without moving.
    function close() {
        if (!shown)
            return
        const target = menu.activeFocus ? returnTo : null
        finish()
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    // The item went away or another screen (the Hub) took over: close without touching the focus.
    function dismiss() {
        if (!shown)
            return
        const mine = menu.activeFocus
        const target = returnTo
        finish()
        if (mine && target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    function finish() {
        shown = false
        openAnim.stop()
        slide = 0
        closeAnim.restart()
    }

    function choose() {
        if (rows.length === 0)
            return
        const id = rows[current].id
        Sfx.select()
        close()
        activated(id)
    }

    function move(step) {
        const next = Math.max(0, Math.min(rows.length - 1, current + step))
        if (next === current)
            return
        current = next
        currentId = rows[next].id
        Sfx.navigate()
    }

    // The rows changed while open: keep the focus on the same action, else on the row now at that place.
    onRowsChanged: {
        if (rows.length === 0) {
            current = 0
            return
        }
        const at = rows.findIndex(r => r.id === currentId)
        current = at >= 0 ? at : Math.max(0, Math.min(rows.length - 1, current))
        currentId = rows[current].id
        if (shown)
            place()
    }
    onNoteChanged: if (shown) place()

    // ---- placement (02 §1.7) ----
    // The anchor's logical rectangle in this item (a card's own focus scale is not part of it: the
    // 1.08 is added below), from its centre, which does not move under the scale.
    function anchorRect() {
        const c = anchor.mapToItem(menu, anchor.width / 2, anchor.height / 2)
        return { left: c.x - anchor.width / 2, top: c.y - anchor.height / 2,
                 right: c.x + anchor.width / 2, bottom: c.y + anchor.height / 2, w: anchor.width, h: anchor.height }
    }

    function place() {
        const w = sheetWidth
        const h = sheetHeight
        const rightEdge = menu.width - marginX
        const bottomLimit = menu.height - marginY - (Theme.glyphSize + Theme.spaceM) * u
        let side = "edge"
        let x = rightEdge - w
        let y = 0
        if (kind !== "row" && anchor) {
            const r = anchorRect()
            const grow = kind === "card" ? (Theme.focusScale - 1) / 2 : 0      // 4 % of the width (1.08 scale)
            const gap = (Theme.focusRingOffset + Theme.focusRingWidth + Theme.spaceM) * u
            if (r.right + grow * r.w + gap + w <= rightEdge) {
                side = "right"
                x = r.right + grow * r.w + gap
            } else if (r.left - grow * r.w - gap - w >= marginX) {
                side = "left"
                x = r.left - grow * r.w - gap - w
            }
            if (side !== "edge")
                y = Math.max(marginY, Math.min(r.top - grow * r.h, bottomLimit - h))
        }
        if (side === "edge")
            y = Math.max(marginY, (marginY + bottomLimit) / 2 - h / 2)
        placedSide = side
        placedX = x
        placedY = y
    }

    // The sheet follows its anchor while it is on screen: a list that is still scrolling to the card when the
    // menu opens (Home's Recent row) would otherwise leave it where the card was. A Timer, not a
    // FrameAnimation: it also runs in a window that presents no frames (PATTERNS.md, T-460).
    Timer {
        interval: 16        // token-ok: one frame at 60 Hz, a poll and not an animation
        repeat: true
        running: menu.shown && menu.anchor !== null
        onTriggered: menu.place()
    }

    // ---- motion ----
    property real slide: 0
    ParallelAnimation {
        id: openAnim
        NumberAnimation { target: menu; property: "opacity"; from: 0; to: 1; duration: Theme.overlayMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap }
        NumberAnimation { target: menu; property: "slide"; to: 0; duration: Theme.overlayMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap }
    }
    NumberAnimation {
        id: closeAnim
        target: menu
        property: "opacity"
        to: 0
        duration: Theme.focusMs
    }

    // ---- the sheet ----
    GlassShadow {
        objectName: "optionsShadow"
        x: sheet.x
        y: sheet.y
        width: sheet.width
        height: sheet.height
        u: menu.u
        radius: sheet.radius
        kind: "panel"
    }

    Rectangle {
        id: sheet
        objectName: "optionsSheet"
        x: menu.placedX + menu.slide
        y: menu.placedY
        width: menu.sheetWidth
        height: menu.sheetHeight
        radius: Theme.radiusL * menu.u
        color: Theme.glassOpaque

        GlassLayers {
            objectName: "optionsLayers"
            anchors.fill: parent
            u: menu.u
            radius: parent.radius
            grain: false                // nothing is blurred behind it
        }

        TailText {
            id: titleText
            objectName: "optionsTitle"
            x: (Theme.spaceS + Theme.spaceL) * menu.u
            y: Theme.spaceL * menu.u
            maxWidth: menu.sheetWidth - 2 * (Theme.spaceS + Theme.spaceL) * menu.u
            width: Math.min(implicitWidth, maxWidth)
            height: menu.titleHeight
            verticalAlignment: Text.AlignVCenter
            name: menu.title
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * menu.u
            font.weight: Theme.weightDemiBold
        }

        Text {
            id: emptyText
            objectName: "optionsEmpty"
            visible: menu.rowCount === 0 && menu.note.length === 0
            x: (Theme.spaceS + Theme.spaceL) * menu.u
            y: menu.bodyTop
            width: menu.sheetWidth - 2 * (Theme.spaceS + Theme.spaceL) * menu.u
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: qsTr("No options for this yet.")
            color: Theme.text
            font.pixelSize: Theme.typeBody * menu.u
        }

        Text {
            id: noteText
            objectName: "optionsNote"
            visible: menu.note.length > 0
            x: (Theme.spaceS + Theme.spaceL) * menu.u
            y: menu.rowCount > 0 ? menu.bodyTop + menu.rowsHeight + Theme.spaceS * menu.u : menu.bodyTop
            width: menu.sheetWidth - 2 * (Theme.spaceS + Theme.spaceL) * menu.u
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: menu.note
            color: Theme.text
            font.pixelSize: Theme.typeCaption * menu.u
        }

        // The rows share one coordinate space with the glide, so the highlight can move between them.
        Item {
            id: rowsLayer
            objectName: "optionsRows"
            x: Theme.spaceS * menu.u
            y: menu.bodyTop
            width: menu.innerWidth
            height: menu.rowsHeight

            FocusGlide {
                id: glide
                objectName: "optionsGlide"
                u: menu.u
                orientation: Qt.Vertical
                shown: menu.shown && menu.rowCount > 0
            }

            Repeater {
                id: rowRepeater
                model: menu.rows

                delegate: Item {
                    id: row

                    required property int index
                    required property var modelData
                    readonly property bool focused: menu.current === index && menu.shown

                    objectName: "optionsRow_" + modelData.id
                    y: menu.rowTops[index] ?? 0
                    width: menu.innerWidth
                    height: menu.rowHeight

                    Accessible.role: Accessible.MenuItem
                    Accessible.name: modelData.label
                    Accessible.focusable: true
                    Accessible.focused: focused

                    onFocusedChanged: if (focused) glide.target = row
                    Component.onCompleted: if (focused) glide.target = row

                    // The fill of the focused row: the glide's, else this one (the glide cannot show).
                    Rectangle {
                        anchors.fill: parent
                        radius: height / 2
                        color: row.focused && !glide.active ? Theme.focusFill : "transparent"
                    }
                    // The ring is on the row at once; the fill glides.
                    Rectangle {
                        objectName: "optionsRing"
                        anchors.fill: parent
                        radius: height / 2
                        color: "transparent"
                        border.width: row.focused ? Theme.focusRingWidth * menu.u : 0
                        border.color: Theme.focusRing
                    }
                    Icon {
                        id: rowIcon
                        x: Theme.spaceL * menu.u
                        anchors.verticalCenter: parent.verticalCenter
                        u: menu.u
                        name: row.modelData.icon ?? ""
                        filled: row.focused
                        color: Theme.text
                    }
                    Text {
                        objectName: "optionsLabel"
                        anchors.verticalCenter: parent.verticalCenter
                        x: rowIcon.x + Theme.iconM * menu.u + Theme.spaceS * menu.u
                        width: parent.width - x - Theme.spaceL * menu.u
                        textFormat: Text.PlainText
                        maximumLineCount: 1
                        elide: Text.ElideRight
                        text: row.modelData.label
                        color: Theme.text
                        font.pixelSize: Theme.typeBody * menu.u
                    }
                }
            }

            // Hairlines before the rows that ask for one, in the doubled gap above them.
            Repeater {
                model: menu.rows

                delegate: Rectangle {
                    required property int index
                    required property var modelData

                    objectName: "optionsDivider_" + modelData.id
                    visible: index > 0 && modelData.divider === true
                    x: Theme.spaceL * menu.u
                    width: menu.innerWidth - 2 * Theme.spaceL * menu.u
                    height: Theme.hairlineAt(menu.u)
                    y: (menu.rowTops[index] ?? 0) - menu.rowGap - menu.dividerDelta + Theme.spaceXs * menu.u
                    color: Theme.glassBorder
                }
            }
        }
    }

    // A modal: every key is taken, but Guide, which the Shell turns into the Hub (closing this).
    Keys.onPressed: event => {
        const k = event.key
        if (menu.guideKey && menu.guideKey(k))
            return
        if (BackKey.isBackOrBackspace(k) || k === Qt.Key_Menu) {
            if (!event.isAutoRepeat) {
                Sfx.back()
                menu.close()
            }
        } else if (k === Qt.Key_Up) {
            menu.move(-1)
        } else if (k === Qt.Key_Down) {
            menu.move(1)
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            if (!event.isAutoRepeat)
                menu.choose()
        }
        event.accepted = true
    }
    Keys.onReleased: event => {
        if (!(menu.guideKey && menu.guideKey(event.key)))
            event.accepted = true
    }
}
