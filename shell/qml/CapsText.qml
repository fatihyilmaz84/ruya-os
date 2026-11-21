pragma Singleton
import QtQuick
import RuyaShell

// Text in capitals, in the UI language (RUY-804): Turkish has a dotted and a dotless I, so
// "risk" is "RİSK" and "ışık" is "IŞIK"; a font's AllUppercase (and JS toUpperCase) ignores that.
// The one owner of caps text: badges, headings, eyebrows and avatar initials use it; none sets
// font capitalization or uses JavaScript's locale-blind upper-casing (lint-tokens refuses both;
// `// token-ok:` for an id).
//
// `upper` reads `language`, so a binding that calls it is evaluated again when the UI language changes.
QtObject {
    readonly property string language: DeviceSettings.language

    function upper(text) {
        return text.toLocaleUpperCase(language)
    }

    // The first letter in capitals, for an avatar monogram: "ilker" gives "İ" in Turkish.
    function initial(name) {
        return upper(String(name ?? "").charAt(0))
    }
}
