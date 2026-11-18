pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Screenshots" on the game page (RUY-533, 02 §1.8, 04 §5 "Screenshot row"): the store's pictures as 16:9
// cards (the thumb, cropped to fill) in one row that scrolls so the focused card is fully in view. The row
// is one focus stop: Left / Right move along it (stop at the ends), Accept opens the viewer at that
// picture, Back leaves the page. While the record is still loading it shows four placeholders with the
// shimmer, not focusable. The page decides whether the section is shown and hands over `shots`
// (the record's `screenshots`: [{ image, thumb, caption }]) and the overlay the viewer is built on.
// A .play package may also hand over a `trailer` ({ video, poster, name, seconds }, RUY-802, 04 5.4): its
// poster is the row's first card, with the play circle and "Trailer · m:ss"; Accept opens the viewer in
// trailer mode, and Back brings the focus back to that card.
Column {
    id: root

    property real u: 1
    property var shots: []
    property var trailer: null
    property bool loading: false
    property Item overlay: null
    // How far the row runs past the content's right edge: the page's side bleed, to the screen's edge (the peek).
    property real reach: 0
    readonly property alias strip: strip
    readonly property alias viewerSlot: viewerSlot
    readonly property ScreenshotViewer viewer: viewerSlot.item as ScreenshotViewer
    readonly property int count: shots.length
    // The trailer card comes first; `cards` counts it with the pictures.
    readonly property bool hasTrailer: trailer !== null && trailer !== undefined && Object.keys(trailer).length > 0
    readonly property int lead: hasTrailer ? 1 : 0
    readonly property int cards: count + lead
    readonly property real cardWidth: Theme.cardWidthHero * u
    readonly property real cardHeight: Theme.cardArtHeight(cardWidth)
    readonly property real step: cardWidth + Theme.cardGap * u
    // What the hint bar says while the row has the focus.
    readonly property var hints: [
        { action: "accept", text: hasTrailer && strip.currentIndex === 0 ? qsTr("Play") : qsTr("View") },
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
        text: root.hasTrailer ? qsTr("Screenshots and trailer") : qsTr("Screenshots")
    }

    Item {
        id: strip
        objectName: "screenshotStrip"
        width: parent.width
        height: root.cardHeight + 2 * Theme.spaceM * root.u      // room for the focused card's growth and shadow

        property int currentIndex: 0
        // How far the cards have moved left; the focused card is always fully in view.
        property real scrollX: 0
        readonly property bool stop: root.cards > 0

        // What the focused card grows by (its scale): it is kept this far inside the screen's edge on the right.
        readonly property real grow: (Theme.focusScale - 1) / 2 * root.cardWidth
        readonly property real viewWidth: width + root.reach

        // The first card stays at the content's left edge (x 96; its growth overhangs); later cards scroll
        // just far enough to show the focused one whole, up to the screen's right edge.
        function reveal() {
            const left = currentIndex * root.step
            if (left - grow < scrollX)
                scrollX = Math.max(0, left - grow)
            else if (left + root.cardWidth + grow > scrollX + viewWidth)
                scrollX = left + root.cardWidth + grow - viewWidth
        }
        onCurrentIndexChanged: reveal()
        onActiveFocusChanged: if (activeFocus) reveal()
        onWidthChanged: reveal()
        Behavior on scrollX {
            NumberAnimation { duration: Theme.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide }
        }

        Accessible.role: Accessible.List
        Accessible.name: root.hasTrailer ? qsTr("Screenshots and trailer") : qsTr("Screenshots")

        function move(by) {
            const to = currentIndex + by
            if (to < 0 || to >= root.cards)
                return
            Sfx.navigate()
            currentIndex = to
        }

        function open() {
            if (!root.overlay || root.cards === 0)
                return
            Sfx.select()
            viewerSlot.active = true
            if (root.hasTrailer && currentIndex === 0)
                root.viewer.openTrailer(root.trailer)
            else
                root.viewer.open(root.shots, currentIndex - root.lead)
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
                model: root.cards > 0 ? root.cards : (root.loading ? 4 : 0)

                delegate: Item {
                    id: cell

                    required property int index
                    readonly property bool placeholder: root.cards === 0
                    readonly property bool isTrailer: !placeholder && root.hasTrailer && index === 0
                    readonly property var shot: placeholder || isTrailer ? null : root.shots[index - root.lead]
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
                        picture: cell.placeholder ? ""
                               : cell.isTrailer ? (root.trailer.poster || "")
                               : (cell.shot.thumb || cell.shot.image || "")
                        glowing: !cell.placeholder

                        CardFocusLayers {
                            anchors.fill: parent
                            u: root.u
                            radius: art.radius
                            focused: cell.lit
                        }

                        // The trailer card: a caption on the art's fade and the play circle (04 5.4).
                        Rectangle {
                            objectName: "trailerCaptionFade"
                            visible: cell.isTrailer
                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                            height: parent.height * 0.5
                            radius: art.radius
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: Theme.artCaptionFadeClear }
                                GradientStop { position: 1.0; color: Theme.artCaptionFade }
                            }
                        }
                        Text {
                            objectName: "trailerCaption"
                            visible: cell.isTrailer
                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: Theme.spaceS * root.u }
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            text: !cell.isTrailer ? "" : (root.trailer.seconds ?? 0) > 0 ? qsTr("Trailer · %1").arg(PlayTrust.clock(root.trailer.seconds)) : qsTr("Trailer")      // Library1 has no length
                            color: Theme.text
                            font.pixelSize: Theme.typeCaption * root.u
                            font.weight: Theme.weightDemiBold
                        }
                        Rectangle {
                            objectName: "trailerPlay"
                            visible: cell.isTrailer
                            width: 88 * root.u              // token-ok: 04 5.4 Screenshots and trailer
                            height: width
                            radius: width / 2
                            x: (parent.width - width) / 2
                            y: parent.height * 0.44 - height / 2       // token-ok: 04 5.4, centre at 44 % of the card
                            color: Theme.primaryFill
                            Icon {
                                anchors.centerIn: parent
                                u: root.u
                                size: 56                    // token-ok: 04 5.4 Screenshots and trailer
                                name: "play_arrow"
                                filled: true
                                color: Theme.onPrimary
                            }
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
                covered: (root.overlay as ModalLayer)?.covered ?? false
                onClosed: index => {
                    strip.currentIndex = index < 0 ? 0 : index + root.lead
                    strip.reveal()
                    strip.forceActiveFocus()
                }
            }
        }
    }
}
