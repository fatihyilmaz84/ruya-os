import QtQuick
import RuyaShell

// Art card (04 §5): 16:9 art edge to edge (AppArt: the picture, else initials on a tint from
// the id hash), the title on a caption fade at the bottom, a state pill in words and the card
// focus (ring and scale). The owner sets `focused` from its view and handles Accept.
Item {
    id: card

    property real u: 1
    property string itemId
    property string title
    property string picture      // path or URL, may be empty
    property bool focused: false
    property bool running: false
    property bool installing: false
    property int installPercent: 0

    readonly property string stateText: running ? qsTr("Running")
                                      : installing ? qsTr("Installing %1 %").arg(installPercent) : ""

    implicitWidth: 360 * u
    implicitHeight: implicitWidth * 9 / 16
    scale: focused ? Theme.focusScale : 1.0
    z: focused ? 1 : 0
    Behavior on scale { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.OutCubic } }

    Accessible.role: Accessible.Button
    Accessible.name: stateText.length > 0 ? title + ", " + stateText : title

    AppArt {
        anchors.fill: parent
        u: card.u
        appId: card.itemId
        appName: card.title
        picture: card.picture
        border.width: card.focused ? Theme.focusRingWidth * card.u : 0
        border.color: Theme.focusRing

        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: parent.height * 0.5
            radius: parent.radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Theme.scrim }
            }
        }

        Text {
            objectName: "artCardTitle"
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: Theme.spaceS * card.u }
            text: card.title
            color: Theme.text
            font.pixelSize: Theme.typeCaption * card.u
            font.weight: Theme.weightDemiBold
            elide: Text.ElideRight
        }

        Badge {
            objectName: "artCardPill"
            anchors { right: parent.right; top: parent.top; margins: Theme.spaceXs * card.u }
            u: card.u
            visible: card.stateText.length > 0
            text: card.stateText
            kind: card.running ? "success" : "info"
        }
    }
}
