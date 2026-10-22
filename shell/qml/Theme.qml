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

    readonly property real safeArea: DeviceSettings.overscan   // fraction of width/height
    readonly property real focusScale: 1.08

    readonly property bool reducedMotion: DeviceSettings.reducedMotion
    readonly property int focusMs: reducedMotion ? 0 : 140
    readonly property int pageMs: reducedMotion ? 0 : 300
    readonly property int tintMs: reducedMotion ? 0 : 700

    readonly property int toastMs: 4000      // how long a toast stays on screen
    readonly property int caretMs: 530       // text caret blink half-period
    readonly property int osdMs: 1500        // how long the volume OSD stays after the last change

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
