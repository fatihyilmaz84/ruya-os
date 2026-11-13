import QtQuick
import RuyaShell

// The left column of Controls in games and Remap buttons (RUY-465, 02 §1.2): the pad's silhouette (its model, else its family's)
// at `cardIconSize` (the controller page's literal, 04 §5), "Changes here reach games only. Menus
// keep their buttons." and the console profile the controls belong to. Not focusable.
Column {
    id: intro

    property real u: 1
    property string family: ""
    property string model: ""

    width: 470 * u
    spacing: Theme.spaceM * u

    Icon {
        objectName: "controlsGlyph"
        u: intro.u
        size: Theme.cardIconSize
        name: DeviceIcons.iconFor("controller", intro.family, intro.model)
    }
    Text {
        objectName: "controlsGamesOnly"
        width: parent.width
        text: qsTr("Changes here reach games only. Menus keep their buttons.")
        color: Theme.text
        font.pixelSize: Theme.typeBody * intro.u
        wrapMode: Text.Wrap
    }
    Text {
        objectName: "controlsProfileName"
        width: parent.width
        textFormat: Text.PlainText          // a profile's own name
        text: qsTr("Profile: %1").arg(Profiles.active.name ?? "")
        color: Theme.text
        font.pixelSize: Theme.typeBody * intro.u
        elide: Text.ElideRight
    }
}
