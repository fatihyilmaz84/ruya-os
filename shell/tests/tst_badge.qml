import QtQuick
import QtTest
import RuyaShell

// Badge (04 §5): the kind picks the colour; the accessible name is the text.
Item {
    width: 400
    height: 300

    Badge { id: badge; text: "Official" }

    TestCase {
        name: "Badge"
        when: windowShown

        function init() { badge.kind = "neutral"; DeviceSettings.language = "en" }

        function test_kinds() {
            const kinds = { success: Theme.toastSuccess, info: Theme.toastInfo, warning: Theme.toastWarning }
            for (const k in kinds) {
                badge.kind = k
                compare(badge.tone, kinds[k], k)
                compare(badge.color.r, kinds[k].r, k)
                compare(badge.color.a, Theme.badgeFillAlpha, k)
                compare(badge.border.width, 0, k)
            }
        }

        function test_neutral() {
            compare(badge.tone, Theme.textDim)
            compare(badge.color, Theme.background)
            compare(badge.border.color, Theme.glassBorder)
            verify(badge.border.width > 0)
        }

        function test_accessible_name() {
            compare(badge.Accessible.name, "Official")
            badge.text = "Dev"
            compare(badge.Accessible.name, "Dev")
        }

        // Capitals follow the UI language: Turkish has a dotted capital I (RUY-804).
        function test_caps_in_turkish() {
            compare(CapsText.upper("risk"), "RISK")
            DeviceSettings.language = "tr"
            tryCompare(CapsText, "language", "tr")
            compare(CapsText.upper("risk ışık"), "RİSK IŞIK")
            badge.text = "Yüksek risk"
            compare(findChild(badge, "badgeLabel").text, "YÜKSEK RİSK")
            DeviceSettings.language = "en"
            tryCompare(findChild(badge, "badgeLabel"), "text", "YÜKSEK RISK")
            badge.text = "Official"
            compare(findChild(badge, "badgeLabel").text, "OFFICIAL")
        }
    }
}
