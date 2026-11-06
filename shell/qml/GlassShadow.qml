import QtQuick
import QtQuick.Effects
import RuyaShell

// A soft drop shadow under a surface (04 §3.5, §3.8), on the High and Balanced tiers only.
// Place it before the surface it belongs to, with the surface's size (`anchors.fill: parent`) and
// corner radius. `kind`: "lift" (a focused card), "panel" (glass panels, modals, toasts) or "pill"
// (the top bar; offset and blur follow the height). `active` is the owner's condition (a card:
// focused); the shadow fades with `Theme.focusMs`. Only the shadow outside the surface is drawn (the
// shape is cut out by an inverted mask), so it is safe under translucent surfaces too, and during a
// scale or fade of the owner. A card's shadow follows the art's scale (ArtCard). Reduced motion does
// not remove shadows, it only makes the fade instant.
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

    // Fades in and out with the owner's condition: the effect and its layers stay alive until the
    // fade-out ends (`visible` drops only at opacity 0).
    visible: opacity > 0
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.focusMs } }

    // The shadow's source: the surface's shape. It is cut out again by the inverted mask below, so
    // only the shadow outside the surface is drawn and nothing can show through the surface.
    Item {
        id: box
        x: -shadow.pad
        y: -shadow.pad
        width: shadow.width + 2 * shadow.pad
        height: shadow.height + 2 * shadow.pad
        visible: false
        layer.enabled: shadow.visible
        Rectangle {
            x: shadow.pad
            y: shadow.pad
            width: shadow.width
            height: shadow.height
            radius: shadow.radius
            color: Theme.shadowColor
        }
    }
    Item {
        id: cutout
        x: box.x
        y: box.y
        width: box.width
        height: box.height
        visible: false
        layer.enabled: shadow.visible
        Rectangle {
            x: shadow.pad
            y: shadow.pad
            width: shadow.width
            height: shadow.height
            radius: shadow.radius
            color: Theme.shadowColor
        }
    }

    MultiEffect {
        objectName: "shadowEffect"
        x: box.x
        y: box.y
        width: box.width
        height: box.height
        source: box
        autoPaddingEnabled: false
        maskEnabled: true
        maskInverted: true
        maskSource: cutout
        blurMax: shadow.effectBlurMax
        shadowEnabled: true
        shadowColor: Theme.shadowColor
        shadowOpacity: shadow.alpha
        shadowBlur: Math.min(1, shadow.blurPx / shadow.effectBlurMax)
        shadowVerticalOffset: shadow.offsetY
    }
}
