pragma Singleton
import QtQuick

// The built-in colour themes (04 §3.1, T-209). Dreamglass is the default and is the palette the
// shell shipped with before themes existed. Colours are the only thing a theme changes; sizes,
// type, motion and the focus ring width are the same in all of them.
//
// A light theme (Daylight) turns the rules around: dark text on frosted white glass, white
// washes instead of night scrims, a dark focus ring, darker status colours. The contrast gate
// (tests/tst_theme_contrast.qml) holds every theme to 04 §7.
QtObject {
    readonly property string defaultKey: "dreamglass"

    // Names of every themeable token, in ThemeSet.qml order (checked by scripts/lint-tokens.ps1).
    readonly property var tokenNames: [
        "lightness",
        "background", "text", "textDim", "glass", "glassStrong", "glassOpaque", "glassBorder",
        "focusRing", "focusFill", "selectedFill", "keyFocusFill", "entryKeyFocusFill", "entryKeyActiveFill",
        "scrim", "scrimOverlay", "panel", "dangerFill", "primaryFill", "onPrimary",
        "heroScrim", "artCaptionFade", "errorText", "warningText", "blobHighlight",
        "defaultTint", "tileGames", "tileMedia", "tileStore", "tileSettings", "tileOther",
        "toastInfo", "toastSuccess", "toastWarning", "toastError", "toastBackground",
        "glassSheen", "glassRim", "glassRimLit", "glassTint", "shadowColor",
        "blobStrength", "shadowStrength", "artLightTop", "artLightBottom"
    ]

    // Every set, in the order the Settings row cycles through them.
    readonly property var all: [dreamglass, midnight, aurora, ember, daylight]
    readonly property var keys: all.map(s => s.key)

    function byKey(key) {
        for (let i = 0; i < all.length; ++i) {
            if (all[i].key === key)
                return all[i]
        }
        return dreamglass
    }

    // The values of a set as a plain object (for tests and for the cross-fade).
    function snapshot(set) {
        const o = {}
        for (let i = 0; i < tokenNames.length; ++i)
            o[tokenNames[i]] = set[tokenNames[i]]
        return o
    }

    // Night blue glass, the original look.
    property ThemeSet dreamglass: ThemeSet {
        key: "dreamglass"
        label: qsTr("Dreamglass")
        lightness: 0
        background: "#05070d"
        text: "#f2f4f8"
        textDim: "#a3abbd"
        glass: "#1fffffff"
        glassStrong: "#1fffffff"
        glassOpaque: "#e6182033"
        glassBorder: "#33ffffff"
        focusRing: "#ffffff"
        focusFill: Qt.rgba(1, 1, 1, 0.2)
        selectedFill: Qt.rgba(1, 1, 1, 0.1)
        keyFocusFill: Qt.rgba(1, 1, 1, 0.22)
        entryKeyFocusFill: Qt.rgba(1, 1, 1, 0.24)
        entryKeyActiveFill: Qt.rgba(1, 1, 1, 0.3)
        scrim: "#d0000000"
        scrimOverlay: "#d8000000"
        panel: "#1a1d26"
        dangerFill: "#8f2d2d"
        primaryFill: "#f2f4f8"
        onPrimary: "#05070d"
        heroScrim: "#bf05070d"
        artCaptionFade: "#d905070d"
        errorText: "#ff8a80"
        warningText: "#ffb74d"
        blobHighlight: "#ffffff"
        defaultTint: "#3a5bd9"
        tileGames: "#3a5bd9"
        tileMedia: "#d9483a"
        tileStore: "#2fa37a"
        tileSettings: "#7a5bd9"
        tileOther: "#5a6478"
        toastInfo: "#6ea8ff"
        toastSuccess: "#4cc38a"
        toastWarning: "#ffb74d"
        toastError: "#ff6b6b"
        toastBackground: "#f0161a24"
        glassSheen: Qt.rgba(1, 1, 1, 0.06)
        glassRim: Qt.rgba(1, 1, 1, 0.15)
        glassRimLit: Qt.rgba(1, 1, 1, 0.30)
        glassTint: Qt.rgba(0x12 / 255, 0x10 / 255, 0x18 / 255, 0.44)
        shadowColor: Qt.rgba(0, 0, 0, 1)
        blobStrength: 1
        shadowStrength: 1
        artLightTop: 0.42
        artLightBottom: 0.18
    }

    // True black for OLED panels, neutral grey glass, quiet blobs.
    property ThemeSet midnight: ThemeSet {
        key: "midnight"
        label: qsTr("Midnight")
        lightness: 0
        background: "#000000"
        text: "#f5f5f5"
        textDim: "#a9a9a9"
        glass: "#1affffff"
        glassStrong: "#1affffff"
        glassOpaque: "#e6121212"
        glassBorder: "#2effffff"
        focusRing: "#ffffff"
        focusFill: Qt.rgba(1, 1, 1, 0.2)
        selectedFill: Qt.rgba(1, 1, 1, 0.1)
        keyFocusFill: Qt.rgba(1, 1, 1, 0.22)
        entryKeyFocusFill: Qt.rgba(1, 1, 1, 0.24)
        entryKeyActiveFill: Qt.rgba(1, 1, 1, 0.3)
        scrim: "#d9000000"
        scrimOverlay: "#e0000000"
        panel: "#111111"
        dangerFill: "#8f2d2d"
        primaryFill: "#f5f5f5"
        onPrimary: "#000000"
        heroScrim: "#bf000000"
        artCaptionFade: "#d9000000"
        errorText: "#ff8a80"
        warningText: "#ffb74d"
        blobHighlight: "#ffffff"
        defaultTint: "#56627a"
        tileGames: "#56627a"
        tileMedia: "#7a5656"
        tileStore: "#4f7a68"
        tileSettings: "#66587a"
        tileOther: "#5c5c5c"
        toastInfo: "#6ea8ff"
        toastSuccess: "#4cc38a"
        toastWarning: "#ffb74d"
        toastError: "#ff6b6b"
        toastBackground: "#f00c0c0c"
        glassSheen: Qt.rgba(1, 1, 1, 0.05)
        glassRim: Qt.rgba(1, 1, 1, 0.14)
        glassRimLit: Qt.rgba(1, 1, 1, 0.28)
        glassTint: Qt.rgba(0, 0, 0, 0.5)
        shadowColor: Qt.rgba(0, 0, 0, 1)
        blobStrength: 0.45
        shadowStrength: 1
        artLightTop: 0.34
        artLightBottom: 0.12
    }

    // Deep teal ground with violet accents.
    property ThemeSet aurora: ThemeSet {
        key: "aurora"
        label: qsTr("Aurora")
        lightness: 0
        background: "#04121a"
        text: "#eaf6f4"
        textDim: "#9fbcc0"
        glass: "#1fcdfff2"
        glassStrong: "#1fcdfff2"
        glassOpaque: "#e60f2a32"
        glassBorder: "#33c8fff0"
        focusRing: "#ffffff"
        focusFill: Qt.rgba(1, 1, 1, 0.2)
        selectedFill: Qt.rgba(1, 1, 1, 0.1)
        keyFocusFill: Qt.rgba(1, 1, 1, 0.22)
        entryKeyFocusFill: Qt.rgba(1, 1, 1, 0.24)
        entryKeyActiveFill: Qt.rgba(1, 1, 1, 0.3)
        scrim: "#d0020a0e"
        scrimOverlay: "#d8020a0e"
        panel: "#112630"
        dangerFill: "#8f2d44"
        primaryFill: "#eaf6f4"
        onPrimary: "#04121a"
        heroScrim: "#bf04121a"
        artCaptionFade: "#d904121a"
        errorText: "#ff9a94"
        warningText: "#ffc266"
        blobHighlight: "#d6c4ff"
        defaultTint: "#2a9d8f"
        tileGames: "#2a9d8f"
        tileMedia: "#9a5fd9"
        tileStore: "#2fa37a"
        tileSettings: "#7a5bd9"
        tileOther: "#4f6f7a"
        toastInfo: "#7ab8ff"
        toastSuccess: "#4cc38a"
        toastWarning: "#ffc266"
        toastError: "#ff7a7a"
        toastBackground: "#f00d2229"
        glassSheen: Qt.rgba(1, 1, 1, 0.06)
        glassRim: Qt.rgba(0.8, 1, 0.95, 0.16)
        glassRimLit: Qt.rgba(0.85, 1, 0.97, 0.32)
        glassTint: Qt.rgba(0.02, 0.07, 0.1, 0.44)
        shadowColor: Qt.rgba(0, 0.03, 0.05, 1)
        blobStrength: 0.85
        shadowStrength: 1
        artLightTop: 0.40
        artLightBottom: 0.16
    }

    // Warm near-black with red and orange.
    property ThemeSet ember: ThemeSet {
        key: "ember"
        label: qsTr("Ember")
        lightness: 0
        background: "#0d0605"
        text: "#f8efe9"
        textDim: "#bda99c"
        glass: "#1fffe3c8"
        glassStrong: "#1fffe3c8"
        glassOpaque: "#e62b1713"
        glassBorder: "#33ffd9b8"
        focusRing: "#ffffff"
        focusFill: Qt.rgba(1, 1, 1, 0.2)
        selectedFill: Qt.rgba(1, 1, 1, 0.1)
        keyFocusFill: Qt.rgba(1, 1, 1, 0.22)
        entryKeyFocusFill: Qt.rgba(1, 1, 1, 0.24)
        entryKeyActiveFill: Qt.rgba(1, 1, 1, 0.3)
        scrim: "#d0100403"
        scrimOverlay: "#d8100403"
        panel: "#241411"
        dangerFill: "#9c2b2b"
        primaryFill: "#f8efe9"
        onPrimary: "#0d0605"
        heroScrim: "#bf0d0605"
        artCaptionFade: "#d90d0605"
        errorText: "#ff9a8c"
        warningText: "#ffc266"
        blobHighlight: "#ffd9b0"
        defaultTint: "#c2492c"
        tileGames: "#c2492c"
        tileMedia: "#d9483a"
        tileStore: "#c98a2c"
        tileSettings: "#a83a5a"
        tileOther: "#7a5a4f"
        toastInfo: "#7ab0ff"
        toastSuccess: "#5cc88f"
        toastWarning: "#ffc266"
        toastError: "#ff7a6b"
        toastBackground: "#f0241510"
        glassSheen: Qt.rgba(1, 0.95, 0.9, 0.06)
        glassRim: Qt.rgba(1, 0.85, 0.7, 0.16)
        glassRimLit: Qt.rgba(1, 0.9, 0.78, 0.32)
        glassTint: Qt.rgba(0.1, 0.04, 0.03, 0.44)
        shadowColor: Qt.rgba(0.05, 0, 0, 1)
        blobStrength: 0.85
        shadowStrength: 1
        artLightTop: 0.40
        artLightBottom: 0.15
    }

    // Light: dark text on frosted white glass over a pale backdrop.
    property ThemeSet daylight: ThemeSet {
        key: "daylight"
        label: qsTr("Daylight")
        lightness: 1
        background: "#eef1f7"
        text: "#0f1420"
        textDim: "#475066"
        glass: "#a6ffffff"
        glassStrong: "#b8ffffff"
        glassOpaque: "#f2f8f9fd"
        glassBorder: "#2e0f1420"
        focusRing: "#0f1420"
        focusFill: Qt.rgba(0x0f / 255, 0x14 / 255, 0x20 / 255, 0.12)
        selectedFill: Qt.rgba(0x0f / 255, 0x14 / 255, 0x20 / 255, 0.07)
        keyFocusFill: Qt.rgba(0x0f / 255, 0x14 / 255, 0x20 / 255, 0.14)
        entryKeyFocusFill: Qt.rgba(0x0f / 255, 0x14 / 255, 0x20 / 255, 0.16)
        entryKeyActiveFill: Qt.rgba(0x0f / 255, 0x14 / 255, 0x20 / 255, 0.2)
        scrim: "#d9f2f4f9"
        scrimOverlay: "#e0f2f4f9"
        panel: "#f8f9fc"
        dangerFill: "#ec9a91"
        primaryFill: "#0f1420"
        onPrimary: "#f5f7fb"
        heroScrim: "#bff2f4f9"
        artCaptionFade: "#d9f2f4f9"
        errorText: "#b3261e"
        warningText: "#7d4a00"
        blobHighlight: "#ffffff"
        defaultTint: "#8ea4f2"
        tileGames: "#8ea4f2"
        tileMedia: "#f29a8e"
        tileStore: "#7fd0b0"
        tileSettings: "#b39af2"
        tileOther: "#a5aec0"
        toastInfo: "#1d57c4"
        toastSuccess: "#136b42"
        toastWarning: "#7d4a00"
        toastError: "#b3261e"
        toastBackground: "#f0f9fafd"
        glassSheen: Qt.rgba(1, 1, 1, 0.5)
        glassRim: Qt.rgba(0x0f / 255, 0x14 / 255, 0x20 / 255, 0.14)
        glassRimLit: Qt.rgba(1, 1, 1, 0.95)
        glassTint: Qt.rgba(1, 1, 1, 0.55)
        shadowColor: Qt.rgba(0x0f / 255, 0x14 / 255, 0x20 / 255, 1)
        blobStrength: 0.45
        shadowStrength: 0.45
        artLightTop: 0.84
        artLightBottom: 0.72
    }
}
