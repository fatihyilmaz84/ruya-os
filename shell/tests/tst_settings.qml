import QtQuick
import QtTest
import RuyaShell

// Settings page and the reusable controls. Driven with controller keys only (arrows,
// Return = Accept, Escape = Back). Signs in as "Ada" (p2, no PIN) and opens the Settings
// tile. DeviceSettings is in-memory under test and restored after every test.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test-1.2.3"; focus: true }
    }

    // Controls under test, standalone (no pane around them).
    Component { id: toggleComponent; ToggleRow { label: "Toggle"; width: 700 } }
    Component {
        id: choiceComponent
        ChoiceRow {
            label: "Choice"
            width: 700
            options: [{ value: "a", label: "A" }, { value: "b", label: "B" }, { value: "c", label: "C" }]
            value: "a"
        }
    }
    Component { id: sliderComponent; SliderRow { label: "Slider"; width: 700; from: 0; to: 3; stepSize: 1; value: 1 } }
    Component { id: plainComponent; SettingRow { label: "Plain"; width: 700; value: "x" } }

    SignalSpy { id: spy }

    TestCase {
        id: tc
        name: "Settings"
        when: windowShown

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("tiles").activeFocus, 2000, "home shelf takes focus after sign-in")
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.overscan = 0.05
        }

        function openSettings() {
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList") !== null && find("categoryList").activeFocus, 2000, "category list has focus")
        }

        function selectCategory(index) {
            const list = find("categoryList")
            while (list.currentIndex < index)
                keyClick(Qt.Key_Down)
            while (list.currentIndex > index)
                keyClick(Qt.Key_Up)
        }

        readonly property int displayIndex: 3
        readonly property int aboutIndex: 8

        function test_two_pane_navigation() {
            openSettings()
            const list = find("categoryList")
            compare(list.currentIndex, 0)
            verify(find("paneComingSoon").visible, "Profiles has no content yet")

            selectCategory(tc.displayIndex)
            verify(find("paneDisplay").visible)
            verify(!find("paneComingSoon").visible)
            verify(!find("paneAbout").visible)

            keyClick(Qt.Key_Right)                       // enter the pane
            tryVerify(() => find("rowQuality").activeFocus, 2000, "first row takes focus")
            verify(!list.activeFocus)

            keyClick(Qt.Key_Escape)                      // Back returns to the list (Left would cycle the ChoiceRow)
            tryVerify(() => list.activeFocus)
            compare(list.currentIndex, tc.displayIndex)
            compare(tc.shell.currentPage, "settings")

            keyClick(Qt.Key_Return)                      // Accept also enters
            tryVerify(() => find("rowQuality").activeFocus)
            keyClick(Qt.Key_Escape)                      // Back leaves the pane, not the page
            tryVerify(() => list.activeFocus)
            compare(tc.shell.currentPage, "settings")

            keyClick(Qt.Key_Down)                        // Audio: nothing to enter
            verify(find("paneComingSoon").visible)
            keyClick(Qt.Key_Right)
            verify(list.activeFocus, "Right on an empty category stays on the list")

            selectCategory(tc.aboutIndex)
            verify(find("paneAbout").visible)
            keyClick(Qt.Key_Down)                        // clamps at the last category
            compare(list.currentIndex, tc.aboutIndex)

            keyClick(Qt.Key_Escape)                      // Back on the list closes the page
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("tiles").activeFocus, 2000, "tiles regain focus")
            compare(find("tiles").currentIndex, 3)
        }

        function test_pane_rows_navigate_and_clamp() {
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            keyClick(Qt.Key_Up)                          // clamped at the first row
            verify(find("rowQuality").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("rowReducedMotion").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("rowOverscan").activeFocus)
            keyClick(Qt.Key_Down)                        // clamped at the last row
            verify(find("rowOverscan").activeFocus)
            verify(find("tiles").activeFocus === false)
        }

        function test_pane_remembers_last_row() {
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("rowOverscan").activeFocus)
            keyClick(Qt.Key_Escape)                      // Back leaves the pane
            tryVerify(() => find("categoryList").activeFocus)

            keyClick(Qt.Key_Down)                        // another category
            keyClick(Qt.Key_Up)                          // and back
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowOverscan").activeFocus, 2000, "re-entering restores the last row")
        }

        function test_controls() {
            // ToggleRow: only Accept changes it.
            const toggle = createTemporaryObject(toggleComponent, host)
            toggle.forceActiveFocus()
            verify(toggle.activeFocus)
            spy.target = toggle
            spy.signalName = "toggled"
            spy.clear()
            const selects = Sfx.selectCount
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Up)
            compare(toggle.checked, false)
            keyClick(Qt.Key_Return)
            compare(toggle.checked, true)
            keyClick(Qt.Key_Enter)
            compare(toggle.checked, false)
            compare(spy.count, 2)
            compare(Sfx.selectCount, selects + 2, "Accept takes the select sound path")

            // ChoiceRow: Left/Right cycle (wrapping), nothing else changes it.
            const choice = createTemporaryObject(choiceComponent, host)
            choice.forceActiveFocus()
            verify(choice.activeFocus)
            spy.target = choice
            spy.signalName = "edited"
            spy.clear()
            const navs = Sfx.navigateCount
            compare(choice.value, "a")
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Down)
            compare(choice.value, "a")
            keyClick(Qt.Key_Right)
            compare(choice.value, "b")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(choice.value, "a", "wraps past the last option")
            keyClick(Qt.Key_Left)
            compare(choice.value, "c", "wraps before the first option")
            compare(spy.count, 4)
            compare(Sfx.navigateCount, navs + 4, "changes take the navigate sound path")

            // SliderRow: steps within the bounds and clamps.
            const slider = createTemporaryObject(sliderComponent, host)
            slider.forceActiveFocus()
            verify(slider.activeFocus)
            spy.target = slider
            spy.signalName = "edited"
            spy.clear()
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Up)
            compare(slider.value, 1)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(slider.value, 3)
            keyClick(Qt.Key_Right)
            compare(slider.value, 3, "clamps at the upper bound")
            compare(spy.count, 2, "no signal when nothing changed")
            for (let i = 0; i < 5; ++i)
                keyClick(Qt.Key_Left)
            compare(slider.value, 0, "clamps at the lower bound")

            // SettingRow: Accept emits activated(), nothing else.
            const plain = createTemporaryObject(plainComponent, host)
            plain.forceActiveFocus()
            spy.target = plain
            spy.signalName = "activated"
            spy.clear()
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            compare(spy.count, 0)
            keyClick(Qt.Key_Return)
            compare(spy.count, 1)
        }

        function test_choice_row_keeps_focus() {
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            const list = find("categoryList")

            keyClick(Qt.Key_Right)
            compare(find("rowQuality").value, "balanced")
            verify(find("rowQuality").activeFocus, "focus stays on the row")
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            compare(find("rowQuality").value, "performance", "cycles backwards, wrapping")
            verify(find("rowQuality").activeFocus)
            verify(!list.activeFocus, "never leaves the pane")
            compare(tc.shell.currentPage, "settings")
        }

        function test_display_settings_apply_live() {
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)

            keyClick(Qt.Key_Right)
            compare(DeviceSettings.effectsQuality, "balanced")
            compare(Theme.blurMax, 32)
            keyClick(Qt.Key_Right)
            compare(DeviceSettings.effectsQuality, "performance")
            compare(Theme.blurMax, 0)

            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            compare(DeviceSettings.reducedMotion, true)
            compare(Theme.pageMs, 0)
            verify(find("rowReducedMotion").checked)

            keyClick(Qt.Key_Down)
            compare(find("rowOverscan").value, 5)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(DeviceSettings.overscan, 0.07)
            for (let i = 0; i < 10; ++i)
                keyClick(Qt.Key_Right)
            compare(DeviceSettings.overscan, 0.10, "clamps at 10 %")
            for (let j = 0; j < 12; ++j)
                keyClick(Qt.Key_Left)
            compare(DeviceSettings.overscan, 0.0, "clamps at 0 %")
            compare(find("brand").x, 0, "the header follows the setting")

            // Back on the shelf the blur is gone (performance tier).
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("home").visible)
            verify(!find("shelfBlur").visible, "the shelf blur is off in the performance tier")
        }

        function test_rows_follow_external_changes() {
            openSettings()
            selectCategory(tc.displayIndex)
            DeviceSettings.effectsQuality = "balanced"
            DeviceSettings.reducedMotion = true
            DeviceSettings.overscan = 0.03
            compare(find("rowQuality").value, "balanced")
            compare(find("rowReducedMotion").checked, true)
            compare(find("rowOverscan").value, 3)
        }

        function test_about_shows_version() {
            openSettings()
            selectCategory(tc.aboutIndex)
            verify(find("paneAbout").visible)
            compare(find("aboutVersion").value, "test-1.2.3")
            compare(find("aboutQt").value, SystemInfo.qtVersion)
            verify(SystemInfo.qtVersion.length > 0)
            compare(find("aboutServices").value, Profiles.mock ? "Mock (in-memory)" : "D-Bus")
            compare(find("aboutLicence").value, "GPL-3.0-or-later; see LICENSE.md")

            keyClick(Qt.Key_Right)
            tryVerify(() => find("aboutVersion").activeFocus)
            keyClick(Qt.Key_Return)                      // read-only rows: Accept does nothing
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("aboutLicence").activeFocus)
            keyClick(Qt.Key_Down)
            verify(find("aboutLicence").activeFocus, "clamps at the last row")
            keyClick(Qt.Key_Left)
            tryVerify(() => find("categoryList").activeFocus)
        }

        function test_guide_overlay_over_settings_pane() {
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            keyClick(Qt.Key_HomePage)                    // the pane leaves Guide alone
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("rowQuality").activeFocus, 2000, "focus returns to the row")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openSettings()
            selectCategory(tc.displayIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            keyClick(Qt.Key_Down)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/7-settings-display.png")

            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus)
            selectCategory(tc.aboutIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("aboutVersion").activeFocus)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/8-settings-about.png")
        }
    }
}
