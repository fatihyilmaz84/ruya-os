import QtQuick
import RuyaShell

// Label plus a switch. Only Accept toggles it; Left/Right are left to the pane.
// `checked` is changed by the control itself; toggled() reports a change made by the user.
SettingControl {
    id: row

    property bool checked: false

    signal toggled(bool checked)

    Rectangle {
        id: track
        objectName: "switchTrack"
        anchors { right: parent.right; rightMargin: Theme.spaceL * row.u; verticalCenter: parent.verticalCenter }
        width: 96 * row.u
        height: 48 * row.u
        radius: height / 2
        color: row.checked ? Theme.toastSuccess : Theme.glass
        border.width: Math.max(1, row.u)
        border.color: Theme.glassBorder
        Behavior on color { ColorAnimation { duration: Theme.focusMs } }

        Rectangle {
            width: parent.height - 12 * row.u
            height: width
            radius: width / 2
            y: 6 * row.u
            x: row.checked ? parent.width - width - 6 * row.u : 6 * row.u
            color: Theme.text
            Behavior on x { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.OutCubic } }
        }
    }

    function toggle() {
        Sfx.select()
        checked = !checked
        toggled(checked)
    }
    Keys.onReturnPressed: toggle()
    Keys.onEnterPressed: toggle()
}
