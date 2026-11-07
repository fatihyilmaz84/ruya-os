pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import RuyaShell

// The glass sheet of a picker modal (04 §3.6, §3.7, T-272): `glassStrong` over a blurred crop of
// the shared L0 layer, rounded by a mask, with the tint of a modal (`GlassLayers.tint`: text stays
// legible over bright art), the sheen, grain and lit rim, and the panel shadow behind. Size it
// like the card it replaces and put the content over it.
//
// Baked, not redrawn (04 §3.8): the crop is a `ShaderEffectSource` that is not live. It is captured
// once when the modal opens (`shown` turns true) and again if the sheet changes size, so the frame
// loop only draws one textured quad. Without blur behind it (the Performance tier, no L0 to sample,
// or the software renderer, where `MultiEffect` draws nothing) the fill is `glassOpaque`, never
// translucent glass over sharp art; the tint, sheen and rim stay, the grain and the shadow go.
//
// The L0 item is found on the modal layer (a parent with a `glassSource`, the Shell's `modalLayer`),
// or set as `source` by a host that has one. The sheet and L0 share a coordinate origin (both fill
// the shell), which is what `mapToItem` uses.
Item {
    id: sheet

    property real u: 1
    property real radius: Theme.radiusL * u
    // The owner's open state: a rising edge captures the backdrop.
    property bool shown: false
    property Item source: null

    // The scene graph is on a GPU (the software renderer of the offscreen tests draws no MultiEffect;
    // a test overrides this to check the blurred branch).
    property bool gpu: GraphicsInfo.api !== GraphicsInfo.Software
                       && GraphicsInfo.api !== GraphicsInfo.Null
                       && GraphicsInfo.api !== GraphicsInfo.Unknown
    // Blur is drawn: a tier with blur, a layer to sample and a GPU scene graph.
    readonly property bool blurred: Theme.blurMax > 0 && source !== null && gpu
    // What the fill is now (tests and the screenshots read these).
    readonly property color fillColor: blurred ? Theme.glassStrong : Theme.glassOpaque
    readonly property alias layers: glassLayers
    readonly property alias shadow: glassShadow
    // How many times the backdrop was captured (a test checks it is once per opening).
    property int bakeCount: 0

    // The nearest ancestor that offers an L0 layer (the Shell's modal layer).
    function lookupSource() {
        for (let p = sheet.parent; p; p = p.parent) {
            const s = p["glassSource"]
            if (s)
                return s
        }
        return null
    }

    function bake() {
        if (!sheet.shown || sheet.width <= 0 || sheet.height <= 0)
            return
        if (!sheet.source)
            sheet.source = sheet.lookupSource()
        if (!sheet.source || !sheet.blurred)
            return
        const at = sheet.mapToItem(sheet.source, 0, 0)
        crop.sourceRect = Qt.rect(at.x, at.y, sheet.width, sheet.height)
        crop.scheduleUpdate()
        sheet.bakeCount += 1
    }

    onShownChanged: if (shown) Qt.callLater(bake)           // after the owner has sized the sheet for this opening
    onWidthChanged: if (shown) Qt.callLater(bake)
    onHeightChanged: if (shown) Qt.callLater(bake)
    Component.onCompleted: if (!source) source = lookupSource()

    GlassShadow {
        id: glassShadow
        objectName: "glassSheetShadow"
        anchors.fill: parent
        u: sheet.u
        radius: sheet.radius
        kind: "panel"
    }

    ShaderEffectSource {
        id: crop
        visible: false
        live: false
        sourceItem: sheet.blurred ? sheet.source : null
        textureSize: Qt.size(Math.max(1, sheet.width / 4), Math.max(1, sheet.height / 4))
    }
    Rectangle {
        id: mask
        anchors.fill: parent
        radius: sheet.radius
        visible: false
        layer.enabled: sheet.blurred
    }
    MultiEffect {
        objectName: "glassSheetBlur"
        anchors.fill: parent
        visible: sheet.blurred
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
        objectName: "glassSheetFill"
        anchors.fill: parent
        radius: sheet.radius
        color: sheet.fillColor
    }
    GlassLayers {
        id: glassLayers
        objectName: "glassSheetLayers"
        anchors.fill: parent
        u: sheet.u
        radius: sheet.radius
        tint: true
        grain: sheet.blurred
    }
}
