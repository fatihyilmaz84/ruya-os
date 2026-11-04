import QtQuick
import RuyaShell

// Body of one Settings category: a vertical stack of settings rows. Up/Down move between the
// rows (clamped), Left/Back hand focus back to the category list (exitRequested). Rows keep
// the keys they use (Left/Right on a ChoiceRow or SliderRow never reach this pane).
// Being a FocusScope, the pane remembers its last focused row: forceActiveFocus() on it
// re-enters at that row. Rows live in a Flickable that follows focus, so a pane may have
// more rows than fit on the screen.
FocusScope {
    id: pane

    property real u: 1

    default property alias rows: column.data

    signal exitRequested()

    // The visible part of the pane (Flickable plus clip). Rows are never drawn cut: scrolling
    // moves in whole rows (the top edge is always the top of a row) and the viewport ends at the
    // bottom of the last row that fits. Its height is therefore at most the pane's.
    readonly property Item viewport: view
    readonly property real scrollY: flick.contentY

    // Visible rows (and spacers) of the column in order, with a height.
    function laidOutRows() {
        const found = []
        for (let i = 0; i < column.children.length; ++i) {
            const r = column.children[i]
            if (r && r.visible && r.height > 0)
                found.push(r)
        }
        return found.sort((a, b) => a.y - b.y)
    }

    // Height of the viewport for the current scroll position: down to the bottom of the last row
    // that fits whole below the top edge.
    function updateView() {
        let best = 0
        for (const r of laidOutRows()) {
            if (r.y >= flick.contentY - 0.5 && r.y + r.height <= flick.contentY + pane.height + 0.5)
                best = Math.max(best, r.y + r.height - flick.contentY)
        }
        view.height = best > 0 ? best : pane.height
    }

    // After the rows or the pane size changed: put the top edge on a row's top again.
    function relayout() {
        let top = 0
        for (const r of laidOutRows()) {
            if (r.y <= flick.contentY + 0.5)
                top = r.y
        }
        if (Math.abs(flick.contentY - top) > 0.5)
            flick.contentY = top
        updateView()
    }

    // Scrolls so the focused row is fully visible. Called after every move and when the
    // pane gains focus; call it after changing focus from code.
    function ensureFocusedVisible() {
        const row = focusableRows().find(r => r.activeFocus)
        if (!row)
            return
        if (row.y < flick.contentY) {
            flick.contentY = row.y
        } else if (row.y + row.height > flick.contentY + pane.height) {
            // The first row boundary that brings the bottom of the focused row into view.
            const need = row.y + row.height - pane.height
            let top = row.y
            for (const r of laidOutRows()) {
                if (r.y >= need - 0.5 && r.y < top)
                    top = r.y
            }
            flick.contentY = top
        }
        updateView()
    }
    // On entering the pane: if no row holds focus (the remembered row is hidden, or there is
    // none yet), take the first visible one; then scroll it into view.
    function settleFocus() {
        if (!activeFocus)
            return                     // focus moved on meanwhile (e.g. to a modal opened by a row)
        const list = focusableRows()
        if (list.length > 0 && !list.some(r => r.activeFocus))
            list[0].forceActiveFocus()
        ensureFocusedVisible()
    }
    onActiveFocusChanged: if (activeFocus) Qt.callLater(settleFocus)

    function focusableRows() {
        const found = []
        for (let i = 0; i < column.children.length; ++i) {
            const row = column.children[i] as SettingControl
            if (row && row.visible && row.enabled)
                found.push(row)
        }
        return found
    }

    function move(delta) {
        const list = focusableRows()
        if (list.length === 0)
            return
        let current = list.findIndex(r => r.activeFocus)
        if (current < 0)
            current = 0
        const next = Math.min(list.length - 1, Math.max(0, current + delta))
        if (next !== current || !list[next].activeFocus) {
            list[next].forceActiveFocus()
            if (next !== current)
                Sfx.navigate()
            ensureFocusedVisible()
        }
    }

    Item {
        id: view
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: pane.height
        clip: true

        Flickable {
            id: flick
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: pane.height
            contentWidth: width
            contentHeight: column.height
            interactive: false                 // focus drives the scrolling, not touch
            boundsBehavior: Flickable.StopAtBounds
            onContentYChanged: pane.updateView()

            Column {
                id: column
                width: flick.width
                spacing: Theme.spaceS * pane.u
                onHeightChanged: Qt.callLater(pane.relayout)
            }
        }
    }
    onHeightChanged: Qt.callLater(relayout)

    Component.onCompleted: {
        // Where focus lands the first time the pane is entered. The pane is usually still
        // hidden here, so don't filter on visibility.
        for (let i = 0; i < column.children.length; ++i) {
            const row = column.children[i] as SettingControl
            if (row) {
                row.focus = true
                break
            }
        }
    }

    Keys.onPressed: event => {
        // A hidden row cannot keep focus; if that left no row focused, repair it first.
        if (!focusableRows().some(r => r.activeFocus))
            settleFocus()
        switch (event.key) {
        case Qt.Key_Up:
            move(-1)
            break
        case Qt.Key_Down:
            move(1)
            break
        case Qt.Key_Right:
            break                      // nothing to the right of a row; stay put
        case Qt.Key_Left:
        case Qt.Key_Escape:
        case Qt.Key_Back:
            Sfx.back()
            exitRequested()
            break
        default:
            return                     // Guide/Menu and the rest bubble up
        }
        event.accepted = true
    }
}
