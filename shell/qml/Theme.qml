pragma Singleton
import QtQuick

// Design tokens. Components take sizes in 1080p "design pixels" multiplied by the
// window's unit (height / 1080), so the layout scales to 720p, 1080p and 4K alike.
QtObject {
    readonly property color background: "#05070d"
    readonly property color text: "#f2f4f8"
    readonly property color textDim: "#a3abbd"
    readonly property color glass: "#1fffffff"
    readonly property color glassBorder: "#33ffffff"
    readonly property color focusRing: "#ffffff"

    readonly property real safeArea: 0.05      // overscan-safe margin, fraction of width/height
    readonly property real focusScale: 1.08

    readonly property int focusMs: 140
    readonly property int pageMs: 300
    readonly property int tintMs: 700

    readonly property real pageSlide: 60       // design px the shelf/page slide during a page transition

    readonly property real blurMax: 64
}
