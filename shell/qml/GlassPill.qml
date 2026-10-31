import QtQuick
import QtQuick.Effects
import RuyaShell

// Glass pill (04 §3.6): `glassStrong` over a blurred crop of `source` (the shared L0 layer),
// rounded by a mask. `sourceX/Y` is where this item sits in the source's coordinates. With no
// blur (the Performance tier) it is `glassOpaque`, never translucent over sharp art.
Item {
    id: glass

    property real u: 1
    property Item source
    property real sourceX: 0
    property real sourceY: 0

    ShaderEffectSource {
        id: crop
        visible: false
        sourceItem: glass.source
        sourceRect: Qt.rect(glass.sourceX, glass.sourceY, glass.width, glass.height)
        textureSize: Qt.size(Math.max(1, glass.width / 4), Math.max(1, glass.height / 4))
    }
    Rectangle {
        id: mask
        anchors.fill: parent
        radius: height / 2
        visible: false
        layer.enabled: true
    }
    MultiEffect {
        objectName: "glassBlur"
        anchors.fill: parent
        visible: Theme.blurMax > 0     // performance tier: no blur, opaque pill below
        source: crop
        maskEnabled: true
        maskSource: mask
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 1.0
        blurMax: Theme.blurMax
        brightness: -0.08
        saturation: 0.3
    }
    Rectangle {
        objectName: "glassFill"
        anchors.fill: parent
        radius: height / 2
        color: Theme.blurMax > 0 ? Theme.glassStrong : Theme.glassOpaque
        border.width: Math.max(1, glass.u)
        border.color: Theme.glassBorder
    }
}
