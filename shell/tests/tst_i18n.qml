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

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
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
            keyClick(Qt.Key_Up)                        // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                    // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus)
            for (let i = 0; i < 20 && list.currentItem.objectName !== "category_system"; ++i)   // System; an admin has Manage profiles too, so select by key
                keyClick(Qt.Key_Down)
            compare(list.currentItem.objectName, "category_system")
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
            compare(find("setupStepLabel").text, "Step 2 of 6")

            keyClick(Qt.Key_Right)                     // Türkçe: the wizard re-translates at once
            compare(DeviceSettings.language, "tr")
            tryCompare(find("setupStepLabel"), "text", "Adım 2 / 6")
            tryCompare(find("setupLanguageTitle"), "text", "Dil")
            keyClick(Qt.Key_Return)                    // -> time zone
            tryCompare(setup, "step", 2)
            tryCompare(find("setupZoneTitle"), "text", "Neredesiniz?")
            tryVerify(() => find("setupZoneRegion_Europe"), 2000, "the regions are listed")
            tryCompare(find("setupZoneRegion_Europe"), "label", "Avrupa")
            keyClick(Qt.Key_Menu)                      // Start: skip -> network
            tryCompare(setup, "step", 3)
            tryCompare(find("setupNetworkTitle"), "text", "Ağ")

            keyClick(Qt.Key_Escape)                    // back to the time zone, then the language step, choose English
            tryCompare(setup, "step", 2)
            keyClick(Qt.Key_Escape)
            tryCompare(setup, "step", 1)
            keyClick(Qt.Key_Left)
            compare(DeviceSettings.language, "en")
            tryCompare(find("setupStepLabel"), "text", "Step 2 of 6")
            keyClick(Qt.Key_Return)
            tryCompare(setup, "step", 2)
            tryCompare(find("setupZoneTitle"), "text", "Where are you?")
            keyClick(Qt.Key_Menu)
            tryCompare(setup, "step", 3)
            tryCompare(find("setupNetworkTitle"), "text", "Network")
        }

        function test_home_nav_follows_language() {
            startShell()
            keyClick(Qt.Key_Return)
            const pad = find("pinPad")
            tryVerify(() => pad.shown)
            for (const d of "1234") keyClick(d)
            keyClick(Qt.Key_Enter)
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => find("homePlay").activeFocus)
            keyClick(Qt.Key_Up)                        // the section nav
            keyClick(Qt.Key_Right)
            const nav = find("sectionNav")
            compare(nav.currentKey, "games")
            compare(find("navPill_games").Accessible.name, "Games")
            keyClick(Qt.Key_Right)
            compare(nav.currentIndex, 2)
            DeviceSettings.language = "tr"
            tryCompare(find("navPill_media").Accessible, "name", "Medya")
            compare(nav.currentIndex, 2, "the language change keeps the selected pill")
            DeviceSettings.language = "en"
            tryCompare(find("navPill_media").Accessible, "name", "Media")
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
            const nav = find("sectionNav")
            tryVerify(() => find("homePlay").activeFocus)
            keyClick(Qt.Key_Up)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Left)
            compare(nav.currentKey, "settings")
            keyClick(Qt.Key_Return)                    // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => nav.activeFocus)
            compare(nav.currentKey, "settings", "back on the Settings pill")
        }

        // T-291: the app page's age badge for an app with no rating (Racer Beta in the mock).
        function test_unrated_app_age_is_translated() {
            startShell()
            keyClick(Qt.Key_Return)                    // Player One
            const pad = find("pinPad")
            tryVerify(() => pad.shown)
            for (const d of "1234") keyClick(d)
            keyClick(Qt.Key_Enter)
            tryCompare(Profiles, "activeProfile", "p1")
            tc.shell.openPage("appDetail", { appId: "org.example.Beta" })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryCompare(find("detailAge"), "text", "Not rated")
            DeviceSettings.language = "tr"
            tryCompare(find("detailAge"), "text", "Derecelendirilmemiş")
            DeviceSettings.language = "en"
            tryCompare(find("detailAge"), "text", "Not rated")
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
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus)
            for (let i = 0; i < 20 && list.currentIndex < 4; ++i)   // Ekran ve hareket
                keyClick(Qt.Key_Down)
            compare(list.currentIndex, 4)
            keyClick(Qt.Key_Return)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/16-settings-tr.png")
        }
    }
}
