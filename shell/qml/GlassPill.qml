pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Glass pill (04 §3.6): `glassStrong` over a blurred crop of `source` (the shared L0 layer),
// rounded by a mask. `sourceX/Y` is where this item sits in the source's coordinates. With no
// blur (the Performance tier) it is `glassOpaque`, never translucent over sharp art. On top:
// the sheen, grain and lit rim of 04 §3.8 (GlassLayers) and, behind, the pill shadow
// (GlassShadow; High and Balanced). On the High tier, with `Theme.liquidPill` on, the blurred crop
// goes through the liquid shader (LiquidGlass: edge refraction and a slow specular, 04 §3.8, T-205);
// if the shader cannot be built the pill stays exactly as it is without it.
Item {
    id: glass

    property real u: 1
    property Item source
    property real sourceX: 0
    property real sourceY: 0

    // The liquid look is wanted (tier and switch) and is drawing (its shader compiled).
    readonly property bool liquidWanted: Theme.liquidOn && Theme.blurMax > 0
    readonly property bool liquid: liquidWanted && liquidLoader.item !== null && (liquidLoader.item as LiquidGlass).compiled

    GlassShadow {
        objectName: "glassShadow"
        anchors.fill: parent
        u: glass.u
        radius: height / 2
        kind: "pill"
    }

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
        layer.smooth: true
    }
    SmoothMask {
        id: blurFx
        objectName: "glassBlur"
        anchors.fill: parent
        visible: Theme.blurMax > 0 && !glass.liquid   // performance tier: no blur, opaque pill below; the liquid pill draws this through its shader
        source: crop
        maskSource: mask
        blurEnabled: true
        blur: 1.0
        blurMax: Theme.blurMax * (glass.liquid ? Theme.liquidBlurFactor : 1)   // a lighter blur keeps the detail the edge bends
        brightness: -0.08 + (glass.liquid ? Theme.liquidBrightnessLift : 0)   // the lighter blur of the liquid pill is brightened back to the plain pill's level
        saturation: 0.3
    }
    Loader {
        id: liquidLoader
        objectName: "liquidLoader"
        anchors.fill: parent
        active: glass.liquidWanted
        sourceComponent: LiquidGlass {
            objectName: "liquidGlass"
            blurSource: blurFx
            u: glass.u
        }
    }
    Rectangle {
        objectName: "glassFill"
        anchors.fill: parent
        radius: height / 2
        color: Theme.blurMax > 0 ? Theme.glassStrong : Theme.glassOpaque
    }
    GlassLayers {
        objectName: "glassLayers"
        anchors.fill: parent
        u: glass.u
        radius: height / 2
    }
}
