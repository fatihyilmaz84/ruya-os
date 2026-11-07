pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Display & motion -> Resolution / Refresh rate (T-198): a modal list of choices, one
// row each, the screen's own recommendation and the one in use marked. Up/Down move (clamped),
// Accept chooses (chosen(key)) and closes, Back closes without choosing. The model is a list of
// { key, label, note }: keys never change with the language, labels are computed by the caller.
// Modal: it accepts every key. Focus returns to the item that had it before open().
FocusScope {
    id: picker

    property real u: 1
    property string title
    // [{ key, label, note }]: `note` is the right-hand text ("Recommended", "Current").
    property var entries: []
    // The key that is in use now: the list opens on it.
    property string currentKey: ""
    property bool shown: false
    property Item returnTo: null
    property int visibleRows: 6

    // What the buttons do while it is open (Shell.modalHintsOf, the hint bar).
    readonly property var modalHints: [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Cancel") }]

    signal closed()
    // The owner chose an entry; the caller acts on it.
    signal chosen(string key)

    function open() {
        returnTo = Window.activeFocusItem
        let at = 0
        for (let i = 0; i < entries.length; ++i) {
            if (entries[i].key === currentKey)
                at = i
        }
        list.currentIndex = at
        list.positionViewAtIndex(at, ListView.Contain)
        shown = true
        list.forceActiveFocus()
    }

    function close() {
        shown = false
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    function choose() {
        if (list.currentIndex < 0 || list.currentIndex >= entries.length)
            return
        Sfx.select()
        const key = entries[list.currentIndex].key
        close()
        chosen(key)
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    Rectangle {
        objectName: picker.objectName + "Panel"
        anchors.centerIn: parent
        width: list.width + 2 * Theme.spaceXl * picker.u
        height: content.height + 2 * Theme.spaceXl * picker.u
        radius: Theme.radiusL * picker.u
        color: Theme.panel
        border.width: Theme.hairlineAt(picker.u)
        border.color: Theme.glassBorder
    }

    Column {
        id: content
        anchors.centerIn: parent
        spacing: Theme.spaceM * picker.u

        Text {
            objectName: picker.objectName + "Title"
            text: picker.title
            color: Theme.text
            font.pixelSize: Theme.typeTitle * picker.u
            font.weight: Theme.weightDemiBold
        }

        ListView {
            id: list
            objectName: picker.objectName + "List"
            Accessible.role: Accessible.List
            Accessible.name: picker.title
            width: 900 * picker.u
            readonly property real rowStep: (Theme.rowHeight + Theme.spaceS) * picker.u
            height: Math.min(Math.max(1, picker.entries.length), picker.visibleRows) * rowStep - Theme.spaceS * picker.u
            clip: true
            interactive: false
            spacing: Theme.spaceS * picker.u
            model: picker.entries
            currentIndex: 0
            onCurrentIndexChanged: {
                positionViewAtIndex(currentIndex, ListView.Contain)
                if (currentItem && picker.shown)
                    currentItem.forceActiveFocus()
            }

            delegate: SettingRow {
                id: entry
                required property int index
                required property var modelData
                objectName: picker.objectName + "Entry_" + modelData.key
                u: picker.u
                label: modelData.label
                value: modelData.note
                onActivated: {
                    list.currentIndex = entry.index
                    picker.choose()
                }
            }
        }
    }

    // Modal: every key stops here. Up/Down move the list by hand (a list that takes every key
    // gets no key navigation of its own).
    Keys.onPressed: event => {
        if (BackKey.isBackOrBackspace(event.key)) {
            Sfx.back()
            picker.close()
        } else if (event.key === Qt.Key_Down && list.currentIndex < picker.entries.length - 1) {
            list.incrementCurrentIndex()
        } else if (event.key === Qt.Key_Up && list.currentIndex > 0) {
            list.decrementCurrentIndex()
        }
        event.accepted = true
    }
}
