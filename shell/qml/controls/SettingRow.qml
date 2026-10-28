import QtQuick
import RuyaShell

// Label plus a value text. Accept emits activated(); with no handler it is read-only.
SettingControl {
    id: row

    property string value

    signal activated()

    Text {
        objectName: "value"
        anchors { right: parent.right; rightMargin: Theme.spaceL * row.u; verticalCenter: parent.verticalCenter }
        text: row.value
        color: Theme.textDim
        font.pixelSize: Theme.typeBody * row.u
    }

    function accept() {
        Sfx.select()
        activated()
    }
    Keys.onReturnPressed: accept()
    Keys.onEnterPressed: accept()
}
