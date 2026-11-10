pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects

// Stand-in for hero artwork: slow-drifting soft colour fields tinted by the focused tile.
// Cheap to render (a few rectangles). On a page (`blurred`) the fields are shown through one
// blurred copy, as a wallpaper is (WallpaperLayer, T-208): glass on a page never sits over the
// blobs' sharp edges (04 §3.6, T-421).
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

    // True while something opaque covers all of this (set by Shell): an app in front (T-293) or the
    // Home hero's art or colour field (T-421). The blobs rest and cost no frames; they carry on from
    // where they stopped when they are seen again.
    property bool paused: false

    // True while a page (not Home) is on top (set by Shell): the blurred copy fades in over the sharp
    // fields. Not on the Performance tier (no blur there, 04 §3.6).
    property bool blurred: false
    readonly property bool blurActive: blurred && Theme.blurMax > 0

    // True while any blob is drifting; stops with reduced motion or the performance tier.
    readonly property bool drifting: blobA.drifting || blobB.drifting || blobC.drifting

    // The sharp fields: the gradient and the blobs. The blurred copy below is made from this item.
    Item {
        id: fields
        objectName: "backdropFields"
        anchors.fill: parent

        Rectangle {
            objectName: "backdropGradient"
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.backdropTop(backdrop.tintA) }
                GradientStop { position: 1.0; color: Theme.background }
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

    // The blurred copy (04 §3.6): a quarter-size texture of the fields, blurred, faded in over the
    // sharp fields while a page is open. It replaces them as the L0 that the page's glass and the
    // glass pills see; one full-screen blur, as with a wallpaper (which hides this backdrop).
    Loader {
        id: blurLoader
        objectName: "backdropBlurLoader"
        anchors.fill: parent
        active: backdrop.shown && Theme.blurMax > 0
        sourceComponent: Item {
            id: blurHost
            // The blur works at a quarter of the screen size and is drawn scaled up (T-434): its passes
            // ran at full size before, about 12 % of the Dell's GPU while the blobs drift on a page.
            readonly property int reducedWidth: Math.max(1, Math.round(backdrop.width / 4))
            readonly property int reducedHeight: Math.max(1, Math.round(backdrop.height / 4))

            ShaderEffectSource {
                id: reduced
                objectName: "backdropReduced"
                visible: false
                sourceItem: fields
                textureSize: Qt.size(blurHost.reducedWidth, blurHost.reducedHeight)
                // Re-rendered only while the copy is shown or fading (T-434): off pages (Home, the profile
                // picker) the drifting blobs would redraw this texture every frame for nothing.
                live: backdrop.blurActive || pageBlur.opacity > 0
                // Once the opaque blurred copy covers them, the sharp fields are not drawn on screen as
                // well (still into this texture): about 8 % of the Dell's GPU while they drift (T-421).
                hideSource: pageBlur.opacity >= 1
            }
            MultiEffect {
                id: pageBlur
                objectName: "backdropBlur"
                width: blurHost.reducedWidth
                height: blurHost.reducedHeight
                transform: Scale {
                    xScale: backdrop.width / pageBlur.width
                    yScale: backdrop.height / pageBlur.height
                }
                source: reduced
                visible: opacity > 0
                opacity: backdrop.blurActive ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }
                autoPaddingEnabled: false
                blurEnabled: true
                blur: 1.0
                // blurMax is in the effect's own pixels. At a quarter size a third of the tier's value
                // matched the old full-size blur best in the shots (T-434: a mean difference under one
                // level of 255 over the screen; a quarter was visibly tighter, a half far softer).
                blurMax: Math.round(Theme.blurMax / 3)
            }
        }
    }
}
