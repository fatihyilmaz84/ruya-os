import QtQuick
import RuyaShell

// The layer stack on top of a glass surface (04 §3.8): optional `glassTint` (sheets and modals
// over bright art), the top sheen, the grain tile and the lit rim. Put it over the fill, with the
// same size and corner radius (`anchors.fill: parent`), and under the content. Tiers: sheen,
// rim and tint on every tier (also on opaque glass); grain only where the surface is blurred
// (High, Balanced). A surface that draws its own focus ring sets `rim: false` while it does.
Item {
    id: layers

    property real u: 1
    property real radius: Theme.radiusL * u
    property bool tint: false        // glassTint over the fill (sheets, modals)
    property bool grain: true        // off for a surface that has no blur behind it
    property bool rim: true

    // What is drawn now (tests and the screenshots read these).
    readonly property bool sheenVisible: true
    readonly property bool rimVisible: rim
    readonly property bool tintVisible: tint
    readonly property bool grainVisible: grain && Theme.grainOn

    Rectangle {
        objectName: "glassTint"
        anchors.fill: parent
        visible: layers.tintVisible
        radius: layers.radius
        color: Theme.glassTint
    }

    Rectangle {
        objectName: "glassSheen"
        anchors.fill: parent
        visible: layers.sheenVisible
        radius: layers.radius
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.glassSheen }
            GradientStop { position: Theme.glassSheenSpan; color: Theme.glassSheenEnd }
            GradientStop { position: 1.0; color: Theme.glassSheenEnd }
        }
    }

    // A rectangle inset so that its corners stay inside the rounded surface; at 2 % the edge is invisible.
    Image {
        objectName: "glassGrain"
        readonly property real inset: layers.radius * 0.3
        x: inset; y: inset
        width: Math.max(0, layers.width - 2 * inset)
        height: Math.max(0, layers.height - 2 * inset)
        visible: layers.grainVisible
        source: "qrc:/qt/qml/RuyaShell/assets/glass-grain.png"
        fillMode: Image.Tile
        smooth: false
        opacity: Theme.glassGrainOpacity
    }

    GlassRim {
        objectName: "glassRim"
        anchors.fill: parent
        visible: layers.rimVisible
        radius: layers.radius
        line: Theme.hairlineAt(layers.u)
    }
}
