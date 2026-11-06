import QtQuick
import QtTest
import RuyaShell

// The accessibility gate of the colour themes (04 §7, T-209). For every built-in theme it
// measures the contrast of the text tokens against the surfaces they sit on, computed with the
// same arithmetic and the same Backdrop formulas the shell uses (ThemeMath), and fails a theme
// that drops below the floor. A deliberately bad fixture proves the gate can fail.
//
// What a row means:
//  - text (>= 4.5): `text` on the ground, panels, opaque glass, scrims, art fades, toasts, the
//    primary and danger buttons, and on glass over the Backdrop (each blob over the gradient's
//    brighter end, and the ground). `textDim` only on opaque surfaces (04 §3.1).
//  - overlap (>= 3): glass where the two big blobs overlap, with the white blob on top: the
//    pessimistic corner, held to the large-text floor.
//  - ring (>= 3): the focus ring against the glass, the ground, the panel and the scrims.
//  - a theme that is light also holds its glass text over pure white and pure black ("any
//    wallpaper"); a dark theme does not claim that (see test_known_limits).
Item {
    width: 400
    height: 300

    TestCase {
        name: "ThemeContrast"
        when: windowShown

        property var white: Qt.rgba(1, 1, 1, 1)
        property var black: Qt.rgba(0, 0, 0, 1)

        // The backdrop is measured with the theme's own default tint. The profile avatar colours
        // tint it too (they belong to profiles); their effect is documented in 04 §7.

        // The Backdrop colours for a tint, as Backdrop.qml composes them: gradient ends, each
        // blob over the brighter end, and the overlap (A then B, then the highlight blob).
        function backdropSamples(t, tint) {
            const top = ThemeMath.backdropTop(tint, t.background, t.lightness)
            const a = ThemeMath.blobOpacityA * t.blobStrength
            const b = ThemeMath.blobOpacityB * t.blobStrength
            const hi = ThemeMath.blobOpacityC * t.blobStrength
            const blobA = Qt.rgba(tint.r, tint.g, tint.b, a)
            const lit = Qt.lighter(tint, 1.4)
            const blobB = Qt.rgba(lit.r, lit.g, lit.b, b)
            const blobC = Qt.rgba(t.blobHighlight.r, t.blobHighlight.g, t.blobHighlight.b, hi)
            const overlap = ThemeMath.over(blobC, ThemeMath.over(blobB, ThemeMath.over(blobA, top)))
            return {
                strict: [t.background, top, ThemeMath.over(blobA, top), ThemeMath.over(blobB, top)],
                overlap: overlap
            }
        }

        function row(rows, label, fg, bg, min) {
            rows.push({ label: label, ratio: ThemeMath.contrast(fg, bg), min: min })
        }

        // Every measured pair of a theme (a snapshot object: Themes.snapshot(set) or a fixture).
        function rowsOf(t) {
            const rows = []
            const tint = t.defaultTint
            const samples = backdropSamples(t, tint)

            for (let i = 0; i < samples.strict.length; ++i) {
                const s = samples.strict[i]
                for (const [name, fill] of [["glass", t.glass], ["glassStrong", t.glassStrong]]) {
                    const g = ThemeMath.over(fill, s)
                    row(rows, "text on " + name + " over backdrop " + i, t.text, g, 4.5)
                    row(rows, "ring on " + name + " over backdrop " + i, t.focusRing, g, 3)
                }
                row(rows, "ring on backdrop " + i, t.focusRing, s, 3)
            }
            row(rows, "text on glass in the blob overlap", t.text, ThemeMath.over(t.glass, samples.overlap), 3)
            row(rows, "ring on glass in the blob overlap", t.focusRing, ThemeMath.over(t.glass, samples.overlap), 3)

            row(rows, "text on background", t.text, t.background, 4.5)
            row(rows, "textDim on background", t.textDim, t.background, 4.5)
            row(rows, "text on panel", t.text, t.panel, 4.5)
            row(rows, "textDim on panel", t.textDim, t.panel, 4.5)
            row(rows, "ring on panel", t.focusRing, t.panel, 3)
            row(rows, "errorText on panel", t.errorText, t.panel, 4.5)
            row(rows, "warningText on panel", t.warningText, t.panel, 4.5)
            row(rows, "errorText on background", t.errorText, t.background, 4.5)
            row(rows, "warningText on background", t.warningText, t.background, 4.5)

            const ends = [["white", white], ["black", black]]
            for (let i = 0; i < ends.length; ++i) {
                const name = ends[i][0]
                const e = ends[i][1]
                const opaque = ThemeMath.over(t.glassOpaque, e)
                row(rows, "text on glassOpaque over " + name, t.text, opaque, 4.5)
                row(rows, "textDim on glassOpaque over " + name, t.textDim, opaque, 4.5)
                row(rows, "text on scrim over " + name, t.text, ThemeMath.over(t.scrim, e), 4.5)
                row(rows, "ring on scrim over " + name, t.focusRing, ThemeMath.over(t.scrim, e), 3)
                row(rows, "text on scrimOverlay over " + name, t.text, ThemeMath.over(t.scrimOverlay, e), 4.5)
                row(rows, "text on heroScrim over " + name + " art", t.text, ThemeMath.over(t.heroScrim, e), 4.5)
                row(rows, "text on artCaptionFade over " + name + " art", t.text, ThemeMath.over(t.artCaptionFade, e), 4.5)
                const toast = ThemeMath.over(t.toastBackground, e)
                row(rows, "text on toast over " + name, t.text, toast, 4.5)
                for (const kind of ["toastInfo", "toastSuccess", "toastWarning", "toastError"])
                    row(rows, kind + " (icon) on toast over " + name, t[kind], toast, 3)
            }

            row(rows, "onPrimary on primaryFill", t.onPrimary, t.primaryFill, 4.5)
            row(rows, "text on dangerFill", t.text, t.dangerFill, 4.5)
            row(rows, "ring on primaryFill", t.focusRing, ThemeMath.over(t.glass, t.background), 3)
            // Badges: the kind colour on its own 18 % fill over the panel.
            for (const kind of ["toastInfo", "toastSuccess", "toastWarning"]) {
                const tone = t[kind]
                const fill = ThemeMath.over(Qt.rgba(tone.r, tone.g, tone.b, Theme.badgeFillAlpha), t.panel)
                row(rows, "badge " + kind + " on its fill", tone, fill, 4.5)
            }

            // A light theme claims any wallpaper: its glass text holds over pure white and black.
            if (t.lightness >= 0.5) {
                for (let i = 0; i < ends.length; ++i) {
                    const g = ThemeMath.over(t.glass, ends[i][1])
                    const gs = ThemeMath.over(t.glassStrong, ends[i][1])
                    row(rows, "text on glass over " + ends[i][0], t.text, g, 4.5)
                    row(rows, "text on glassStrong over " + ends[i][0], t.text, gs, 4.5)
                    row(rows, "ring on glass over " + ends[i][0], t.focusRing, g, 3)
                    row(rows, "text on glassTint over " + ends[i][0], t.text, ThemeMath.over(t.glassTint, ends[i][1]), 4.5)
                }
            }
            return rows
        }

        function failures(t) {
            const out = []
            const rows = rowsOf(t)
            for (let i = 0; i < rows.length; ++i) {
                if (rows[i].ratio < rows[i].min)
                    out.push(rows[i].label + ": " + rows[i].ratio.toFixed(2) + " < " + rows[i].min)
            }
            return out
        }

        function test_every_theme_passes_the_gate_data() {
            return Themes.all.map(s => ({ tag: s.key, key: s.key }))
        }
        function test_every_theme_passes_the_gate(data) {
            const bad = failures(Themes.snapshot(Themes.byKey(data.key)))
            verify(bad.length === 0, data.key + " fails: " + bad.join("; "))
        }

        function test_the_gate_measures_a_lot() {
            const rows = rowsOf(Themes.snapshot(Themes.byKey("dreamglass")))
            verify(rows.length >= 60, "rows: " + rows.length)
            const light = rowsOf(Themes.snapshot(Themes.byKey("daylight")))
            verify(light.length > rows.length, "a light theme adds the any-wallpaper rows")
        }

        // The self-check: the gate really fails. Dreamglass with dark text, then with a ring that
        // vanishes into the glass, then with a translucent panel colour: each must be caught.
        function test_gate_fails_a_bad_theme() {
            const good = Themes.snapshot(Themes.byKey("dreamglass"))
            compare(failures(good).length, 0)

            const darkText = Themes.snapshot(Themes.byKey("dreamglass"))
            darkText.text = Qt.color("#303848")
            verify(failures(darkText).length > 0, "dark text on a dark theme")

            const faintRing = Themes.snapshot(Themes.byKey("dreamglass"))
            faintRing.focusRing = Qt.color("#101626")
            verify(failures(faintRing).some(f => f.indexOf("ring") >= 0), "a ring that sits in the glass")

            const lightOnLight = Themes.snapshot(Themes.byKey("daylight"))
            lightOnLight.glass = Qt.color("#08ffffff")      // Daylight with its frosted glass nearly clear
            lightOnLight.text = Qt.color("#f2f4f8")         // ... and light text left over from a dark theme
            verify(failures(lightOnLight).length > 0, "light text on a light theme")
        }

        // Pinned limits (04 §3.6, §7): what the gate does NOT promise, so a fix has to change the
        // spec too. A dark theme's glass is not legible over a bright wallpaper, and glassTint,
        // which exists for sheets over bright art, does not carry text on a dark theme.
        function test_known_limits() {
            const dream = Themes.snapshot(Themes.byKey("dreamglass"))
            const tinted = ThemeMath.contrast(dream.text, ThemeMath.over(dream.glassTint, white))
            verify(tinted < 4.5 && tinted > 2.0, "text on glassTint over white art (04 §3.6 says 2.5): " + tinted)
            for (const key of ["dreamglass", "midnight", "aurora", "ember"]) {
                const t = Themes.snapshot(Themes.byKey(key))
                const onWhite = ThemeMath.contrast(t.text, ThemeMath.over(t.glass, white))
                verify(onWhite < 4.5, key + ": text on glass over a white wallpaper is not claimed: " + onWhite)
            }
            // ... while Daylight does hold there (it is in the gate above).
            const day = Themes.snapshot(Themes.byKey("daylight"))
            verify(ThemeMath.contrast(day.text, ThemeMath.over(day.glass, white)) >= 4.5)
            verify(ThemeMath.contrast(day.text, ThemeMath.over(day.glass, black)) >= 4.5)
        }
    }
}
