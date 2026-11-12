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
    Component {
        id: translucentComponent
        Item {
            width: 400; height: 225
            GlassShadow { anchors.fill: parent; radius: 32; kind: "panel" }
            Rectangle { anchors.fill: parent; radius: 32; color: Theme.glass }
        }
    }
    Component { id: holderComponent; Item { width: 400; height: 225 } }
    Component { id: sheetComponent; GlassSheet { width: 400; height: 240; shown: true } }
    Component { id: rowComponent; SettingControl { width: 600; label: "Row" } }
    Component { id: placeholderComponent; Item { width: 800; height: 400; ComingSoon {} } }
    // A modal layer as the Shell has it: it offers the L0 layer to the sheets below it.
    Component {
        id: layerComponent
        ModalLayer {
            id: modalLayer
            width: 800; height: 480
            glassSource: Rectangle { parent: modalLayer; width: 800; height: 480; color: "#336699" }
        }
    }
    Component { id: sourceComponent; Rectangle { width: 400; height: 80; color: "#336699" } }
    // A picker modal's shape (T-349): it fades, and is visible only while its opacity is above 0.
    Component {
        id: fadingModalComponent
        Item {
            id: fader
            property bool shown: false
            width: 800; height: 480
            opacity: shown ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: Theme.pageMs } }
            GlassSheet { objectName: "fadingSheet"; width: 400; height: 240; gpu: true; shown: fader.shown }
        }
    }

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
            // The effect exists only while the shadow is drawn (T-430): none on Performance.
            compare(findChild(s, "shadowEffect") !== null, data.shown)
            if (data.shown)
                compare(findChild(s, "shadowEffect").visible, true)
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

        function test_shadow_fades_out_instead_of_vanishing() {
            const s = createTemporaryObject(shadowComponent, host)
            compare(s.visible, true)
            s.active = false
            compare(s.visible, true, "the fade-out is still running: effect and layers stay")
            tryCompare(s, "visible", false)
            compare(s.opacity, 0)
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

        // T-434: a Settings row lies straight on L0. With blur (High, Balanced) L0 is blurred on pages
        // and the row is translucent glass; with none (Performance) it is opaque, like the pill and the
        // sheet, so the sharp blobs or picture never show through it (04 §3.6). Focused it is focusFill.
        function test_row_is_opaque_glass_without_blur() {
            const row = createTemporaryObject(rowComponent, host)
            verify(row)
            const fill = findChild(row, "rowFill")
            verify(fill)
            compare(fill.color, Theme.glass, "translucent over the blurred L0 on High")
            DeviceSettings.effectsQuality = "balanced"
            tryCompare(fill, "color", Theme.glass)
            DeviceSettings.effectsQuality = "performance"
            tryCompare(fill, "color", Theme.glassOpaque, 2000, "opaque glass on Performance")
            row.forceActiveFocus()
            tryCompare(fill, "color", Theme.focusFill, 2000, "focused: the focus fill on every tier")
            verify(row.activeFocus)
        }

        // The other translucent surface that lies straight on L0 on a page: the placeholder's button.
        function test_page_placeholder_is_opaque_glass_without_blur() {
            const page = createTemporaryObject(placeholderComponent, host)
            const button = findChild(page, "pagePlaceholder")
            verify(button)
            compare(button.color, Theme.glass)
            DeviceSettings.effectsQuality = "performance"
            compare(button.color, Theme.glassOpaque, "opaque glass on Performance")
        }

        // --- the glass sheet of the picker modals (T-272) ---------------------------------------

        function test_sheet_is_opaque_glass_without_blur() {
            const sheet = createTemporaryObject(sheetComponent, host)
            verify(sheet)
            compare(sheet.blurred, false, "nothing to sample, so no blur")
            compare(sheet.fillColor, Theme.glassOpaque)
            const l = findChild(sheet, "glassSheetLayers")
            verify(l.tintVisible, "a modal carries the tint")
            verify(l.sheenVisible && l.rimVisible, "sheen and rim stay on opaque glass")
            compare(l.grainVisible, false, "no grain where nothing is blurred")
            compare(findChild(sheet, "glassSheetBlur").visible, false)
            compare(l.radius, Theme.radiusL * sheet.u)
        }

        function test_sheet_blurs_the_modal_layers_source_on_the_gpu() {
            const layer = createTemporaryObject(layerComponent, host)
            const sheet = createTemporaryObject(sheetComponent, layer, { gpu: true })
            tryVerify(() => sheet.source === layer.glassSource, 2000, "found on the modal layer")
            compare(sheet.blurred, true)
            compare(sheet.fillColor, Theme.glassStrong)
            verify(findChild(sheet, "glassSheetBlur").visible)
            verify(findChild(sheet, "glassSheetLayers").grainVisible, "grain with blur")
            verify(findChild(sheet, "glassSheetLayers").tintVisible)
            DeviceSettings.effectsQuality = "performance"
            compare(sheet.blurred, false, "the Performance tier: no blur")
            compare(sheet.fillColor, Theme.glassOpaque, "opaque glass, never translucent over sharp art")
            compare(findChild(sheet, "glassSheetBlur").visible, false)
            compare(sheet.shadow.shown, false, "and no shadow")
            verify(findChild(sheet, "glassSheetLayers").sheenVisible && findChild(sheet, "glassSheetLayers").rimVisible)
        }

        function test_sheet_is_baked_when_it_opens_not_every_frame() {
            const layer = createTemporaryObject(layerComponent, host)
            const sheet = createTemporaryObject(sheetComponent, layer, { gpu: true, shown: false, x: 100, y: 60 })
            compare(sheet.bakeCount, 0, "nothing is captured while it is closed")
            sheet.shown = true
            tryCompare(sheet, "bakeCount", 1, 2000, "captured once on opening")
            verify(sheet.source === layer.glassSource)
            wait(300)
            compare(sheet.bakeCount, 1, "and not again while it stays open")
            sheet.shown = false
            sheet.shown = true
            tryCompare(sheet, "bakeCount", 2, 2000, "once more on the next opening")
        }

        // A closed sheet holds no texture (T-349): no crop of L0 (which would make L0 render into a
        // layer for it), no mask layer and nothing captured until the modal first opens; both are let
        // go once the modal has faded out, and kept while it fades.
        function test_sheet_takes_no_texture_until_shown() {
            const layer = createTemporaryObject(layerComponent, host)
            const modal = createTemporaryObject(fadingModalComponent, layer)
            const sheet = findChild(modal, "fadingSheet")
            const mask = findChild(sheet, "glassSheetMask")
            tryVerify(() => sheet.source === layer.glassSource, 2000, "found on the modal layer")
            compare(sheet.blurred, true)
            compare(sheet.backdropCrop.sourceItem, null, "no crop of L0 before the first opening")
            compare(mask.layer.enabled, false, "and no mask layer")
            compare(sheet.bakeCount, 0, "nothing captured")
            modal.shown = true
            verify(sheet.backdropCrop.sourceItem === layer.glassSource, "the crop is taken when it opens")
            verify(mask.layer.enabled)
            tryCompare(sheet, "bakeCount", 1, 2000, "and captured once")
            tryCompare(modal, "opacity", 1, 2000, "the modal has faded in")
            modal.shown = false
            verify(sheet.backdropCrop.sourceItem === layer.glassSource, "kept while the modal fades out")
            tryCompare(sheet.backdropCrop, "sourceItem", null, 3000, "let go once the modal is hidden")
            compare(mask.layer.enabled, false)
            modal.shown = true
            verify(sheet.backdropCrop.sourceItem === layer.glassSource, "taken again on the next opening")
            tryCompare(sheet, "bakeCount", 2, 2000)
        }

        // T-387: the blur's mask is handed to MultiEffect only while the mask's layer is on, so every
        // opening gives it the new layer. Under one unchanged `maskSource` a layer turned off and on again
        // masked the whole blur away on a GPU: every opening after the first was a flat sheet (`shots`
        // Wallpaper::test_zz_sheet_after_an_app, which checks the pixels).
        function test_sheet_hands_the_new_mask_layer_to_the_blur_on_every_opening() {
            const layer = createTemporaryObject(layerComponent, host)
            const modal = createTemporaryObject(fadingModalComponent, layer)
            const sheet = findChild(modal, "fadingSheet")
            const mask = findChild(sheet, "glassSheetMask")
            const blur = findChild(sheet, "glassSheetBlur")
            tryVerify(() => sheet.source === layer.glassSource, 2000, "found on the modal layer")
            compare(blur.maskSource, null, "no mask before the first opening (it has no layer)")
            for (let opening = 1; opening <= 2; ++opening) {
                modal.shown = true
                verify(mask.layer.enabled, "opening " + opening + ": the mask's layer is on")
                verify(blur.maskSource === mask, "opening " + opening + ": the blur is cut by it")
                tryCompare(modal, "opacity", 1, 2000)
                modal.shown = false
                tryCompare(sheet, "engaged", false, 3000, "let go once the modal is hidden")
                compare(mask.layer.enabled, false)
                compare(blur.maskSource, null, "opening " + opening + ": the blur lets go of the layer with it")
            }
        }

        // T-430: the T-387 class in GlassShadow. Its layers (`box`, `cutout`) are on only while the
        // shadow is drawn; a pill hidden behind an app and shown again turned them off and on under the
        // same MultiEffect with an unchanged `source`/`maskSource`, and on a GPU the shadow was gone
        // (owner report 2026-11-12; the Dell logs "Texture t7 is not assigned a valid texture provider").
        // Now the effects exist only while the layers are on: every showing makes them anew over the
        // new layers. The pixels are in `shots` (TopBarShadow::test_zz_pill_shadow_comes_back).
        function test_shadow_effects_are_made_anew_on_every_showing() {
            const holder = createTemporaryObject(translucentComponent, host)
            const shadow = holder.children[0]
            let previous = null
            for (let round = 1; round <= 2; ++round) {
                tryVerify(() => shadow.visible, 2000, "round " + round + ": drawn")
                const fx = findChild(shadow, "shadowEffect")
                verify(fx !== null, "round " + round + ": the effect exists while the shadow is drawn")
                verify(fx !== previous, "round " + round + ": a new effect, not the one from before the hide")
                verify(fx.maskSource.layer.enabled, "round " + round + ": the cutout's layer is on")
                verify(fx.source.layer.enabled, "round " + round + ": the box's layer is on")
                previous = fx
                holder.visible = false
                compare(fx.maskSource.layer.enabled, false, "round " + round + ": hidden, the layers are off")
                verify(!findChild(shadow, "shadowLoader").active, "round " + round + ": and no effect samples them")
                tryVerify(() => findChild(shadow, "shadowEffect") === null, 2000, "round " + round + ": the effect is gone")
                holder.visible = true
            }
            // The halo of a focused card's lift shadow (High tier) goes and comes back the same way.
            const card = createTemporaryObject(cardComponent, host, { picture: artFixtures + "/red.png" })
            card.focused = true
            tryVerify(() => findChild(card, "haloEffect") !== null, 3000, "the focused card has a halo")
            const halo = findChild(card, "haloEffect")
            card.visible = false
            verify(!findChild(card, "haloLoader").active, "a hidden card holds no halo")
            tryVerify(() => findChild(card, "haloEffect") === null, 2000)
            card.visible = true
            tryVerify(() => findChild(card, "haloEffect") !== null, 2000, "shown again: a halo")
            verify(findChild(card, "haloEffect") !== halo, "a new one, over the new layers")
            verify(findChild(card, "haloEffect").maskSource.layer.enabled)
        }

        // --- card focus ------------------------------------------------------------------------

        function glareOf(card) { return findChild(card, "cardFocusLayers") }
        function glareAnim(card) { return findChild(card, "glareAnimation") }

        // T-462: the pulse dip lasts 70 ms, so polling for it (every 50 ms) missed it about one run in
        // nine. Instead the art's own scale change is the sensor: the first value under 0.96 counts
        // (`pulseDips`) and holds the animation there for the screenshot. A tick that jumps past the
        // dip still writes the segment's end value (0.94) before the next segment starts.
        property var pulseAnim: null
        property int pulseDips: 0
        function onPulseScale() {
            if (pulseAnim && pulseDips === 0 && pulseAnim.running && pulseArtItem.scale < 0.96) {
                pulseDips = 1
                pulseAnim.pause()
            }
        }
        property Item pulseArtItem: null

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
            const ring = findChild(card, "cardRing")
            compare(ring.border.width, Theme.focusRingWidth * card.u)
            compare(ring.border.color, Theme.focusRing)
            verify(card.z > 0)

            card.focused = false
            compare(findChild(card, "cardSheen").visible, false)
            compare(findChild(card, "cardLiftShadow").shown, false)
            compare(ring.border.width, 0)
        }

        // The Accept pulse shrinks the art only; the lift shadow must shrink with it, or its
        // (cut-out) shape would not match the art (T-155 look).
        function test_lift_shadow_follows_the_pulse() {
            Theme.motionFactor = 1.0           // real time: the pulse must be long enough to sample mid-way (T-463)
            const card = createTemporaryObject(cardComponent, host)
            const art = findChild(card, "artMonogram").parent
            const shadow = findChild(card, "cardLiftShadow")
            card.focused = true
            compare(shadow.scale, 1)
            card.pulse()
            tryVerify(() => art.scale < 0.99, 2000, "the pulse shrinks the art")
            compare(shadow.scale, art.scale, "the shadow follows the art mid-pulse")
            tryCompare(art, "scale", 1, 2000)
            compare(shadow.scale, 1)
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
            Theme.motionFactor = 1.0           // real time: the subject is the shimmer's duration (T-463)
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

        function test_shimmer_switch_turns_it_off() {
            const art = createTemporaryObject(artComponent, host, { shimmer: false })
            art.imageStatus = Image.Loading
            compare(art.pending, true)
            compare(art.shimmering, false, "the Home hero art does not shimmer")
            compare(findChild(art, "artShimmerAnimation").running, false)
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
            // Mid-pulse: the art is smaller than the card; no black frame may show around it.
            const rightArt = findChild(right, "artMonogram").parent
            pulseArtItem = rightArt
            pulseAnim = findChild(right, "pulseAnimation")
            pulseDips = 0
            rightArt.scaleChanged.connect(onPulseScale)
            right.pulse()
            tryCompare(this, "pulseDips", 1, 2000, "the art dipped under 0.96")
            verify(pulseAnim.paused, "held at the dip for the picture")
            grabImage(stage).save(shotsDir + "/glass-card-pulse.png")
            rightArt.scaleChanged.disconnect(onPulseScale)
            pulseAnim.resume()
            tryCompare(rightArt, "scale", 1, 2000)
            pulseAnim = null
            left.destroy()
            right.destroy()

            // A shadow under a translucent surface: only the outside is shadowed, the inside is
            // the stage seen through the glass (no dark box).
            const sheet = createTemporaryObject(translucentComponent, stage, { x: 520, y: 120 })
            wait(0)
            grabImage(stage).save(shotsDir + "/glass-shadow-translucent.png")
            sheet.destroy()

            // The placeholder, mid-gleam.
            const art = createTemporaryObject(artComponent, stage, { x: 60, y: 120, width: 400, height: 225, appId: "steam:620", appName: "Portal 2" })
            art.imageStatus = Image.Loading
            const gleam = findChild(art, "artShimmer")
            tryVerify(() => gleam.x > art.width * 0.3 && gleam.x < art.width * 0.6, 3000)
            grabImage(stage).save(shotsDir + "/glass-placeholder.png")
            stage.visible = false
        }

        // T-430 probe of the T-387 class for AppArt (GPU): a rounded picture whose card is hidden (an
        // app in front, a page closed) and shown again turns both its layers off and on. The picture's
        // own layer makes its SmoothMask anew each time, so the mask is handed over fresh: the picture
        // must come back exactly as it was (the centre is the picture, the corner outside the rounding
        // is the stage).
        function artSamples(art) {
            const img = grabImage(stage)
            const at = art.mapToItem(stage, 0, 0)
            const pick = (x, y) => [img.red(Math.round(x), Math.round(y)), img.green(Math.round(x), Math.round(y)),
                                    img.blue(Math.round(x), Math.round(y))]
            const out = [[0.5, 0.5], [0.2, 0.3], [0.8, 0.7], [0.5, 0.95]].map(p => pick(at.x + art.width * p[0], at.y + art.height * p[1]))
            const c = art.radius * 0.25       // inside the rounded-off corner: the stage
            out.push(pick(at.x + c, at.y + c))
            out.push(pick(at.x + art.width - c, at.y + art.height - c))
            return { img: img, samples: out }
        }

        function test_zz_art_mask_after_a_hide() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            stage.visible = true
            const holder = createTemporaryObject(holderComponent, stage, { x: 60, y: 120 })
            const art = createTemporaryObject(artComponent, holder, { width: 400, height: 225, appId: "white",
                                                                     appName: "White", picture: artFixtures + "/white.png" })
            verify(art.masked, "the GPU path: the picture is drawn through the mask")
            tryCompare(art, "imageStatus", Image.Ready, 3000)
            waitForRendering(stage)
            wait(200)
            const fresh = artSamples(art)
            fresh.img.save(shotsDir + "/glass-art-mask-fresh.png")
            verify(fresh.samples[0][0] > 200 && fresh.samples[0][1] > 200, "the white picture shows: " + JSON.stringify(fresh.samples[0]))
            for (let round = 1; round <= 2; ++round) {
                holder.visible = false
                waitForRendering(stage)
                wait(300)
                holder.visible = true
                waitForRendering(stage)
                wait(200)
                const again = artSamples(art)
                if (round === 2)
                    again.img.save(shotsDir + "/glass-art-mask-again.png")
                let d = 0
                for (let i = 0; i < again.samples.length; ++i)
                    for (let ch = 0; ch < 3; ++ch)
                        d = Math.max(d, Math.abs(again.samples[i][ch] - fresh.samples[i][ch]))
                verify(d <= 2, "round " + round + ": the picture is as before (max channel difference " + d + "): "
                       + JSON.stringify(fresh.samples) + " vs " + JSON.stringify(again.samples))
            }
            stage.visible = false
        }

        // T-430 (GPU): a focused card's lift shadow and its halo after the card was hidden and shown
        // again (a page behind an app, then back): the same pixels around the card as before. The
        // samples lie left of and below the card, outside it, where only the shadow and halo draw.
        function cardShadowSamples(card) {
            const img = grabImage(stage)
            const at = card.mapToItem(stage, 0, 0)
            const out = []
            for (const p of [[-12, 0.5], [-30, 0.5], [-50, 0.3]])
                out.push([Math.round(at.x + p[0]), Math.round(at.y + card.height * p[1])])
            for (const p of [[0.3, 10], [0.5, 25], [0.7, 45]])
                out.push([Math.round(at.x + card.width * p[0]), Math.round(at.y + card.height + p[1])])
            return { img: img, samples: out.map(q => [img.red(q[0], q[1]), img.green(q[0], q[1]), img.blue(q[0], q[1])]) }
        }

        function test_zz_card_shadow_after_a_hide() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            failOnWarning(/is not assigned a valid texture provider/)
            stage.visible = true
            const holder = createTemporaryObject(holderComponent, stage, { x: 300, y: 150 })
            const card = createTemporaryObject(cardComponent, holder, { width: 400, picture: artFixtures + "/red.png" })
            card.focused = true
            const shadow = findChild(card, "cardLiftShadow")
            tryVerify(() => findChild(card, "haloEffect") !== null && shadow.opacity === 1 && shadow.glowMix === 1, 3000,
                      "the glowing shadow and its halo are up")
            tryCompare(glareAnim(card), "running", false, 2000)
            waitForRendering(stage)
            wait(300)
            const fresh = cardShadowSamples(card)
            fresh.img.save(shotsDir + "/glass-card-shadow-fresh.png")
            holder.visible = false
            waitForRendering(stage)
            wait(300)
            const none = cardShadowSamples(card)
            holder.visible = true
            tryVerify(() => findChild(card, "haloEffect") !== null, 2000)
            waitForRendering(stage)
            wait(300)
            const again = cardShadowSamples(card)
            again.img.save(shotsDir + "/glass-card-shadow-again.png")
            let seen = 0
            let d = 0
            for (let i = 0; i < fresh.samples.length; ++i) {
                for (let ch = 0; ch < 3; ++ch) {
                    seen = Math.max(seen, Math.abs(none.samples[i][ch] - fresh.samples[i][ch]))
                    d = Math.max(d, Math.abs(again.samples[i][ch] - fresh.samples[i][ch]))
                }
            }
            verify(seen >= 8, "the samples lie in the shadow and halo (difference to no card " + seen + ")")
            verify(d <= 3, "the shadow and halo are back as before (max channel difference " + d + "): "
                   + JSON.stringify(fresh.samples) + " vs " + JSON.stringify(again.samples))
            stage.visible = false
        }
    }
}
