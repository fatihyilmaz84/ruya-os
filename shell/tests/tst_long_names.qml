import QtQuick
import QtTest
import RuyaShell

// T-312: a name from outside (a profile's, here) is one line, capped to its container's width and
// elided at the end, wherever it is drawn: the profile cards, the status cluster and the PIN pad
// title; the full name stays in the accessible name. And the Dim wallpaper row says why Left/Right
// can look dead (the picture raises the dim). 1080p, the size a living-room TV has; `shots` saves the
// picker with two 32-character names and the Dim row.
Item {
    id: host
    width: 1920
    height: 1080

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "LongNames"
        when: windowShown

        // Both are 32 characters, the shipped maximum.
        readonly property string longA: "Mehmet Ali Yilmaz-Kucukoglu Doga"
        readonly property string longB: "Zeynep Su Aksoy-Karaoglanoglu Ec"

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            compare(tc.longA.length, 32)
            compare(tc.longB.length, 32)
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

        function cleanup() {
            Profiles.renameProfile("p1", "1234", "p1", "Player One")
            Profiles.renameProfile("p1", "1234", "p2", "Ada")
            tryVerify(() => Profiles.profiles.some(p => p.id === "p2" && p.name === "Ada")
                      && Profiles.profiles.some(p => p.id === "p1" && p.name === "Player One"))
            DeviceSettings.wallpaper = ""
            DeviceSettings.wallpaperDim = 0.2
            DeviceSettings.language = "en"
            DeviceSettings.theme = "dreamglass"
            tryCompare(Theme, "mix", 1, 3000)
        }

        function renameBoth() {
            Profiles.renameProfile("p1", "1234", "p1", tc.longA)
            Profiles.renameProfile("p1", "1234", "p2", tc.longB)
            tryVerify(() => Profiles.profiles.some(p => p.id === "p1" && p.name === tc.longA)
                      && Profiles.profiles.some(p => p.id === "p2" && p.name === tc.longB))
        }

        function lockToPicker() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has focus")
        }

        // Every Text named `objectName` below `item` (a ListView lists its delegates twice: once as
        // children and once through its contentItem, hence the set).
        function namedTexts(item, objectName, found, seen) {
            if (seen.has(item))
                return found
            seen.add(item)
            if (item.objectName === objectName && typeof item.elide === "number")
                found.push(item)
            for (let i = 0; i < item.children.length; ++i)
                namedTexts(item.children[i], objectName, found, seen)
            if (item.contentItem)
                namedTexts(item.contentItem, objectName, found, seen)
            return found
        }

        function test_profile_cards_elide_a_32_character_name() {
            renameBoth()
            lockToPicker()
            const names = []
            tryVerify(() => {
                names.length = 0
                namedTexts(find("profileList"), "profileCardName", names, new Set())
                return names.length === 3
            }, 3000, "three profile cards")
            const cardWidth = Theme.cardProfileWidth * tc.shell.u
            let elided = 0
            for (const text of names) {
                verify(text.width <= cardWidth + 0.5, text.text + ": the name is " + text.width + " wide in a card of " + cardWidth)
                compare(text.elide, Text.ElideRight)
                compare(text.horizontalAlignment, Text.AlignHCenter)
                if (text.text === tc.longA || text.text === tc.longB) {
                    verify(text.implicitWidth > cardWidth, "the long name needs more than a card: " + text.implicitWidth)
                    verify(text.truncated, text.text + " is cut with an ellipsis")
                    ++elided
                }
            }
            compare(elided, 2, "both long names are elided")
            // The full name stays in the accessible name of the card.
            const item = find("profileList").itemAtIndex(0)
            verify(item.Accessible.name.indexOf(tc.longA) >= 0 || item.Accessible.name.indexOf(tc.longB) >= 0,
                   "the card's accessible name has the whole name: " + item.Accessible.name)
        }

        function test_status_cluster_stops_growing_at_a_cap() {
            renameBoth()
            const name = find("activeProfileName")
            tryCompare(name, "text", tc.longB)
            const cap = 220 * tc.shell.u
            verify(name.implicitWidth > cap, "the name needs more than the cap: " + name.implicitWidth)
            verify(name.width <= cap + 0.5, "the status name is " + name.width + ", the cap " + cap)
            verify(name.truncated, "the status name ends in an ellipsis")
            // A short name still gets its full width.
            Profiles.renameProfile("p1", "1234", "p2", "Ada")
            tryCompare(name, "text", "Ada")
            compare(name.width, name.implicitWidth)
            verify(!name.truncated)
        }

        function test_pin_pad_title_is_one_capped_line() {
            renameBoth()
            lockToPicker()
            find("profileList").currentIndex = 0         // Player One (renamed) has a PIN
            keyClick(Qt.Key_Return)
            tryVerify(() => find("pinPad") !== null && find("pinPad").visible, 2000, "the PIN pad opens")
            const title = find("pinTitle")
            verify(title !== null)
            const cap = 3 * Theme.cardProfileWidth * tc.shell.u
            const pad = find("pinPad")
            // English: the name is cut inside the title, which stays one line within the cap.
            tryVerify(() => title.text.indexOf("Enter PIN for Mehmet") === 0, 2000, "title is: " + title.text)
            verify(title.text.endsWith("…"), "the name ends in an ellipsis: " + title.text)
            verify(title.text.length < ("Enter PIN for " + tc.longA).length, "the title is shorter than the whole text")
            verify(title.implicitWidth <= cap + 0.5, "the title is " + title.implicitWidth + " wide, the cap " + cap)
            verify(title.width <= cap + 0.5)
            verify(!title.truncated, "the Text itself cuts nothing: the name was cut before")
            compare(title.Accessible.name, "Enter PIN for " + tc.longA, "the accessible name is the whole title")
            // Turkish puts the name first: the instruction after it must survive.
            DeviceSettings.language = "tr"
            tryVerify(() => title.text.endsWith(" için PIN girin"), 2000, "the Turkish title keeps its instruction: " + title.text)
            verify(title.text.indexOf("…") > 0, "the name is cut: " + title.text)
            verify(title.implicitWidth <= cap + 0.5, "the Turkish title is " + title.implicitWidth + " wide, the cap " + cap)
            verify(!title.truncated)
            compare(title.Accessible.name, tc.longA + " için PIN girin", "the accessible name is the whole Turkish title")
            DeviceSettings.language = "en"
            tryVerify(() => title.text.indexOf("Enter PIN for") === 0)
            verify(pad.visible)
            keyClick(Qt.Key_Escape)                      // Back closes the pad
            tryVerify(() => !find("pinPad").visible, 2000, "Back closes the pad")
            tryVerify(() => find("profileList").activeFocus, 2000, "focus returns to the picker")
        }

        function openSettingsDisplay() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList") !== null && find("categoryList").activeFocus, 2000, "category list has focus")
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Down)                    // Display & motion
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus, 2000, "first row takes focus")
        }

        // The caption shows exactly while the applied dim is above the slider's own value.
        function test_dim_row_caption_follows_the_rule() {
            openSettingsDisplay()
            const row = find("rowWallpaperDim")
            const caption = findChild(row, "caption")
            verify(caption !== null, "the row has a caption")
            DeviceSettings.wallpaper = "dusk"
            tryVerify(() => row.visible)
            compare(row.shownValue, row.value, "a dark picture needs nothing beyond the slider")
            verify(!caption.visible, "no caption when the slider is what is applied")

            DeviceSettings.wallpaper = "daybreak"
            tryVerify(() => row.shownValue > row.value)
            verify(caption.visible, "the bright picture raises the dim: the caption says so")
            compare(caption.text, "Raised for this picture")
            verify(row.Accessible.name.indexOf("Raised for this picture") >= 0, "a reader hears it: " + row.Accessible.name)

            DeviceSettings.wallpaperDim = 0.6
            tryCompare(row, "shownValue", 60)
            verify(!caption.visible, "the owner's dim above the rule: nothing is raised")
            verify(row.Accessible.name.indexOf("Raised") < 0)
            DeviceSettings.wallpaperDim = 0.2
            tryVerify(() => caption.visible)
            DeviceSettings.language = "tr"
            tryVerify(() => caption.text === "Bu resim için artırıldı", 2000, "caption is: " + caption.text)
            DeviceSettings.language = "en"
            tryCompare(caption, "text", "Raised for this picture")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            // The Dim row over the bright picture.
            DeviceSettings.wallpaper = "daybreak"
            tryVerify(() => find("wallpaperLayer").covering, 5000, "the picture covers the backdrop")
            openSettingsDisplay()
            verify(find("rowWallpaperDim").visible)
            waitForRendering(tc.shell)
            wait(1200)
            // The Column of the rows stayed unlaid in this real window until its next polish (the case
            // `SettingsPane.reflow()` documents): lay it out before the picture is taken.
            find("rowQuality").parent.forceLayout()
            tryVerify(() => find("rowWallpaperDim").y > 0, 2000, "the rows are laid out")
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/73-dim-row-caption.png")
            DeviceSettings.language = "tr"
            tryCompare(findChild(find("rowWallpaperDim"), "caption"), "text", "Bu resim için artırıldı")
            wait(400)
            grabImage(tc.shell).save(shotsDir + "/73-dim-row-caption-tr.png")
            DeviceSettings.language = "en"
            tryCompare(findChild(find("rowWallpaperDim"), "caption"), "text", "Raised for this picture")
            // The picker with two 32-character names.
            DeviceSettings.wallpaper = ""
            renameBoth()
            tryCompare(find("activeProfileName"), "text", tc.longB)
            wait(400)
            grabImage(find("statusGlass")).save(shotsDir + "/73-long-names-status-crop.png")
            grabImage(tc.shell).save(shotsDir + "/73-long-names-status.png")
            lockToPicker()
            wait(700)
            grabImage(tc.shell).save(shotsDir + "/73-long-names-picker.png")
            find("profileList").currentIndex = 0
            keyClick(Qt.Key_Return)
            tryVerify(() => find("pinPad") !== null && find("pinPad").visible, 2000, "the PIN pad opens")
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/73-long-names-pin-pad.png")
        }
    }
}
