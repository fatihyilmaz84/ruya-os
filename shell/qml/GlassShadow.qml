import QtQuick
import QtQuick.Effects
import RuyaShell

// A soft drop shadow under a surface (04 §3.5, §3.8), on the High and Balanced tiers only.
// Place it before the surface it belongs to, with the surface's size (`anchors.fill: parent`) and
// corner radius. `kind`: "lift" (a focused card), "panel" (glass panels, modals, toasts) or "pill"
// (the top bar; offset and blur follow the height). `active` is the owner's condition (a card:
// focused); the shadow fades with `Theme.focusMs`. The shadow source is a black rounded rectangle
// under the surface, so it must sit under an (almost) opaque surface: the glass pill's blurred
// crop and the panels are. Reduced motion does not remove shadows, it only makes the fade instant.
Item {
    id: shadow

    property real u: 1
    property real radius: 0
    property string kind: "panel"
    property bool active: true

    readonly property var spec: kind === "lift" ? Theme.shadowLift : kind === "pill" ? Theme.shadowPill : Theme.shadowPanel
    readonly property real offsetY: kind === "pill" ? Theme.shadowPill.offsetFactor * height : spec.offsetY * u
    readonly property real blurPx: kind === "pill" ? Math.min(Theme.shadowPill.blurFactor * height, Theme.shadowPill.blurMax * u) : spec.blur * u
    readonly property real alpha: spec.alpha
    readonly property bool shown: Theme.shadowsOn && active

    readonly property real pad: Math.ceil(blurPx + Math.abs(offsetY)) + 2
    readonly property real effectBlurMax: 64

    visible: opacity > 0
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.focusMs } }

    Item {
        id: box
        x: -shadow.pad
        y: -shadow.pad
        width: shadow.width + 2 * shadow.pad
        height: shadow.height + 2 * shadow.pad
        visible: false
        layer.enabled: shadow.shown
        Rectangle {
            x: shadow.pad
            y: shadow.pad
            width: shadow.width
            height: shadow.height
            radius: shadow.radius
            color: "black"
        }
    }

    MultiEffect {
        objectName: "shadowEffect"
        x: box.x
        y: box.y
        width: box.width
        height: box.height
        visible: shadow.shown
        source: box
        autoPaddingEnabled: false
        blurMax: shadow.effectBlurMax
        shadowEnabled: true
        shadowColor: "black"
        shadowOpacity: shadow.alpha
        shadowBlur: Math.min(1, shadow.blurPx / shadow.effectBlurMax)
        shadowVerticalOffset: shadow.offsetY
    }
}
