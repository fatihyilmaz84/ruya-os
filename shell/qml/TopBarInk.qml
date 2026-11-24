import QtQuick
import RuyaShell

// The ink of one item of the top bar (RUY-1136, 04 §5.5): the nav and the tray have no shade under them, so each item's
// glyphs and text take light ink (`Theme.inkLight`) or dark ink (`Theme.inkDark`) from the light behind that item:
// `band`, the top band of the picture behind the bar under the item's own x range (`under`, measured by `light`,
// Shell's barLight: ArtPalette.bandOf), held against the light seen through the nav's glass when `onGlass`
// (ThemeMath.bandThroughGlass; without blur the glass is `glassOpaque`, a known ground). ThemeMath.trayInk decides,
// its hysteresis fed by the ink this item chose last. While the band is not known, or the theme's own ground lies there
// (the Backdrop of a page), it is the theme's `text`. Busy art under the item (neither ink reads at 4.5:1) turns its
// glyph halo on: `haloColor`, the other ink at `trayHaloAlpha`, drawn by the item's own text layer (GlyphHalo, hugging
// each glyph, never a box). The ink cross-fades over `tintMs` (the hero's own cross-fade), at once under reduced
// motion. Not drawn itself.
Item {
    id: ink

    // What lies behind the bar (Shell's barLight: `frame`, the item the art fills, and `bandAt(from, to)`).
    property TopBarLight light: null
    // The item (or group of items) whose ink this is: its x range in `light.frame` picks the art behind it.
    property Item under: null
    // The item lies on the nav's glass pill: the light as seen through `glassStrong`.
    property bool onGlass: false
    // The item shows its warning ink now (a low battery's number): the warning pair must read at 3:1 too, else the
    // halo goes on (ThemeMath.trayInk's `warning`).
    property bool warning: false

    // The item's x range as fractions of the frame's width ({ from, to }), or null. Summing the x of every item up to
    // the frame makes the binding follow each of them (a Row moving its children, the tray growing to the left).
    readonly property var span: {
        if (!light || !under || !light.frame || light.frame.width <= 0)
            return null
        let x = 0
        for (let i = under; i !== light.frame; i = i.parent) {
            if (!i)
                return null          // not under the frame (yet)
            x += i.x
        }
        return { from: x / light.frame.width, to: (x + under.width) / light.frame.width }
    }
    // The light behind the item ({ high, low } relative luminances), or null for the theme's own `text`.
    readonly property var band: {
        if (!span)
            return null
        const b = light.bandAt(span.from, span.to)
        if (!b || !onGlass)
            return b
        return Theme.blurMax > 0 ? ThemeMath.bandThroughGlass(b, Theme.glassStrong) : null
    }
    // ThemeMath.trayInk's answer for the band ({ ink, busy, light, dark }), or null with no band. Set when the band
    // changes, from the ink chosen last (the hysteresis), so it is state, not a binding on itself.
    property var pick: null
    function update() {
        pick = band ? ThemeMath.trayInk(band, pick ? pick.ink : "", Theme, warning) : null
    }
    onBandChanged: update()
    onWarningChanged: update()
    Component.onCompleted: update()

    // The ink the text heads for, and its warning pair (a low battery's number).
    readonly property color target: !pick ? Theme.text : pick.ink === "light" ? Theme.inkLight : Theme.inkDark
    readonly property color warningTarget: !pick ? Theme.warningText : pick.ink === "light" ? Theme.inkLightWarning : Theme.inkDarkWarning
    // The ink as drawn right now (moving towards `target`).
    property color color: target
    property color warningColor: warningTarget
    Behavior on color { ColorAnimation { duration: Theme.tintMs; easing.type: Easing.InOutQuad } }   // tintMs is 0 under reduced motion: a jump
    Behavior on warningColor { ColorAnimation { duration: Theme.tintMs; easing.type: Easing.InOutQuad } }

    // The glyph halo: on over busy art under this item only, in the other ink.
    readonly property bool halo: pick !== null && pick.busy
    readonly property color haloColor: Qt.alpha(pick && pick.ink === "dark" ? Theme.inkLight : Theme.inkDark, Theme.trayHaloAlpha)

    visible: false
}
