import QtQuick
import RuyaShell

// Hub game card (04 §5, 02 §1.6, T-471): the Quick Hub's first row over a game, and its Resume control.
// The game's art (AppArt, 16:9, 256 u wide) at the left, its title (typeHeadline DemiBold, up to two lines)
// and its state ("Paused · 12 min", typeBody) at the right, on a Hub row's fill with the row's focus
// (focusFill and the ring). The owner sets `focused` from its list and handles Accept (Resume).
Rectangle {
    id: card

    property real u: 1
    property string appId
    property string title
    property string picture
    property string stateText
    property bool paused: false          // Session1 reports the game frozen (T-457)
    property bool focused: false

    readonly property real pad: Theme.spaceS * u

    implicitHeight: Math.max(art.height, info.implicitHeight) + 2 * pad
    height: implicitHeight
    radius: Theme.radiusL * u
    color: focused ? Theme.focusFill : Theme.glass
    border.width: focused ? Theme.focusRingWidth * u : Theme.hairline
    border.color: focused ? Theme.focusRing : Theme.glassBorder

    AppArt {
        id: art
        objectName: "hubCardArt"
        x: card.pad
        anchors.verticalCenter: parent.verticalCenter
        u: card.u
        width: 256 * card.u
        height: Theme.cardArtHeight(width)
        appId: card.appId
        appName: card.title
        picture: card.picture
        shimmer: false
    }
    Column {
        id: info
        objectName: "hubCardInfo"
        anchors { left: art.right; leftMargin: Theme.spaceM * card.u; right: parent.right; rightMargin: card.pad
                  verticalCenter: parent.verticalCenter }
        spacing: Theme.spaceXs * card.u
        Text {
            objectName: "hubCardTitle"
            width: parent.width
            textFormat: Text.PlainText          // a game's name comes from outside
            text: card.title
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * card.u
            font.weight: Theme.weightDemiBold
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }
        Text {
            objectName: "hubCardState"
            width: parent.width
            textFormat: Text.PlainText
            text: card.stateText
            color: Theme.text
            font.pixelSize: Theme.typeBody * card.u
            font.weight: card.paused ? Theme.weightDemiBold : Theme.weightRegular
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }
    }
}
