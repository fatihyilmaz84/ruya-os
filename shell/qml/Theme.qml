pragma Singleton
import QtQuick
import RuyaShell

// Design tokens. Components take sizes in 1080p "design pixels" multiplied by the
// window's unit (height / 1080), so the layout scales to 720p, 1080p and 4K alike.
// Motion and effect tokens follow the per-device settings (reduced motion, quality tier).
QtObject {
    id: root

    // --- Theme switching (T-209) ---
    // `shownSet` is the ThemeSet the tokens are heading for. When it changes, `fromColors` keeps
    // what was on screen and `mix` runs 0 -> 1 over tintMs, so every token is a blend of the two
    // (a switch in mid-fade starts from the blended look: no jump). Under reduced motion tintMs
    // is 0 and the switch is immediate.
    property var shownSet: Themes.byKey(Themes.defaultKey)   // replaced by the stored theme in onCompleted
    property var fromColors: null
    property real mix: 1

    function tok(name) {
        const to = shownSet[name]
        if (mix >= 1 || fromColors === null)
            return to
        return ThemeMath.blend(fromColors[name], to, mix)
    }

    // Starts a switch to the set `key` (an unknown key means the default).
    function switchTo(key) {
        const next = Themes.byKey(key)
        if (next === shownSet)
            return
        fromColors = currentLook()
        shownSet = next
        fade.stop()
        if (tintMs <= 0) {
            mix = 1
            return
        }
        mix = 0
        fade.start()
    }
    // What is on screen right now (the target set, or the blend of the last two).
    function currentLook() {
        const o = {}
        for (let i = 0; i < Themes.tokenNames.length; ++i)
            o[Themes.tokenNames[i]] = tok(Themes.tokenNames[i])
        return o
    }

    property NumberAnimation fade: NumberAnimation {
        target: root
        property: "mix"
        from: 0
        to: 1
        duration: root.tintMs
        easing.type: Easing.InOutQuad
    }

    // Reduced motion switched on during a fade: finish it now.
    onTintMsChanged: {
        if (tintMs <= 0 && mix < 1) {
            fade.stop()
            mix = 1
        }
    }

    property Connections follow: Connections {
        target: DeviceSettings
        function onThemeChanged() { root.switchTo(DeviceSettings.theme) }
    }
    Component.onCompleted: {
        shownSet = Themes.byKey(DeviceSettings.theme)
    }

    // --- Colour (04 §3.1, T-209) ---
    // Every colour below comes from the current ThemeSet (qml/themes/Themes.qml) and cross-fades
    // over tintMs when DeviceSettings.theme changes (at once under reduced motion). The names are
    // the ones components always used, so no screen changes with the theme.
    readonly property string themeKey: shownSet.key
    readonly property bool lightTheme: lightness >= 0.5
    readonly property real lightness: tok("lightness")

    readonly property color background: tok("background")
    readonly property color text: tok("text")
    readonly property color textDim: tok("textDim")
    readonly property color glass: tok("glass")
    readonly property color glassOpaque: tok("glassOpaque")        // shelf panel when there is no blur behind it
    readonly property color glassBorder: tok("glassBorder")
    readonly property color glassStrong: tok("glassStrong")        // top bar and quick menu, blurred with a saturation boost
    readonly property color focusRing: tok("focusRing")            // white on the dark themes, dark on Daylight (04 §4)

    // Fills and overlays. A translucent mark of the ring colour marks focus, selection and key caps.
    readonly property color focusFill: tok("focusFill")            // focused row, pill, action
    readonly property color selectedFill: tok("selectedFill")      // selected but not focused
    readonly property color keyFocusFill: tok("keyFocusFill")      // focused PIN-pad key
    readonly property color entryKeyFocusFill: tok("entryKeyFocusFill")   // focused on-screen-keyboard key
    readonly property color entryKeyActiveFill: tok("entryKeyActiveFill") // latched key (Shift, symbols)
    readonly property color scrim: tok("scrim")                    // behind PIN pad and keyboard
    readonly property color scrimOverlay: tok("scrimOverlay")      // behind the Guide overlay
    readonly property color panel: tok("panel")                    // card of the Guide overlay
    readonly property color dangerFill: tok("dangerFill")          // confirm button of restart / power off
    readonly property color primaryFill: tok("primaryFill")        // the one main verb per screen (Play, Open Store)
    readonly property color onPrimary: tok("onPrimary")            // text on primaryFill
    readonly property color heroScrim: tok("heroScrim")            // left legibility scrim over hero art (75 %, fades to 0 over 75 % of the width)
    readonly property color artCaptionFade: tok("artCaptionFade")  // caption fade at the bottom of an art card (85 % to 0)
    // The clear ends of those two fades: the same colour at alpha 0 (plain "transparent" fades through black).
    readonly property color heroScrimClear: Qt.rgba(heroScrim.r, heroScrim.g, heroScrim.b, 0)
    readonly property color artCaptionFadeClear: Qt.rgba(artCaptionFade.r, artCaptionFade.g, artCaptionFade.b, 0)
    readonly property color errorText: tok("errorText")
    readonly property real disabledOpacity: 0.4                     // unavailable controls (PIN-pad OK, locked pad)
    readonly property real peekOpacity: 0.7                         // scroll cue: the first / last visible row while more rows exist beyond it (not disabledOpacity, which means unavailable)
    readonly property color warningText: tok("warningText")
    readonly property color blobHighlight: tok("blobHighlight")   // faint third backdrop blob

    // Accent colours: the backdrop default (also the fallback avatar colour) and the home tiles.
    readonly property color defaultTint: tok("defaultTint")
    function tileAccent(key) {
        switch (key) {
        case "games": return tok("tileGames")
        case "media": return tok("tileMedia")
        case "store": return tok("tileStore")
        case "settings": return tok("tileSettings")
        default: return tok("tileOther")      // power
        }
    }

    // Backdrop (Backdrop.qml): the top of its gradient for a tint, and the three blob opacities.
    // The blobs and the gradient top are built from the theme's own blob colours with the profile's
    // tint mixed in at `blobTintShare` (T-271): `blobTintA(tint)` for the first blob and the
    // gradient, `blobTintB(tint)` for the second (which Backdrop draws 1.4 times lighter).
    readonly property color blobA: tok("blobA")
    readonly property color blobB: tok("blobB")
    readonly property real blobTintShare: tok("blobTintShare")
    function blobTintA(tint) { return ThemeMath.blobTint(blobA, tint, blobTintShare) }
    function blobTintB(tint) { return ThemeMath.blobTint(blobB, tint, blobTintShare) }
    function backdropTop(tint) { return ThemeMath.backdropTop(tint, background, lightness) }
    readonly property real blobOpacityA: ThemeMath.blobOpacityA * tok("blobStrength")
    readonly property real blobOpacityB: ThemeMath.blobOpacityB * tok("blobStrength")
    readonly property real blobOpacityC: ThemeMath.blobOpacityC * tok("blobStrength")
    // The art placeholder gradient (AppArt) for a hue 0..1: top and bottom.
    function artTop(hue) { return ThemeMath.artColor(hue, 0.55, tok("artLightTop")) }
    function artBottom(hue) { return ThemeMath.artColor(hue, 0.6, tok("artLightBottom")) }

    // Type scale (04 §3.2): design px, multiplied by `u` at the call site.
    readonly property string fontFamily: "Inter"   // bundled (T-145); main.cpp and the test host make it the application font
    // Icons (04 §3.7, T-157): two static cuts of Material Symbols Rounded under their own family names.
    readonly property string iconFamily: "Material Symbols Rounded"
    readonly property string iconFamilyFilled: "Material Symbols Rounded Filled"
    readonly property real iconM: 40
    readonly property real iconL: 64
    readonly property real typeHero: 96
    readonly property real typeDisplay: 64
    readonly property real typeTitle: 48
    readonly property real typeHeadline: 34
    readonly property real typeBody: 30
    readonly property real typeCaption: 24
    readonly property real typeMicro: 20
    readonly property int weightLight: Font.Light
    readonly property int weightRegular: Font.Normal
    readonly property int weightDemiBold: Font.DemiBold
    readonly property int weightBold: Font.Bold

    // Spacing (8 px grid), shape and sizes (04 §3.3): design px, multiplied by `u` at the call site.
    readonly property real spaceXxs: 4
    readonly property real spaceXs: 8
    readonly property real spaceS: 16
    readonly property real spaceM: 24
    readonly property real spaceL: 36
    readonly property real spaceXl: 48
    readonly property real spaceXxl: 64
    readonly property real spaceXxxl: 96
    readonly property real radiusS: 12      // keys (badges are pills)
    readonly property real radiusM: 18      // tiles, art, toasts
    readonly property real radiusL: 32      // panels, dialogs (pills are height / 2)
    readonly property real rowHeight: 84
    readonly property real buttonHeight: 76
    readonly property real tileWidth: 400
    readonly property real tileHeight: 260
    readonly property real avatarSize: 200
    readonly property real glyphSize: 40    // controller button glyph (hint bar)
    readonly property real focusRingWidth: 4
    readonly property real focusRingOffset: 7
    readonly property real hairline: 1      // outline of unfocused glass and neutral badges
    function hairlineAt(u) { return Math.max(1, hairline * u) }   // never thinner than a pixel
    readonly property real badgeFillAlpha: 0.18   // badge fill = the kind's colour at this alpha
    function badgeFill(c) { return Qt.rgba(c.r, c.g, c.b, badgeFillAlpha) }

    readonly property real safeArea: DeviceSettings.overscan   // fraction of width/height
    // UI size (T-198, 04 §2): a factor on the 1080p unit (height / 1080). The owner's choice
    // (100, 125, 150, 200 %) or, on Auto, what the screen's physical size asks for: 1 on a TV read
    // from the sofa, less on a smaller, nearer monitor. Shell.u multiplies it in.
    readonly property real uiScale: Display.uiScaleFactor
    readonly property real focusScale: 1.08

    readonly property bool reducedMotion: DeviceSettings.reducedMotion
    // One global motion scale (04 §3.8): every duration token below is its base value times this.
    // `motionFactor` is the speed (1.0 as designed; the reference study ran at 0.83); reduced motion forces 0.
    property real motionFactor: 1.0
    readonly property real motionScale: reducedMotion ? 0 : motionFactor
    readonly property int focusMs: Math.round(140 * motionScale)
    readonly property int pageMs: Math.round(300 * motionScale)
    readonly property int tintMs: Math.round(700 * motionScale)
    readonly property int overlayMs: Math.round(200 * motionScale)   // Guide overlay fade

    // Gliding highlight (04 §3.8, T-205): one highlight glides between the rows of a single-row
    // selector in `glideMs` with `easeGlide` and stretches with speed.
    readonly property int glideMs: Math.round(280 * motionScale)
    readonly property real glideSpeedRef: 2600    // design px per second that stretches the highlight fully
    readonly property real glideSmoothing: 14     // per second: how fast the stretch follows the speed
    readonly property real glideStretchMax: 0.5   // extra length at full stretch, as a fraction of the highlight's length

    // Easing curves (04 §3.8) as Easing.Bezier arrays [c1x, c1y, c2x, c2y, 1, 1]. Use them as
    // `easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide`.
    readonly property var easeGlide: [0.25, 1, 0.5, 1, 1, 1]   // positions, lifts, the gliding highlight
    readonly property var easeSnap: [0.23, 1, 0.32, 1, 1, 1]   // pages and overlays
    readonly property real popOvershoot: 0.94                  // OutBack overshoot of pops (about 3 %)

    // Feedback animations. Under reduced motion the PIN-pad shake and the card pulse do not run
    // at all (their call sites check `reducedMotion`); the error text/sound or the page change
    // that follows is the feedback.
    readonly property real shakeDistance: 18     // design px
    readonly property int shakeQuickMs: Math.round(45 * motionScale)
    readonly property int shakeSlowMs: Math.round(90 * motionScale)
    readonly property real pulseScale: 0.94
    readonly property int pulseDownMs: Math.round(70 * motionScale)
    readonly property int pulseUpMs: Math.round(180 * motionScale)

    readonly property int toastMs: 4000      // how long a toast stays on screen
    readonly property int caretMs: 530       // text caret blink half-period
    readonly property int osdMs: 1500        // how long the volume OSD stays after the last change
    readonly property int guideHoldMs: 2000  // holding Guide this long opens the power menu (spec 01 §2.2)

    readonly property color toastInfo: tok("toastInfo")
    readonly property color toastSuccess: tok("toastSuccess")
    readonly property color toastWarning: tok("toastWarning")
    readonly property color toastError: tok("toastError")
    readonly property color toastBackground: tok("toastBackground")

    readonly property real pageSlide: 60 * motionScale   // design px the shelf/page slide during a page transition

    // Effects tier: high 64, balanced 32, performance 0 (no blur at all).
    readonly property real blurMax: DeviceSettings.effectsQuality === "high" ? 64
                                  : DeviceSettings.effectsQuality === "balanced" ? 32 : 0
    // Ambient movement (backdrop drift) runs only with full motion on a non-performance tier.
    readonly property bool ambientMotion: !reducedMotion && DeviceSettings.effectsQuality !== "performance"

    // Glass layers, shadows and card focus (04 §3.8). The tier switches follow `effectsQuality`.
    readonly property bool shadowsOn: DeviceSettings.effectsQuality !== "performance"   // shadows and grain: High and Balanced
    readonly property bool grainOn: DeviceSettings.effectsQuality !== "performance"
    readonly property bool glareOn: ambientMotion                                         // card glare and shimmer: motion on, not Performance
    readonly property bool shimmerOn: ambientMotion

    // Liquid pill (04 §3.8, T-205): the top-bar pills refract the blur behind them and carry a slow
    // specular. `liquidPill` is the one switch (the default is decided on the Dell, B-002); the
    // pill also needs the High tier and a shader that compiled (GlassPill falls back to the plain
    // pill otherwise).
    property bool liquidPill: true
    readonly property bool liquidOn: liquidPill && DeviceSettings.effectsQuality === "high"
    readonly property real liquidBendFactor: 0.5   // refraction depth at the edge, as a fraction of the pill height ...
    readonly property real liquidBendMax: 30       // ... at most this many design px
    readonly property int liquidIdleMs: 30000       // no input for this long: the specular clock pauses (LiquidGate)
    readonly property real liquidBrightnessLift: 0.08   // added to the pill's brightness while the liquid look is on (its lighter blur read darker and smokier)
    readonly property real liquidBlurFactor: 0.4   // the liquid pill blurs less (times blurMax), so there is detail to bend at the edge
    readonly property var liquidPeriods: [9, 15, 23]   // seconds of the three sines that move the specular
    readonly property int liquidCycleMs: 1035000       // their common period (lcm of 9, 15, 23 = 1035 s): the time uniform loops here

    readonly property color glassSheen: tok("glassSheen")       // top of a panel, fades to 0 over glassSheenSpan
    readonly property color glassSheenEnd: Qt.rgba(1, 1, 1, 0)      // the clear end of white gradients (plain "transparent" would fade through black)
    readonly property real glassSheenSpan: 0.35
    readonly property color glassRim: tok("glassRim")         // 1 px ring (replaces the flat glassBorder on glass)
    readonly property color glassRimLit: tok("glassRimLit")      // on the top-left half (light from 135 deg)
    readonly property color glassSpecular: tok("glassSpecular")   // peak colour of the liquid pill's moving specular (High tier, 04 §3.8)
    readonly property color glassTint: tok("glassTint")   // Dreamglass: #121018 at 44 %: sheets and modals over bright art. Never carries text (04 §3.6)
    readonly property real glassGrainOpacity: 1.0                    // the tile carries white 2 % / black 2.4 % noise in its alpha; this scales it

    readonly property color shadowColor: tok("shadowColor")         // colour of every shadow (alpha is in the shadow tokens)

    // Shadows: offset and blur in design px (multiply by u), alpha of black. The pill's offset and
    // blur follow its height: offset 0.18 h, blur min(0.6 h, 40).
    readonly property var shadowLift: ({ offsetY: 14, blur: 34, alpha: 0.60 * tok("shadowStrength") })    // focused card
    readonly property var shadowPanel: ({ offsetY: 10, blur: 30, alpha: 0.35 * tok("shadowStrength") })   // glass panels, modals, toasts
    readonly property var shadowPill: ({ offsetFactor: 0.18, blurFactor: 0.6, blurMax: 40, alpha: 0.27 * tok("shadowStrength") })   // top bar, pills

    // Card focus: a white top sheen (all tiers) and a one-time glare sweep (04 §3.8).
    readonly property color cardSheen: Qt.rgba(1, 1, 1, 0.09)
    readonly property real cardSheenSpan: 1 / 3
    readonly property int glareMs: Math.round(550 * motionScale)
    readonly property color glarePeak: Qt.rgba(1, 1, 1, 0.6)      // centre of the glare band
    readonly property int glareGapMs: 300       // focus entering a card within this time of the last entry plays no glare
    // The screen saver (T-202, 04 §5), not themeable: its ground is the same near black in every set,
    // so the OLED pixels are off on Daylight too. The clock is the only text (white at 70 %: 4.5:1 or
    // better on the ground and on pure-white art at the 30 % dim, asserted by tst_themes). The motion
    // tokens are 0 under reduced motion; the slide interval is a Timer's, not an animation's.
    readonly property color saverGround: Qt.rgba(0.02, 0.02, 0.03, 1)
    readonly property color saverText: Qt.rgba(1, 1, 1, 0.7)
    readonly property real saverArtOpacity: 0.3
    readonly property int saverFadeMs: Math.round(2800 * motionScale)     // art cross-fade
    readonly property int saverDriftMs: Math.round(28000 * motionScale)   // one pan, there and back
    readonly property int saverZoomMs: Math.round(56000 * motionScale)    // one slow zoom
    readonly property int saverSlideMs: 20000                             // the next picture
    // Shimmer of an art placeholder: a gleam of this alpha at this speed (design px per second).
    readonly property color shimmerPeak: Qt.rgba(1, 1, 1, 0.085)   // centre of the gleam
    readonly property real shimmerSpeed: 760

    // Wallpaper (04 §3.5, T-208): the least dim over a wallpaper that is shown without the blur (the
    // Performance tier, on a page). With the blur the picture is soft and the owner's dim is enough.
    readonly property real wallpaperDimUnblurred: 0.35
}
