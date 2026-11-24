import QtQuick
import QtQuick.Effects
import RuyaShell

// The glyph halo of the top bar's text (RUY-1136, 04 §5.5; the owner, 2026-11-23: "letter shadow"): a soft shadow
// hugging each glyph of a text layer, in the other ink at `trayHaloAlpha`, blur radius `spaceXs`, no offset. Only over
// busy art, where neither ink reads at 4.5:1 (TopBarInk.halo). Used as the `layer.effect` of each top-bar item whose
// own art is busy (a nav pill, the battery chips, the profile, the clock), switched on with `layer.enabled`, so it is
// never a box, band or pill and costs nothing while it is off. It draws on every tier: the halo is legibility, not decoration.
MultiEffect {
    property real u: 1
    // The halo's colour with its alpha (TopBarInk.haloColor).
    property color haloColor: "transparent"

    shadowEnabled: true
    shadowColor: Qt.alpha(haloColor, 1)
    shadowOpacity: haloColor.a
    shadowBlur: 1.0
    blurMax: Math.max(1, Math.round(Theme.spaceXs * u))
    shadowHorizontalOffset: 0
    shadowVerticalOffset: 0
    autoPaddingEnabled: true
}
