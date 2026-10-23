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
    readonly property color errorText: "#ff8a80"
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

    readonly property real safeArea: DeviceSettings.overscan   // fraction of width/height
    readonly property real focusScale: 1.08

    readonly property bool reducedMotion: DeviceSettings.reducedMotion
    readonly property int focusMs: reducedMotion ? 0 : 140
    readonly property int pageMs: reducedMotion ? 0 : 300
    readonly property int tintMs: reducedMotion ? 0 : 700

    // Feedback animations. Under reduced motion the PIN-pad shake and the tile pulse do not run
    // at all (their call sites check `reducedMotion`); the error text/sound or the page change
    // that follows is the feedback.
    readonly property real shakeDistance: 18     // design px
    readonly property int shakeQuickMs: reducedMotion ? 0 : 45
    readonly property int shakeSlowMs: reducedMotion ? 0 : 90
    readonly property real pulseScale: 0.94
    readonly property int pulseDownMs: reducedMotion ? 0 : 70
    readonly property int pulseUpMs: reducedMotion ? 0 : 180

    readonly property int toastMs: 4000      // how long a toast stays on screen
    readonly property int caretMs: 530       // text caret blink half-period
    readonly property int osdMs: 1500        // how long the volume OSD stays after the last change
    readonly property int guideHoldMs: 2000  // holding Guide this long opens the power menu (spec 01 §2.2)

    readonly property color toastInfo: "#6ea8ff"
    readonly property color toastSuccess: "#4cc38a"
    readonly property color toastWarning: "#ffb74d"
    readonly property color toastError: "#ff6b6b"
    readonly property color toastBackground: "#f0161a24"

    readonly property real pageSlide: reducedMotion ? 0 : 60   // design px the shelf/page slide during a page transition

    // Effects tier: high 64, balanced 32, performance 0 (no blur at all).
    readonly property real blurMax: DeviceSettings.effectsQuality === "high" ? 64
                                  : DeviceSettings.effectsQuality === "balanced" ? 32 : 0
    // Ambient movement (backdrop drift) runs only with full motion on a non-performance tier.
    readonly property bool ambientMotion: !reducedMotion && DeviceSettings.effectsQuality !== "performance"
}
