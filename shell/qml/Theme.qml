pragma Singleton
import QtQuick
import RuyaShell

// Design tokens. Components take sizes in 1080p "design pixels" multiplied by the
// window's unit (height / 1080), so the layout scales to 720p, 1080p and 4K alike.
// Motion and effect tokens follow the per-device settings (reduced motion, quality tier).
QtObject {
    readonly property color background: "#05070d"
    readonly property color text: "#f2f4f8"
    readonly property color textDim: "#a3abbd"
    readonly property color glass: "#1fffffff"
    readonly property color glassOpaque: "#e6182033"   // shelf panel when there is no blur behind it
    readonly property color glassBorder: "#33ffffff"
    readonly property color glassStrong: "#1fffffff"    // top bar and quick menu: white 12 %, blurred with a saturation boost
    readonly property color focusRing: "#ffffff"

    // Fills and overlays. White at a given alpha marks focus, selection and key caps.
    readonly property color focusFill: Qt.rgba(1, 1, 1, 0.2)        // focused row, pill, action
    readonly property color selectedFill: Qt.rgba(1, 1, 1, 0.1)     // selected but not focused
    readonly property color keyFocusFill: Qt.rgba(1, 1, 1, 0.22)    // focused PIN-pad key
    readonly property color entryKeyFocusFill: Qt.rgba(1, 1, 1, 0.24)   // focused on-screen-keyboard key
    readonly property color entryKeyActiveFill: Qt.rgba(1, 1, 1, 0.3)   // latched key (Shift, symbols)
    readonly property color scrim: "#d0000000"                      // behind PIN pad and keyboard
    readonly property color scrimOverlay: "#d8000000"               // behind the Guide overlay
    readonly property color panel: "#1a1d26"                        // card of the Guide overlay
    readonly property color dangerFill: "#8f2d2d"                   // confirm button of restart / power off
    readonly property color primaryFill: "#f2f4f8"                  // the one main verb per screen (Play, Open Store)
    readonly property color onPrimary: "#05070d"                    // text on primaryFill
    readonly property color heroScrim: "#bf05070d"                  // left legibility scrim over hero art (75 %, fades to 0 over 75 % of the width)
    readonly property color artCaptionFade: "#d905070d"             // caption fade at the bottom of an art card (85 % to 0)
    readonly property color errorText: "#ff8a80"
    readonly property real disabledOpacity: 0.4                     // unavailable controls (PIN-pad OK, locked pad)
    readonly property real peekOpacity: 0.5                         // scroll cue: the first / last visible row while more rows exist beyond it (not disabledOpacity, which means unavailable)
    readonly property color warningText: "#ffb74d"
    readonly property color blobHighlight: "#ffffff"                // faint third backdrop blob

    // Accent colours: the backdrop default (also the fallback avatar colour) and the home tiles.
    readonly property color defaultTint: "#3a5bd9"
    function tileAccent(key) {
        switch (key) {
        case "games": return "#3a5bd9"
        case "media": return "#d9483a"
        case "store": return "#2fa37a"
        case "settings": return "#7a5bd9"
        default: return "#5a6478"      // power
        }
    }

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

    readonly property color toastInfo: "#6ea8ff"
    readonly property color toastSuccess: "#4cc38a"
    readonly property color toastWarning: "#ffb74d"
    readonly property color toastError: "#ff6b6b"
    readonly property color toastBackground: "#f0161a24"

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

    readonly property color glassSheen: Qt.rgba(1, 1, 1, 0.06)       // top of a panel, fades to 0 over glassSheenSpan
    readonly property color glassSheenEnd: Qt.rgba(1, 1, 1, 0)      // the clear end of white gradients (plain "transparent" would fade through black)
    readonly property real glassSheenSpan: 0.35
    readonly property color glassRim: Qt.rgba(1, 1, 1, 0.15)         // 1 px ring (replaces the flat glassBorder on glass)
    readonly property color glassRimLit: Qt.rgba(1, 1, 1, 0.30)      // on the top-left half (light from 135 deg)
    readonly property color glassTint: Qt.rgba(0x12 / 255, 0x10 / 255, 0x18 / 255, 0.44)   // #121018 at 44 %: sheets and modals over bright art
    readonly property real glassGrainOpacity: 1.0                    // the tile carries white 2 % / black 2.4 % noise in its alpha; this scales it

    readonly property color shadowColor: Qt.rgba(0, 0, 0, 1)         // colour of every shadow (alpha is in the shadow tokens)

    // Shadows: offset and blur in design px (multiply by u), alpha of black. The pill's offset and
    // blur follow its height: offset 0.18 h, blur min(0.6 h, 40).
    readonly property var shadowLift: ({ offsetY: 14, blur: 34, alpha: 0.60 })    // focused card
    readonly property var shadowPanel: ({ offsetY: 10, blur: 30, alpha: 0.35 })   // glass panels, modals, toasts
    readonly property var shadowPill: ({ offsetFactor: 0.18, blurFactor: 0.6, blurMax: 40, alpha: 0.27 })   // top bar, pills

    // Card focus: a white top sheen (all tiers) and a one-time glare sweep (04 §3.8).
    readonly property color cardSheen: Qt.rgba(1, 1, 1, 0.09)
    readonly property real cardSheenSpan: 1 / 3
    readonly property int glareMs: Math.round(550 * motionScale)
    readonly property color glarePeak: Qt.rgba(1, 1, 1, 0.6)      // centre of the glare band
    readonly property int glareGapMs: 300       // focus entering a card within this time of the last entry plays no glare
    // Shimmer of an art placeholder: a gleam of this alpha at this speed (design px per second).
    readonly property color shimmerPeak: Qt.rgba(1, 1, 1, 0.085)   // centre of the gleam
    readonly property real shimmerSpeed: 760

    // Wallpaper (04 §3.5, T-208): the least dim over a wallpaper that is shown without the blur (the
    // Performance tier, on a page). With the blur the picture is soft and the owner's dim is enough.
    readonly property real wallpaperDimUnblurred: 0.35
}
