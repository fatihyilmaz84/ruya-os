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

    // The colour a Backdrop blob (and the gradient top) is built from: the theme's palette colour
    // with the profile's `tint` mixed in at `share` (T-271). Share 1 is the tint itself, exactly.
    function blobTint(palette, tint, share) {
        if (share >= 1)
            return tint
        return blend(palette, tint, share)
    }

    // The Backdrop colours of a theme snapshot `t` for a profile tint, as Backdrop.qml composes them:
    // the gradient's two ends and each blob over the brighter end (`strict`), and the overlap of
    // the three blobs (`overlap`). The contrast gate and the distinctness test measure these.
    function backdropSamples(t, tint) {
        const tintA = blobTint(t.blobA, tint, t.blobTintShare)
        const tintB = blobTint(t.blobB, tint, t.blobTintShare)
        const top = backdropTop(tintA, t.background, t.lightness)
        const blobA = Qt.rgba(tintA.r, tintA.g, tintA.b, blobOpacityA * t.blobStrength)
        const lit = Qt.lighter(tintB, 1.4)
        const blobB = Qt.rgba(lit.r, lit.g, lit.b, blobOpacityB * t.blobStrength)
        const blobC = Qt.rgba(t.blobHighlight.r, t.blobHighlight.g, t.blobHighlight.b, blobOpacityC * t.blobStrength)
        return {
            strict: [t.background, top, over(blobA, top), over(blobB, top)],
            overlap: over(blobC, over(blobB, over(blobA, top)))
        }
    }

    // --- Distinctness (T-271) ---

    // CIE L*a*b* (D65) of an opaque colour, and the distance between two colours (CIE76 delta E:
    // about 2.3 is the least a trained eye sees side by side; 10 is "clearly another colour").
    function lab(c) {
        const r = channel(c.r), g = channel(c.g), b = channel(c.b)
        const x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        const y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        const z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        const f = v => v > 0.008856 ? Math.cbrt(v) : 7.787 * v + 16 / 116
        return { L: 116 * f(y) - 16, a: 500 * (f(x) - f(y)), b: 200 * (f(y) - f(z)) }
    }
    function deltaE(c1, c2) {
        const p = lab(c1), q = lab(c2)
        return Math.sqrt((p.L - q.L) * (p.L - q.L) + (p.a - q.a) * (p.a - q.a) + (p.b - q.b) * (p.b - q.b))
    }

    // The four colours that make a theme recognisable at a glance, from a snapshot `t`:
    //  ground: the middle of the backdrop gradient (its top for the theme's default tint, and the ground)
    //  glass:  the opaque glass (shelf, sheets) over the ground
    //  blobs:  the three backdrop blobs overlapping, over the gradient top
    //  accent: `primaryFill`, the colour of the one main verb on a screen
    function lookColors(t) {
        const s = backdropSamples(t, t.defaultTint)
        return {
            ground: blend(s.strict[1], t.background, 0.5),
            glass: over(t.glassOpaque, t.background),
            blobs: s.overlap,
            accent: t.primaryFill
        }
    }

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
    // An opaque grey of relative luminance `lum` (the inverse of `channel`).
    function grey(lum) {
        const s = lum <= 0.0031308 ? lum * 12.92 : 1.055 * Math.pow(lum, 1 / 2.4) - 0.055
        return Qt.rgba(s, s, s, 1)
    }
    // A band of light ({ high, low } luminances) seen through a layer of `layer` at `alpha` (the wallpaper's dim).
    function bandUnder(band, layer, alpha) {
        const veil = Qt.rgba(layer.r, layer.g, layer.b, alpha)
        return { high: luminance(over(veil, grey(band.high))), low: luminance(over(veil, grey(band.low))) }
    }
    // Contrast ratio of two colours; a translucent `fg` is first painted over `bg`.
    function contrast(fg, bg) {
        const f = over(fg, bg)
        const l1 = luminance(f)
        const l2 = luminance(bg)
        return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05)
    }

    // --- The top bar's ink (RUY-1136, 04 §5.5) ---

    // The ink of the top bar's text over a band of light (`band`: { high, low } relative luminances of what lies
    // behind it): "light" (`t.inkLight`) or "dark" (`t.inkDark`), and whether the art is `busy` (the chosen ink is
    // under 4.5:1 against its worst case: the glyph halo goes on). Light ink when it reads at 4.5:1 over the band's
    // bright end, else dark ink when it reads at 4.5:1 over its dark end, else the ink whose worst case is higher.
    // `current` is the ink chosen last ("" for none): the other ink takes over only when its worst case beats the
    // current one's by `trayInkHysteresis`, so art near the threshold does not flicker. `light` / `dark` in the
    // result: each ink's worst-case contrast. `warning` true: the item shows its warning ink now (a low battery's
    // number, large text): the chosen ink's warning pair must also read at 3:1 against the same worst case, else the art
    // is busy for that item too (the halo carries it); the ink chosen does not change. `warningContrast` in the result:
    // that pair's contrast. Pure: the gate and the shell use the same function.
    readonly property real trayInkHysteresis: 0.5
    function trayInk(band, current, t, warning) {
        const light = contrast(t.inkLight, grey(band.high))
        const dark = contrast(t.inkDark, grey(band.low))
        let ink = light >= 4.5 ? "light" : dark >= 4.5 ? "dark" : light >= dark ? "light" : "dark"
        if ((current === "light" || current === "dark") && ink !== current) {
            const mine = current === "light" ? light : dark
            const other = current === "light" ? dark : light
            if (other < mine + trayInkHysteresis)
                ink = current
        }
        const warn = ink === "light" ? contrast(t.inkLightWarning, grey(band.high)) : contrast(t.inkDarkWarning, grey(band.low))
        const busy = (ink === "light" ? light : dark) < 4.5 || (warning === true && warn < 3)
        return { ink: ink, busy: busy, light: light, dark: dark, warningContrast: warn }
    }

    // How much a glass pill darkens its blurred crop (GlassPill's MultiEffect brightness, 04 §3.6; the liquid pill
    // lifts it back by `Theme.liquidBrightnessLift`).
    readonly property real glassPillDarken: 0.08
    // A band of light seen through a glass pill: its blurred crop, darkened by up to `glassPillDarken`, under `glass`
    // (`glassStrong`). The bright end is taken undarkened and the dark end darkened, so each end is the worst case for
    // the ink that is held over it (trayInk).
    function bandThroughGlass(band, glass) {
        const dim = Math.max(0, grey(band.low).r - glassPillDarken)
        return { high: luminance(over(glass, grey(band.high))), low: luminance(over(glass, Qt.rgba(dim, dim, dim, 1))) }
    }
}
