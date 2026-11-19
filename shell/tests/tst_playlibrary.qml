import QtQuick
import QtTest
import RuyaShell

// A .play app in the Library (RUY-856, part B of RUY-104): Home's hero draws the logo in place of the title,
// the cards and the hero art take the .play art roles, and the game page shows the trust row (and its signer
// sheet) and the trailer, each only when the item has the data. Fixtures (`playart:<dir>`): Star Hopper (every
// field), Quiet Quest (a .play app with an icon only) and Oddity (a Flatpak that is not a .play app but carries
// a logo, a trailer and a tier). Properties, not pixels; the pictures are in `playlibrary` shots.
// Signs in as "Ada" (p2, a Standard profile).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "PlayLibrary"
        when: windowShown

        property Shell shell: null
        readonly property string hopper: "flatpak:play.com.example.starhopper"
        readonly property string quiet: "flatpak:play.com.example.quiet"
        readonly property string oddity: "flatpak:org.example.Oddity"

        function find(name) { return findChild(tc.shell, name) }
        function page() { return find("page_appDetail") }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            DeviceSettings.language = "en"
            Library.resetMockForTests("playart:" + artFixtures)
            Session.mockReset()
            Store.mockReset()
            Usage.mockReset()
        }

        function cleanup() {
            DeviceSettings.language = "en"
            host.width = 1280
            host.height = 720
        }

        function start() {
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
            tryVerify(() => Library.items.length === 13)
            tryVerify(() => Store.available && Store.catalogue.length > 0)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            wait(50)
        }

        // Home's hero on the item `id` (Recent is in last-played order: Star Hopper, Quiet Quest, Oddity, ...).
        function heroOn(id) {
            const order = [hopper, quiet, oddity]
            keyClick(Qt.Key_Down)
            tryVerify(() => find("recentRow").activeFocus)
            for (let i = 0; i < order.indexOf(id); ++i)
                keyClick(Qt.Key_Right)
            tryCompare(find("recentRow"), "currentIndex", order.indexOf(id))
            keyClick(Qt.Key_Up)
            tryVerify(() => find("homePlay").activeFocus)
        }

        function openPage(id) {
            tc.shell.openPage("appDetail", { id: id })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
        }

        function heroArtPicture() {
            const a = find("heroArtA")
            const b = find("heroArtB")
            return (a.opacity >= b.opacity ? a : b).picture
        }

        // ---- Home ----

        function test_hero_draws_the_logo_for_a_play_app() {
            start()
            const hero = find("heroBlock")
            tryCompare(hero, "logoShown", true)
            compare(find("heroLogo").visible, true)
            compare(find("heroTitle").visible, false, "the logo replaces the text")
            compare(find("heroLogo").Accessible.name, "Star Hopper", "the title stays the accessible name")
            verify(find("heroLogo").height > 0)
            verify(find("heroLogo").height <= 2 * Theme.typeHero * hero.u + 1, "no taller than two title lines")
        }

        function test_hero_art_and_cards_take_the_play_roles() {
            start()
            verify(heroArtPicture().endsWith("playhero.png"), "the hero role: " + heroArtPicture())
            verify(find("recentCard_" + hopper).picture.endsWith("playcard.png"), "the card role: " + find("recentCard_" + hopper).picture)
            // An icon-only .play app has no card art: the card keeps its monogram, as any item without art.
            compare(find("recentCard_" + quiet).picture, "")
        }

        function test_hero_of_an_icon_only_play_app_shows_the_title() {
            start()
            heroOn(quiet)
            compare(find("heroBlock").logoShown, false)
            compare(find("heroTitle").visible, true)
            compare(find("heroTitle").text, "Quiet Quest")
        }

        function test_a_logo_on_a_non_play_item_is_not_drawn() {
            start()
            heroOn(oddity)
            compare(find("heroBlock").logoShown, false)
            compare(find("heroTitle").visible, true)
            compare(find("heroTitle").text, "Oddity")
        }

        function test_hero_goes_back_to_the_title_when_the_logo_does_not_load() {
            start()
            const hero = find("heroBlock")
            tryCompare(hero, "logoShown", true)
            hero.logo = artFixtures + "/does-not-exist.png"
            tryCompare(hero, "logoShown", false)
            compare(find("heroTitle").visible, true)
        }

        // ---- The game page ----

        function test_play_page_shows_trust_signer_and_trailer() {
            start()
            openPage(hopper)
            const trust = find("detailTrustRow")
            verify(trust.visible)
            compare(trust.trust.state, "developer")
            compare(trust.trust.line, "Signed by Example Games · key 0123…cdef", "the name and the short key Library1 gives")
            compare(find("detailScreenshotsSection").visible, true)
            compare(find("screenshotsHeading").text, "Screenshots and trailer")
            compare(find("detailScreenshotsSection").count, 3, "the item's three pictures (the trailer card is extra)")
            compare(page().storeDown, false, "a .play app is not a Store app: no 'Store details are unavailable'")
            compare(find("detailStoreDown").visible, false)
            compare(find("detail_retry"), null)
        }

        function test_trust_row_is_a_stop_and_opens_the_signer_sheet() {
            start()
            openPage(hopper)
            const play = find("detailPrimary")
            const trustRow = find("detailTrustRow")
            verify(trustRow.mapToItem(null, 0, 0).y > play.mapToItem(null, 0, 0).y, "the trust row is drawn below the buttons")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("detailTrustRow").activeFocus, 2000, "Down from Play goes down to the trust row")
            keyClick(Qt.Key_Return)
            const sheet = find("detailSigner")
            tryCompare(sheet, "shown", true)
            tryVerify(() => sheet.activeFocus)
            tryCompare(find("signerRowName"), "visible", true)
            const key = find("signerRowKey")
            compare(key.visible, true, "Library1 gives the key id of a signed package")
            compare(findChild(key, "signerValue").text, "0123 4567 89ab cdef 0123 4567 89ab cdef")
            compare(find("signerRowSeen").visible, false, "Seen before is an install-time comparison")
            keyClick(Qt.Key_Escape)
            tryCompare(sheet, "shown", false)
            tryVerify(() => find("detailTrustRow").activeFocus, 2000, "focus returns to the trust row")
            compare(tc.shell.currentPage, "appDetail", "Back closed the sheet only")
        }

        function test_trailer_card_is_the_next_stop_and_opens_the_viewer() {
            start()
            openPage(hopper)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            tryVerify(() => find("screenshotStrip").activeFocus, 2000, "Down again lands on the trailer card")
            keyClick(Qt.Key_Return)
            const viewer = find("detailScreenshotsSection").viewer
            verify(viewer, "the viewer is built on Accept")
            tryCompare(viewer, "trailerMode", true)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("screenshotStrip").activeFocus, 2000, "Back returns to the trailer card")
        }

        function test_icon_only_play_page_has_none_of_the_sections_and_no_gap() {
            start()
            openPage(quiet)
            compare(find("detailTrustRow").visible, false)
            compare(find("detailScreenshotsSection").visible, false)
            compare(page().screenshots.length, 0, "no screenshots without Library1 pictures")
            compare(find("detailStoreDown").visible, false)
            const trustSlot = find("detailTrustRow").parent
            compare(trustSlot.height, 0, "the trust row's slot takes no room")
            keyClick(Qt.Key_Down)
            verify(!find("detailTrustRow").activeFocus, "the trust row is not a stop")
        }

        function test_a_non_play_item_with_play_keys_gets_no_badge_signer_or_trailer() {
            start()
            openPage(oddity)
            compare(find("detailTrustRow").visible, false)
            compare(find("detailScreenshotsSection").visible, false)
            compare(page().trustShown, false)
            compare(page().playTrailer, null)
            keyClick(Qt.Key_Down)
            verify(!find("detailTrustRow").activeFocus)
        }

        // ---- screenshots (dev.ps1 shots; English and Turkish, 1080p): the full-art fixture and the icon-only one ----

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            host.width = 1920
            host.height = 1080
            for (const lang of ["en", "tr"]) {
                DeviceSettings.language = lang
                Library.resetMockForTests("playart:" + artFixtures)
                start()
                wait(900)
                grabImage(tc.shell).save(shotsDir + "/" + "150-play-home-full-art-" + lang + "-1080p.png")
                heroOn(quiet)
                wait(900)
                grabImage(tc.shell).save(shotsDir + "/" + "151-play-home-icon-only-" + lang + "-1080p.png")
                tc.shell.destroy()
                tc.shell = null
                start()
                openPage(hopper)
                wait(900)
                grabImage(tc.shell).save(shotsDir + "/" + "152-play-page-full-art-" + lang + "-1080p.png")
                keyClick(Qt.Key_Down)
                keyClick(Qt.Key_Down)
                wait(900)
                grabImage(tc.shell).save(shotsDir + "/" + "153-play-page-trailer-" + lang + "-1080p.png")
                keyClick(Qt.Key_Escape)
                tryCompare(tc.shell, "currentPage", "")
                openPage(quiet)
                wait(900)
                grabImage(tc.shell).save(shotsDir + "/" + "154-play-page-icon-only-" + lang + "-1080p.png")
                tc.shell.destroy()
                tc.shell = null
            }
        }

        function test_play_page_is_in_turkish() {
            DeviceSettings.language = "tr"
            start()
            openPage(hopper)
            compare(find("detailTrustRow").trust.badge, "Geliştirici")
            compare(find("screenshotsHeading").text, "Ekran görüntüleri ve fragman")
        }
    }
}
