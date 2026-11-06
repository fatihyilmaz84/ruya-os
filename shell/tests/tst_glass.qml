import QtQuick
import QtTest
import RuyaShell

// Dreamglass materials and motion (04 §3.8, T-204): the glass layer stack per tier, the shadows,
// the card focus (lift shadow, sheen, one-time glare) and the shimmer placeholder. Offscreen is the
// software renderer, so these assert properties and animation state, never pixels; the look is in
// the screenshots (`dev.ps1 shots`).
Item {
    id: host
    width: 1000
    height: 600

    Component { id: layersComponent; GlassLayers { width: 300; height: 100; radius: 50 } }
    Component { id: shadowComponent; GlassShadow { width: 300; height: 100; radius: 50 } }
    Component { id: pillComponent; GlassPill { width: 400; height: 80 } }
    Component { id: cardComponent; ArtCard { itemId: "steam:620"; title: "Portal 2"; width: 320 } }
    Component { id: artComponent; AppArt { width: 320; height: 180; appId: "x"; appName: "X"; picture: "/nonexistent.png" } }
    Component { id: sourceComponent; Rectangle { width: 400; height: 80; color: "#336699" } }

    // The stage of the screenshots. Outside the TestCase, which is invisible itself.
    Rectangle {
        id: stage
        x: 0; y: 0; width: 1000; height: 600
        visible: false
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#5b6fd6" }
            GradientStop { position: 1.0; color: "#1c2140" }
        }
    }

    TestCase {
        id: tc
        name: "Glass"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            GlareGate.reset()
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            GlareGate.reset()
        }

        // --- layers per tier -------------------------------------------------------------------

        function layerState(l) {
            return {
                sheen: l.sheenVisible && findChild(l, "glassSheen").visible,
                rim: l.rimVisible && findChild(l, "glassRim").visible,
                tint: l.tintVisible && findChild(l, "glassTint").visible,
                grain: l.grainVisible && findChild(l, "glassGrain").visible
            }
        }

        function test_layers_per_tier_data() {
            return [
                { tag: "high", tier: "high", grain: true },
                { tag: "balanced", tier: "balanced", grain: true },
                { tag: "performance", tier: "performance", grain: false }
            ]
        }

        function test_layers_per_tier(data) {
            DeviceSettings.effectsQuality = data.tier
            const l = createTemporaryObject(layersComponent, host)
            verify(l)
            const s = layerState(l)
            verify(s.sheen, "sheen is on every tier")
            verify(s.rim, "the rim is on every tier")
            compare(s.tint, false, "no tint unless asked for")
            compare(s.grain, data.grain, "grain only where there is blur: " + data.tier)
            l.tint = true
            verify(layerState(l).tint, "tint on every tier when asked for")
            l.grain = false
            compare(layerState(l).grain, false, "a surface without blur turns the grain off")
            l.rim = false
            compare(layerState(l).rim, false)
        }

        function test_layers_follow_the_tier_live() {
            const l = createTemporaryObject(layersComponent, host)
            verify(layerState(l).grain)
            DeviceSettings.effectsQuality = "performance"
            compare(layerState(l).grain, false)
            verify(layerState(l).sheen && layerState(l).rim)
            DeviceSettings.effectsQuality = "balanced"
            verify(layerState(l).grain)
        }

        function test_grain_tile_is_the_128_noise_tile() {
            const l = createTemporaryObject(layersComponent, host)
            const g = findChild(l, "glassGrain")
            tryCompare(g, "status", Image.Ready)
            compare(g.implicitWidth, 128)
            compare(g.implicitHeight, 128)
            compare(g.fillMode, Image.Tile)
            compare(g.opacity, Theme.glassGrainOpacity)
        }

        // --- shadows ---------------------------------------------------------------------------

        function test_shadow_per_tier_data() {
            return [
                { tag: "high", tier: "high", shown: true },
                { tag: "balanced", tier: "balanced", shown: true },
                { tag: "performance", tier: "performance", shown: false }
            ]
        }

        function test_shadow_per_tier(data) {
            DeviceSettings.effectsQuality = data.tier
            const s = createTemporaryObject(shadowComponent, host)
            compare(s.shown, data.shown)
            tryCompare(s, "visible", data.shown)
            compare(findChild(s, "shadowEffect").visible, data.shown)
        }

        function test_shadow_numbers_follow_the_kind() {
            const s = createTemporaryObject(shadowComponent, host, { u: 2 })
            s.kind = "lift"
            compare(s.offsetY, 14 * 2)
            compare(s.blurPx, 34 * 2)
            compare(s.alpha, 0.60)
            s.kind = "panel"
            compare(s.offsetY, 10 * 2)
            compare(s.blurPx, 30 * 2)
            compare(s.alpha, 0.35)
            s.kind = "pill"            // height 100: offset 0.18 h, blur min(0.6 h, 40 u)
            fuzzyCompare(s.offsetY, 18, 0.001)
            compare(s.blurPx, 60)
            s.height = 200
            compare(s.blurPx, 80, "capped at 40 design px")
            compare(s.alpha, 0.27)
        }

        function test_shadow_stays_under_reduced_motion() {
            DeviceSettings.reducedMotion = true
            const s = createTemporaryObject(shadowComponent, host)
            compare(s.shown, true)
            compare(s.visible, true, "the fade is instant, the shadow stays")
        }

        function test_inactive_shadow_is_hidden() {
            const s = createTemporaryObject(shadowComponent, host, { active: false })
            compare(s.shown, false)
            tryCompare(s, "visible", false)
            s.active = true
            tryCompare(s, "visible", true)
        }

        function test_pill_has_layers_and_shadow_per_tier() {
            const src = createTemporaryObject(sourceComponent, host)
            const pill = createTemporaryObject(pillComponent, host, { source: src })
            verify(pill)
            const layers = findChild(pill, "glassLayers")
            const shadow = findChild(pill, "glassShadow")
            verify(layers && shadow)
            verify(layerState(layers).grain && layerState(layers).sheen && layerState(layers).rim)
            compare(shadow.shown, true)
            compare(findChild(pill, "glassFill").color, Theme.glassStrong)
            DeviceSettings.effectsQuality = "performance"
            compare(findChild(pill, "glassFill").color, Theme.glassOpaque, "opaque glass")
            verify(layerState(layers).sheen && layerState(layers).rim, "opaque glass keeps sheen and rim")
            compare(layerState(layers).grain, false, "and drops the grain")
            compare(shadow.shown, false, "and the shadow")
        }

        // --- card focus ------------------------------------------------------------------------

        function glareOf(card) { return findChild(card, "cardFocusLayers") }
        function glareAnim(card) { return findChild(card, "glareAnimation") }

        function test_card_focus_shows_lift_sheen_and_glare() {
            const card = createTemporaryObject(cardComponent, host)
            const fx = glareOf(card)
            verify(fx)
            compare(findChild(card, "cardSheen").visible, false, "no sheen at rest")
            compare(findChild(card, "cardLiftShadow").shown, false, "no shadow at rest")
            compare(fx.glareCount, 0)
            compare(glareAnim(card).running, false, "no resting glare")
            compare(card.scale, 1)

            card.focused = true
            compare(findChild(card, "cardSheen").visible, true)
            compare(findChild(card, "cardLiftShadow").shown, true)
            compare(fx.glareCount, 1, "the glare starts when focus enters")
            compare(glareAnim(card).running, true)
            compare(glareAnim(card).duration, Theme.glareMs)
            compare(glareAnim(card).easing.type, Easing.InOutQuad)
            tryCompare(glareAnim(card), "running", false)   // once: it ends and does not restart
            compare(fx.glareCount, 1)
            wait(0)
            compare(glareAnim(card).running, false)

            // The ring and the 1.08 scale are unchanged.
            tryCompare(card, "scale", Theme.focusScale)
            compare(Theme.focusScale, 1.08)
            const art = findChild(card, "artMonogram").parent
            compare(art.border.width, Theme.focusRingWidth * card.u)
            compare(art.border.color, Theme.focusRing)
            verify(card.z > 0)

            card.focused = false
            compare(findChild(card, "cardSheen").visible, false)
            compare(findChild(card, "cardLiftShadow").shown, false)
            compare(art.border.width, 0)
        }

        function test_glare_is_skipped_when_focus_moved_within_300_ms() {
            const a = createTemporaryObject(cardComponent, host)
            const b = createTemporaryObject(cardComponent, host)
            const c = createTemporaryObject(cardComponent, host)
            compare(Theme.glareGapMs, 300)
            GlareGate.fakeNow = 1000
            a.focused = true
            compare(glareOf(a).glareCount, 1, "the first entry glares")
            a.focused = false
            GlareGate.fakeNow = 1299       // 299 ms after the last entry
            b.focused = true
            compare(glareOf(b).glareCount, 0, "focus moved on within 300 ms: no glare")
            compare(glareAnim(b).running, false)
            verify(findChild(b, "cardSheen").visible, "the sheen still shows")
            b.focused = false
            GlareGate.fakeNow = 1599       // 300 ms after the skipped entry at 1299
            c.focused = true
            compare(glareOf(c).glareCount, 1, "300 ms after the last entry it plays again")
            c.focused = false
            compare(glareAnim(c).running, false, "losing focus stops the glare")
        }

        function test_no_glare_under_reduced_motion() {
            DeviceSettings.reducedMotion = true
            const card = createTemporaryObject(cardComponent, host)
            GlareGate.fakeNow = 1000
            card.focused = true
            compare(glareOf(card).glareCount, 0)
            compare(glareAnim(card).running, false)
            compare(findChild(card, "cardSheen").visible, true, "sheen and shadow stay")
            compare(findChild(card, "cardLiftShadow").shown, true)
            compare(card.scale, Theme.focusScale, "the lift is instant")
        }

        function test_no_glare_on_performance_and_no_shadow() {
            DeviceSettings.effectsQuality = "performance"
            const card = createTemporaryObject(cardComponent, host)
            GlareGate.fakeNow = 1000
            card.focused = true
            compare(glareOf(card).glareCount, 0)
            compare(glareAnim(card).running, false)
            compare(findChild(card, "cardSheen").visible, true, "the sheen is on every tier")
            compare(findChild(card, "cardLiftShadow").shown, false, "no lift shadow on Performance")
        }

        function test_balanced_has_glare_and_shadow() {
            DeviceSettings.effectsQuality = "balanced"
            const card = createTemporaryObject(cardComponent, host)
            card.focused = true
            compare(glareOf(card).glareCount, 1)
            compare(findChild(card, "cardLiftShadow").shown, true)
        }

        // --- shimmer ---------------------------------------------------------------------------

        function test_placeholder_shimmers_while_the_picture_loads() {
            const art = createTemporaryObject(artComponent, host)
            art.imageStatus = Image.Loading
            const anim = findChild(art, "artShimmerAnimation")
            verify(anim)
            compare(art.pending, true)
            compare(art.shimmering, true)
            compare(anim.running, true)
            verify(anim.loops < 0, "loops for ever")
            // 760 design px per second over the way the gleam travels.
            const travel = art.width + findChild(art, "artShimmer").width
            fuzzyCompare(anim.duration, travel / (Theme.shimmerSpeed * art.u) * 1000, 1)
            fuzzyCompare(Theme.shimmerPeak.a, 0.085, 0.0001)
            art.imageStatus = Image.Ready
            compare(anim.running, false, "a loaded picture does not shimmer")
        }

        function test_no_shimmer_when_there_is_nothing_to_wait_for() {
            const art = createTemporaryObject(artComponent, host, { picture: "" })
            art.imageStatus = Image.Loading
            compare(art.shimmering, false, "no picture: initials only")
            art.picture = "/nonexistent.png"
            art.imageStatus = Image.Error
            compare(art.shimmering, false, "a picture that failed keeps the fallback, calm")
        }

        function test_no_shimmer_under_reduced_motion_or_performance() {
            const art = createTemporaryObject(artComponent, host)
            art.imageStatus = Image.Loading
            verify(art.shimmering)
            DeviceSettings.reducedMotion = true
            compare(art.shimmering, false)
            compare(findChild(art, "artShimmerAnimation").running, false)
            DeviceSettings.reducedMotion = false
            verify(art.shimmering)
            DeviceSettings.effectsQuality = "performance"
            compare(art.shimmering, false)
            compare(findChild(art, "artShimmerAnimation").running, false)
        }

        // --- screenshots (shots only) ----------------------------------------------------------

        function test_zz_screenshots_card_glare_and_placeholder() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            stage.visible = true
            const left = createTemporaryObject(cardComponent, stage, { x: 60, y: 120, width: 400, title: "Portal 2" })
            const right = createTemporaryObject(cardComponent, stage, { x: 520, y: 120, width: 400, itemId: "steam:730", title: "Counter-Strike" })
            right.focused = true
            // Mid-glare: wait for the band to be about half-way across the card.
            const band = findChild(right, "cardGlare")
            tryVerify(() => glareAnim(right).running && band.x > right.width * 0.3, 2000)
            wait(0)
            grabImage(stage).save(shotsDir + "/glass-card-glare.png")
            tryCompare(glareAnim(right), "running", false)
            wait(200)
            grabImage(stage).save(shotsDir + "/glass-card-focus.png")
            left.destroy()
            right.destroy()

            // The placeholder, mid-gleam.
            const art = createTemporaryObject(artComponent, stage, { x: 60, y: 120, width: 400, height: 225, appId: "steam:620", appName: "Portal 2" })
            art.imageStatus = Image.Loading
            const gleam = findChild(art, "artShimmer")
            tryVerify(() => gleam.x > art.width * 0.3 && gleam.x < art.width * 0.6, 3000)
            grabImage(stage).save(shotsDir + "/glass-placeholder.png")
            stage.visible = false
        }
    }
}
