pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Running strip (04 §5, 02 §1.6, T-471): the Quick Hub's row of the other running apps, one art tile each
// (AppArt, the Library card's 16:9 crop; three across the panel, `spaceS` apart), with the name of the
// focused tile under it. One focus stop: the owner's list has the focus, `currentIndex` is the tile
// Left/Right stand on, and the owner handles Accept (Switch to). More than three tiles scroll sideways
// so the current one stays in view. The focused tile takes the card focus (`focusScale`, the ring at
// `focusRingOffset`); the strip keeps room round the tiles so neither is clipped.
Item {
    id: strip

    property real u: 1
    // [{ appId, title, picture, name (under the tile), label (the accessible name: "Switch to <app>") }]
    property var apps: []
    property int currentIndex: 0
    property bool focused: false        // the row has the focus
    // 1 = three tiles across the strip; less at a large UI size (RUY-401): the tiles shrink, centred, so the
    // Hub fits without scrolling. The name and the focus ring keep the UI size.
    property real fit: 1

    // Room round the tiles for the focused one's scale and ring: `spaceM` at the sides (a tile grows into it
    // by half its scale and the whole ring), `spaceS` above and below (a tile is shorter than it is wide).
    readonly property real edgeX: Theme.spaceM * u
    readonly property real edgeY: Theme.spaceS * u
    readonly property real fullTileWidth: (width - 2 * edgeX - 2 * view.spacing) / 3
    readonly property real tileWidth: fullTileWidth * fit
    readonly property real tileHeight: Theme.cardArtHeight(tileWidth)
    readonly property alias view: view

    // The line for the focused tile's name takes no height while the strip has no focus (RUY-401); it opens
    // over `focusMs` when the focus enters. `nameFull` is its height when open.
    readonly property real nameFull: Theme.spaceXs * u + name.implicitHeight
    property real nameLine: focused && apps.length > 0 ? nameFull : 0
    Behavior on nameLine { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide } }
    // The current tile's centre in the strip's own coordinates (Up into Home | Close game picks the nearest column).
    readonly property real currentCentre: currentIndex * (tileWidth + view.spacing) - view.contentX + tileWidth / 2

    clip: true
    implicitHeight: view.height + nameLine
    height: implicitHeight

    ListView {
        id: view
        objectName: "hubRunningView"
        width: parent.width
        height: strip.tileHeight + 2 * strip.edgeY
        orientation: ListView.Horizontal
        interactive: false
        clip: true
        leftMargin: strip.edgeX + 1.5 * (strip.fullTileWidth - strip.tileWidth)
        rightMargin: leftMargin
        spacing: Theme.spaceS * strip.u
        model: strip.apps
        currentIndex: strip.currentIndex
        highlightFollowsCurrentItem: false
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        onCountChanged: positionViewAtIndex(currentIndex, ListView.Contain)

        // A horizontal ListView places its delegates at y 0: the delegate is the strip's full height and the
        // tile sits `edgeY` down inside it, so the focused tile's scale and ring have room above it too.
        delegate: Item {
            id: tile
            required property int index
            required property var modelData
            readonly property bool focused: strip.focused && index === strip.currentIndex
            readonly property string label: modelData.label

            objectName: "quickMenuItem_to:" + modelData.appId
            Accessible.role: Accessible.Button
            Accessible.name: label
            width: strip.tileWidth
            height: view.height
            z: focused ? 1 : 0

            Item {
                id: card
                objectName: "hubRunningTile"
                y: strip.edgeY
                width: parent.width
                height: strip.tileHeight
                scale: tile.focused ? Theme.focusScale : 1.0
                Behavior on scale { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide } }

                AppArt {
                    id: art
                    objectName: "hubRunningArt"
                    anchors.fill: parent
                    u: strip.u
                    appId: tile.modelData.appId
                    appName: tile.modelData.title
                    picture: tile.modelData.picture
                    monogramSize: Theme.typeDisplay
                    shimmer: false
                }
                // The card focus ring (04 §4): outside the art at `focusRingOffset`.
                Rectangle {
                    objectName: "hubRunningRing"
                    anchors.fill: parent
                    anchors.margins: -Theme.focusRingOffset * strip.u
                    radius: art.radius + Theme.focusRingOffset * strip.u
                    color: "transparent"
                    visible: tile.focused
                    border.width: Theme.focusRingWidth * strip.u
                    border.color: Theme.focusRing
                }
            }
        }
    }

    // The focused tile's name, centred under it and kept inside the strip.
    Text {
        id: name
        objectName: "hubRunningName"
        readonly property var current: strip.apps[strip.currentIndex]
        visible: strip.focused && current !== undefined
        y: view.height + Theme.spaceXs * strip.u
        width: Math.min(implicitWidth, strip.width)
        // From the index, as the tiles are laid out (index * (tile + spacing), less the view's scroll), not from
        // itemAtIndex: on the first focus the delegates may not exist yet and the name would sit at the left.
        readonly property real tileCentre: strip.currentIndex * (strip.tileWidth + view.spacing) - view.contentX + strip.tileWidth / 2
        x: Math.max(0, Math.min(strip.width - width, tileCentre - width / 2))
        textFormat: Text.PlainText          // an app's name comes from outside
        text: current ? current.name : ""
        color: Theme.text
        font.pixelSize: Theme.typeCaption * strip.u
        font.weight: Theme.weightDemiBold
        elide: Text.ElideRight
    }
}
