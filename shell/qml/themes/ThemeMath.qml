pragma Singleton
import QtQuick

// Colour arithmetic shared by Theme.qml (the cross-fade, the backdrop gradient) and by the
// contrast gate (tests/tst_theme_contrast.qml), so the gate measures what the shell draws.
QtObject {
    // Linear blend of two token values: colours per channel (alpha too), numbers directly.
    function blend(a, b, t) {
        if (typeof b === "number")
            return a + (b - a) * t
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
    }

    // The top of Backdrop's gradient for a tint: the tint darkened (dark themes) or the tint
    // washed into the pale ground (light themes); `lightness` blends the two during a cross-fade.
    function backdropTop(tint, ground, lightness) {
        const dark = Qt.darker(tint, 3.2)
        if (lightness <= 0)
            return dark
        const pale = Qt.rgba(ground.r + (tint.r - ground.r) * 0.3, ground.g + (tint.g - ground.g) * 0.3,
                             ground.b + (tint.b - ground.b) * 0.3, 1)
        return blend(dark, pale, lightness)
    }

    // The opacities of Backdrop's three blobs at strength 1 (tint, lighter tint, highlight).
    readonly property real blobOpacityA: 0.55
    readonly property real blobOpacityB: 0.35
    readonly property real blobOpacityC: 0.08

    // The art placeholder gradient (AppArt): hue 0..1, `light` the set's lightness for this end.
    function artColor(hue, saturation, light) {
        return Qt.hsla(hue, saturation, light, 1)
    }

    // --- WCAG ---

    function channel(c) {
        return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
    }
    // Relative luminance of an opaque colour.
    function luminance(c) {
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }
    // `top` painted over an opaque `bottom` (alpha blend in sRGB, as the scene graph does).
    function over(top, bottom) {
        const a = top.a
        return Qt.rgba(top.r * a + bottom.r * (1 - a), top.g * a + bottom.g * (1 - a), top.b * a + bottom.b * (1 - a), 1)
    }
    // Contrast ratio of two colours; a translucent `fg` is first painted over `bg`.
    function contrast(fg, bg) {
        const f = over(fg, bg)
        const l1 = luminance(f)
        const l2 = luminance(bg)
        return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05)
    }
}
