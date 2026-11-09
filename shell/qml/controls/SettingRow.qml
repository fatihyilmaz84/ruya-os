import QtQuick
import RuyaShell

// Label plus a value text. Accept emits activated(); with no handler it is read-only.
SettingControl {
    id: row

    property string value
    // A row that does nothing on Accept (a fact, a result): it makes no sound and emits nothing.
    // The pane then also offers Back only in the hint bar while it has focus (04 section 5).
    property bool inert: false

    signal activated()

    accessibleValue: value

    Text {
        objectName: "value"
        anchors { right: parent.right; rightMargin: Theme.spaceL * row.u; verticalCenter: parent.verticalCenter }
        textFormat: Text.PlainText      // a value may be a name from a drive (a wallpaper): never markup
        text: row.value
        color: Theme.text
        font.pixelSize: Theme.typeBody * row.u
    }

    function accept() {
        if (inert)
            return
        Sfx.select()
        activated()
    }
    Keys.onReturnPressed: accept()
    Keys.onEnterPressed: accept()
}
