import QtQuick
import QtTest
import RuyaShell

// Translations (T-109): switching DeviceSettings.language installs the translator and
// re-translates the live UI. Own file: it changes the language, and each file gets a fresh
// engine. Tests start from English (the ephemeral default, whatever the machine's locale) and
// put it back in cleanup().
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // What Main.qml does under --reverse.
    Component {
        id: mirroredShellComponent
        Shell {
            anchors.fill: parent; version: "test"; focus: true
            LayoutMirroring.enabled: true
            LayoutMirroring.childrenInherit: true
        }
    }

    TestCase {
        id: tc
        name: "I18n"
        when: windowShown

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            Profiles.lock()
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            DeviceSettings.language = "en"
        }

        function cleanup() {
            DeviceSettings.language = "en"
        }

        function startShell() {
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.available)
        }

        function test_default_is_english() {
            compare(DeviceSettings.language, "en")
            startShell()
            compare(find("pickerTitle").text, "Who's playing?")
        }

        function test_switch_to_turkish() {
            startShell()
            DeviceSettings.language = "tr"
            tryCompare(find("pickerTitle"), "text", "Kim oynuyor?")
        }

        function test_switch_back() {
            startShell()
            DeviceSettings.language = "tr"
            tryCompare(find("pickerTitle"), "text", "Kim oynuyor?")
            DeviceSettings.language = "en"
            tryCompare(find("pickerTitle"), "text", "Who's playing?")
        }

        function test_plurals() {
            // English: "attempt" for 1, "attempts" otherwise (the plural forms live in the en .ts).
            compare(ProfileStatus.describe("wrong-pin", 1, 0), "Wrong PIN. 1 attempt left.")
            compare(ProfileStatus.describe("wrong-pin", 3, 0), "Wrong PIN. 3 attempts left.")
            DeviceSettings.language = "tr"
            compare(ProfileStatus.describe("wrong-pin", 1, 0), "Yanlış PIN. 1 deneme hakkı kaldı.")
            compare(ProfileStatus.describe("wrong-pin", 3, 0), "Yanlış PIN. 3 deneme hakkı kaldı.")
        }

        function test_settings_language_row() {
            startShell()
            tryCompare(Profiles, "activeProfile", "")
            keyClick(Qt.Key_Return)                    // Player One
            const pad = find("pinPad")
            tryVerify(() => pad.shown)
            for (const d of "1234") keyClick(d)
            keyClick(Qt.Key_Enter)
            tryCompare(Profiles, "activeProfile", "p1")
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                    // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus)
            while (list.currentIndex < 7)              // System
                keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            const row = find("rowLanguage")
            tryVerify(() => row.activeFocus, 2000, "the language row has focus")
            compare(row.value, "en")
            keyClick(Qt.Key_Right)                     // Türkçe
            compare(DeviceSettings.language, "tr")
            compare(row.value, "tr")
            tryCompare(row, "label", "Dil")
            verify(row.activeFocus, "the row keeps focus after the language changed")
            keyClick(Qt.Key_Right)                     // wraps back to English
            compare(DeviceSettings.language, "en")
            tryCompare(row, "label", "Language")
        }

        function test_setup_follows_language() {
            Profiles.resetMockForTests("empty")
            tryVerify(() => Profiles.profiles.length === 0)
            startShell()
            const setup = find("setup")
            tryVerify(() => setup.visible)
            keyClick(Qt.Key_Return)                    // welcome -> language
            tryCompare(setup, "step", 1)
            const row = find("setupLanguageRow")
            tryVerify(() => row.activeFocus)
            compare(find("setupStepLabel").text, "Step 2 of 5")

            keyClick(Qt.Key_Right)                     // Türkçe: the wizard re-translates at once
            compare(DeviceSettings.language, "tr")
            tryCompare(find("setupStepLabel"), "text", "Adım 2 / 5")
            tryCompare(find("setupLanguageTitle"), "text", "Dil")
            keyClick(Qt.Key_Return)                    // -> network
            tryCompare(setup, "step", 2)
            tryCompare(find("setupNetworkTitle"), "text", "Ağ")

            keyClick(Qt.Key_Escape)                    // back to the language step, choose English
            tryCompare(setup, "step", 1)
            keyClick(Qt.Key_Left)
            compare(DeviceSettings.language, "en")
            tryCompare(find("setupStepLabel"), "text", "Step 2 of 5")
            keyClick(Qt.Key_Return)
            tryCompare(setup, "step", 2)
            tryCompare(find("setupNetworkTitle"), "text", "Network")
        }

        function test_home_tiles_follow_language() {
            startShell()
            keyClick(Qt.Key_Return)
            const pad = find("pinPad")
            tryVerify(() => pad.shown)
            for (const d of "1234") keyClick(d)
            keyClick(Qt.Key_Enter)
            tryCompare(Profiles, "activeProfile", "p1")
            const tiles = find("tiles")
            tryVerify(() => tiles.currentItem !== null)
            compare(tiles.currentItem.title, "Games")
            keyClick(Qt.Key_Right)
            compare(tiles.currentIndex, 1)
            DeviceSettings.language = "tr"
            tryCompare(tiles.currentItem, "title", "Medya")
            compare(tiles.currentIndex, 1, "the language change keeps the selected tile")
            DeviceSettings.language = "en"
            tryCompare(tiles.currentItem, "title", "Media")
        }

        // RTL readiness: with the layout mirrored, the whole sign-in -> home -> Settings -> back
        // flow still works. Left/Right swap meaning on the horizontal lists (visual order).
        function test_rtl_navigation() {
            tc.shell = createTemporaryObject(mirroredShellComponent, host)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.available)
            const list = find("profileList")
            tryVerify(() => list.activeFocus)
            compare(list.currentIndex, 0)
            keyClick(Qt.Key_Left)                      // mirrored: Left goes to the next profile
            compare(list.currentIndex, 1)
            keyClick(Qt.Key_Right)
            compare(list.currentIndex, 0)
            keyClick(Qt.Key_Return)
            const pad = find("pinPad")
            tryVerify(() => pad.shown)
            for (const d of "1234") keyClick(d)
            keyClick(Qt.Key_Enter)
            tryCompare(Profiles, "activeProfile", "p1")
            const tiles = find("tiles")
            tryVerify(() => tiles.activeFocus)
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Left)
            compare(tiles.currentIndex, 3)
            keyClick(Qt.Key_Return)                    // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => tiles.activeFocus)
            compare(tiles.currentIndex, 3, "back on the Settings tile")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            startShell()
            DeviceSettings.language = "tr"
            tryCompare(find("pickerTitle"), "text", "Kim oynuyor?")
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/15-picker-tr.png")
            keyClick(Qt.Key_Return)
            const pad = find("pinPad")
            tryVerify(() => pad.shown)
            for (const d of "1234") keyClick(d)
            keyClick(Qt.Key_Enter)
            tryCompare(Profiles, "activeProfile", "p1")
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus)
            while (list.currentIndex < 3)              // Ekran ve hareket
                keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/16-settings-tr.png")
        }
    }
}
