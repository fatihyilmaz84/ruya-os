import QtQuick
import RuyaShell

// The ink of the top bar's text (RUY-1136, 04 §5.5): the nav and the tray have no shade under them, so their glyphs
// and text take light ink (`Theme.inkLight`) or dark ink (`Theme.inkDark`) from the light behind them (`band`, what
// ArtPalette.bandOf measures; ThemeMath.trayInk decides, its hysteresis fed by the ink chosen last). While the band is
// not known, or the theme's own ground lies there (the Backdrop of a page), it is the theme's `text`. Busy art (neither
// ink reads at 4.5:1) turns the glyph halo on: `haloColor`, the other ink at `trayHaloAlpha`, drawn by the text layer
// that uses it (GlyphHalo, hugging each glyph, never a box). The ink cross-fades over `tintMs` (the hero's own
// cross-fade), at once under reduced motion. Not drawn itself.
Item {
    id: ink

    // The light behind the text ({ high, low } relative luminances), or null for the theme's own `text`.
    property var band: null
    // ThemeMath.trayInk's answer for the band ({ ink, busy, light, dark }), or null with no band. Set when the band
    // changes, from the ink chosen last (the hysteresis), so it is state, not a binding on itself.
    property var pick: null
    function update() {
        pick = band ? ThemeMath.trayInk(band, pick ? pick.ink : "", Theme) : null
    }
    onBandChanged: update()
    Component.onCompleted: update()

    // The ink the text heads for, and its warning pair (a low battery's number).
    readonly property color target: !pick ? Theme.text : pick.ink === "light" ? Theme.inkLight : Theme.inkDark
    readonly property color warningTarget: !pick ? Theme.warningText : pick.ink === "light" ? Theme.inkLightWarning : Theme.inkDarkWarning
    // The ink as drawn right now (moving towards `target`).
    property color color: target
    property color warningColor: warningTarget
    Behavior on color { ColorAnimation { duration: Theme.tintMs; easing.type: Easing.InOutQuad } }   // tintMs is 0 under reduced motion: a jump
    Behavior on warningColor { ColorAnimation { duration: Theme.tintMs; easing.type: Easing.InOutQuad } }

    // The glyph halo: on over busy art only, in the other ink.
    readonly property bool halo: pick !== null && pick.busy
    readonly property color haloColor: Qt.alpha(pick && pick.ink === "dark" ? Theme.inkLight : Theme.inkDark, Theme.trayHaloAlpha)

    visible: false
}
