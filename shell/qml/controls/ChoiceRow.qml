import QtQuick
import RuyaShell

// Label plus "‹ value ›". Left/Right cycle through `options` (wrapping) and are always
// consumed, so they can never move focus out of the pane. `options` is a list of
// { value, label }; `value` is the selected option's value. edited(value) reports a change
// made by the user.
SettingControl {
    id: row

    property var options: []
    property var value

    readonly property int currentIndex: {
        for (let i = 0; i < options.length; ++i) {
            if (options[i].value === value)
                return i
        }
        return -1
    }
    readonly property string currentLabel: currentIndex >= 0 ? options[currentIndex].label : ""

    signal edited(var value)

    function step(delta) {
        if (options.length === 0)
            return
        const from = currentIndex >= 0 ? currentIndex : 0
        const next = (from + delta + options.length) % options.length
        Sfx.navigate()
        value = options[next].value
        edited(value)
    }

    Text {
        objectName: "value"
        anchors { right: parent.right; rightMargin: 36 * row.u; verticalCenter: parent.verticalCenter }
        text: "‹  " + row.currentLabel + "  ›"
        color: Theme.text
        font.pixelSize: Theme.typeBody * row.u
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Left) {
            row.step(-1)
            event.accepted = true
        } else if (event.key === Qt.Key_Right) {
            row.step(1)
            event.accepted = true
        }
    }
}
