import QtQuick
import RuyaShell

// The light behind the top bar (RUY-1136, 04 §5.5): the top band of the picture behind it as ArtPalette measures it
// (its bright and dark 2 %, `bandOf`) under an x range of the screen (`bandAt`, fractions of `frame`'s width: the
// hero and the wallpaper fill the frame), the wallpaper under its dim layer; null while it is not measured, for
// unreadable art and a placeholder, and on the theme's Backdrop (its ground is known: the theme's `text` reads there).
// Each item of the bar takes its ink from the part under it (TopBarInk). One instance, Shell's `barLight`. Not drawn.
Item {
    id: light

    // The item the picture behind the bar fills (the shell): the items' x ranges are measured in it.
    property Item frame: null
    // What lies behind the bar (Shell.trayBackground()): { kind: "art" | "wallpaper" | "unknown" | "backdrop", source,
    // aspect }.
    property var behind: ({ kind: "backdrop", source: "", aspect: 0 })
    // The wallpaper's dim layer (the theme's ground at the wallpaper's effective dim).
    property real wallpaperDim: 0

    property int measured: 0          // bumped when ArtPalette has measured the picture behind the bar

    // The band under `from`..`to` (fractions of the frame's width), or null (see above). Read in a binding, it follows
    // what lies behind and its measurement.
    function bandAt(from, to) {
        void measured
        if (behind.kind !== "art" && behind.kind !== "wallpaper")
            return null
        const b = ArtPalette.bandOf(behind.source, behind.aspect, from, to)
        if (b.ok !== true)
            return null
        return behind.kind === "wallpaper" ? ThemeMath.bandUnder(b, Theme.background, wallpaperDim) : b
    }

    Connections {
        target: ArtPalette
        function onSampled(source) {
            if (source === light.behind.source)
                ++light.measured
        }
    }

    visible: false
}
