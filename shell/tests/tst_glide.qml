import QtQuick
import QtTest
import RuyaShell

// Gliding highlight and liquid pill (04 §3.8, T-205). The highlight is a picture: it follows the
// focused item's geometry, glides with easeGlide, retargets from where it is, snaps under reduced
// motion, stretches with speed, and never takes focus (keys, names and rings stay on the items).
// Offscreen is the software renderer, so the liquid pill is asserted by its gates and its
// fallback; its look is in the screenshots (`dev.ps1 shots`).
Item {
    id: host
    width: 900
    height: 400

    // Three siblings inside an offset parent, so the mapping through ancestors is exercised.
    Component {
        id: stripComponent
        Item {
            id: strip
            width: 700
            height: 200
            property alias glide: g
            property alias a: a
            property alias b: b
            property alias c: c
            Item {
                x: 30
                y: 20
                width: 600
                height: 100
                Item { id: a; objectName: "a"; x: 0; y: 10; width: 100; height: 40 }
                Item { id: b; objectName: "b"; x: 150; y: 10; width: 200; height: 40 }
                Item { id: c; objectName: "c"; x: 400; y: 30; width: 120; height: 60 }
            }
            FocusGlide { id: g; objectName: "g" }
        }
    }

    Component {
        id: navHostComponent
        FocusScope {
            property alias nav: benchNav
            property alias other: other
            width: benchNav.width + 40
            height: benchNav.height + 40
            Rectangle { anchors.fill: parent; color: Theme.background }
            SectionNav { id: benchNav; x: 20; y: 20; focus: true }
            FocusScope { id: other; x: 0; y: 0; width: 10; height: 10 }
        }
    }

    Component { id: liquidComponent; LiquidGlass { } }
    Component { id: pillComponent; GlassPill { width: 400; height: 80 } }

    // The stage of the screenshots: sharp, colourful art behind the nav, so the blur and the
    // refraction at the pill's edge have something to bend. Outside the TestCase (invisible itself).
    Rectangle {
        id: stage
        x: 0; y: 0; width: 900; height: 400
        visible: false
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#4a63d8" }
            GradientStop { position: 1.0; color: "#c2569a" }
        }
        Repeater {
            model: 9
            Rectangle {
                required property int index
                x: index * 100 + 10
                y: 0
                width: 40
                height: 400
                color: index % 2 === 0 ? "#f3c34a" : "#37c6a4"
            }
        }
        Rectangle { x: 120; y: 150; width: 180; height: 180; radius: 90; color: "#ffffff" }
        Rectangle { x: 560; y: 180; width: 220; height: 120; radius: 30; color: "#101820" }
        SectionNav {
            id: stageNav
            objectName: "stageNav"
            x: 100
            y: 40
            u: 1
            blurSource: stage
            blurX: x
            blurY: y
            section: "home"
        }
    }

    TestCase {
        id: tc
        name: "Glide"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.theme = "dreamglass"
            Theme.liquidPill = true
            Theme.motionFactor = 1
            LiquidGate.reset()
        }

        function makeStrip() {
            const s = createTemporaryObject(stripComponent, host)
            verify(s)
            return s
        }

        // Point the highlight at an item and wait until it has settled there.
        function settleOn(s, item) {
            s.glide.target = item
            tryVerify(() => s.glide.primed)
            tryCompare(s.glide, "x", s.glide.targetX)
            tryCompare(s.glide, "y", s.glide.targetY)
            tryVerify(() => !s.glide.gliding)
        }

        // --- geometry follows the target ---------------------------------------------------------

        function test_geometry_follows_the_target() {
            const s = makeStrip()
            compare(s.glide.active, false, "no target: nothing is drawn")
            compare(s.glide.visible, false)
            for (const item of [s.a, s.b, s.c]) {
                s.glide.target = item
                compare(s.glide.targetX, 30 + item.x)
                compare(s.glide.targetY, 20 + item.y)
                compare(s.glide.targetWidth, item.width)
                compare(s.glide.targetHeight, item.height)
                compare(s.glide.active, true)
            }
        }

        function test_geometry_follows_a_moving_target() {
            const s = makeStrip()
            s.glide.target = s.b
            s.b.x = 260
            s.b.width = 90
            compare(s.glide.targetX, 30 + 260, "an item that moves or resizes is followed")
            compare(s.glide.targetWidth, 90)
        }

        function test_target_outside_the_parent_is_not_drawn() {
            const s = makeStrip()
            const stray = createTemporaryObject(stripComponent, host)
            s.glide.target = stray.a
            compare(s.glide.active, false, "an item below another parent has no geometry here")
        }

        function test_hidden_highlight_does_not_glide_but_shows_in_place() {
            const s = makeStrip()
            s.glide.shown = false
            s.glide.target = s.a
            tryVerify(() => s.glide.primed)
            s.glide.target = s.c
            compare(s.glide.x, s.glide.targetX, "hidden: follows without a glide")
            compare(s.glide.active, false)
            s.glide.shown = true
            tryCompare(s.glide, "opacity", 1)
            compare(s.glide.x, 30 + s.c.x, "shown where the focus is, not gliding from the old row")
        }

        // --- the glide -------------------------------------------------------------------------

        function test_glides_instead_of_jumping() {
            const s = makeStrip()
            settleOn(s, s.a)
            const start = s.glide.x
            s.glide.target = s.c
            verify(s.glide.gliding, "the position animates")
            tryVerify(() => s.glide.x > start + 1, 2000, "it moves")
            verify(s.glide.x < s.glide.targetX - 1 || s.glide.gliding, "and does not start at the goal")
            tryCompare(s.glide, "x", s.glide.targetX)
            tryCompare(s.glide, "width", s.c.width)
        }

        function test_retarget_mid_glide_does_not_jump() {
            Theme.motionFactor = 4              // a 1120 ms glide: a wide window to retarget in, same assertions
            const s = makeStrip()
            settleOn(s, s.a)
            const start = s.glide.x
            s.glide.target = s.c
            tryVerify(() => s.glide.x > start + 20, 2000)
            const mid = s.glide.x
            verify(mid < 30 + s.c.x - 1, "still on its way to c")
            // Retarget to b, which is back along the way: the position continues from `mid`.
            s.glide.target = s.b
            verify(Math.abs(s.glide.x - mid) < 2, "no jump at the retarget: " + s.glide.x + " vs " + mid)
            verify(s.glide.x > start + 1, "no restart from zero")
            const goal = 30 + s.b.x
            const lo = Math.min(mid, goal) - 1
            const hi = Math.max(mid, goal) + 1
            for (let i = 0; i < 6; ++i) {
                wait(20)
                verify(s.glide.x >= lo && s.glide.x <= hi, "stays between where it was and the goal: " + s.glide.x)
            }
            tryCompare(s.glide, "x", goal)
        }

        function test_snaps_under_reduced_motion() {
            const s = makeStrip()
            settleOn(s, s.a)
            DeviceSettings.reducedMotion = true
            compare(Theme.motionScale, 0)
            s.glide.target = s.c
            compare(s.glide.x, 30 + s.c.x, "snaps at once")
            compare(s.glide.y, 20 + s.c.y)
            compare(s.glide.width, s.c.width)
            compare(s.glide.height, s.c.height)
            compare(s.glide.gliding, false)
        }

        function test_first_placement_snaps() {
            const s = makeStrip()
            s.glide.target = s.c
            compare(s.glide.x, 30 + s.c.x, "the first target is not reached by gliding from 0,0")
        }

        // --- stretch -----------------------------------------------------------------------------

        function test_stretch_factor_from_speed() {
            const s = makeStrip()
            compare(s.glide.stretchFor(0), 0)
            fuzzyCompare(s.glide.stretchFor(1300), 0.5, 0.0001)
            compare(s.glide.stretchFor(2600), 1)
            compare(s.glide.stretchFor(9000), 1, "clamped")
            fuzzyCompare(s.glide.stretchFor(-1300), 0.5, 0.0001, "direction does not matter")
        }

        function test_stretch_is_smoothed_at_14_per_second() {
            const s = makeStrip()
            s.glide.stepStretch(1 / 14, 2600)
            fuzzyCompare(s.glide.stretch, 1 - Math.exp(-1), 0.0001, "one time constant")
            for (let i = 0; i < 120; ++i)
                s.glide.stepStretch(1 / 60, 2600)
            verify(s.glide.stretch > 0.99, "converges to the factor: " + s.glide.stretch)
            for (let i = 0; i < 120; ++i)
                s.glide.stepStretch(1 / 60, 0)
            verify(s.glide.stretch < 0.01, "and relaxes: " + s.glide.stretch)
        }

        function test_stretch_lengthens_the_body_behind_the_motion() {
            const s = makeStrip()
            s.glide.target = s.b
            const body = findChild(s, "focusGlideBody")
            compare(body.width, s.b.width, "at rest the body is the item")
            for (let i = 0; i < 90; ++i)
                s.glide.stepStretch(1 / 60, 2600)       // moving right
            const extra = Theme.glideStretchMax * s.b.width * s.glide.stretch
            verify(extra > 50)
            fuzzyCompare(body.width, s.b.width + extra, 0.01)
            fuzzyCompare(body.x, -extra, 0.01, "trails to the left when moving right")
            for (let i = 0; i < 90; ++i)
                s.glide.stepStretch(1 / 60, -2600)      // moving left
            fuzzyCompare(body.x, 0, 0.01, "extends to the right when moving left")
            verify(body.width > s.b.width + 50)
        }

        function test_no_stretch_under_reduced_motion() {
            const s = makeStrip()
            DeviceSettings.reducedMotion = true
            s.glide.stepStretch(1 / 60, 5000)
            compare(s.glide.stretch, 0)
        }

        function test_stretch_follows_a_real_glide_and_settles() {
            const s = makeStrip()
            settleOn(s, s.a)
            s.glide.target = s.c
            tryVerify(() => s.glide.stretch > 0.02, 2000, "a glide stretches")
            tryVerify(() => !s.glide.gliding && s.glide.stretch === 0, 3000, "and the body is the item again at rest")
        }

        // --- never holds focus: the section nav ----------------------------------------------

        function makeNav() {
            const f = createTemporaryObject(navHostComponent, host)
            verify(f)
            f.forceActiveFocus()
            tryVerify(() => f.nav.activeFocus)
            return f
        }

        function test_nav_highlight_follows_focus_and_never_takes_it() {
            const f = makeNav()
            const nav = f.nav
            const glide = findChild(nav, "navGlide")
            const pills = findChild(nav, "navPills")
            tryVerify(() => glide.active)
            compare(glide.activeFocus, false, "the highlight never has focus")
            compare(glide.focus, false)
            compare(nav.activeFocus, true)
            compare(glide.targetX, pills.x + findChild(nav, "navPill_home").x, "starts on the focused pill")
            for (const key of ["games", "media", "store", "settings"]) {
                keyClick(Qt.Key_Right)
                compare(nav.currentKey, key)
                const pill = findChild(nav, "navPill_" + key)
                compare(glide.targetX, pills.x + pill.x, "the highlight's goal is the focused pill: " + key)
                compare(glide.targetY, pills.y + pill.y)
                compare(glide.targetWidth, pill.width)
                compare(glide.targetHeight, pill.height)
                compare(nav.activeFocus, true, "focus stays on the nav")
                compare(glide.activeFocus, false)
                compare(nav.Accessible.name, nav.label(key), "the screen reader's name is the focused pill at once")
            }
            keyClick(Qt.Key_Left)
            compare(nav.currentKey, "store")
            compare(nav.Accessible.role, Accessible.PageTabList)
        }

        function test_nav_pill_hides_its_own_fill_only_while_the_highlight_is_drawn() {
            const f = makeNav()
            const nav = f.nav
            const glide = findChild(nav, "navGlide")
            keyClick(Qt.Key_Right)                       // Games; the section on screen is Home
            tryVerify(() => glide.active)
            const fill = findChild(nav, "navPillFill_games")
            compare(fill.color.a, 0, "the highlight is the fill")
            compare(fill.border.width > 0, true, "the ring stays on the pill")
            compare(Qt.colorEqual(fill.border.color, Theme.focusRing), true)
            // Without the highlight (here: switched off by its owner) the pill falls back to its own fill.
            glide.shown = false
            compare(glide.active, false)
            compare(Qt.colorEqual(fill.color, Theme.focusFill), true, "fallback fill")
            compare(fill.border.width > 0, true)
        }

        function test_nav_highlight_leaves_with_focus() {
            const f = makeNav()
            const glide = findChild(f.nav, "navGlide")
            tryVerify(() => glide.active)
            f.other.forceActiveFocus()
            tryCompare(f.nav, "activeFocus", false)
            compare(glide.active, false)
            tryCompare(glide, "visible", false)
            f.nav.forceActiveFocus()
            tryVerify(() => glide.active)
            compare(glide.x, glide.targetX, "comes back in place, not gliding in")
        }

        function test_nav_glides_over_several_steps() {
            const f = makeNav()
            const glide = findChild(f.nav, "navGlide")
            tryVerify(() => glide.active && glide.primed)
            tryVerify(() => !glide.gliding)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            compare(f.nav.currentKey, "settings")
            verify(glide.x < glide.targetX, "on its way, not there yet: " + glide.x + " vs " + glide.targetX)
            verify(glide.gliding)
            tryCompare(glide, "x", glide.targetX)
        }

        function test_nav_under_reduced_motion_snaps() {
            DeviceSettings.reducedMotion = true
            const f = makeNav()
            const glide = findChild(f.nav, "navGlide")
            tryVerify(() => glide.active)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(glide.x, glide.targetX)
            compare(glide.gliding, false)
        }

        // --- theme: the highlight follows the active theme ------------------------------------

        function test_highlight_colour_follows_the_theme() {
            const s = makeStrip()
            s.glide.target = s.a
            const body = findChild(s, "focusGlideBody")
            const was = DeviceSettings.theme
            for (const key of Themes.keys) {
                DeviceSettings.theme = key
                tryVerify(() => Qt.colorEqual(body.color, Theme.focusFill), 2000, "theme " + key)
            }
            DeviceSettings.theme = was
        }

        // --- liquid pill: gates and fallback ---------------------------------------------------

        function test_liquid_pill_is_gated_by_tier_and_switch() {
            DeviceSettings.effectsQuality = "high"
            const p = createTemporaryObject(pillComponent, host)
            verify(p)
            const loader = findChild(p, "liquidLoader")
            compare(p.liquidWanted, true, "High tier, switch on")
            compare(loader.active, true)
            DeviceSettings.effectsQuality = "balanced"
            compare(p.liquidWanted, false, "Balanced keeps the plain pill")
            compare(loader.active, false)
            DeviceSettings.effectsQuality = "performance"
            compare(p.liquidWanted, false)
            DeviceSettings.effectsQuality = "high"
            Theme.liquidPill = false
            compare(p.liquidWanted, false, "the one switch turns it off on High")
            compare(loader.active, false)
            Theme.liquidPill = true
            compare(p.liquidWanted, true)
        }

        function test_liquid_pill_falls_back_to_the_plain_pill() {
            DeviceSettings.effectsQuality = "high"
            const p = createTemporaryObject(pillComponent, host)
            const blur = findChild(p, "glassBlur")
            // The plain pill is drawn unless the shader compiled; the software renderer never
            // compiles it, a GPU does (the screenshots).
            compare(blur.visible, !p.liquid)
            // T-314: the blur is cut to the pill through SmoothMask (an antialiased edge, not steps).
            compare(blur.maskThresholdMin, 0.5, "the 50 % point of the mask is the outline")
            compare(blur.maskSpreadAtMin, 1, "a one-pixel ramp")
            compare(blur.maskSource.layer.smooth, true, "the mask's layer is filtered")
            DeviceSettings.effectsQuality = "balanced"
            compare(p.liquid, false)
            compare(blur.visible, true, "Balanced: plain blurred pill")
            DeviceSettings.effectsQuality = "performance"
            compare(blur.visible, false, "Performance: opaque pill, as before")
            verify(findChild(p, "glassFill").visible)
        }

        function test_liquid_shader_is_built_into_the_module() {
            // qsb through the shell's CMake: the compiled shader is a resource of the module.
            const xhr = new XMLHttpRequest()
            xhr.open("GET", Qt.resolvedUrl("qrc:/qt/qml/RuyaShell/qml/shaders/liquid.frag.qsb"), false)
            let ok = true
            try {
                xhr.send()
            } catch (e) {
                ok = false
            }
            verify(ok, "liquid.frag.qsb is a resource of the RuyaShell module")
            verify(xhr.responseText.length > 100, "and is not empty: " + xhr.responseText.length)
        }

        // --- the specular clock's idle gate (LiquidGate) --------------------------------------

        function test_liquid_clock_runs_only_when_something_may_be_watching() {
            const g = createTemporaryObject(liquidComponent, host, { width: 200, height: 80 })
            compare(LiquidGate.running, true)
            compare(g.clockWanted, true, "motion on, no app, screen shown, recent input")
            LiquidGate.appOpen = true
            compare(g.clockWanted, false, "an app in front")
            LiquidGate.appOpen = false
            compare(g.clockWanted, true)
            LiquidGate.screenShown = false
            compare(g.clockWanted, false, "screen not shown")
            LiquidGate.screenShown = true
            DeviceSettings.reducedMotion = true
            compare(g.clockWanted, false, "reduced motion stands the specular still")
        }

        function test_liquid_clock_pauses_after_idle_and_resumes_on_input() {
            LiquidGate.idleMs = 150
            const g = createTemporaryObject(liquidComponent, host, { width: 200, height: 80 })
            compare(LiquidGate.idle, false)
            tryCompare(LiquidGate, "idle", true, 2000, "no input for the idle period")
            compare(g.clockWanted, false)
            LiquidGate.noteInput()
            compare(LiquidGate.idle, false, "the next input resumes it")
            compare(g.clockWanted, true)
            tryCompare(LiquidGate, "idle", true, 2000, "and the idle period starts over")
        }

        function test_idle_period_does_not_run_while_an_app_is_open() {
            LiquidGate.idleMs = 100
            LiquidGate.appOpen = true
            wait(400)
            compare(LiquidGate.idle, false, "nothing to pause while paused already")
            LiquidGate.appOpen = false
            tryCompare(LiquidGate, "idle", true, 2000, "the period counts from when the app closes")
        }

        function test_liquid_tokens() {
            compare(Theme.liquidPeriods.length, 3)
            compare(Theme.liquidPeriods[0], 9)
            compare(Theme.liquidPeriods[1], 15)
            compare(Theme.liquidPeriods[2], 23)
            compare(Theme.liquidCycleMs, 1035 * 1000, "lcm of the three periods")
            compare(Theme.liquidBendMax, 30)
            compare(Theme.liquidBendFactor, 0.5)
        }

        function test_glide_tokens() {
            compare(Theme.glideMs, 280)
            DeviceSettings.reducedMotion = true
            compare(Theme.glideMs, 0)
        }

        // --- screenshots (shots only) ----------------------------------------------------------

        function focusStageNav() {
            stage.visible = true
            stageNav.currentIndex = 1                    // Games; the section on screen is Home
            stageNav.forceActiveFocus()
            tryVerify(() => stageNav.activeFocus)
            const glide = findChild(stageNav, "navGlide")
            tryVerify(() => glide.active && glide.primed)
            tryVerify(() => !glide.gliding)
            return glide
        }

        function test_zz_screenshots_glide() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            const glide = focusStageNav()
            keyClick(Qt.Key_Right)
            tryVerify(() => glide.gliding && glide.x > glide.targetX - glide.targetWidth * 0.7, 2000)
            grabImage(stage).save(shotsDir + "/glide-nav-mid.png")
            tryVerify(() => !glide.gliding, 2000)
            wait(200)
            grabImage(stage).save(shotsDir + "/glide-nav-rest.png")
            // A fast run across the whole nav: the highlight is a stroke.
            stageNav.currentIndex = 1
            tryVerify(() => !glide.gliding, 2000)
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            tryVerify(() => glide.stretch > 0.08, 2000)
            grabImage(stage).save(shotsDir + "/glide-nav-stretch.png")
            tryVerify(() => !glide.gliding, 2000)
        }

        function test_zz_screenshots_liquid() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            focusStageNav()
            keyClick(Qt.Key_Right)
            wait(600)
            DeviceSettings.effectsQuality = "high"
            Theme.liquidPill = true
            wait(500)
            const pill = findChild(stageNav, "sectionNavGlass")
            verify(pill.liquidWanted)
            verify(pill.liquid, "the liquid shader is drawing on this GPU")
            // The clock really runs, holds its phase when paused and picks it up again.
            const anim = findChild(stageNav, "liquidClock")
            tryVerify(() => anim.running, 2000, "the specular clock runs")
            const liquidItem = findChild(stageNav, "liquidGlass")
            tryVerify(() => liquidItem.clock > 0)
            LiquidGate.appOpen = true
            tryVerify(() => !anim.running)
            const held = liquidItem.clock
            wait(300)
            compare(liquidItem.clock, held, "paused: the phase holds")
            LiquidGate.appOpen = false
            tryVerify(() => anim.running && liquidItem.clock > held, 2000, "and moves on from there")
            const broken = createTemporaryObject(liquidComponent, stage, { shader: "shaders/missing.frag.qsb", width: 200, height: 80 })
            tryCompare(broken, "compiled", false, 3000, "a shader that is not there falls back")
            broken.destroy()
            grabImage(stage).save(shotsDir + "/liquid-pill-high.png")
            wait(7000)                                   // the specular has moved
            grabImage(stage).save(shotsDir + "/liquid-pill-high-later.png")
            Theme.liquidPill = false
            wait(300)
            grabImage(stage).save(shotsDir + "/liquid-pill-high-switch-off.png")
            Theme.liquidPill = true
            DeviceSettings.effectsQuality = "balanced"
            wait(300)
            verify(!pill.liquid)
            grabImage(stage).save(shotsDir + "/liquid-pill-balanced.png")
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.theme = "daylight"
            wait(500)
            grabImage(stage).save(shotsDir + "/liquid-pill-daylight.png")
            DeviceSettings.theme = "dreamglass"
        }
    }
}
