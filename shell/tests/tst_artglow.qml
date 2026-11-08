import QtQuick
import QtTest
import RuyaShell

// The art glow (T-281, 04 §3.8) and the card family (04 §5): the colours ArtPalette takes from a
// picture, the focused card's shadow taking them (and fading between cards), the High-tier halo,
// and the sizes of every card kind. Offscreen is the software renderer, so these assert properties,
// never pixels; the look is in the screenshots (`dev.ps1 shots`, last tests).
Item {
    id: host
    width: 1280
    height: 720

    Component { id: cardComponent; ArtCard { itemId: "steam:620"; title: "Portal 2"; width: 320 } }
    Component { id: bareCardComponent; ArtCard { itemId: "steam:620"; title: "Portal 2" } }
    Component { id: shadowComponent; GlassShadow { width: 300; height: 100; radius: 50 } }
    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }
    Component {
        id: shell720Component
        Shell { width: 1280; height: 720; version: "test"; focus: true }   // a real 720p screen, whatever the test window is
    }
    Component {
        id: shell450Component
        Shell { width: 1280; height: 450; version: "test"; focus: true }   // a short screen: the hint bar is close to the content
    }
    Component {
        id: shell1080Component
        Shell { width: 1920; height: 1080; version: "test"; focus: true }
    }
    Component {
        id: galleryComponent
        // Six cards that all glow at once, to see the colour families side by side.
        Rectangle {
            id: gallery
            width: 1280; height: 720
            color: Theme.background
            readonly property var names: ["red", "blue", "green", "white", "dark", "redblue"]
            Repeater {
                model: gallery.names
                ArtCard {
                    required property int index
                    required property string modelData
                    objectName: "gallery_" + modelData
                    x: 64 + (index % 3) * 408
                    y: 60 + Math.floor(index / 3) * 330
                    width: Theme.cardWidthHero * 0.9
                    itemId: "gallery:" + modelData
                    title: modelData
                    picture: artFixtures + "/" + modelData + ".png"
                    focused: true
                }
            }
        }
    }

    TestCase {
        id: tc
        name: "ArtGlow"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            GlareGate.reset()
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.theme = "dreamglass"
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.theme = "dreamglass"
            GlareGate.reset()
        }

        function path(name) { return artFixtures + "/" + name + ".png" }
        // The same picture under another cache key: a file URL (a Windows drive path needs three slashes).
        function fileUrl(name) { return path(name).startsWith("/") ? "file://" + path(name) : "file:///" + path(name) }

        // The colours of a fixture picture, waiting for the background analysis.
        function colorsOf(name) {
            tryVerify(() => ArtPalette.colorsOf(path(name)).color !== undefined, 5000, name + " is analysed")
            return ArtPalette.colorsOf(path(name))
        }

        // Hue distance on the 0..1 circle.
        function hueGap(a, b) {
            const d = Math.abs(a - b)
            return Math.min(d, 1 - d)
        }

        function near(a, b, eps) {
            return Math.abs(a.r - b.r) < eps && Math.abs(a.g - b.g) < eps && Math.abs(a.b - b.b) < eps
        }

        // --- the sampler -----------------------------------------------------------------------

        function test_fixtures_exist() {
            verify(artFixtures.length > 0, "tst_main writes the pictures")
        }

        function test_colour_families() {
            const red = colorsOf("red")
            verify(hueGap(red.color.hslHue, 0) < 0.04, "red is red: " + red.color.hslHue)
            const blue = colorsOf("blue")
            verify(hueGap(blue.color.hslHue, 0.62) < 0.05, "blue is blue: " + blue.color.hslHue)
            const green = colorsOf("green")
            verify(hueGap(green.color.hslHue, 0.37) < 0.05, "green is green: " + green.color.hslHue)
            const darkRed = colorsOf("darkred")
            verify(hueGap(darkRed.color.hslHue, 0) < 0.04, "a very dark red is still red")
            for (const c of [red, blue, green, darkRed])
                compare(c.neutral, false)
        }

        function test_white_grey_and_black_are_neutral() {
            for (const name of ["white", "grey", "dark"]) {
                const c = colorsOf(name)
                compare(c.neutral, true, name + " has no dominant hue")
                verify(c.color.hslSaturation < 0.01, name + " glow is a grey: " + c.color.hslSaturation)
                verify(c.strength <= 0.6 + 1e-6, name + " neutral glow is capped: " + c.strength)
            }
        }

        function test_a_very_dark_picture_glows_faintly() {
            const dark = colorsOf("dark")
            const darkRed = colorsOf("darkred")
            const red = colorsOf("red")
            verify(dark.strength < 0.3, "black: " + dark.strength)
            verify(darkRed.strength < 0.4, "very dark red: " + darkRed.strength)
            verify(red.strength > 0.8, "a bright red: " + red.strength)
            verify(red.strength > darkRed.strength && darkRed.strength >= dark.strength - 1e-6)
        }

        function test_output_is_bounded() {
            for (const name of ["red", "blue", "green", "white", "dark", "grey", "pastel", "darkred", "redblue"]) {
                const c = colorsOf(name)
                for (const col of [c.color, c.secondary]) {
                    verify(col.hslLightness >= 0.40 - 0.01 && col.hslLightness <= 0.60 + 0.01,
                           name + " lightness " + col.hslLightness)
                    verify(col.hslSaturation <= 0.90 + 0.01, name + " saturation " + col.hslSaturation)
                }
                verify(c.strength >= 0.2 - 1e-6 && c.strength <= 1 + 1e-6, name + " strength " + c.strength)
            }
        }

        function test_two_colour_picture_gives_two_colours() {
            const c = colorsOf("redblue")
            verify(hueGap(c.color.hslHue, c.secondary.hslHue) > 0.3,
                   "primary and secondary are different families: " + c.color.hslHue + " " + c.secondary.hslHue)
            const hues = [c.color.hslHue, c.secondary.hslHue]
            verify(hues.some(h => hueGap(h, 0) < 0.05), "one is red")
            verify(hues.some(h => hueGap(h, 0.64) < 0.06), "one is blue")
            const single = colorsOf("red")
            verify(near(single.color, single.secondary, 0.001), "a one-colour picture repeats its colour")
        }

        function test_each_picture_is_analysed_once() {
            colorsOf("green")
            const before = ArtPalette.analysed
            for (let i = 0; i < 20; ++i)
                ArtPalette.colorsOf(path("green"))
            wait(50)
            compare(ArtPalette.analysed, before, "asking again does not decode again")
            // The same picture on many cards: still one analysis.
            for (let i = 0; i < 5; ++i)
                createTemporaryObject(cardComponent, host, { picture: path("pastel") })
            tryVerify(() => ArtPalette.colorsOf(path("pastel")).color !== undefined, 5000)
            compare(ArtPalette.analysed, before + 1, "five cards, one picture: one analysis")
            verify(ArtPalette.lastAnalyseUs >= 0)
            // The cost is told in the Outcome; it must stay far below a frame (16 ms = 16000 us).
            verify(ArtPalette.lastAnalyseUs < 16000, "analysis took " + ArtPalette.lastAnalyseUs + " us")
        }

        function test_an_unreadable_picture_stays_empty() {
            const before = ArtPalette.analysed
            const missing = artFixtures + "/does-not-exist.png"
            compare(Object.keys(ArtPalette.colorsOf(missing)).length, 0)
            wait(150)
            compare(Object.keys(ArtPalette.colorsOf(missing)).length, 0)
            compare(ArtPalette.analysed, before)
            const card = createTemporaryObject(cardComponent, host, { picture: missing })
            const art = findChild(card, "artMonogram").parent
            wait(100)
            compare(art.sampled, false)
            compare(art.glowColor, Theme.glowFallback(art.hue), "it keeps the placeholder's colour")
        }

        // --- the glow on the card --------------------------------------------------------------

        function artOf(card) { return findChild(card, "artMonogram").parent }
        function shadowOf(card) { return findChild(card, "cardLiftShadow") }

        function test_card_without_a_picture_glows_in_its_placeholder_hue() {
            const card = createTemporaryObject(cardComponent, host)
            const art = artOf(card)
            compare(art.sampled, false)
            compare(art.glowColor, Theme.glowFallback(art.hue))
            compare(art.glowStrength, Theme.glowFallbackStrength)
            const other = createTemporaryObject(cardComponent, host, { itemId: "steam:730" })
            verify(!near(art.glowColor, artOf(other).glowColor, 0.01), "another id, another placeholder glow")
        }

        function test_the_card_takes_the_colours_of_its_picture() {
            const card = createTemporaryObject(cardComponent, host, { picture: path("blue") })
            const art = artOf(card)
            tryVerify(() => art.sampled, 5000)
            verify(hueGap(art.glowColor.hslHue, 0.62) < 0.05)
            const sampled = colorsOf("blue")
            compare(art.glowStrength, sampled.strength)
            // A new picture on the same card is read again.
            card.picture = path("green")
            tryVerify(() => hueGap(art.glowColor.hslHue, 0.37) < 0.05, 5000)
        }

        function test_the_shadow_of_the_focused_card_is_the_sampled_colour() {
            const card = createTemporaryObject(cardComponent, host, { picture: path("red") })
            const art = artOf(card)
            const shadow = shadowOf(card)
            tryVerify(() => art.sampled, 5000)
            compare(shadow.glowMix, 0, "no glow at rest")
            verify(near(shadow.tint, Theme.shadowColor, 0.001), "the neutral shadow at rest")
            card.focused = true
            tryCompare(shadow, "glowMix", 1, 3000)
            tryVerify(() => near(shadow.glow, art.glowColor, 0.01), 3000, "the shadow's glow is the sampled colour")
            const expected = Theme.glowShadow(art.glowColor, art.glowStrength)
            verify(near(shadow.tint, expected, 0.01), "tint is " + shadow.tint + ", expected " + expected)
            verify(hueGap(shadow.tint.hslHue, art.glowColor.hslHue) < 0.02, "same hue as the picture")
            verify(!near(shadow.tint, Theme.shadowColor, 0.05), "and not the neutral shadow")
            compare(shadow.shown, true)
        }

        function test_the_glow_crosses_over_to_the_next_card() {
            const a = createTemporaryObject(cardComponent, host, { picture: path("red") })
            const b = createTemporaryObject(cardComponent, host, { picture: path("blue"), itemId: "steam:730" })
            tryVerify(() => artOf(a).sampled && artOf(b).sampled, 5000)
            a.focused = true
            tryCompare(shadowOf(a), "glowMix", 1, 3000)
            a.focused = false
            b.focused = true
            verify(Theme.tintMs > 0)
            verify(shadowOf(b).glowMix < 1, "the new card's glow is on its way: " + shadowOf(b).glowMix)
            tryCompare(shadowOf(b), "glowMix", 1, 3000)
            tryCompare(shadowOf(a), "glowMix", 0, 3000)
            verify(near(shadowOf(b).tint, Theme.glowShadow(artOf(b).glowColor, artOf(b).glowStrength), 0.01))
            verify(near(shadowOf(a).tint, Theme.shadowColor, 0.01), "the old card is neutral again")
            verify(hueGap(shadowOf(b).tint.hslHue, 0.62) < 0.05, "blue, not red")
        }

        function test_no_fade_under_reduced_motion() {
            DeviceSettings.reducedMotion = true
            compare(Theme.tintMs, 0)
            const card = createTemporaryObject(cardComponent, host, { picture: path("red") })
            tryVerify(() => artOf(card).sampled, 5000)
            const shadow = shadowOf(card)
            card.focused = true
            compare(shadow.glowMix, 1, "the tint is there at once")
            verify(near(shadow.tint, Theme.glowShadow(artOf(card).glowColor, artOf(card).glowStrength), 0.01))
            card.focused = false
            compare(shadow.glowMix, 0, "and gone at once")
        }

        function test_halo_per_tier() {
            const card = createTemporaryObject(cardComponent, host, { picture: path("red"), focused: true })
            const shadow = shadowOf(card)
            const halo = findChild(card, "haloEffect")
            verify(halo)
            compare(shadow.haloShown, true, "High draws the halo")
            compare(halo.visible, true)
            verify(shadow.haloBlurPx > shadow.blurPx, "wider and softer than the lift shadow")
            DeviceSettings.effectsQuality = "balanced"
            compare(shadow.shown, true, "Balanced keeps the tinted lift shadow")
            compare(shadow.haloShown, false, "but not the halo")
            compare(halo.visible, false)
            DeviceSettings.effectsQuality = "performance"
            compare(shadow.shown, false, "Performance has no shadow ...")
            compare(shadow.haloShown, false, "... and no halo")
            compare(halo.visible, false)
        }

        function test_a_plain_shadow_has_no_halo() {
            const plain = createTemporaryObject(shadowComponent, host)
            verify(plain)
            compare(plain.haloShown, false)
            compare(plain.glowMix, 0)
            compare(plain.alpha, plain.spec.alpha, "a neutral shadow keeps its numbers")
            plain.glowStrength = 1
            plain.halo = false
            compare(plain.haloShown, false, "no halo unless the owner asks for one")
        }

        function test_daylight_glow_is_darker_more_saturated_and_louder() {
            const red = Qt.rgba(0.85, 0.2, 0.2, 1)
            DeviceSettings.reducedMotion = true
            DeviceSettings.theme = "dreamglass"
            tryCompare(Theme, "lightness", 0)
            compare(Theme.glowBoost, 1)
            const night = Theme.glowShadow(red, 1)
            verify(hueGap(night.hslHue, red.hslHue) < 0.02, "on a dark theme the glow is the art colour mixed toward black")
            DeviceSettings.theme = "daylight"
            tryCompare(Theme, "lightness", 1)
            const day = Theme.glowShadow(red, 1)
            // What the glow would be without the light-theme treatment: the plain mix toward the shadow colour.
            const plain = ThemeMath.blend(Theme.shadowColor, red, Theme.glowShare)
            verify(day.hslLightness < plain.hslLightness - 0.03,
                   "the art colour is darkened on the pale ground: " + day.hslLightness + " vs " + plain.hslLightness)
            verify(day.hslSaturation > plain.hslSaturation + 0.1,
                   "and more saturated, so it reads coloured and not grey: " + day.hslSaturation + " vs " + plain.hslSaturation)
            verify(hueGap(day.hslHue, red.hslHue) < 0.03, "and keeps its hue")
            compare(Theme.glowBoost, 1 + 1.5 * Theme.lightness)
            const card = createTemporaryObject(cardComponent, host, { picture: path("red"), focused: true })
            const shadow = shadowOf(card)
            tryVerify(() => artOf(card).sampled, 5000)
            tryCompare(shadow, "glowMix", 1)
            compare(shadow.alpha, shadow.spec.alpha * Theme.glowBoost, "a glowing shadow is louder on a pale ground")
            verify(shadow.alpha <= 1)
            DeviceSettings.theme = "dreamglass"
            tryCompare(Theme, "lightness", 0)
            compare(Theme.glowBoost, 1)
        }

        // The colours of a picture that has not been analysed yet arrive after the card exists: the
        // card must pick them up (a new cache key, so nothing is known when the card is made).
        function test_a_late_sample_reaches_the_card_and_its_shadow() {
            const card = createTemporaryObject(cardComponent, host, { picture: fileUrl("blue"), focused: true })
            const art = artOf(card)
            const shadow = shadowOf(card)
            compare(art.sampled, false, "nothing is known when the card is made")
            compare(art.glowColor, Theme.glowFallback(art.hue), "it glows in its placeholder hue first")
            tryVerify(() => art.sampled, 5000, "the analysis arrives")
            verify(hueGap(art.glowColor.hslHue, 0.62) < 0.05, "and the glow turns blue: " + art.glowColor.hslHue)
            tryVerify(() => near(shadow.glow, art.glowColor, 0.01), 3000, "the focused shadow's glow follows")
            tryCompare(shadow, "glowMix", 1, 3000)
            verify(hueGap(shadow.tint.hslHue, 0.62) < 0.05, "the shadow is blue")
        }

        // --- the focus ring and the picture's corners ---------------------------------------------

        function test_the_ring_is_the_top_most_item_and_fits_the_card() {
            for (const size of [{ w: 400, u: 1 }, { w: 267, u: 0.667 }]) {
                const card = createTemporaryObject(cardComponent, host, { width: size.w, u: size.u, focused: true, picture: path("red") })
                const art = artOf(card)
                const ring = findChild(card, "cardRing")
                verify(ring, "the card has a ring item")
                compare(ring.parent, card, "the ring is not inside the art (the picture would cover it)")
                compare(ring.width, art.width)
                compare(ring.height, art.height)
                compare(ring.border.width, Theme.focusRingWidth * size.u, "ring width at u " + size.u)
                compare(ring.border.color, Theme.focusRing)
                compare(ring.radius, Theme.radiusM * size.u)
                compare(art.border.width, 0, "the art draws no ring of its own")
                const kids = card.children
                verify(kids[kids.length - 1] === ring, "the ring is the last (top-most) child")
                verify(kids.indexOf(ring) > kids.indexOf(art))
                for (let i = 0; i < kids.length; ++i)
                    verify(kids[i].z <= ring.z, "no sibling is above the ring")
                card.focused = false
                compare(ring.border.width, 0, "no ring at rest")
            }
        }

        function test_the_picture_is_masked_to_the_corners_on_a_gpu() {
            const card = createTemporaryObject(cardComponent, host, { picture: path("red") })
            const art = artOf(card)
            const gpu = host.GraphicsInfo.api !== GraphicsInfo.Software
            compare(art.masked, gpu, "masked on a GPU, rectangular clip on the software renderer")
            const image = findChild(art, "artImage")
            tryVerify(() => image.visible, 3000)
            compare(image.layer.enabled, gpu, "the picture is drawn through the mask")
            compare(findChild(art, "artImageMask").layer.enabled, gpu)
            compare(findChild(art, "artImageMask").radius, art.radius)
            art.radius = 0
            compare(art.masked, false, "a square art (the Home hero) needs no mask")
        }

        // --- the card family -------------------------------------------------------------------

        function test_the_tokens() {
            compare(Theme.cardWidthHero, 400)
            compare(Theme.cardWidthShelf, 320)
            compare(Theme.cardWidthCompact, 288)
            compare(Theme.cardIconSize, 160)
            compare(Theme.cardProfileWidth, 260)
            compare(Theme.cardProfileHeight, 320)
            compare(Theme.cardGap, Theme.spaceM)
            compare(Theme.cardCaptionHeight, 72)
            for (const w of [Theme.cardWidthHero, Theme.cardWidthShelf, Theme.cardWidthCompact]) {
                compare(Theme.cardArtHeight(w) * 16, w * 9, "16:9")
                compare(Theme.cardArtHeight(w), Math.round(Theme.cardArtHeight(w)), "whole design pixels")
            }
            verify(Theme.cardWidthHero > Theme.cardWidthShelf && Theme.cardWidthShelf > Theme.cardWidthCompact)
            compare(Theme.cardProfileWidth > Theme.avatarSize, true, "the avatar fits the profile card")
        }

        function test_an_art_card_defaults_to_the_shelf_size() {
            const card = createTemporaryObject(bareCardComponent, host)
            compare(card.implicitWidth, Theme.cardWidthShelf)
            compare(card.implicitHeight, Theme.cardArtHeight(Theme.cardWidthShelf))
            compare(artOf(card).radius, Theme.radiusM * card.u)
        }

        function signIn(component) {
            Library.resetMockForTests("art:" + artFixtures)
            Store.mockReset()
            Store.mockArtDir(artFixtures)
            // The cards read a record once, when the row is built: the pictures must be in first.
            tryVerify(() => (Library.item("steam:730").art ?? {}).tile !== undefined, 2000, "the library has pictures")
            tryVerify(() => (Store.catalogue.find(a => a.id === "org.example.Racer") ?? {}).tile !== undefined
                            && Store.catalogue.find(a => a.id === "org.example.Racer").tile.length > 0, 2000, "the store has pictures")
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(component ?? shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            tryVerify(() => Library.items.length === 10)
        }

        function openSection(index, page) {
            keyClick(Qt.Key_Up)
            for (let i = 0; i < index; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", page)
        }

        function test_profile_card_size() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000)
            const list = find("profileList")
            tryVerify(() => list.currentItem !== null)
            compare(list.currentItem.width, Theme.cardProfileWidth * tc.shell.u)
            compare(list.currentItem.height, Theme.cardProfileHeight * tc.shell.u)
            tc.shell.destroy()
        }

        function test_games_home_and_store_use_the_documented_sizes() {
            signIn()
            const u = tc.shell.u
            // Home: the Recent row is the shelf size, its cards carry the picture's glow.
            const recent = find("recentRow")
            tryVerify(() => recent.currentItem !== null)
            compare(recent.currentItem.width, Theme.cardWidthShelf * u)
            compare(recent.currentItem.height, Theme.cardArtHeight(Theme.cardWidthShelf) * u)
            compare(recent.spacing, Theme.cardGap * u)
            const first = recent.currentItem
            tryVerify(() => artOf(first).sampled, 5000, "the picture of the focused Home card is sampled")
            // Games: hero size, the documented gap.
            openSection(1, "games")
            const grid = find("gamesGrid")
            tryVerify(() => grid.activeFocus, 2000)
            const game = grid.currentItem
            compare(game.width, Theme.cardWidthHero * u)
            compare(game.height, Theme.cardArtHeight(Theme.cardWidthHero) * u)
            compare(grid.cellWidth, game.width + Theme.cardGap * u)
            // Room for the glow on every side, and the leftover width split between left and right.
            const pad = Theme.glowPad * u
            const columns = Math.round((grid.width - 2 * pad + Theme.cardGap * u) / grid.cellWidth)
            verify(columns >= 1)
            const last = columns - 1
            tryVerify(() => grid.itemAtIndex(last) !== null, 3000, "the last card of the first row is built")
            // Item positions, not mapped ones: the focused card is scaled and would shift.
            const left = grid.itemAtIndex(0).x - grid.contentX
            const right = grid.width - (grid.itemAtIndex(last).x - grid.contentX + grid.itemAtIndex(last).width)
            verify(left >= pad && right >= pad, "room for the glow: " + left + " / " + right + " >= " + pad)
            verify(Math.abs(left - right) < 1.5, "centred: " + left + " vs " + right)
            verify(Math.abs(grid.x + grid.width / 2 - grid.parent.width / 2) < 1, "the grid is centred in its place")
            verify(grid.itemAtIndex(0).y - grid.contentY >= Math.min(Theme.glowPad, Theme.spaceM) * u, "room above the first row (the free gap, not more)")
            verify(grid.width <= grid.parent.width + 2 * pad + 0.5, "the columns fit the place")
            verify(grid.cellHeight - game.height - Theme.cardGap * u < 0.001)
            compare(artOf(game).radius, Theme.radiusM * u)
            tryVerify(() => artOf(game).sampled, 5000)
            tc.shell.destroy()
        }

        // A list that is larger than its place (for the glow) must not reach over the hint bar.
        function listEnd(list) { return list.mapToItem(tc.shell, 0, list.height).y }

        function checkListsStayAboveTheHintBar(component, label) {
            signIn(component)
            openSection(1, "games")
            const grid = find("gamesGrid")
            tryVerify(() => grid.activeFocus, 2000)
            const hint = find("hintBar")
            verify(listEnd(grid) <= hint.y + 0.5, label + ": the Games grid ends at " + listEnd(grid) + ", the hint bar starts at " + hint.y)
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("homePlay") !== null)
            tc.shell.destroy()

            signIn(component)
            openSection(3, "store")
            tryVerify(() => find("storeCards_featured") && find("storeCards_featured").activeFocus, 2000)
            const rows = find("storeRows")
            verify(listEnd(rows) <= find("hintBar").y + 0.5, label + ": the Store rows end at " + listEnd(rows) + ", the hint bar starts at " + find("hintBar").y)
            keyClick(Qt.Key_Up)
            verify(find("storeSearch").activeFocus)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("storeSearchEntry").visible, 2000)
            find("storeSearchEntry").accepted("o")
            tryVerify(() => find("storeResults").visible, 2000, "results replace the rows")
            const results = find("storeResults")
            verify(listEnd(results) <= find("hintBar").y + 0.5, label + ": the results end at " + listEnd(results) + ", the hint bar starts at " + find("hintBar").y)
            tc.shell.destroy()
        }

        function test_glow_room_never_reaches_over_the_hint_bar_on_a_short_screen() {
            checkListsStayAboveTheHintBar(shell450Component, "1280x450")
        }

        function test_glow_room_never_reaches_over_the_hint_bar_at_1080p() {
            checkListsStayAboveTheHintBar(shell1080Component, "1920x1080")
        }

        function test_store_cards_use_the_compact_size() {
            signIn()
            const u = tc.shell.u
            openSection(3, "store")
            const row = find("storeCards_featured")
            tryVerify(() => row && row.activeFocus, 2000)
            const card = row.currentItem
            compare(card.width, Theme.cardWidthCompact * u)
            compare(card.height, (Theme.cardArtHeight(Theme.cardWidthCompact) + Theme.cardCaptionHeight) * u)
            compare(row.spacing, Theme.cardGap * u)
            const art = findChild(card, "cardFocusLayers").parent
            compare(art.width, card.width)
            compare(art.height, Theme.cardArtHeight(Theme.cardWidthCompact) * u)
            compare(art.radius, Theme.radiusM * u)
            tryVerify(() => art.sampled, 5000, "a Store card samples its tile")
            const ring = findChild(card, "cardRing")
            verify(ring, "the Store card has a ring item above its art")
            compare(ring.width, art.width)
            compare(ring.height, art.height)
            compare(ring.border.width, Theme.focusRingWidth * u)
            verify(card.children.indexOf(ring) > card.children.indexOf(art))
            for (let i = 0; i < card.children.length; ++i)
                verify(card.children[i].z <= ring.z)
            // The glow of a card at the left or top edge is not cut off: the list is larger than its place.
            const pad = Theme.glowPad * u
            const at = card.mapToItem(find("storeRows"), 0, 0)
            verify(at.x >= pad - 0.5, "room left of the first card: " + at.x + " >= " + pad)
            verify(at.y >= Math.min(Theme.glowPad, Theme.spaceM) * u - 0.5, "room above the first row: " + at.y)
            const shadow = findChild(card, "cardLiftShadow")
            compare(shadow.halo, true)
            tryCompare(shadow, "glowMix", 1, 3000)
            verify(near(shadow.glow, art.glowColor, 0.01))
            tc.shell.destroy()
        }

        function test_focus_moves_the_glow_with_the_selection() {
            signIn()
            keyClick(Qt.Key_Down)                                  // to the Recent row
            const recent = find("recentRow")
            tryVerify(() => recent.activeFocus, 2000)
            const a = recent.currentItem
            tryCompare(a, "focused", true)
            const shadowA = findChild(a, "cardLiftShadow")
            tryCompare(shadowA, "glowMix", 1, 3000)
            keyClick(Qt.Key_Right)
            tryVerify(() => recent.currentIndex === 1)
            const b = recent.currentItem
            tryCompare(b, "focused", true)
            compare(a.focused, false)
            verify(recent.activeFocus)
            const shadowB = findChild(b, "cardLiftShadow")
            tryCompare(shadowB, "glowMix", 1, 3000)
            tryCompare(shadowA, "glowMix", 0, 3000)
            tryVerify(() => artOf(b).sampled, 5000)
            verify(near(shadowB.glow, artOf(b).glowColor, 0.01))
            verify(hueGap(artOf(a).glowColor.hslHue, artOf(b).glowColor.hslHue) > 0.2, "red and blue neighbours")
            tc.shell.destroy()
        }

        // --- screenshots (shots only) ----------------------------------------------------------

        function shoot(file) {
            wait(900)
            grabImage(tc.shell).save(file + ".png")
        }

        function test_zz_screenshots_gallery() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            for (const theme of ["dreamglass", "daylight"]) {
                DeviceSettings.theme = theme
                tryCompare(Theme, "lightness", theme === "daylight" ? 1 : 0, 3000)
                const gallery = createTemporaryObject(galleryComponent, host)
                for (const name of gallery.names)
                    tryVerify(() => findChild(gallery, "gallery_" + name) !== null, 2000)
                wait(1500)
                grabImage(gallery).save(shotsDir + "/art-glow-gallery-" + theme + ".png")
                gallery.destroy()
            }
        }

        // One page of the shell per sign-in, so each shot starts from a known place.
        function test_zz_screenshots_pages() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            const out = shotsDir + "/art-glow-"
            for (const theme of ["dreamglass", "daylight"]) {
                DeviceSettings.theme = theme
                tryCompare(Theme, "lightness", theme === "daylight" ? 1 : 0, 3000)
                signIn()
                keyClick(Qt.Key_Down)                              // to the Recent row: the red card
                tryVerify(() => find("recentRow").activeFocus, 2000)
                shoot(out + "home-red-" + theme)
                keyClick(Qt.Key_Right)                             // the blue one
                shoot(out + "home-blue-" + theme)
                keyClick(Qt.Key_Right)                             // green
                keyClick(Qt.Key_Right)                             // the white one
                shoot(out + "home-white-" + theme)
                tc.shell.destroy()

                signIn()
                openSection(1, "games")
                tryVerify(() => find("gamesGrid").activeFocus, 2000)
                shoot(out + "games-" + theme)
                keyClick(Qt.Key_Right)                             // the blue one
                shoot(out + "games-blue-" + theme)
                for (let i = 0; i < 3; ++i)
                    keyClick(Qt.Key_Right)                         // the dark one: a faint glow, the ring still shows
                shoot(out + "games-dark-" + theme)
                tc.shell.destroy()

                signIn(shell720Component)                          // a real 720p screen
                openSection(1, "games")
                tryVerify(() => find("gamesGrid").activeFocus, 2000)
                keyClick(Qt.Key_Right)
                shoot(out + "games-720p-" + theme)
                tc.shell.destroy()

                signIn()
                openSection(3, "store")
                tryVerify(() => find("storeCards_featured").activeFocus, 2000)
                shoot(out + "store-" + theme)
                keyClick(Qt.Key_Right)
                shoot(out + "store-next-" + theme)
                tc.shell.destroy()
            }
        }
    }
}
