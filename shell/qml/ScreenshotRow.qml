pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Screenshots" on the game page (RUY-533, 02 §1.8, 04 §5 "Screenshot row"): the store's pictures as 16:9
// cards (the thumb, cropped to fill) in one row that scrolls so the focused card is fully in view. The row
// is one focus stop: Left / Right move along it (stop at the ends), Accept opens the viewer at that
// picture, Back leaves the page. While the record is still loading it shows four placeholders with the
// shimmer, not focusable. The page decides whether the section is shown and hands over `shots`
// (the record's `screenshots`: [{ image, thumb, caption }]) and the overlay the viewer is built on.
Column {
    id: root

    property real u: 1
    property var shots: []
    property bool loading: false
    property Item overlay: null
    readonly property alias strip: strip
    readonly property alias viewerSlot: viewerSlot
    readonly property ScreenshotViewer viewer: viewerSlot.item as ScreenshotViewer
    readonly property int count: shots.length
    readonly property real cardWidth: Theme.cardWidthHero * u
    readonly property real cardHeight: Theme.cardArtHeight(cardWidth)
    readonly property real step: cardWidth + Theme.cardGap * u
    // What the hint bar says while the row has the focus.
    readonly property var hints: [
        { action: "accept", text: qsTr("View") },
        { action: "back", text: qsTr("Back") }
    ]

    width: parent ? parent.width : 1728 * u
    spacing: Theme.spaceS * u

    Text {
        objectName: "screenshotsHeading"
        width: parent.width
        textFormat: Text.PlainText
        color: Theme.text
        font.pixelSize: Theme.typeHeadline * root.u
        font.weight: Theme.weightDemiBold
        elide: Text.ElideRight
        text: qsTr("Screenshots")
    }

    Item {
        id: strip
        objectName: "screenshotStrip"
        width: parent.width
        height: root.cardHeight + 2 * Theme.spaceM * root.u      // room for the focused card's growth and shadow

        property int currentIndex: 0
        // How far the cards have moved left; the focused card is always fully in view.
        property real scrollX: 0
        readonly property bool stop: root.count > 0

        // What the focused card grows by (its scale; the ring's own width is the page's ringBleed): the page
        // clips just outside the content edge, so the card is kept this far inside it.
        readonly property real grow: (Theme.focusScale - 1) / 2 * root.cardWidth

        function reveal() {
            const left = currentIndex * root.step
            if (left - grow < scrollX)
                scrollX = left - grow
            else if (left + root.cardWidth + grow > scrollX + width)
                scrollX = left + root.cardWidth + grow - width
        }
        onCurrentIndexChanged: reveal()
        onActiveFocusChanged: if (activeFocus) reveal()
        onWidthChanged: reveal()
        Behavior on scrollX {
            NumberAnimation { duration: Theme.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide }
        }

        Accessible.role: Accessible.List
        Accessible.name: qsTr("Screenshots")

        function move(by) {
            const to = currentIndex + by
            if (to < 0 || to >= root.count)
                return
            Sfx.navigate()
            currentIndex = to
        }

        function open() {
            if (!root.overlay || root.count === 0)
                return
            Sfx.select()
            viewerSlot.active = true
            root.viewer.open(root.shots, currentIndex)
        }

        Keys.onPressed: event => {
            if (!stop)
                return
            if (event.key === Qt.Key_Left) {
                move(-1)
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                move(1)
                event.accepted = true
            }
        }
        Keys.onReturnPressed: open()
        Keys.onEnterPressed: open()

        Row {
            x: -strip.scrollX
            y: Theme.spaceM * root.u
            spacing: Theme.cardGap * root.u

            Repeater {
                model: root.count > 0 ? root.shots : (root.loading ? 4 : 0)

                delegate: Item {
                    id: cell

                    required property int index
                    required property var modelData
                    readonly property bool placeholder: root.count === 0
                    readonly property bool lit: !placeholder && strip.activeFocus && strip.currentIndex === index

                    objectName: "screenshotCard_" + index
                    width: root.cardWidth
                    height: root.cardHeight
                    scale: lit ? Theme.focusScale : 1.0
                    z: lit ? 1 : 0
                    Behavior on scale { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide } }

                    GlassShadow {
                        anchors.fill: parent
                        u: root.u
                        radius: art.radius
                        kind: "lift"
                        active: cell.lit
                        glow: art.glowColor
                        glowStrength: art.glowStrength
                        halo: true
                    }

                    AppArt {
                        id: art
                        objectName: "screenshotArt"
                        anchors.fill: parent
                        u: root.u
                        appId: "screenshot" + cell.index
                        appName: ""
                        monogram: false
                        loading: cell.placeholder
                        picture: cell.placeholder ? "" : (cell.modelData.thumb || cell.modelData.image || "")
                        glowing: !cell.placeholder

                        CardFocusLayers {
                            anchors.fill: parent
                            u: root.u
                            radius: art.radius
                            focused: cell.lit
                        }
                    }

                    Rectangle {
                        objectName: "screenshotRing"
                        anchors.fill: art
                        radius: art.radius
                        color: "transparent"
                        border.width: cell.lit ? Theme.focusRingWidth * root.u : 0
                        border.color: Theme.focusRing
                    }
                }
            }
        }
    }

    // The viewer is built on the first opening, on the page's overlay (above toasts).
    Loader {
        id: viewerSlot
        parent: root.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            ScreenshotViewer {
                objectName: "screenshotViewer"
                u: root.u
                onClosed: index => {
                    strip.currentIndex = index
                    strip.reveal()
                    strip.forceActiveFocus()
                }
            }
        }
    }
}
