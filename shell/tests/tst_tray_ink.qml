import QtQuick
import QtTest
import RuyaShell

// The top bar's adaptive ink (RUY-1136, 04 §5.5; the shade it replaced was RUY-1117): ThemeMath.trayInk picks light or
// dark ink for the nav's and the tray's text from the light of the art behind them (ArtPalette measures it: the top
// band of the picture, in the same pass and cache as the glow's colours), with hysteresis, and turns the glyph halo on
// over busy art; Shell's `trayInk` and `navInk` follow what is behind the bar (the hero art on Home, the wallpaper on a
// page; the theme's `text` over its own Backdrop or art not measured yet), cross-faded over `tintMs`, at once under
// reduced motion. `shots` saves Home over a dark, a light and a busy hero, Dreamglass and Daylight, 1080p and 720p.
// Signs in as "Ada" (p2, no PIN) with controller keys.
Item {
    id: host
    width: 1920
    height: 1080

    Component {
        id: sizedShell
        Shell { version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "TrayInk"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        function path(name) { return artFixtures + "/" + name + ".png" }
        // The same picture under another cache key (not measured yet): a file URL (a Windows drive path needs three slashes).
        function fileUrl(name) { return path(name).startsWith("/") ? "file://" + path(name) : "file:///" + path(name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.theme = "dreamglass"
            DeviceSettings.wallpaper = ""
            DeviceSettings.effectsQuality = "balanced"
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.theme = "dreamglass"
            DeviceSettings.wallpaper = ""
            DeviceSettings.effectsQuality = "balanced"
            Theme.motionFactor = 0.1
            Batteries.mockReset()
        }

        function grey(lum) { return { high: lum, low: lum } }
        function pick(band, current) { return ThemeMath.trayInk(band, current ?? "", Theme) }

        // --- ThemeMath.trayInk ------------------------------------------------------------------------

        function test_the_inks_are_the_two_themes_text() {
            verify(Qt.colorEqual(Theme.inkLight, Themes.byKey("dreamglass").text))
            verify(Qt.colorEqual(Theme.inkDark, Themes.byKey("daylight").text))
            verify(Qt.colorEqual(Theme.inkLightWarning, Themes.byKey("dreamglass").warningText))
            verify(Qt.colorEqual(Theme.inkDarkWarning, Themes.byKey("daylight").warningText))
            compare(Theme.trayHaloAlpha, 0.6)
            compare(ThemeMath.trayInkHysteresis, 0.5)
            DeviceSettings.theme = "aurora"
            tryCompare(Theme, "mix", 1, 5000)
            verify(Qt.colorEqual(Theme.inkLight, Themes.byKey("dreamglass").text), "not themeable")
        }

        function test_the_rule_over_the_fixtures() {
            const black = pick(grey(0))
            compare(black.ink, "light", "uniform black: light ink")
            verify(!black.busy)
            const white = pick(grey(1))
            compare(white.ink, "dark", "uniform white: dark ink")
            verify(!white.busy)
            const sky = pick({ high: 0.85, low: 0.45 })
            compare(sky.ink, "dark", "a light sky: dark ink")
            verify(!sky.busy && sky.dark >= 4.5)
            const scene = pick({ high: 0.06, low: 0.003 })
            compare(scene.ink, "light", "a dark scene: light ink")
            verify(!scene.busy && scene.light >= 4.5)
            // Mid grey 0.18: neither ink reaches 4.5:1 (the inks are not pure white and black): busy, the higher one.
            const mid = pick(grey(0.18))
            verify(mid.light < 4.5 && mid.dark < 4.5, "mid grey: " + mid.light + " / " + mid.dark)
            verify(mid.busy, "mid grey is busy: the halo")
            compare(mid.ink, mid.light >= mid.dark ? "light" : "dark", "the higher worst case")
            // Bright and dark patches: busy, the halo.
            const patches = pick({ high: 0.9, low: 0.004 })
            verify(patches.busy)
            compare(patches.ink, patches.light >= patches.dark ? "light" : "dark")
            // Light ink first: where it reads, it is chosen however well dark ink would read.
            for (let i = 0; i <= 100; ++i) {
                const p = pick(grey(i / 100))
                if (p.light >= 4.5)
                    compare(p.ink, "light", "luminance " + i / 100)
                else if (p.dark >= 4.5)
                    compare(p.ink, "dark", "luminance " + i / 100)
                else
                    verify(p.busy, "luminance " + i / 100 + " is busy")
            }
        }

        // Once chosen, the other ink wins only when its worst case beats the current one's by 0.5: no flip near the threshold.
        function test_hysteresis_keeps_the_ink_within_half_a_point() {
            const near = { high: 0.2, low: 0.17 }       // busy: dark ink is a little better than light
            const fresh = pick(near)
            compare(fresh.ink, "dark")
            verify(fresh.dark - fresh.light < 0.5 && fresh.dark > fresh.light, fresh.light + " / " + fresh.dark)
            const kept = pick(near, "light")
            compare(kept.ink, "light", "within 0.5 the current ink stays")
            verify(kept.busy, "and carries the halo")
            compare(pick(near, "dark").ink, "dark")
            // Far enough: it changes.
            compare(pick({ high: 0.25, low: 0.24 }, "light").ink, "dark", "dark ink reads, 0.5 better: it takes over")
            compare(pick(grey(0), "dark").ink, "light", "over black light ink takes over")
            compare(pick(grey(1), "light").ink, "dark")
            // Every current ink: the chosen one reads, or is never 0.5 or more worse than the other.
            for (let i = 0; i <= 100; ++i) {
                for (const current of ["light", "dark"]) {
                    const p = pick(grey(i / 100), current)
                    const mine = p.ink === "light" ? p.light : p.dark
                    const other = p.ink === "light" ? p.dark : p.light
                    verify(mine >= 4.5 || other < mine + 0.5, i / 100 + " from " + current + ": " + mine + " / " + other)
                }
            }
        }

        // The nav's words lie on its glass: the light through it (Daylight's frosted white glass over dark art reads dark).
        function test_the_band_through_the_nav_glass() {
            const day = Themes.snapshot(Themes.byKey("daylight"))
            const dark = ThemeMath.bandThroughGlass(grey(0), day.glassStrong)
            verify(dark.high > 0.3, "Daylight's glass over black is light: " + dark.high)
            compare(pick(dark).ink, "dark")
            const dream = Themes.snapshot(Themes.byKey("dreamglass"))
            const through = ThemeMath.bandThroughGlass({ high: 0.5, low: 0.5 }, dream.glassStrong)
            verify(through.high > 0.5, "the glass lightens the bright end")
            verify(through.low < through.high, "and the dark end is darkened by the blur's brightness: " + through.low)
            compare(ThemeMath.bandThroughGlass(grey(0), Qt.rgba(1, 1, 1, 0)).low, 0, "clear glass over black stays black")
        }

        // --- ArtPalette.bandOf ------------------------------------------------------------------------

        readonly property real wide: 16 / 9     // the view's aspect: a 16:9 screen
        function bandOf(source, aspect) {
            const a = aspect === undefined ? tc.wide : aspect
            tryVerify(() => ArtPalette.bandOf(source, a).ok === true, 5000, source + " is measured")
            return ArtPalette.bandOf(source, a)
        }

        function test_the_top_band_is_measured() {
            const bright = bandOf(path("brighttop"))
            verify(bright.high > 0.9, "white at the top: " + bright.high)
            verify(bright.low > 0.5, "the band is the top only, the black below is not in it: " + bright.low)
            const dark = bandOf(path("darktop"))
            verify(dark.high < 0.02, "black at the top, however white below: " + dark.high)
            verify(dark.low <= dark.high)
            const white = bandOf(path("white"))
            verify(white.high > 0.8 && white.low > 0.7, "a white picture: " + white.low + " .. " + white.high)
            // A small bright patch (about 5 % of the band, where the clock is) counts: the 98th percentile, not the 90th.
            const patch = bandOf(path("darkpatch"))
            verify(patch.high > 0.3, "a bright patch behind the clock: " + patch.high)
            verify(patch.low < 0.02, "on black: " + patch.low)
        }

        // The hero and the wallpaper are a centred PreserveAspectCrop: the band is the top of what is on screen. A 2:3
        // cover dark over its top quarter and a square tile dark over its top 30 % show only white rows in a 16:9 view
        // (the cover) or white at the top of the band (the tile): the band is bright, not the off-screen black.
        function test_the_band_is_the_top_of_the_visible_crop() {
            const portrait = bandOf(path("portraitdarktop"))
            verify(portrait.high > 0.9, "a 2:3 cover in 16:9: its visible top is white: " + portrait.high)
            const whole = bandOf(path("portraitdarktop"), 0)
            verify(whole.high < 0.02, "uncropped, its top is the black: " + whole.high)
            const square = bandOf(path("squaredarktop"))
            verify(square.high > 0.9, "a square tile in 16:9: the band reaches into the white: " + square.high)
            verify(square.low < 0.02, "and the black at its top is in it too: " + square.low)
            verify(bandOf(path("squaredarktop"), 0).high < 0.02, "uncropped, its top 20 % is black")
            // A 16:9 picture in a 16:9 view is not cropped, and in a narrower view only its sides go.
            compare(bandOf(path("darktop")).high, bandOf(path("darktop"), 0).high)
            compare(bandOf(path("brighttop"), 4 / 3).high, bandOf(path("brighttop"), 0).high)
        }

        function test_one_decode_for_the_colours_and_the_band() {
            const source = fileUrl("brighttop")
            const before = ArtPalette.analysed
            compare(Object.keys(ArtPalette.bandOf(source, tc.wide)).length, 0, "not known yet")
            ArtPalette.colorsOf(source)
            tryVerify(() => ArtPalette.bandOf(source, tc.wide).ok === true, 5000)
            verify(ArtPalette.colorsOf(source).color !== undefined, "the colours came with it")
            wait(50)
            compare(ArtPalette.analysed, before + 1, "one picture, both measures: one analysis")
            for (let i = 0; i < 10; ++i)
                ArtPalette.bandOf(source, i % 3)
            wait(50)
            compare(ArtPalette.analysed, before + 1, "asking again does not decode again")
        }

        function test_an_unreadable_picture_has_no_band() {
            const missing = artFixtures + "/no-such-band.png"
            compare(Object.keys(ArtPalette.bandOf(missing, tc.wide)).length, 0)
            wait(150)
            compare(Object.keys(ArtPalette.bandOf(missing, tc.wide)).length, 0, "it stays unknown")
        }

        // --- the ink in the shell ---------------------------------------------------------------------

        function signIn(w, h, scenario) {
            Library.resetMockForTests(scenario ?? ("art:" + artFixtures))
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(sizedShell, host, { width: w ?? 1920, height: h ?? 1080 })
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            tryVerify(() => Library.items.length === 10)
            // The shell has shown its own hero (the focused Recent item's picture): a test's hero is not replaced later.
            tryVerify(() => front().picture.length > 0, 2000, "the hero has its picture")
        }

        // The hero layer in front, and the hero showing a picture (the shell's own `heroArt.show`, as for a focused item).
        function front() { return find("heroArt").showB ? find("heroArtB") : find("heroArtA") }
        function showHero(picture) {
            find("heroArt").show({ id: "test:" + picture, title: "Hero", art: { tile: picture } })
            compare(front().picture, picture)
        }
        // The bar's light is measured for `picture` and both inks have arrived where they head.
        function settledOn(picture) {
            const light = find("barLight")
            tryVerify(() => light.behind.source === picture && light.band !== null, 5000,
                      picture + " is measured (behind " + light.behind.kind + " " + light.behind.source + ")")
            settled()
            return find("trayInk")
        }
        function settled() {
            for (const name of ["trayInk", "navInk"]) {
                const ink = find(name)
                tryVerify(() => Qt.colorEqual(ink.color, ink.target) && Qt.colorEqual(ink.warningColor, ink.warningTarget),
                          5000, name + " has arrived")
            }
        }
        function same(a, b) { return Qt.colorEqual(a, b) }

        function test_the_ink_follows_the_hero() {
            Batteries.mockPopulate()             // the chips and "N more" in the tray
            signIn()
            const ink = find("trayInk")
            showHero(path("dark"))
            compare(find("barLight").behind.kind, "art")
            settledOn(path("dark"))
            compare(ink.pick.ink, "light", "a dark hero: light ink")
            verify(!ink.halo)
            compare(find("barLight").behind.aspect, front().width / front().height, "measured as drawn")
            compare(JSON.stringify(ink.band), JSON.stringify(ArtPalette.bandOf(path("dark"), find("barLight").behind.aspect)))
            // Every glyph and word of the tray is in the ink.
            verify(same(find("activeProfileName").color, Theme.inkLight))
            verify(same(find("statusClock").color, Theme.inkLight))
            verify(same(find("playerChip_1").ring, Theme.inkLight), "the avatar's ring")
            verify(same(find("navLabel_games").color, Theme.inkLight), "a nav word at rest")
            verify(same(find("navIcon_notifications").color, Theme.inkLight), "the bell")
            showHero(path("white"))
            settledOn(path("white"))
            compare(ink.pick.ink, "dark", "a light hero: dark ink")
            verify(!ink.halo)
            verify(same(find("statusClock").color, Theme.inkDark))
            verify(same(find("navLabel_games").color, Theme.inkDark), "Dreamglass glass over white: dark ink")
            verify(same(find("bellBadge").border.color, find("navInk").color), "the badge's outline in the nav's ink")
            const chip = find("batteryStatus").children.find(c => c.objectName.startsWith("batteryChip_"))
            verify(same(findChild(chip, "batteryKindIcon").color, Theme.inkDark), "a battery chip's glyph")
            verify(same(findChild(chip, "batteryPercent").color, chip.low ? Theme.inkDarkWarning : Theme.inkDark), "and its number")
            verify(same(findChild(find("batteryMore"), "batteryMoreLabel").color, Theme.inkDark), "\"N more\"")
            // The current and the focused pill keep their own colours.
            verify(same(find("navLabel_home").color, Theme.onPrimary), "the current pill")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("sectionNav").activeFocus)
            keyClick(Qt.Key_Right)
            verify(same(find("navLabel_games").color, Theme.text), "the focused pill is its own surface")
            verify(same(find("navLabel_media").color, Theme.inkDark))
        }

        function test_busy_art_turns_the_halo_on() {
            signIn()
            const ink = find("trayInk")
            showHero(path("dark"))
            settledOn(path("dark"))
            verify(!ink.halo)
            verify(!find("statusRow").layer.enabled, "no halo over a dark hero")
            verify(!find("navPills").layer.enabled)
            showHero(path("darkpatch"))
            settledOn(path("darkpatch"))
            verify(ink.pick.busy, "a bright patch on black: busy " + JSON.stringify(ink.band))
            verify(ink.halo)
            verify(find("statusRow").layer.enabled, "the tray's text layer carries the halo")
            const other = ink.pick.ink === "light" ? Theme.inkDark : Theme.inkLight
            verify(same(Qt.rgba(ink.haloColor.r, ink.haloColor.g, ink.haloColor.b, 1), other), "in the other ink")
            compare(ink.haloColor.a.toFixed(2), Theme.trayHaloAlpha.toFixed(2), "at trayHaloAlpha")
            compare(find("navPills").layer.enabled, find("navInk").halo, "the nav's words follow their own light")
            showHero(path("white"))
            settledOn(path("white"))
            verify(!find("statusRow").layer.enabled, "off again when the art is not busy")
        }

        // Daylight's nav glass is frosted white: over a dark hero the tray reads light, the nav's words dark.
        function test_the_nav_reads_through_its_glass() {
            DeviceSettings.theme = "daylight"
            signIn()
            tryCompare(Theme, "mix", 1, 5000)
            showHero(path("dark"))
            settledOn(path("dark"))
            compare(find("trayInk").pick.ink, "light")
            compare(find("navInk").pick.ink, "dark", "the words on the white glass")
            verify(same(find("navLabel_games").color, Theme.inkDark))
            verify(same(find("statusClock").color, Theme.inkLight))
        }

        // Without blur (Performance) the nav's pill is `glassOpaque`, a known ground: its words are the theme's text.
        function test_the_nav_on_opaque_glass_takes_the_theme_text() {
            signIn()
            showHero(path("white"))
            settledOn(path("white"))
            verify(same(find("navLabel_games").color, Theme.inkDark), "over white through the clear glass: dark ink")
            DeviceSettings.effectsQuality = "performance"
            compare(find("navInk").band, null)
            settled()
            verify(same(find("navLabel_games").color, Theme.text), "on glassOpaque: the theme's text")
            verify(same(find("statusClock").color, Theme.inkDark), "the tray still follows the art")
        }

        function test_unknown_art_takes_the_theme_text_then_its_ink() {
            signIn()
            const ink = find("trayInk")
            showHero(path("dark"))
            settledOn(path("dark"))
            const fresh = fileUrl("white")       // a picture not measured yet
            showHero(fresh)
            compare(ink.band, null, "not measured yet")
            verify(same(ink.target, Theme.text), "the theme's text while it is unknown")
            tryVerify(() => ink.pick !== null && ink.pick.ink === "dark", 5000, "then the measured ink")
            // A picture that cannot be read keeps the theme's text.
            showHero(artFixtures + "/no-such-hero.png")
            wait(150)
            compare(ink.band, null)
            verify(same(ink.target, Theme.text), "unreadable art: the theme's text")
            // An item without a picture is drawn as its placeholder: never measured.
            find("heroArt").show({ id: "test:none", title: "None", art: {} })
            compare(find("barLight").behind.kind, "unknown")
            verify(same(ink.target, Theme.text))
            verify(!ink.halo)
        }

        function openPage() {
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "games")
        }

        function test_a_page_takes_the_theme_text_or_the_wallpaper() {
            signIn()
            const ink = find("trayInk")
            showHero(path("white"))
            settledOn(path("white"))
            openPage()
            compare(find("barLight").behind.kind, "backdrop", "a page without a wallpaper: the Backdrop")
            compare(ink.band, null, "the theme's own ground")
            settled()
            verify(same(find("statusClock").color, Theme.text))
            DeviceSettings.wallpaper = "daybreak"
            tryVerify(() => find("wallpaperLayer").has, 5000, "the wallpaper shows")
            const light = find("barLight")
            compare(light.behind.kind, "wallpaper")
            compare(light.behind.source, find("wallpaperLayer").target)
            tryVerify(() => light.band !== null, 5000, "the wallpaper is measured")
            compare(light.behind.aspect, find("wallpaperLayer").width / find("wallpaperLayer").height)
            const raw = ArtPalette.bandOf(find("wallpaperLayer").target, light.behind.aspect)
            const dimmed = ThemeMath.bandUnder(raw, Theme.background, find("wallpaperLayer").effectiveDim)
            compare(JSON.stringify(light.band), JSON.stringify(dimmed), "the wallpaper under its dim")
            compare(ink.pick.ink, ThemeMath.trayInk(dimmed, "", Theme).ink)
            verify(dimmed.high <= raw.high, "the dim only darkens")
        }

        function test_changes_cross_fade_over_tintMs_and_jump_under_reduced_motion() {
            Theme.motionFactor = 1.0     // the subject is the duration
            signIn()
            const ink = find("trayInk")
            showHero(path("dark"))
            settledOn(path("dark"))
            verify(same(ink.color, Theme.inkLight))
            showHero(path("white"))
            tryVerify(() => ink.pick !== null && ink.pick.ink === "dark", 5000)
            verify(!same(ink.color, Theme.inkDark), "it does not jump")
            tryVerify(() => !same(ink.color, Theme.inkLight) && !same(ink.color, Theme.inkDark), 1000, "it moves between the inks")
            tryVerify(() => same(ink.color, Theme.inkDark), Theme.tintMs + 1000, "and arrives")

            DeviceSettings.reducedMotion = true
            compare(Theme.tintMs, 0)
            showHero(path("dark"))
            tryVerify(() => ink.pick !== null && ink.pick.ink === "light", 5000)
            verify(same(ink.color, Theme.inkLight), "under reduced motion it jumps")
            showHero(path("white"))
            tryVerify(() => ink.pick !== null && ink.pick.ink === "dark", 5000)
            verify(same(ink.color, Theme.inkDark), "both ways")
        }

        // --- screenshots ------------------------------------------------------------------------------

        function test_zz_screenshots_data() {
            const rows = []
            for (const theme of ["dreamglass", "daylight"])
                for (const size of [[1920, 1080, "1080"], [1280, 720, "720"]])
                    rows.push({ tag: theme + "-" + size[2], theme: theme, w: size[0], h: size[1], size: size[2] })
            return rows
        }
        function test_zz_screenshots(data) {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.reducedMotion = true
            DeviceSettings.theme = data.theme
            signIn(data.w, data.h)
            tryCompare(Theme, "mix", 1, 5000, "the theme has finished fading")
            for (const hero of [["dark", path("dark")], ["light", path("white")], ["busy", path("darkpatch")]]) {
                showHero(hero[1])
                settledOn(hero[1])
                wait(500)
                grabImage(tc.shell).save(shotsDir + "/trayink-" + data.theme + "-" + data.size + "-" + hero[0] + ".png")
            }
        }
    }
}
