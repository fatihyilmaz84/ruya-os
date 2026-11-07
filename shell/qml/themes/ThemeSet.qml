import QtQuick

// One colour theme (04 §3.1, T-209): every token that may change with the theme. All are
// `required`, so a theme that forgets one does not compile. `Theme.qml` exposes the same names,
// driven by the current set; `Themes.tokenNames` lists them (scripts/lint-tokens.ps1 checks that
// the list and this file agree). Not themeable and so not here: sizes, type, motion, the focus
// ring width, and the white art effects (card sheen, glare, shimmer).
QtObject {
    required property string key         // stored in DeviceSettings.theme
    required property string label       // shown in Settings (translated by the caller)

    // 0 for a dark theme, 1 for a light one: switches Backdrop's gradient and a few art values.
    required property real lightness

    required property color background
    required property color text
    required property color textDim
    required property color glass
    required property color glassStrong
    required property color glassOpaque
    required property color glassBorder
    required property color focusRing
    required property color focusFill
    required property color selectedFill
    required property color keyFocusFill
    required property color entryKeyFocusFill
    required property color entryKeyActiveFill
    required property color scrim
    required property color scrimOverlay
    required property color panel
    required property color dangerFill
    required property color primaryFill
    required property color onPrimary
    required property color heroScrim
    required property color artCaptionFade
    required property color errorText
    required property color warningText
    required property color blobHighlight
    required property color defaultTint
    required property color tileGames
    required property color tileMedia
    required property color tileStore
    required property color tileSettings
    required property color tileOther
    required property color toastInfo
    required property color toastSuccess
    required property color toastWarning
    required property color toastError
    required property color toastBackground
    required property color glassSheen
    required property color glassRim
    required property color glassRimLit
    required property color glassTint
    required property color glassSpecular
    required property color shadowColor

    // Strength of the three Backdrop blobs (1 = as designed), of the shadow alphas, and the
    // lightness of the art placeholder gradient (top, bottom).
    required property real blobStrength
    required property real shadowStrength
    required property real artLightTop
    required property real artLightBottom
}
