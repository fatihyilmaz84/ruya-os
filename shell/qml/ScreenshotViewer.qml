pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The full-screen screenshot viewer (RUY-533, 02 §1.8, 04 §5 "Screenshot viewer"): a modal in the page's
// overlay. A scrim over the whole screen, the picture fitted into a 1532 x 862 box (x 194, y 54; another
// shape is letterboxed), the counter "1 of 5" below it and a disc with a chevron on each side where there
// is a previous / next picture (cues, never focus stops). Left / Right step (nothing at the ends, no
// sound), Back closes. Every other key is taken: nothing leaks to the page or the Guide overlay's owner.
//
//   open(shots, index)    shots: [{ image, thumb, caption }]; the focus is taken
//   openTrailer(trailer) trailer: { video, poster, name, seconds } (RUY-802, 04 §5.4): the same box plays the
//                        trailer (TrailerPlayer); A plays or pauses, Left / Right seek 10 s, Back closes
//   closed(index)         the picture last shown (the row puts the focus on its card); -1 for the trailer
//
// The picture is the `image`; until it is there the `thumb` is stretched to the box; if it cannot be
// loaded the box says so. Opening, closing and stepping fade; none of it under reduced motion.
FocusScope {
    id: viewer

    property real u: 1
    property var shots: []
    property int index: 0
    property bool shown: false
    // The trailer in the box (null = the pictures), and whether the Hub (or "Who's playing?") is over it.
    property var trailer: null
    property bool covered: false
    readonly property bool trailerMode: trailer !== null
    readonly property alias trailerPlayer: trailerBox

    // What the hint bar says while this is open (Shell.modalHintsOf).
    readonly property var modalHints: trailerMode ? [
        { action: "accept", text: trailerBox.wantsPlay ? qsTr("Pause") : qsTr("Play") },
        { actions: ["left", "right"], text: qsTr("Seek 10 s") },
        { action: "back", text: qsTr("Back") }
    ] : [
        { actions: ["left", "right"], text: qsTr("Browse") },
        { action: "back", text: qsTr("Close") }
    ]

    readonly property int count: shots.length
    readonly property bool hasPrevious: index > 0
    readonly property bool hasNext: index < count - 1
    // The box the picture is fitted into (04 §5 Screenshot viewer).
    readonly property real boxX: 194 * u          // token-ok: 04 §5 Screenshot viewer
    readonly property real boxY: 54 * u           // token-ok: 04 §5 Screenshot viewer
    readonly property real boxWidth: 1532 * u     // token-ok: 04 §5 Screenshot viewer
    readonly property real boxHeight: 862 * u     // token-ok: 04 §5 Screenshot viewer
    // The picture that is shown now: slot `front` of the two that cross-fade.
    property int front: 0
    readonly property var current: front === 0 ? pictureA : pictureB

    signal closed(int index)

    function open(list, at) {
        trailer = null
        shots = list
        index = Math.max(0, Math.min(at, list.length - 1))
        front = 0
        pictureA.shot = shots[index]
        pictureB.shot = null
        shown = true
        forceActiveFocus()
    }

    function openTrailer(t) {
        trailer = t
        shown = true
        forceActiveFocus()
    }

    function close() {
        if (!shown)
            return
        shown = false
        closed(trailerMode ? -1 : index)
    }

    function step(by) {
        const to = index + by
        if (to < 0 || to >= count)
            return
        Sfx.navigate()
        front = 1 - front
        current.shot = shots[to]
        index = to
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.overlayMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Accessible.role: Accessible.Dialog
    Accessible.name: trailerMode ? (trailer.name || qsTr("Trailer")) : qsTr("%1 of %2").arg(index + 1).arg(count)

    Keys.onPressed: event => viewer.handleKey(event)

    function handleKey(event) {
        if (BackKey.isBackOrBackspace(event.key)) {
            Sfx.back()
            viewer.close()
        } else if (viewer.trailerMode) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (!event.isAutoRepeat) {      // a held A does not toggle again
                    Sfx.select()
                    trailerBox.toggle()
                }
            } else if (event.key === Qt.Key_Left) {
                trailerBox.seek(-trailerBox.seekMs)
            } else if (event.key === Qt.Key_Right) {
                trailerBox.seek(trailerBox.seekMs)
            } else {
                trailerBox.wake()
            }
        } else if (event.key === Qt.Key_Left) {
            viewer.step(-1)
        } else if (event.key === Qt.Key_Right) {
            viewer.step(1)
        }
        event.accepted = true      // modal: nothing leaks to the page underneath
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    // One picture in the box. Two of them cross-fade when the viewer steps.
    component ShotPicture: Item {
        id: pic

        property var shot: null
        property bool active: false
        readonly property bool failed: full.status === Image.Error
        readonly property bool ready: full.status === Image.Ready

        x: viewer.boxX
        y: viewer.boxY
        width: viewer.boxWidth
        height: viewer.boxHeight
        opacity: active && shot ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.focusMs } }

        function url(path) {
            if (!path)
                return ""
            return path.startsWith("/") ? "file://" + path : /^[A-Za-z]:\//.test(path) ? "file:///" + path : path
        }

        // Until the picture is there: the thumb, stretched to the box.
        Image {
            objectName: "viewerThumb"
            anchors.fill: parent
            visible: status === Image.Ready && !pic.ready && !pic.failed
            source: pic.url(pic.shot ? pic.shot.thumb : "")
            fillMode: Image.Stretch
            asynchronous: true
        }

        // The picture itself: the frame is its fitted size, centred, with the rounded corners.
        Item {
            id: frame
            objectName: "viewerFrame"
            readonly property real scaleToFit: full.implicitWidth > 0 && full.implicitHeight > 0
                ? Math.min(pic.width / full.implicitWidth, pic.height / full.implicitHeight) : 0
            anchors.centerIn: parent
            width: full.implicitWidth * scaleToFit
            height: full.implicitHeight * scaleToFit
            visible: pic.ready
            readonly property bool masked: GraphicsInfo.api !== GraphicsInfo.Software

            Image {
                id: full
                objectName: "viewerImage"
                anchors.fill: parent
                source: pic.active || pic.opacity > 0 ? pic.url(pic.shot ? pic.shot.image : "") : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                layer.enabled: frame.masked && pic.ready
                layer.smooth: true
                layer.effect: SmoothMask { maskSource: frameMask }
            }
            Rectangle {
                id: frameMask
                anchors.fill: parent
                radius: Theme.radiusM * viewer.u
                visible: false
                layer.enabled: frame.masked && pic.ready
                layer.smooth: true
            }
        }

        // It cannot be loaded: the box says so.
        Rectangle {
            objectName: "viewerFailed"
            anchors.fill: parent
            visible: pic.failed
            radius: Theme.radiusM * viewer.u
            color: Theme.glassOpaque

            Column {
                anchors.centerIn: parent
                spacing: Theme.spaceS * viewer.u
                Icon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    u: viewer.u
                    name: "info"
                    color: Theme.textDim
                }
                Text {
                    objectName: "viewerFailedText"
                    anchors.horizontalCenter: parent.horizontalCenter
                    textFormat: Text.PlainText
                    text: qsTr("Couldn't load this picture.")
                    color: Theme.text
                    font.pixelSize: Theme.typeBody * viewer.u
                }
            }
        }
    }

    ShotPicture { id: pictureA; active: viewer.front === 0 && !viewer.trailerMode }
    ShotPicture { id: pictureB; active: viewer.front === 1 && !viewer.trailerMode }

    // The trailer: in the same box, playing only while the viewer shows it.
    TrailerPlayer {
        id: trailerBox
        objectName: "trailerPlayer"
        x: viewer.boxX
        y: viewer.boxY
        width: viewer.boxWidth
        height: viewer.boxHeight
        u: viewer.u
        visible: viewer.trailerMode
        trailer: viewer.trailer
        active: viewer.shown && viewer.trailerMode
        covered: viewer.covered
    }

    Text {
        objectName: "viewerTrailerName"
        visible: viewer.trailerMode
        x: viewer.boxX
        y: 940 * viewer.u       // token-ok: 04 §5.4 Screenshots and trailer
        width: viewer.boxWidth
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: viewer.trailer ? (viewer.trailer.name ?? "") : ""
        color: Theme.text
        font.pixelSize: Theme.typeBody * viewer.u
        font.weight: Theme.weightDemiBold
    }

    Text {
        objectName: "viewerCounter"
        visible: !viewer.trailerMode
        x: 0
        width: parent.width
        y: 932 * viewer.u       // token-ok: 04 §5 Screenshot viewer
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: qsTr("%1 of %2").arg(viewer.index + 1).arg(viewer.count)
        color: Theme.text
        font.pixelSize: Theme.typeCaption * viewer.u
    }

    // The arrows: cues that there is more on that side, not stops.
    component Arrow: Rectangle {
        property string glyph
        property bool wanted: false
        width: Theme.buttonHeight * viewer.u
        height: width
        radius: width / 2
        y: 485 * viewer.u - height / 2       // token-ok: 04 §5 Screenshot viewer
        color: Theme.glassOpaque
        border.width: Math.max(1, viewer.u)
        border.color: Theme.glassBorder
        visible: wanted
        Icon {
            anchors.centerIn: parent
            u: viewer.u
            name: parent.glyph
            color: Theme.text
        }
    }

    Arrow {
        objectName: "viewerPrevious"
        x: 96 * viewer.u          // token-ok: 04 §5 Screenshot viewer
        glyph: "chevron_left"
        wanted: viewer.hasPrevious && !viewer.trailerMode
    }
    Arrow {
        objectName: "viewerNext"
        x: 1748 * viewer.u        // token-ok: 04 §5 Screenshot viewer
        glyph: "chevron_right"
        wanted: viewer.hasNext && !viewer.trailerMode
    }
}
