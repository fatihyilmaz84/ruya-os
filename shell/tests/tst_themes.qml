import QtQuick
import QtTest
import RuyaShell

// Colour themes (04 §3.1, T-209): the sets, switching at run time with a cross-fade, what a theme
// must not change, and the Theme row of Settings -> Display & motion. The contrast gate is in
// tst_theme_contrast.qml; the pictures are in the screenshot functions at the end.
// Signs in as "Ada" (p2, no PIN) with controller keys. DeviceSettings is in memory under test.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }
    Component { id: backdropComponent; Backdrop { anchors.fill: parent } }

    TestCase {
        id: tc
        name: "Themes"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        function same(a, b, msg) { verify(Qt.colorEqual(a, b), (msg ?? "colour") + ": " + a + " vs " + b) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = true      // switches are immediate unless a test wants the fade
            DeviceSettings.theme = "dreamglass"
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.theme = "dreamglass"
        }

        // --- the sets ---

        function test_there_are_five_themes_and_the_lists_agree() {
            compare(Themes.keys, ["dreamglass", "midnight", "aurora", "ember", "daylight"])
            compare(DeviceSettings.availableThemes, Themes.keys, "the C++ list and the QML sets agree")
            compare(Themes.defaultKey, "dreamglass")
            compare(DeviceSettings.theme, "dreamglass", "Dreamglass is the default")
            compare(Themes.byKey("nonsense").key, "dreamglass", "an unknown key means the default")
        }

        function isNumber(name) {
            return ["lightness", "blobStrength", "blobTintShare", "shadowStrength", "artLightTop", "artLightBottom"].indexOf(name) >= 0
        }

        function test_every_theme_defines_every_token() {
            const names = Themes.tokenNames
            compare(new Set(names).size, names.length, "no token is listed twice")
            verify(names.length >= 40, "tokens: " + names.length)
            for (let i = 0; i < Themes.all.length; ++i) {
                const set = Themes.all[i]
                verify(set.label.length > 0, set.key + " has a label")
                for (let k = 0; k < names.length; ++k) {
                    const v = set[names[k]]
                    if (isNumber(names[k]))
                        verify(typeof v === "number" && !isNaN(v), set.key + "." + names[k] + " is a number: " + v)
                    else
                        verify(v !== undefined && v.a !== undefined && !isNaN(v.r), set.key + "." + names[k] + " is a colour: " + v)
                }
            }
            // No two themes are the same palette.
            for (let i = 0; i < Themes.all.length; ++i) {
                for (let j = i + 1; j < Themes.all.length; ++j) {
                    verify(Themes.all[i].background !== Themes.all[j].background
                           || Themes.all[i].text !== Themes.all[j].text
                           || Themes.all[i].glass !== Themes.all[j].glass,
                           Themes.all[i].key + " and " + Themes.all[j].key + " differ")
                }
            }
        }

        function test_theme_follows_the_set_data() {
            return Themes.all.map(s => ({ tag: s.key, key: s.key }))
        }
        function test_theme_follows_the_set(data) {
            const set = Themes.byKey(data.key)
            DeviceSettings.theme = data.key
            compare(Theme.themeKey, data.key)
            const names = Themes.tokenNames
            for (let i = 0; i < names.length; ++i) {
                const name = names[i]
                if (isNumber(name) || name.indexOf("tile") === 0)
                    continue
                same(Theme[name], set[name], "Theme." + name + " in " + data.key)
            }
            compare(Theme.lightness, set.lightness)
            compare(Theme.lightTheme, set.lightness >= 0.5)
            same(Theme.tileAccent("games"), set.tileGames)
            same(Theme.tileAccent("media"), set.tileMedia)
            same(Theme.tileAccent("store"), set.tileStore)
            same(Theme.tileAccent("settings"), set.tileSettings)
            same(Theme.tileAccent("power"), set.tileOther)
            fuzzyCompare(Theme.blobOpacityA, 0.55 * set.blobStrength, 1e-9)
            fuzzyCompare(Theme.blobOpacityB, 0.35 * set.blobStrength, 1e-9)
            fuzzyCompare(Theme.blobOpacityC, 0.08 * set.blobStrength, 1e-9)
            fuzzyCompare(Theme.shadowLift.alpha, 0.60 * set.shadowStrength, 1e-9)
            fuzzyCompare(Theme.shadowPanel.alpha, 0.35 * set.shadowStrength, 1e-9)
            fuzzyCompare(Theme.shadowPill.alpha, 0.27 * set.shadowStrength, 1e-9)
            fuzzyCompare(Theme.artTop(0.3).hslLightness, set.artLightTop, 0.01)
            fuzzyCompare(Theme.artBottom(0.3).hslLightness, set.artLightBottom, 0.01)
            // The clear ends of the fades keep the colour and drop the alpha.
            compare(Theme.heroScrimClear.a, 0)
            fuzzyCompare(Theme.heroScrimClear.r, set.heroScrim.r, 0.01)
            fuzzyCompare(Theme.artCaptionFadeClear.b, set.artCaptionFade.b, 0.01)
        }

        function test_dreamglass_is_todays_palette() {
            same(Theme.background, "#05070d")
            same(Theme.text, "#f2f4f8")
            same(Theme.textDim, "#a3abbd")
            same(Theme.glass, "#1fffffff")
            same(Theme.glassOpaque, "#e6182033")
            same(Theme.panel, "#1a1d26")
            same(Theme.primaryFill, "#f2f4f8")
            same(Theme.onPrimary, "#05070d")
            same(Theme.dangerFill, "#8f2d2d")
            same(Theme.focusRing, "#ffffff")
            same(Theme.defaultTint, "#3a5bd9")
            same(Theme.tileAccent("store"), "#2fa37a")
            same(Theme.toastBackground, "#f0161a24")
            compare(Theme.shadowLift.alpha, 0.60)
            fuzzyCompare(Theme.glassTint.a, 0.44, 0.001)
        }

        // What no theme may change: sizes, type, motion, the ring width, the white art effects.
        function nonThemeable() {
            return [Theme.typeBody, Theme.typeHero, Theme.typeCaption, Theme.spaceM, Theme.radiusM, Theme.radiusL,
                    Theme.rowHeight, Theme.buttonHeight, Theme.tileWidth, Theme.avatarSize, Theme.focusRingWidth,
                    Theme.focusRingOffset, Theme.focusScale, Theme.hairline, Theme.badgeFillAlpha,
                    Theme.focusMs, Theme.pageMs, Theme.tintMs, Theme.overlayMs, Theme.glareMs, Theme.pageSlide,
                    Theme.disabledOpacity, Theme.peekOpacity, Theme.popOvershoot, Theme.glassSheenSpan,
                    Theme.cardSheenSpan, Theme.glassGrainOpacity, Theme.blurMax, Theme.shadowLift.offsetY,
                    Theme.shadowLift.blur, Theme.shadowPanel.offsetY, Theme.shadowPill.blurMax,
                    Theme.fontFamily, Theme.weightDemiBold, Theme.easeGlide.join(","), Theme.easeSnap.join(","),
                    Theme.cardSheen.toString(), Theme.glarePeak.toString(), Theme.shimmerPeak.toString(),
                    Theme.glassSheenEnd.toString(), Theme.safeArea, Theme.motionScale,
                    Theme.saverGround.toString(), Theme.saverText.toString(), Theme.saverArtOpacity,
                    Theme.saverFadeMs, Theme.saverDriftMs, Theme.saverZoomMs, Theme.saverSlideMs]
        }

        // The screen saver (T-202, 04 §3.1): near black in every theme, Daylight included, with a
        // clock that reads on it and on pure-white art at the 30 % dim.
        function test_the_saver_ground_is_near_black_in_every_theme_and_its_clock_reads() {
            for (let i = 0; i < Themes.all.length; ++i) {
                DeviceSettings.theme = Themes.all[i].key
                const key = Themes.all[i].key
                verify(ThemeMath.luminance(Theme.saverGround) < 0.02, "saver ground luminance in " + key)
                verify(ThemeMath.contrast(Theme.saverText, Theme.saverGround) >= 4.5, "clock on the ground in " + key)
                const whiteArt = ThemeMath.over(Qt.rgba(1, 1, 1, Theme.saverArtOpacity), Theme.saverGround)
                verify(ThemeMath.contrast(Theme.saverText, whiteArt) >= 4.5, "clock on white art at the dim in " + key)
            }
        }
        function test_non_themeable_tokens_are_identical_in_every_theme() {
            const reference = nonThemeable()
            verify(reference.length > 35, "tokens compared: " + reference.length)
            for (let i = 0; i < Themes.all.length; ++i) {
                DeviceSettings.theme = Themes.all[i].key
                compare(nonThemeable(), reference, "non-themeable tokens in " + Themes.all[i].key)
            }
        }

        // --- switching ---

        function test_reduced_motion_switches_without_a_fade() {
            compare(Theme.tintMs, 0)
            DeviceSettings.theme = "daylight"
            compare(Theme.mix, 1)
            verify(!Theme.fade.running, "no fade runs")
            same(Theme.background, Themes.byKey("daylight").background, "the new look is there at once")
            DeviceSettings.theme = "midnight"
            same(Theme.background, "#000000")
        }

        function test_switch_cross_fades_over_tintMs() {
            DeviceSettings.reducedMotion = false
            compare(Theme.tintMs, 700)
            const from = Theme.background
            DeviceSettings.theme = "daylight"
            verify(Theme.fade.running, "a fade is running")
            verify(Theme.mix < 1)
            // At the start the old look is still there, and the look moves monotonically towards the new one.
            const start = ThemeMath.luminance(Theme.background)
            verify(Math.abs(start - ThemeMath.luminance(from)) < 0.05, "starts from the old look")
            tryVerify(() => Theme.mix > 0.4 && Theme.mix < 0.95, 1500, "mid-fade")
            const mid = ThemeMath.luminance(Theme.background)
            verify(mid > start && mid < ThemeMath.luminance(Themes.byKey("daylight").background),
                   "the ground is between the two looks mid-fade: " + mid)
            tryCompare(Theme, "mix", 1, 3000)
            same(Theme.background, Themes.byKey("daylight").background)
            tryVerify(function () { return !Theme.fade.running }, 2000)
        }

        function test_switch_in_mid_fade_starts_from_what_is_shown() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.theme = "daylight"
            tryVerify(() => Theme.mix > 0.3, 1500)
            const shown = ThemeMath.luminance(Theme.background)
            DeviceSettings.theme = "midnight"
            verify(Math.abs(ThemeMath.luminance(Theme.background) - shown) < 0.05, "no jump when the target changes")
            tryCompare(Theme, "mix", 1, 3000)
            same(Theme.background, "#000000")
        }

        function test_invalid_theme_is_rejected() {
            DeviceSettings.theme = "aurora"
            ignoreWarning(/rejecting invalid theme/)
            DeviceSettings.theme = "neon"
            compare(DeviceSettings.theme, "aurora")
            compare(Theme.themeKey, "aurora")
        }

        function test_theme_persists() {
            compare(themePersistence, "", "a restart keeps the theme, a bad stored value falls back: " + themePersistence)
        }

        function test_backdrop_follows_the_theme() {
            const tint = Qt.color("#3a5bd9")
            const dark = ThemeMath.luminance(Theme.backdropTop(tint))
            DeviceSettings.theme = "daylight"
            const light = ThemeMath.luminance(Theme.backdropTop(tint))
            verify(light > 0.5 && dark < 0.1, "dark theme top " + dark + ", Daylight top " + light)
            // The Backdrop item itself reads the tokens (gradient top and the three blobs).
            const backdrop = createTemporaryObject(backdropComponent, host, { tint: tint })
            verify(backdrop)
            const top = findChild(backdrop, "backdropGradient").gradient.stops[0].color
            same(top, Theme.backdropTop(tint), "the gradient top in Daylight")
            DeviceSettings.theme = "midnight"
            fuzzyCompare(Theme.blobOpacityA, 0.55 * 0.4, 1e-9)
            fuzzyCompare(findChild(backdrop, "blobA").opacity, 0.55 * 0.4, 1e-6)
            fuzzyCompare(findChild(backdrop, "blobB").opacity, 0.35 * 0.4, 1e-6)
            fuzzyCompare(findChild(backdrop, "blobC").opacity, 0.08 * 0.4, 1e-6)
            DeviceSettings.theme = "dreamglass"
            compare(Theme.blobOpacityA, 0.55)
            fuzzyCompare(findChild(backdrop, "blobA").opacity, 0.55, 1e-6)
            same(findChild(backdrop, "backdropGradient").gradient.stops[0].color, Qt.darker(tint, 3.2), "Dreamglass keeps its darkened tint")
            same(findChild(backdrop, "blobA").color, tint, "Dreamglass: the blob is the profile's tint")
            same(findChild(backdrop, "blobB").color, Qt.lighter(tint, 1.4), "Dreamglass: the second blob is the tint, lighter")
        }

        // T-271: a dark theme other than Dreamglass builds the blobs and the gradient from its own
        // colours, with the profile's tint mixed in at blobTintShare: the blobs of two very different
        // profile colours are close, and neither is the tint itself.
        function test_blob_colours_belong_to_the_theme_not_the_profile_tint() {
            const orange = Qt.color("#e8833a")
            const blue = Qt.color("#3a5bd9")
            const a = createTemporaryObject(backdropComponent, host, { tint: orange })
            const b = createTemporaryObject(backdropComponent, host, { tint: blue })
            verify(a && b)
            for (const key of ["midnight", "aurora", "ember"]) {
                DeviceSettings.theme = key
                const set = Themes.byKey(key)
                verify(set.blobTintShare > 0 && set.blobTintShare <= 0.25, key + " share " + set.blobTintShare)
                const ca = findChild(a, "blobA").color
                const cb = findChild(b, "blobA").color
                const apart = ThemeMath.deltaE(orange, blue)
                verify(ThemeMath.deltaE(ca, cb) < apart * set.blobTintShare * 1.2,
                       key + ": blob A of two tints is " + ThemeMath.deltaE(ca, cb) + " apart, the tints " + apart)
                same(ca, ThemeMath.blend(set.blobA, orange, set.blobTintShare), key + " blob A")
                same(findChild(a, "backdropGradient").gradient.stops[0].color,
                     Theme.backdropTop(ThemeMath.blend(set.blobA, orange, set.blobTintShare)), key + " gradient top")
                same(findChild(a, "blobC").color, set.blobHighlight, key + " third blob")
            }
            DeviceSettings.theme = "dreamglass"
            same(findChild(a, "blobA").color, orange, "Dreamglass follows the tint completely")
        }

        // The new blob tokens cross-fade with the rest (700 ms, T-209): mid-fade between two themes the
        // share and the palette are between the two, and the Backdrop's blob colour follows.
        function test_blob_tokens_cross_fade() {
            DeviceSettings.reducedMotion = false
            const tint = Qt.color("#e8833a")
            const backdrop = createTemporaryObject(backdropComponent, host, { tint: tint })
            verify(backdrop)
            same(findChild(backdrop, "blobA").color, tint, "Dreamglass: the tint")
            const aurora = Themes.byKey("aurora")
            DeviceSettings.theme = "aurora"
            verify(Theme.fade.running, "a fade is running")
            tryVerify(() => Theme.mix > 0.3 && Theme.mix < 0.8, 1500, "mid-fade")
            verify(Theme.blobTintShare < 1 && Theme.blobTintShare > aurora.blobTintShare, "share mid-fade: " + Theme.blobTintShare)
            verify(ThemeMath.deltaE(findChild(backdrop, "blobA").color, tint) > 0, "the blob already left the tint")
            tryCompare(Theme, "mix", 1, 3000)
            fuzzyCompare(Theme.blobTintShare, aurora.blobTintShare, 1e-9)
            same(findChild(backdrop, "blobA").color, ThemeMath.blend(aurora.blobA, tint, aurora.blobTintShare), "Aurora's blob at the end")
        }

        // --- distinctness (T-271) ---

        // Four colours make a theme recognisable (ThemeMath.lookColors: the ground, the opaque glass,
        // the backdrop blobs overlapping, the accent). Two themes must differ in at least
        // `keysApart` of the four by `minDeltaE` (CIE76; 10 reads as another colour at a glance), and
        // in total by `minTotal`. One key may stay close: Dreamglass and Midnight both have a white-ish
        // accent. A pair cannot be flattened by editing one colour, nor two.
        readonly property real minDeltaE: 10
        readonly property int keysApart: 3
        readonly property real minTotal: 80
        readonly property var lookKeys: ["ground", "glass", "blobs", "accent"]

        function apartKeys(a, b) {
            const la = ThemeMath.lookColors(Themes.snapshot(a))
            const lb = ThemeMath.lookColors(Themes.snapshot(b))
            const out = { keys: [], total: 0, text: [] }
            for (const k of lookKeys) {
                const d = ThemeMath.deltaE(la[k], lb[k])
                out.total += d
                out.text.push(k + " " + d.toFixed(1))
                if (d >= minDeltaE)
                    out.keys.push(k)
            }
            return out
        }

        function test_themes_are_pairwise_distinct() {
            for (let i = 0; i < Themes.all.length; ++i) {
                for (let j = i + 1; j < Themes.all.length; ++j) {
                    const r = apartKeys(Themes.all[i], Themes.all[j])
                    const name = Themes.all[i].key + " / " + Themes.all[j].key + ": " + r.text.join(", ")
                    verify(r.keys.length >= keysApart, name + " (need " + keysApart + " keys >= " + minDeltaE + ")")
                    verify(r.total >= minTotal, name + " (total " + r.total.toFixed(1) + " < " + minTotal + ")")
                }
            }
        }

        // The measure can fail: two themes made alike on their ground and blobs are caught.
        function test_distinctness_measure_catches_a_flattened_theme() {
            const aurora = Themes.snapshot(Themes.byKey("aurora"))
            const ember = Themes.snapshot(Themes.byKey("ember"))
            const flat = Themes.snapshot(Themes.byKey("ember"))
            for (const n of ["background", "blobA", "blobB", "blobHighlight", "glassOpaque"])
                flat[n] = aurora[n]
            const la = ThemeMath.lookColors(aurora)
            const lf = ThemeMath.lookColors(flat)
            for (const k of ["ground", "glass", "blobs"])
                verify(ThemeMath.deltaE(la[k], lf[k]) < minDeltaE, k + " of the flattened Ember is Aurora's")
            verify(ThemeMath.deltaE(ThemeMath.lookColors(ember).ground, la.ground) >= minDeltaE, "the real ones differ")
            compare(ThemeMath.deltaE(la.ground, la.ground), 0)
            verify(ThemeMath.deltaE(Qt.color("#000000"), Qt.color("#ffffff")) > 99, "black to white is about 100")
        }

        // Reduced motion switched on in the middle of a fade finishes it at once.
        function test_reduced_motion_during_a_fade_finishes_it() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.theme = "ember"
            verify(Theme.fade.running)
            DeviceSettings.reducedMotion = true
            compare(Theme.mix, 1)
            verify(!Theme.fade.running)
            same(Theme.background, Themes.byKey("ember").background)
        }

        // --- the Settings row, with the shell running ---

        function signIn() {
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
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function openThemeRow() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList") !== null && find("categoryList").activeFocus, 2000, "category list has focus")
            const list = find("categoryList")
            for (let i = 0; i < 20 && list.currentIndex < 3; ++i)
                keyClick(Qt.Key_Down)
            compare(list.currentIndex, 3, "Display & motion")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => find("rowTheme").activeFocus, 2000, "the Theme row is the last row of the pane")
        }

        function test_theme_row_switches_the_screens_in_place_and_keeps_focus() {
            signIn()
            openThemeRow()
            const row = find("rowTheme")
            compare(row.currentLabel, "Dreamglass")
            compare(row.accessibleValue, "Dreamglass")
            same(find("chipGround").color, Themes.byKey("dreamglass").background)
            same(find("chipTint").color, Themes.byKey("dreamglass").defaultTint)
            verify(find("themeChips").x + find("themeChips").width < row.valueText.x, "the chips sit before the value")

            const labelBefore = findChild(row, "label").color
            same(labelBefore, Themes.byKey("dreamglass").text)

            keyClick(Qt.Key_Right)                       // -> Midnight
            compare(DeviceSettings.theme, "midnight")
            compare(row.currentLabel, "Midnight")
            verify(find("rowTheme").activeFocus, "focus stays on the row")
            same(find("chipGround").color, "#000000", "the chips show the option shown")

            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)                   // Aurora, Ember, Daylight
            compare(DeviceSettings.theme, "daylight")
            compare(row.currentLabel, "Daylight")
            verify(find("rowTheme").activeFocus, "focus stays on the row after four switches")
            same(findChild(row, "label").color, "#0f1420", "the label read the new text colour")
            same(Theme.text, "#0f1420")

            keyClick(Qt.Key_Right)                       // wraps to Dreamglass
            compare(DeviceSettings.theme, "dreamglass")
            verify(find("rowTheme").activeFocus)
            compare(Theme.mix, 1, "no fade is running under reduced motion")
            same(Theme.text, "#f2f4f8", "Theme.text after wrapping to Dreamglass")
            same(findChild(row, "label").color, "#f2f4f8", "the label after wrapping to Dreamglass")

            keyClick(Qt.Key_Left)                        // and back, the other way
            compare(DeviceSettings.theme, "daylight")

            keyClick(Qt.Key_Escape)                      // Back leaves the pane
            tryVerify(() => find("categoryList").activeFocus, 2000, "Back returns to the category list")
            compare(DeviceSettings.theme, "daylight")
        }

        function test_theme_row_follows_the_setting() {
            signIn()
            openThemeRow()
            DeviceSettings.theme = "ember"               // changed elsewhere
            tryCompare(find("rowTheme"), "value", "ember")
            compare(find("rowTheme").currentLabel, "Ember")
            verify(find("rowTheme").activeFocus)
        }

        // The picker (before anyone signs in) uses the stored device theme.
        function test_picker_uses_the_stored_theme() {
            DeviceSettings.theme = "daylight"
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            same(Theme.background, "#eef1f7")
            same(Theme.focusRing, "#0f1420")
        }

        // --- screenshots (dev.ps1 shots): the picker, a PIN pad (modal), Home, the Guide overlay and the
        // Theme row of Settings in each theme, read against 04 §8 ---

        function test_zz_screenshots_themes_data() {
            return Themes.all.map(s => ({ tag: s.key, key: s.key }))
        }
        function test_zz_screenshots_themes(data) {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.theme = data.key
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/t209-" + data.key + "-1-picker.png")

            keyClick(Qt.Key_Return)                      // Player One has a PIN: the pad is a modal
            tryVerify(() => find("pinPad").shown, 2000, "the PIN pad opens")
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/t209-" + data.key + "-2-pin.png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("profileList").activeFocus, 2000, "back on the picker")

            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/t209-" + data.key + "-3-home.png")

            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Guide overlay opens")
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/t209-" + data.key + "-4-guide.png")
            keyClick(Qt.Key_HomePage)
            tryCompare(find("systemPanel"), "open", false)
            tryVerify(() => find("homePlay").activeFocus, 2000, "the Guide closes, focus back on Play")

            openThemeRow()
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/t209-" + data.key + "-5-settings.png")
        }
    }
}
