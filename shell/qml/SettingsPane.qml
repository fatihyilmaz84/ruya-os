import QtQuick
import RuyaShell

// Body of one Settings category: a vertical stack of settings rows. Up/Down move between the
// rows (clamped; so do Tab / Shift+Tab), Left/Back hand focus back to the category list
// (exitRequested). Rows keep the keys they use (Left/Right on a ChoiceRow or SliderRow never reach this pane).
// Being a FocusScope, the pane remembers its last focused row: forceActiveFocus() on it
// re-enters at that row. Rows live in a Flickable that follows focus, so a pane may have
// more rows than fit on the screen.
FocusScope {
    id: pane

    property real u: 1

    // What the buttons do while this pane has focus (the hint bar, T-158): a list of
    // { button, text }. By default the focused row's own (`SettingControl.hints`, by its kind, RUY-512);
    // a pane that sets `hints:` itself still wins (a pane with nothing to select sets
    // `hints: [{ button: "B", text: qsTr("Back") }]`).
    property var hints: focusedRow ? focusedRow.hints : [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Back") }]

    // The row of the column that holds the active focus now, or null. Read from the window, so it
    // follows every move without a handler per row.
    readonly property Item focusedRow: {
        let item = Window.window ? Window.window.activeFocusItem : null
        while (item && item.parent !== column)
            item = item.parent
        return item as SettingControl
    }

    default property alias rows: column.data

    signal exitRequested()

    // The visible part of the pane (Flickable plus clip). Rows are never drawn cut: scrolling
    // moves in whole rows (the top edge is always the top of a row) and the viewport ends at the
    // bottom of the last row that fits. Its height is therefore at most the pane's.
    readonly property Item viewport: view
    readonly property real scrollY: flick.contentY
    // Scroll cue (T-185): while rows exist beyond the first / last visible row, that row (the peek
    // row) is drawn at Theme.peekOpacity. Never the focused row. Set by updatePeek().
    property Item peekAbove: null
    property Item peekBelow: null

    // The facts of the column get their hairline (RUY-512): a fact whose next visible item is a fact too
    // draws `ruleBelow`; the last fact of a run, a message and anything else never does. Called after
    // every layout of the column.
    function updateRules() {
        let prev = null
        for (let i = 0; i < column.children.length; ++i) {
            const c = column.children[i]
            if (!c || !c.visible || c.height <= 0)
                continue
            const row = c as SettingControl
            const fact = row !== null && row.flat && row.enabled
            if (prev)
                prev.ruleBelow = fact
            prev = fact ? row : null
            if (row)
                row.ruleBelow = false
        }
    }

    // What decides the hairlines, per child: visible, height > 0, flat, enabled. A row that changes one in
    // place (a kind, `enabled`, `flat`) may not change the column's height, so no relayout follows: this
    // binding re-evaluates on any of them and the rules are recomputed (RUY-542).
    readonly property string ruleKey: {
        let k = ""
        for (let i = 0; i < column.children.length; ++i) {
            const c = column.children[i]
            const row = c as SettingControl
            k += (c && c.visible && c.height > 0 ? "1" : "0") + (row && row.flat ? "f" : "-") + (row && row.enabled ? "e" : "-") + ","
        }
        return k
    }
    onRuleKeyChanged: Qt.callLater(updateRules)

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
        updatePeek()
    }

    // The first / last visible row is the peek row when rows exist beyond it; a row that is not
    // a peek row, or holds focus, is drawn whole. Rows ease their opacity (SettingControl).
    function updatePeek() {
        const list = laidOutRows()
        let first = -1
        let last = -1
        for (let k = 0; k < list.length; ++k) {
            const r = list[k]
            if (r.y + r.height > flick.contentY + 0.5 && first < 0)
                first = k
            if (r.y + r.height <= flick.contentY + view.height + 0.5)
                last = k
        }
        const above = first > 0 ? list[first] : null
        const below = last >= 0 && last < list.length - 1 ? list[last] : null
        peekAbove = above && !above.activeFocus ? above : null
        peekBelow = below && !below.activeFocus ? below : null
        for (let i = 0; i < column.children.length; ++i) {
            const c = column.children[i]
            if (c && c.opacity !== undefined)
                c.opacity = (c === peekAbove || c === peekBelow) ? Theme.peekOpacity : 1
        }
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
        // Rows inserted or removed, a message appearing, the pane resized: with focus in the pane
        // look ahead again, so the focused row is not left as the last visible one with rows
        // beyond it (T-190), and if the focused row was hidden, move to the nearest one (settleFocus,
        // T-356). Without focus the pane keeps the view the snap above gave it.
        if (activeFocus)
            settleFocus()
    }

    // Scrolls so the focused row is fully visible and, when there is room, so is the row above
    // and the row below it (look-ahead, T-185): a focused row touches the pane edge only when it
    // is the first or last row, so the peek row (dimmed by updatePeek) is never the focused one.
    // Scrolls in whole rows and as little as possible. Called after every move and when the pane
    // gains focus; call it after changing focus from code.
    function ensureFocusedVisible() {
        const row = focusableRows().find(r => r.activeFocus)
        if (!row)
            return
        const list = laidOutRows()
        const i = list.indexOf(row)
        if (i < 0)
            return
        let cur = 0                                // the row on top now
        for (let k = 0; k < list.length; ++k) {
            if (list[k].y <= flick.contentY + 0.5)
                cur = k
        }
        // The last row that fits whole when row t is on top.
        const lastFit = t => {
            let b = t
            for (let k = t; k < list.length && list[k].y + list[k].height <= list[t].y + pane.height + 0.5; ++k)
                b = k
            return b
        }
        // The top row nearest to the current one that shows rows lo..hi whole, or -1.
        const place = (lo, hi) => {
            for (let t = 0; t <= lo; ++t) {
                if (lastFit(t) >= hi)
                    return Math.max(t, Math.min(cur, lo))
            }
            return -1
        }
        let top = place(Math.max(0, i - 1), Math.min(list.length - 1, i + 1))
        if (top < 0)
            top = place(i, i)
        flick.contentY = list[top < 0 ? i : top].y
        updateView()
    }
    // On entering the pane, and whenever rows appear or hide: if no row that can hold the focus
    // holds it (the remembered row is hidden or disabled, or there is none yet), take the visible
    // row nearest to the remembered one; with no such row the pane holds the focus itself, never a
    // hidden row (T-356). Then scroll the focused row into view.
    function settleFocus() {
        if (!activeFocus)
            return                     // focus moved on meanwhile (e.g. to a modal opened by a row)
        const list = focusableRows()
        if (!list.some(r => r.activeFocus)) {
            const stale = staleRow()
            if (list.length > 0)
                nearestRow(list, stale).forceActiveFocus()
            else if (stale)
                stale.focus = false    // the active focus falls back to the pane
        }
        ensureFocusedVisible()
    }
    onActiveFocusChanged: if (activeFocus) Qt.callLater(settleFocus)

    // The pane's focused row: when it hides or is disabled, settle at once. relayout() also settles,
    // but it waits for the column's height to change, which needs a polish (a frame) first.
    readonly property Item focusedChild: {
        for (let i = 0; i < column.children.length; ++i) {
            if (column.children[i].focus)
                return column.children[i]
        }
        return null
    }
    Connections {
        target: pane.focusedChild
        // `pane &&`: the rows outlive the pane's id while the page is torn down.
        function onVisibleChanged() { if (pane && pane.activeFocus) Qt.callLater(pane.settleFocus) }
        function onEnabledChanged() { if (pane && pane.activeFocus) Qt.callLater(pane.settleFocus) }
    }

    // How many rows can hold the focus now. When the first one appears while the pane has the focus
    // (it held it itself because no row could), settle at once: waiting for the column's height to
    // change needs a frame, and a hidden row swapped for a shown one of the same height never
    // changes it (T-429). Only 0 -> more: while rows come and go otherwise, settling early would
    // pick the first row instead of the neighbour of the one that went.
    readonly property int focusableCount: {
        let n = 0
        for (let i = 0; i < column.children.length; ++i) {
            const row = column.children[i] as SettingControl
            if (row && row.visible && row.enabled)
                ++n
        }
        return n
    }
    property int countBefore: 0
    onFocusableCountChanged: {
        const was = countBefore
        countBefore = focusableCount
        if (was === 0 && focusableCount > 0 && activeFocus)
            Qt.callLater(settleFocus)
    }

    // The row that is the pane's focused item although it cannot hold the focus (hidden or
    // disabled), or null.
    function staleRow() {
        for (let i = 0; i < column.children.length; ++i) {
            const row = column.children[i] as SettingControl
            if (row && row.focus && !(row.visible && row.enabled))
                return row
        }
        return null
    }

    // Of `list` (focusable rows), the last one before `from` in the column (as the profile panes
    // always did), else the first one after it; the first of the list without `from`.
    function nearestRow(list, from) {
        let before = null
        let passed = false
        for (let i = 0; i < column.children.length; ++i) {
            const c = column.children[i]
            if (c === from) {
                if (before)
                    return before
                passed = true
            } else if (list.indexOf(c) >= 0) {
                if (passed)
                    return c
                before = c
            }
        }
        return list[0]
    }

    function focusableRows() {
        const found = []
        for (let i = 0; i < column.children.length; ++i) {
            const row = column.children[i] as SettingControl
            if (row && row.visible && row.enabled)
                found.push(row)
        }
        return found
    }

    // Lays the rows out now. A Column lays out when its window next polishes it, and a pane whose
    // rows are created after the page opened (a Repeater over data, T-226) was seen to stay unlaid
    // (every row at y 0, the viewport one row high) in a real window until the next repaint:
    // such a pane calls this after changing its rows. Resizing follows through the Column's height.
    function reflow() {
        column.forceLayout()
        Qt.callLater(relayout)
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
                onPositioningComplete: pane.updateRules()
            }
        }
    }
    onHeightChanged: Qt.callLater(relayout)

    Component.onCompleted: {
        // Start from the rows the pane was built with, so only a real 0 -> more settles (T-429 review).
        countBefore = focusableCount
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
        // A hidden row keeps the active focus (Qt does not move it): if no row that can hold it does, repair it first.
        if (!focusableRows().some(r => r.activeFocus))
            settleFocus()
        switch (event.key) {
        case Qt.Key_Up:
            move(-1)
            break
        case Qt.Key_Down:
            move(1)
            break
        case Qt.Key_Tab:                   // a keyboard (a controller never sends Tab); rows are not in the window's tab chain
            move(event.modifiers & Qt.ShiftModifier ? -1 : 1)
            break
        case Qt.Key_Backtab:
            move(-1)
            break
        case Qt.Key_Right:
            break                      // nothing to the right of a row; stay put
        default:
            if (!BackKey.isBackOrBackspace(event.key) && event.key !== Qt.Key_Left)
                return                 // Guide/Menu and the rest bubble up
            Sfx.back()
            exitRequested()
        }
        event.accepted = true
    }
}
