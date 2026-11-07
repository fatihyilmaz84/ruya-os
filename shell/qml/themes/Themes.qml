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
        "blobA", "blobB", "defaultTint", "tileGames", "tileMedia", "tileStore", "tileSettings", "tileOther",
        "toastInfo", "toastSuccess", "toastWarning", "toastError", "toastBackground",
        "glassSheen", "glassRim", "glassRimLit", "glassTint", "glassSpecular", "shadowColor",
        "blobStrength", "blobTintShare", "shadowStrength", "artLightTop", "artLightBottom"
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
        blobA: "#3a5bd9"           // not used: the profile's tint is the whole blob (blobTintShare 1)
        blobB: "#3a5bd9"
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
        glassSpecular: Qt.rgba(1, 1, 1, 0.22)
        shadowColor: Qt.rgba(0, 0, 0, 1)
        blobStrength: 1
        blobTintShare: 1
        shadowStrength: 1
        artLightTop: 0.42
        artLightBottom: 0.18
    }

    // OLED: true black ground, neutral grey glass with no hue, very faint neutral blobs (the
    // profile's tint barely shows), pure white focus and primary button. T-271.
    property ThemeSet midnight: ThemeSet {
        key: "midnight"
        label: qsTr("Midnight")
        lightness: 0
        background: "#000000"
        text: "#f5f5f5"
        textDim: "#a9a9a9"
        glass: "#1affffff"
        glassStrong: "#1affffff"
        glassOpaque: "#e6191919"
        glassBorder: "#2effffff"
        focusRing: "#ffffff"
        focusFill: Qt.rgba(1, 1, 1, 0.2)
        selectedFill: Qt.rgba(1, 1, 1, 0.1)
        keyFocusFill: Qt.rgba(1, 1, 1, 0.22)
        entryKeyFocusFill: Qt.rgba(1, 1, 1, 0.24)
        entryKeyActiveFill: Qt.rgba(1, 1, 1, 0.3)
        scrim: "#d9000000"
        scrimOverlay: "#e0000000"
        panel: "#141414"
        dangerFill: "#8f2d2d"
        primaryFill: "#ffffff"
        onPrimary: "#000000"
        heroScrim: "#bf000000"
        artCaptionFade: "#d9000000"
        errorText: "#ff8a80"
        warningText: "#ffb74d"
        blobHighlight: "#ffffff"
        blobA: "#7a7a7a"
        blobB: "#666666"
        defaultTint: "#6e6e6e"
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
        glassSpecular: Qt.rgba(1, 1, 1, 0.20)
        shadowColor: Qt.rgba(0, 0, 0, 1)
        blobStrength: 0.4
        blobTintShare: 0.08
        shadowStrength: 1
        artLightTop: 0.34
        artLightBottom: 0.12
    }

    // Deep teal-green ground and glass, blobs in teal, green and violet whatever the profile's
    // tint is, a mint focus ring, fills and primary button. T-271.
    property ThemeSet aurora: ThemeSet {
        key: "aurora"
        label: qsTr("Aurora")
        lightness: 0
        background: "#04211e"
        text: "#eaf6f4"
        textDim: "#a8cfca"
        glass: "#1fa6ffe6"
        glassStrong: "#1fa6ffe6"
        glassOpaque: "#e60d3b37"
        glassBorder: "#40a6fff0"
        focusRing: "#9ff5e4"
        focusFill: Qt.rgba(0.45, 1, 0.88, 0.22)
        selectedFill: Qt.rgba(0.45, 1, 0.88, 0.12)
        keyFocusFill: Qt.rgba(0.45, 1, 0.88, 0.24)
        entryKeyFocusFill: Qt.rgba(0.45, 1, 0.88, 0.26)
        entryKeyActiveFill: Qt.rgba(0.45, 1, 0.88, 0.34)
        scrim: "#d0021210"
        scrimOverlay: "#d8021210"
        panel: "#0f3430"
        dangerFill: "#8f2d44"
        primaryFill: "#5eead4"
        onPrimary: "#04211e"
        heroScrim: "#bf08403a"
        artCaptionFade: "#d908403a"
        errorText: "#ff9a94"
        warningText: "#ffc266"
        blobHighlight: "#9b80f0"
        blobA: "#1aa890"
        blobB: "#2fa85c"
        defaultTint: "#1fb5a0"
        tileGames: "#2a9d8f"
        tileMedia: "#9a5fd9"
        tileStore: "#2fa37a"
        tileSettings: "#7a5bd9"
        tileOther: "#4f6f7a"
        toastInfo: "#8cc3ff"
        toastSuccess: "#62dca0"
        toastWarning: "#ffc266"
        toastError: "#ff7a7a"
        toastBackground: "#f00c3430"
        glassSheen: Qt.rgba(0.85, 1, 0.97, 0.07)
        glassRim: Qt.rgba(0.6, 1, 0.9, 0.2)
        glassRimLit: Qt.rgba(0.75, 1, 0.94, 0.38)
        glassTint: Qt.rgba(0, 0.16, 0.14, 0.46)
        glassSpecular: Qt.rgba(0.7, 1, 0.94, 0.26)
        shadowColor: Qt.rgba(0, 0.05, 0.04, 1)
        blobStrength: 0.55
        blobTintShare: 0.2
        shadowStrength: 1
        artLightTop: 0.40
        artLightBottom: 0.16
    }

    // Warm ground, copper glass, blobs in red, amber and copper whatever the profile's tint is,
    // a peach focus ring, warm fills and a copper primary button. T-271.
    property ThemeSet ember: ThemeSet {
        key: "ember"
        label: qsTr("Ember")
        lightness: 0
        background: "#1c0c07"
        text: "#f8efe9"
        textDim: "#c4aa9a"
        glass: "#26ffb27a"
        glassStrong: "#26ffb27a"
        glassOpaque: "#e6482212"
        glassBorder: "#40ffc08a"
        focusRing: "#ffc89a"
        focusFill: Qt.rgba(1, 0.72, 0.45, 0.24)
        selectedFill: Qt.rgba(1, 0.72, 0.45, 0.13)
        keyFocusFill: Qt.rgba(1, 0.72, 0.45, 0.26)
        entryKeyFocusFill: Qt.rgba(1, 0.72, 0.45, 0.28)
        entryKeyActiveFill: Qt.rgba(1, 0.72, 0.45, 0.36)
        scrim: "#d0150602"
        scrimOverlay: "#d8150602"
        panel: "#3d1d10"
        dangerFill: "#9c2b2b"
        primaryFill: "#ffa866"
        onPrimary: "#1c0c07"
        heroScrim: "#bf4a1c0c"
        artCaptionFade: "#d94a1c0c"
        errorText: "#ff9a8c"
        warningText: "#ffc266"
        blobHighlight: "#ffb070"
        blobA: "#d65a24"
        blobB: "#c9892a"
        defaultTint: "#d4502e"
        tileGames: "#c2492c"
        tileMedia: "#d9483a"
        tileStore: "#c98a2c"
        tileSettings: "#a83a5a"
        tileOther: "#7a5a4f"
        toastInfo: "#7ab0ff"
        toastSuccess: "#5cc88f"
        toastWarning: "#ffc266"
        toastError: "#ff7a6b"
        toastBackground: "#f0361a0e"
        glassSheen: Qt.rgba(1, 0.92, 0.82, 0.07)
        glassRim: Qt.rgba(1, 0.78, 0.55, 0.2)
        glassRimLit: Qt.rgba(1, 0.86, 0.68, 0.38)
        glassTint: Qt.rgba(0.22, 0.08, 0.03, 0.46)
        glassSpecular: Qt.rgba(1, 0.86, 0.68, 0.26)
        shadowColor: Qt.rgba(0.08, 0.01, 0, 1)
        blobStrength: 0.66
        blobTintShare: 0.2
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
        blobA: "#8ea4f2"           // not used (blobTintShare 1)
        blobB: "#8ea4f2"
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
        glassSpecular: Qt.rgba(1, 1, 1, 0.70)
        shadowColor: Qt.rgba(0x0f / 255, 0x14 / 255, 0x20 / 255, 1)
        blobStrength: 0.45
        blobTintShare: 1
        shadowStrength: 0.45
        artLightTop: 0.84
        artLightBottom: 0.72
    }
}
