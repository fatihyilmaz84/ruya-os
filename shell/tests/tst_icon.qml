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
