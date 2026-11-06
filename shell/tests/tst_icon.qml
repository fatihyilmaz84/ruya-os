import QtQuick
import QtTest
import RuyaShell

// Icon (04 §3.7, T-157): the bundled Material Symbols fonts are loaded, a known name has a size,
// an unknown one draws nothing, and the Settings pill's gear is filled only for its own section.
Item {
    id: host
    width: 800
    height: 300

    Component { id: iconComponent; Icon {} }
    Component { id: navComponent; SectionNav {} }
    Component {
        id: benchComponent
        FocusScope {
            property alias nav: benchNav
            width: benchNav.width + 40
            height: benchNav.height + 40
            Rectangle { anchors.fill: parent; color: Theme.background }
            SectionNav { id: benchNav; x: 20; y: 20 }
        }
    }

    TestCase {
        id: tc
        name: "Icon"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
        }

        function test_font_families_are_loaded() {
            verify(Qt.fontFamilies().indexOf(Theme.iconFamily) >= 0, Theme.iconFamily)
            verify(Qt.fontFamilies().indexOf(Theme.iconFamilyFilled) >= 0, Theme.iconFamilyFilled)
        }

        function test_known_name_has_a_size() {
            const icon = createTemporaryObject(iconComponent, host, { name: "settings" })
            verify(icon)
            verify(icon.implicitWidth > 0)
            compare(icon.implicitHeight, Theme.iconM)
            icon.u = 2
            compare(icon.implicitHeight, Theme.iconM * 2)
            icon.size = Theme.iconL
            compare(icon.implicitHeight, Theme.iconL * 2)
            compare(icon.Accessible.ignored, true)
        }

        function test_unknown_name_draws_nothing_and_warns_once() {
            ignoreWarning(/unknown icon name 'no_such_icon'/)
            const icon = createTemporaryObject(iconComponent, host, { name: "no_such_icon" })
            verify(icon)
            compare(icon.implicitWidth, 0)
            compare(icon.implicitHeight, 0)
            icon.size = 80                      // no second warning (a second one would fail the test)
            compare(icon.known, false)
        }

        function test_empty_name_is_silent() {
            const icon = createTemporaryObject(iconComponent, host)
            compare(icon.implicitWidth, 0)
        }

        function test_filled_cut_is_a_separate_family() {
            const icon = createTemporaryObject(iconComponent, host, { name: "settings" })
            const glyph = icon.children[0]
            compare(glyph.font.family, Theme.iconFamily)
            icon.filled = true
            compare(glyph.font.family, Theme.iconFamilyFilled)
        }

        // The Settings pill at real pixel size, saved for review (T-206): 1080p and 720p, with the
        // gear outlined (Home on screen), filled (Settings on screen) and focused, in both languages.
        function test_zz_screenshots_gear() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            const bench = createTemporaryObject(benchComponent, host)
            verify(bench)
            const states = [["inactive", "home", false], ["active", "settings", false],
                            ["focused", "settings", true], ["focused-inactive", "home", true]]
            for (const lang of ["en", "tr"]) {
                DeviceSettings.language = lang
                for (const u of [1, 2 / 3]) {
                    for (const st of states) {
                        bench.nav.u = u
                        bench.nav.section = st[1]
                        bench.nav.currentIndex = st[2] ? 4 : 0
                        if (st[2]) bench.nav.forceActiveFocus(); else bench.forceActiveFocus()
                        wait(300)
                        grabImage(bench).save(shotsDir + "/gear-" + lang + "-" + (u === 1 ? "1080" : "720")
                                              + "-" + st[0] + ".png")
                    }
                }
            }
            DeviceSettings.language = "en"
        }

        // Relative luminance (WCAG) of a colour, and the contrast ratio of two.
        function luminance(c) {
            const lin = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        function contrast(a, b) {
            const la = luminance(a), lb = luminance(b)
            return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
        }

        // T-206: the active gear is as big as the inactive one and readable on the white pill.
        function test_active_gear_has_the_inactive_size_and_enough_contrast() {
            for (const u of [1, 2 / 3]) {            // 1080p and a 720p window
                const nav = createTemporaryObject(navComponent, host, { section: "home", u: u })
                verify(nav)
                const icon = findChild(nav, "navIcon_settings")
                const glyph = icon.children[0]
                const size = glyph.font.pixelSize
                const height = icon.height
                verify(Math.abs(size - Theme.iconM * u) <= 1, "the nav gear is iconM at u " + u + ": " + size)   // pixelSize is whole
                nav.section = "settings"
                verify(icon.filled)
                compare(glyph.font.pixelSize, size, "the active gear keeps the glyph size at u " + u)
                compare(icon.height, height, "...and the item height")
                compare(icon.color, Theme.onPrimary)
            }
            verify(contrast(Theme.onPrimary, Theme.primaryFill) >= 4.5,
                   "onPrimary on primaryFill: " + contrast(Theme.onPrimary, Theme.primaryFill))
            verify(contrast(Theme.text, Theme.background) >= 4.5, "the inactive gear on the bar")
        }

        function test_settings_pill_is_filled_only_for_its_section() {
            const nav = createTemporaryObject(navComponent, host, { section: "home" })
            verify(nav)
            const pill = findChild(nav, "navIcon_settings")
            verify(pill, "the Settings pill holds an Icon")
            compare(pill.name, "settings")
            verify(pill.visible)
            verify(!pill.filled, "outlined while Home is on screen")
            nav.section = "settings"
            verify(pill.filled, "filled while Settings is the section")
            nav.section = "games"
            verify(!pill.filled)
            verify(!findChild(nav, "navIcon_home").visible, "the other pills stay words")
        }
    }
}
