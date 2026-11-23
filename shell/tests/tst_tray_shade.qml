import QtQuick
import QtTest
import RuyaShell

// The status tray's adaptive shade (RUY-1117, 04 §5.5): ThemeMath.trayShadeAlpha picks the least alpha at which the
// tray's text reads over the light of the art behind it, ArtPalette measures that light (the top band of the
// picture, in the same pass and cache as the glow's colours), and Shell's `trayShade` follows what is behind the
// tray (the hero art on Home, the wallpaper or the Backdrop on a page), animated over `tintMs`, at once under
// reduced motion. `shots` saves Home over a dark and a bright hero, Dreamglass and Daylight, 1080p and 720p.
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
        name: "TrayShade"
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
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.theme = "dreamglass"
            DeviceSettings.wallpaper = ""
            Theme.motionFactor = 0.1
        }

        // The shade drawn at `alpha` over a grey of luminance `lum`, measured here (not through trayShadeAlpha).
        function reads(t, alpha, lum) {
            const shade = ThemeMath.over(Qt.rgba(t.background.r, t.background.g, t.background.b, alpha), ThemeMath.grey(lum))
            return ThemeMath.contrast(t.text, shade) >= 4.5 && ThemeMath.contrast(t.warningText, shade) >= 3
        }
        function grey(lum) { return { high: lum, low: lum } }

        // --- ThemeMath.trayShadeAlpha -----------------------------------------------------------------

        function test_the_alpha_reads_and_is_the_least_that_does() {
            const step = ThemeMath.trayShadeStep
            compare(step, 0.05)
            compare(Theme.trayShadeAlphaMax, 0.7)
            for (const s of Themes.all) {
                const t = Themes.snapshot(s)
                for (let i = 0; i <= 20; ++i) {
                    const lum = i / 20
                    const a = ThemeMath.trayShadeAlpha(grey(lum), t)
                    const where = s.key + " over luminance " + lum + ": " + a
                    verify(a >= 0 && a <= Theme.trayShadeAlphaMax + 1e-9, where + " is in [0, ceiling]")
                    verify(Math.abs(a / step - Math.round(a / step)) < 1e-6, where + " is a whole step")
                    verify(reads(t, a, lum), where + " reads")
                    if (a > 0)
                        verify(!reads(t, a - step, lum), where + ": one step less would still read")
                }
            }
        }

        function test_bright_and_dark_ends() {
            for (const s of Themes.all) {
                const t = Themes.snapshot(s)
                const light = t.lightness >= 0.5
                const worst = ThemeMath.trayShadeAlpha(grey(light ? 0 : 1), t)
                const best = ThemeMath.trayShadeAlpha(grey(light ? 1 : 0), t)
                compare(best, 0, s.key + ": over art the text already reads on, the shade disappears")
                verify(worst > 0.5, s.key + ": over the worst art the shade is strong: " + worst)
                for (let i = 0; i <= 20; ++i)
                    verify(ThemeMath.trayShadeAlpha(grey(i / 20), t) <= worst, s.key + ": the worst end needs the most")
            }
            compare(ThemeMath.trayShadeAlpha(grey(0), Themes.snapshot(Themes.byKey("daylight"))), Theme.trayShadeAlphaMax,
                    "Daylight over pure black: the ceiling")
            // Over pure white the dark themes need a little less than the ceiling (computed: 0.6 or 0.65).
            for (const key of ["dreamglass", "midnight", "aurora", "ember"]) {
                const a = ThemeMath.trayShadeAlpha(grey(1), Themes.snapshot(Themes.byKey(key)))
                verify(a >= 0.6 - 1e-9 && a <= Theme.trayShadeAlphaMax, key + " over pure white: " + a)
            }
        }

        function test_light_text_holds_over_the_bright_end_dark_text_over_the_dark_end() {
            const band = { high: 1, low: 0 }
            for (const s of Themes.all) {
                const t = Themes.snapshot(s)
                const light = t.lightness >= 0.5
                compare(ThemeMath.trayShadeAlpha(band, t), ThemeMath.trayShadeAlpha(grey(light ? 0 : 1), t),
                        s.key + " is held over the band's " + (light ? "low" : "high") + " end")
            }
        }

        function test_the_backdrop_and_a_dimmed_band() {
            for (const s of Themes.all) {
                const t = Themes.snapshot(s)
                const b = ThemeMath.backdropBand(t, t.defaultTint)
                verify(b.low >= 0 && b.low <= b.high && b.high <= 1, s.key + ": " + b.low + " .. " + b.high)
                verify(Math.abs(b.low - ThemeMath.luminance(t.background)) < 1e-6 || b.low < ThemeMath.luminance(t.background),
                       s.key + ": the ground is one of the samples")
            }
            const veiled = ThemeMath.bandUnder({ high: 1, low: 0 }, Qt.rgba(0, 0, 0, 1), 0.5)
            verify(veiled.high < 1 && veiled.high > 0.1, "a black veil at half darkens white: " + veiled.high)
            compare(veiled.low, 0, "and leaves black black")
            compare(ThemeMath.bandUnder({ high: 0.4, low: 0.2 }, Qt.rgba(0, 0, 0, 1), 0).high.toFixed(3), "0.400", "no veil, no change")
        }

        // --- ArtPalette.bandOf ------------------------------------------------------------------------

        function bandOf(source) {
            tryVerify(() => ArtPalette.bandOf(source).ok === true, 5000, source + " is measured")
            return ArtPalette.bandOf(source)
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
        }

        function test_one_decode_for_the_colours_and_the_band() {
            const source = fileUrl("brighttop")
            const before = ArtPalette.analysed
            compare(Object.keys(ArtPalette.bandOf(source)).length, 0, "not known yet")
            ArtPalette.colorsOf(source)
            tryVerify(() => ArtPalette.bandOf(source).ok === true, 5000)
            verify(ArtPalette.colorsOf(source).color !== undefined, "the colours came with it")
            wait(50)
            compare(ArtPalette.analysed, before + 1, "one picture, both measures: one analysis")
            for (let i = 0; i < 10; ++i)
                ArtPalette.bandOf(source)
            wait(50)
            compare(ArtPalette.analysed, before + 1, "asking again does not decode again")
        }

        function test_an_unreadable_picture_has_no_band() {
            const missing = artFixtures + "/no-such-band.png"
            compare(Object.keys(ArtPalette.bandOf(missing)).length, 0)
            wait(150)
            compare(Object.keys(ArtPalette.bandOf(missing)).length, 0, "it stays unknown")
        }

        // --- the shade in the shell ---------------------------------------------------------------------

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
        function settledOn(picture) {
            const shade = find("trayShade")
            tryVerify(() => shade.behind.source === picture && shade.band !== null, 5000,
                      picture + " is measured (behind " + shade.behind.kind + " " + shade.behind.source + ")")
            tryVerify(() => shade.alpha === shade.targetAlpha, 5000, "the shade has arrived")
            return shade.alpha
        }

        function test_the_shade_follows_the_hero() {
            signIn()
            const shade = find("trayShade")
            showHero(path("darktop"))
            compare(shade.behind.kind, "art")
            const overDark = settledOn(path("darktop"))
            showHero(path("brighttop"))
            const overBright = settledOn(path("brighttop"))
            verify(overDark < overBright, "a dark top needs less shade than a white one: " + overDark + " vs " + overBright)
            compare(overDark, 0, "over dark art it disappears: " + JSON.stringify(shade.band))
            compare(overBright, ThemeMath.trayShadeAlpha(ArtPalette.bandOf(path("brighttop")), Theme))
            compare(find("notificationBell").shade, shade.color, "the bell's glass takes the same shade")
            compare(find("bellGlass").shade, shade.color)
            compare(shade.color.a.toFixed(2), overBright.toFixed(2), "the drawn colour is the ground at that alpha")
            verify(Qt.colorEqual(Qt.rgba(shade.color.r, shade.color.g, shade.color.b, 1), Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 1)))
        }

        function test_unknown_art_gets_the_ceiling_then_its_value() {
            signIn()
            const shade = find("trayShade")
            showHero(path("brighttop"))
            settledOn(path("brighttop"))
            const fresh = fileUrl("darktop")       // a picture not measured yet
            showHero(fresh)
            compare(shade.band, null, "not measured yet")
            compare(shade.targetAlpha, Theme.trayShadeAlphaMax, "the ceiling while it is unknown")
            tryCompare(shade, "targetAlpha", 0, 5000, "then the measured value")
            // A picture that cannot be read keeps the ceiling.
            showHero(artFixtures + "/no-such-hero.png")
            wait(150)
            compare(shade.targetAlpha, Theme.trayShadeAlphaMax, "unreadable art: the ceiling")
            // An item without a picture is drawn as its placeholder: never measured, the ceiling.
            find("heroArt").show({ id: "test:none", title: "None", art: {} })
            compare(shade.behind.kind, "unknown")
            compare(shade.targetAlpha, Theme.trayShadeAlphaMax)
        }

        function openPage() {
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "games")
        }

        function test_a_page_takes_the_backdrop_or_the_wallpaper() {
            signIn()
            const shade = find("trayShade")
            showHero(path("brighttop"))
            settledOn(path("brighttop"))
            openPage()
            compare(shade.behind.kind, "backdrop", "a page without a wallpaper: the Backdrop")
            const band = ThemeMath.backdropBand(Themes.snapshot(Theme.shownSet), find("backdrop").tint)
            compare(shade.targetAlpha, ThemeMath.trayShadeAlpha(band, Theme))
            verify(shade.targetAlpha < Theme.trayShadeAlphaMax, "the dark Backdrop needs little: " + shade.targetAlpha)
            DeviceSettings.wallpaper = "daybreak"
            tryVerify(() => find("wallpaperLayer").has, 5000, "the wallpaper shows")
            compare(shade.behind.kind, "wallpaper")
            compare(shade.behind.source, find("wallpaperLayer").target)
            tryVerify(() => shade.band !== null, 5000, "the wallpaper is measured")
            const raw = ArtPalette.bandOf(find("wallpaperLayer").target)
            const dimmed = ThemeMath.bandUnder(raw, Theme.background, find("wallpaperLayer").effectiveDim)
            compare(shade.targetAlpha, ThemeMath.trayShadeAlpha(dimmed, Theme), "the wallpaper under its dim")
            verify(dimmed.high <= raw.high, "the dim only darkens")
        }

        function test_changes_animate_over_tintMs_and_jump_under_reduced_motion() {
            Theme.motionFactor = 1.0     // the subject is the duration
            signIn()
            const shade = find("trayShade")
            showHero(path("darktop"))
            settledOn(path("darktop"))
            showHero(path("brighttop"))
            settledOn(path("brighttop"))
            const from = shade.alpha
            verify(from > 0)
            showHero(path("darktop"))
            compare(shade.targetAlpha, 0)
            verify(shade.alpha > 0, "it does not jump: " + shade.alpha)
            tryVerify(() => shade.alpha > 0 && shade.alpha < from, 1000, "it moves from " + from + " towards 0")
            tryCompare(shade, "alpha", 0, Theme.tintMs + 1000, "and arrives")

            DeviceSettings.reducedMotion = true
            compare(Theme.tintMs, 0)
            showHero(path("brighttop"))
            compare(shade.alpha, shade.targetAlpha, "under reduced motion it jumps")
            verify(shade.alpha > 0)
            showHero(path("darktop"))
            compare(shade.alpha, 0, "both ways")
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
            for (const hero of [["dark", path("dark")], ["bright", path("white")]]) {
                showHero(hero[1])
                settledOn(hero[1])
                wait(500)
                grabImage(tc.shell).save(shotsDir + "/trayshade-" + data.theme + "-" + data.size + "-" + hero[0] + ".png")
            }
        }
    }
}
