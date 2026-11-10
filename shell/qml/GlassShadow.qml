pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// A soft drop shadow under a surface (04 §3.5, §3.8), on the High and Balanced tiers only.
// Place it before the surface it belongs to, with the surface's size (`anchors.fill: parent`) and
// corner radius. `kind`: "lift" (a focused card), "panel" (glass panels, modals, toasts) or "pill"
// (the top bar; offset and blur follow the height). `active` is the owner's condition (a card:
// focused); the shadow fades with `Theme.focusMs`. Only the shadow outside the surface is drawn (the
// shape is cut out by an inverted mask), so it is safe under translucent surfaces too, and during a
// scale or fade of the owner. A card's shadow follows the art's scale (ArtCard). Reduced motion does
// not remove shadows, it only makes the fade instant.
//
// The art glow (T-281, 04 §3.8): a card hands in the colour of its picture (`glow`, `glowStrength`
// from AppArt). While `active` the shadow's colour moves from the theme's shadow colour to
// `Theme.glowShadow(glow, glowStrength)` over `tintMs` (at once under reduced motion), and a "lift"
// shadow with `halo` set draws a second, wider and softer shadow of the same colour behind it on
// the High tier only. A change of `glow` (the picture's colours arrived) fades over `tintMs` too.
// Without `glowStrength` the shadow is the plain neutral one.
Item {
    id: shadow

    property real u: 1
    property real radius: 0
    property string kind: "panel"
    property bool active: true
    property color glow: Theme.shadowColor
    property real glowStrength: 0
    property bool halo: false
    Behavior on glow { ColorAnimation { duration: Theme.tintMs } }

    // 0..1: how far the shadow has moved to the glow; animated over tintMs when `active` changes.
    property real glowMix: active && glowStrength > 0 ? 1 : 0
    Behavior on glowMix { NumberAnimation { duration: Theme.tintMs } }
    readonly property color tint: ThemeMath.blend(Theme.shadowColor, Theme.glowShadow(glow, glowStrength), glowMix)

    readonly property var spec: kind === "lift" ? Theme.shadowLift : kind === "pill" ? Theme.shadowPill : Theme.shadowPanel
    readonly property real offsetY: kind === "pill" ? Theme.shadowPill.offsetFactor * height : spec.offsetY * u
    readonly property real blurPx: kind === "pill" ? Math.min(Theme.shadowPill.blurFactor * height, Theme.shadowPill.blurMax * u) : spec.blur * u
    readonly property real alpha: spec.alpha * (1 + (Theme.glowBoost - 1) * glowMix)
    readonly property bool haloShown: halo && kind === "lift" && Theme.haloOn && Theme.shadowsOn && glowStrength > 0
    readonly property real haloBlurPx: Theme.glowHalo.blur * u
    readonly property real haloAlpha: Math.min(1, Theme.glowHalo.alpha * glowStrength * glowMix * (1 + (Theme.glowBoost - 1) * glowMix))
    readonly property bool shown: Theme.shadowsOn && active

    readonly property real pad: Math.ceil(Math.max(blurPx, haloShown ? haloBlurPx : 0) + Math.abs(offsetY)) + 2
    readonly property real effectBlurMax: 64
    readonly property real haloBlurMax: 128

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
        layer.smooth: true
        Rectangle {
            x: shadow.pad
            y: shadow.pad
            width: shadow.width
            height: shadow.height
            radius: shadow.radius
            color: Theme.shadowColor
        }
    }

    // The halo of the art glow: wider and softer than the lift shadow, behind it, centred on the card.
    // Both effects cut the surface out through SmoothMask (T-314): the shadow reaches under the
    // surface's antialiased edge instead of stopping a pixel short of it (a light seam at the corners).
    // Made only while it is wanted: a card whose halo is off (not focused, a lower tier) holds no
    // effect, so the Store's forty cards carry one halo, on the focused card (T-428). It stays
    // through the fade-out (until the opacity is 0).
    Loader {
        objectName: "haloLoader"
        active: shadow.haloShown && (shadow.shown || shadow.opacity > 0)
        sourceComponent: SmoothMask {
            objectName: "haloEffect"
            x: box.x
            y: box.y
            width: box.width
            height: box.height
            source: box
            maskInverted: true
            maskSource: cutout
            blurMax: shadow.haloBlurMax
            shadowEnabled: true
            shadowColor: shadow.tint
            shadowOpacity: shadow.haloAlpha
            shadowBlur: Math.min(1, shadow.haloBlurPx / shadow.haloBlurMax)
        }
    }

    SmoothMask {
        objectName: "shadowEffect"
        x: box.x
        y: box.y
        width: box.width
        height: box.height
        source: box
        maskInverted: true
        maskSource: cutout
        blurMax: shadow.effectBlurMax
        shadowEnabled: true
        shadowColor: shadow.tint
        shadowOpacity: shadow.alpha
        shadowBlur: Math.min(1, shadow.blurPx / shadow.effectBlurMax)
        shadowVerticalOffset: shadow.offsetY
    }
}
