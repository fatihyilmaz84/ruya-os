import QtQuick
import RuyaShell

// Body of one Settings category: a vertical stack of settings rows. Up/Down move between the
// rows (clamped), Left/Back hand focus back to the category list (exitRequested). Rows keep
// the keys they use (Left/Right on a ChoiceRow or SliderRow never reach this pane).
// Being a FocusScope, the pane remembers its last focused row: forceActiveFocus() on it
// re-enters at that row.
FocusScope {
    id: pane

    property real u: 1

    default property alias rows: column.data

    signal exitRequested()

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
        }
    }

    Column {
        id: column
        width: parent.width
        spacing: 16 * pane.u
    }

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
