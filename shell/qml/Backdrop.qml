pragma ComponentBehavior: Bound
import QtQuick

// Stand-in for hero artwork: slow-drifting soft colour fields tinted by the focused tile.
// Cheap to render (a few rectangles), and the frosted shelf blurs it into something cinematic.
Item {
    id: backdrop

    property color tint: Theme.defaultTint
    Behavior on tint { ColorAnimation { duration: Theme.tintMs; easing.type: Easing.InOutQuad } }

    // What the blobs and the gradient are built from: the theme's blob colours with `tint` mixed in
    // at the theme's share (all of it in Dreamglass and Daylight, a little in the others, T-271).
    readonly property color tintA: Theme.blobTintA(tint)
    readonly property color tintB: Theme.blobTintB(tint)

    // False while a wallpaper covers the backdrop (T-208): nothing is drawn and the blobs rest.
    property bool shown: true
    visible: shown

    // True while an app is in front and covers all of this (set by Shell, T-293): the blobs rest
    // and cost no frames; they carry on from where they stopped when the app closes.
    property bool paused: false

    // True while any blob is drifting; stops with reduced motion or the performance tier.
    readonly property bool drifting: blobA.drifting || blobB.drifting || blobC.drifting

    Rectangle {
        objectName: "backdropGradient"
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.backdropTop(backdrop.tintA) }
            GradientStop { position: 1.0; color: Theme.background }
        }
    }

    component Blob: Rectangle {
        id: blob
        property real driftX
        property real driftY
        property int period: 18000
        width: backdrop.width * 0.55
        height: width
        radius: width / 2
        opacity: Theme.blobOpacityA
        readonly property bool drifting: xAnim.running || yAnim.running

        SequentialAnimation on driftX {
            id: xAnim
            running: Theme.ambientMotion && backdrop.shown && !backdrop.paused
            loops: Animation.Infinite
            NumberAnimation { to: 1; duration: blob.period; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0; duration: blob.period; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on driftY {
            id: yAnim
            running: Theme.ambientMotion && backdrop.shown && !backdrop.paused
            loops: Animation.Infinite
            NumberAnimation { to: 1; duration: blob.period * 1.3; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0; duration: blob.period * 1.3; easing.type: Easing.InOutSine }
        }
    }

    Blob {
        id: blobA
        objectName: "blobA"
        color: backdrop.tintA
        x: backdrop.width * (-0.1 + 0.25 * driftX)
        y: backdrop.height * (-0.3 + 0.2 * driftY)
    }
    Blob {
        id: blobB
        objectName: "blobB"
        color: Qt.lighter(backdrop.tintB, 1.4)
        period: 23000
        opacity: Theme.blobOpacityB
        x: backdrop.width * (0.55 - 0.2 * driftX)
        y: backdrop.height * (0.1 + 0.25 * driftY)
    }
    Blob {
        id: blobC
        objectName: "blobC"
        color: Theme.blobHighlight
        period: 29000
        opacity: Theme.blobOpacityC
        width: backdrop.width * 0.35
        x: backdrop.width * (0.3 + 0.3 * driftX)
        y: backdrop.height * (0.5 - 0.3 * driftY)
    }
}
