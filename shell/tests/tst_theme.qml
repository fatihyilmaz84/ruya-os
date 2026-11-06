import QtQuick
import QtTest
import RuyaShell

// Design tokens (04 §3). DeviceSettings is in-memory under test and restored after each test.
Item {
    width: 400
    height: 300

    TestCase {
        name: "Theme"
        when: windowShown

        function cleanup() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            Theme.motionFactor = 1.0
        }

        function test_type_scale() {
            compare(Theme.typeHero, 96)
            compare(Theme.typeDisplay, 64)
            compare(Theme.typeTitle, 48)
            compare(Theme.typeHeadline, 34)
            compare(Theme.typeBody, 30)
            compare(Theme.typeCaption, 24)
            compare(Theme.typeMicro, 20)
            DeviceSettings.reducedMotion = false
            compare(Theme.overlayMs, 200)
            DeviceSettings.reducedMotion = true
            compare(Theme.overlayMs, 0)
        }

        Text { id: probe; text: "ç ğ ı İ ö ş ü" }

        function test_font_loaded() {
            verify(Qt.fontFamilies().indexOf("Inter") >= 0)
            compare(Theme.fontFamily, "Inter")
            compare(probe.font.family, "Inter")
            verify(probe.contentWidth > 0)
        }

        function test_space_shape() {
            compare(Theme.spaceXxs, 4)
            compare(Theme.spaceXs, 8)
            compare(Theme.spaceS, 16)
            compare(Theme.spaceM, 24)
            compare(Theme.spaceL, 36)
            compare(Theme.spaceXl, 48)
            compare(Theme.spaceXxl, 64)
            compare(Theme.spaceXxxl, 96)
            compare(Theme.radiusS, 12)
            compare(Theme.radiusM, 18)
            compare(Theme.radiusL, 32)
            compare(Theme.rowHeight, 84)
            compare(Theme.buttonHeight, 76)
            compare(Theme.tileWidth, 400)
            compare(Theme.tileHeight, 260)
            compare(Theme.avatarSize, 200)
            compare(Theme.focusRingWidth, 4)
            compare(Theme.focusRingOffset, 7)
            compare(Theme.badgeFillAlpha, 0.18)
        }

        // --- Dreamglass v2 (04 §3.8, T-204) ---

        function test_easing_curves() {
            compare(Theme.easeGlide, [0.25, 1, 0.5, 1, 1, 1])
            compare(Theme.easeSnap, [0.23, 1, 0.32, 1, 1, 1])
            compare(Theme.popOvershoot, 0.94)
        }

        function test_motion_scale() {
            compare(Theme.motionScale, 1.0)
            compare(Theme.focusMs, 140)
            compare(Theme.pageMs, 300)
            compare(Theme.tintMs, 700)
            compare(Theme.overlayMs, 200)
            compare(Theme.pulseDownMs, 70)
            compare(Theme.pulseUpMs, 180)
            compare(Theme.shakeQuickMs, 45)
            compare(Theme.shakeSlowMs, 90)
            compare(Theme.glareMs, 550)
            compare(Theme.pageSlide, 60)
            Theme.motionFactor = 0.5
            compare(Theme.motionScale, 0.5)
            compare(Theme.focusMs, 70)
            compare(Theme.pageMs, 150)
            compare(Theme.tintMs, 350)
            compare(Theme.overlayMs, 100)
            compare(Theme.pulseDownMs, 35)
            compare(Theme.pulseUpMs, 90)
            compare(Theme.shakeQuickMs, 23)
            compare(Theme.shakeSlowMs, 45)
            compare(Theme.glareMs, 275)
            compare(Theme.pageSlide, 30)
            DeviceSettings.reducedMotion = true
            compare(Theme.motionScale, 0, "reduced motion zeroes the scale whatever the factor")
            compare(Theme.focusMs, 0)
            compare(Theme.pageMs, 0)
            compare(Theme.tintMs, 0)
            compare(Theme.overlayMs, 0)
            compare(Theme.pulseDownMs, 0)
            compare(Theme.pulseUpMs, 0)
            compare(Theme.shakeQuickMs, 0)
            compare(Theme.shakeSlowMs, 0)
            compare(Theme.glareMs, 0)
            compare(Theme.pageSlide, 0)
        }

        function test_shadow_tokens() {
            compare(Theme.shadowLift.offsetY, 14)
            compare(Theme.shadowLift.blur, 34)
            compare(Theme.shadowLift.alpha, 0.60)
            compare(Theme.shadowPanel.offsetY, 10)
            compare(Theme.shadowPanel.blur, 30)
            compare(Theme.shadowPanel.alpha, 0.35)
            compare(Theme.shadowPill.offsetFactor, 0.18)
            compare(Theme.shadowPill.blurFactor, 0.6)
            compare(Theme.shadowPill.blurMax, 40)
            compare(Theme.shadowPill.alpha, 0.27)
        }

        function test_glass_tokens() {
            fuzzyCompare(Theme.glassSheen.a, 0.06, 0.0001)
            compare(Theme.glassSheen.r, 1)
            compare(Theme.glassSheenSpan, 0.35)
            fuzzyCompare(Theme.glassRim.a, 0.15, 0.0001)
            fuzzyCompare(Theme.glassRimLit.a, 0.30, 0.0001)
            fuzzyCompare(Theme.glassTint.a, 0.44, 0.0001)
            fuzzyCompare(Theme.glassTint.r, 0x12 / 255, 0.001)
            fuzzyCompare(Theme.glassTint.g, 0x10 / 255, 0.001)
            fuzzyCompare(Theme.glassTint.b, 0x18 / 255, 0.001)
            compare(Theme.glassGrainOpacity, 1.0)
            fuzzyCompare(Theme.cardSheen.a, 0.09, 0.0001)
            fuzzyCompare(Theme.glarePeak.a, 0.6, 0.0001)
            compare(Theme.glareGapMs, 300)
            fuzzyCompare(Theme.shimmerPeak.a, 0.085, 0.0001)
            compare(Theme.shimmerSpeed, 760)
        }

        function test_tier_switches() {
            DeviceSettings.effectsQuality = "high"
            verify(Theme.shadowsOn && Theme.grainOn && Theme.glareOn && Theme.shimmerOn)
            DeviceSettings.effectsQuality = "balanced"
            verify(Theme.shadowsOn && Theme.grainOn && Theme.glareOn && Theme.shimmerOn)
            DeviceSettings.effectsQuality = "performance"
            verify(!Theme.shadowsOn && !Theme.grainOn && !Theme.glareOn && !Theme.shimmerOn)
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.reducedMotion = true
            verify(Theme.shadowsOn && Theme.grainOn, "reduced motion does not remove shadows or grain")
            verify(!Theme.glareOn && !Theme.shimmerOn, "but the glare and the shimmer stop")
        }
    }
}
