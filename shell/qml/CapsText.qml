pragma Singleton
import QtQuick
import RuyaShell

// Text in capitals, in the UI language (RUY-804): Turkish has a dotted and a dotless I, so
// "risk" is "RİSK" and "ışık" is "IŞIK"; a font's AllUppercase (and JS toUpperCase) ignores that.
// The one owner of caps text: Badge and the Install-from-USB drive heading use it, none sets
// font capitalization (lint-tokens refuses the font-based caps).
//
// `upper` reads `language`, so a binding that calls it is evaluated again when the UI language changes.
QtObject {
    readonly property string language: DeviceSettings.language

    function upper(text) {
        return text.toLocaleUpperCase(language)
    }
}
