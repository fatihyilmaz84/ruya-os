import QtQuick
import QtTest
import RuyaShell

// Wallpapers (T-208): the setting and the backdrop it drives, the picker (controller keys only),
// the copy from a USB drive (mock stick with a real folder of made-up pictures), Delete, the
// fall-back to the default look, the tiers, the legibility rule and memory. DeviceSettings and the
// wallpaper library are in-memory / in a temporary folder under test.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test-1.2.3"; focus: true }
    }
    // A throw-away Image to ask "is this file a picture the shell can load".
    Component { id: probeComponent; Image { asynchronous: true; cache: false } }

    SignalSpy { id: copySpy; target: Wallpapers; signalName: "copyFinished" }

    TestCase {
        id: tc
        name: "Wallpaper"
        when: windowShown

        property Shell shell: null
        property string usbRoot: ""

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
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
            copySpy.clear()
        }

        function cleanup() {
            DeviceSettings.wallpaper = ""
            DeviceSettings.wallpaperDim = 0.2
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.reducedMotion = false
            Wallpapers.mockSetCopyDelay(0)
            Wallpapers.mockReset()
            Storage.mockReset(false)
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text)
            return out
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
            compare(find("categoryList").currentIndex, 3)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus, 2000, "first row takes focus")
        }

        // Settings -> Display & motion -> the Wallpaper row -> Accept: the picker, on the current tile.
        function openPicker() {
            openSettingsDisplay()
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Down)
            verify(find("rowWallpaper").activeFocus, "the Wallpaper row")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("wallpaperPicker").shown)
            verify(find("wallpaperGrid").activeFocus, "the grid takes focus")
        }

        function loadable(url) {
            const img = createTemporaryObject(probeComponent, host, { source: url })
            tryVerify(() => img.status !== Image.Loading && img.status !== Image.Null)
            return img.status === Image.Ready
        }

        // Relative luminance of a colour (sRGB, WCAG).
        function lum(c) {
            const f = v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
            return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
        }

        function selectBundled(id) {
            // From the default tile (index 0) to `id`: 4 tiles per row.
            const grid = find("wallpaperGrid")
            const target = find("wallpaperPicker").indexOfId(id)
            const col = target % 4
            const row = Math.floor(target / 4)
            for (let i = 0; i < row; ++i)
                keyClick(Qt.Key_Down)
            for (let i = 0; i < col; ++i)
                keyClick(Qt.Key_Right)
            compare(grid.currentIndex, target)
            verify(grid.activeFocus)
        }

        function setWallpaper(id) {
            DeviceSettings.wallpaper = id
            tryVerify(() => find("wallpaperLayer").covering, 5000, "the picture covers the backdrop")
        }

        function test_default_look_has_no_wallpaper() {
            const layer = find("wallpaperLayer")
            compare(DeviceSettings.wallpaper, "")
            compare(layer.has, false)
            compare(layer.decoded, 0)
            compare(find("backdrop").shown, true, "the blobs are the default look")
            compare(find("wallpaperDim").visible, false)
        }

        function test_bundled_catalogue() {
            compare(Wallpapers.bundled.length, 6)
            for (const b of Wallpapers.bundled) {
                verify(b.source.startsWith("qrc:/"), b.id)
                verify(b.peak > 0 && b.peak <= 1, b.id)
                verify(loadable(b.source), b.id + " loads")
            }
            compare(Wallpapers.userLimit, 12)
        }

        function test_choosing_a_bundled_wallpaper_sets_the_setting_and_the_backdrop() {
            openPicker()
            const picker = find("wallpaperPicker")
            compare(find("wallpaperGrid").currentIndex, 0, "the default look is the current one")
            tryVerify(() => find("wallpaperCurrent_") !== null && find("wallpaperCurrent_").visible, 2000, "the current tile is marked")
            selectBundled("dusk")
            compare(find("wallpaperGrid").currentIndex, 1)
            keyClick(Qt.Key_Return)
            compare(DeviceSettings.wallpaper, "dusk")
            tryCompare(picker, "shown", false)
            verify(find("rowWallpaper").activeFocus, "focus returns to the row")
            compare(find("rowWallpaper").value, "Dusk")

            const layer = find("wallpaperLayer")
            verify(layer.target.endsWith("/dusk.jpg"), layer.target)
            tryVerify(() => layer.covering, 5000)
            compare(layer.has, true)
            compare(find("backdrop").shown, false, "the blobs rest while the picture covers them")
            const shown = layer.front
            verify(shown.source.toString().endsWith("/dusk.jpg"))
            tryCompare(shown, "status", Image.Ready)
            compare(shown.asynchronous, true)
            verify(shown.sourceSize.width > 0 && shown.sourceSize.width <= host.width, "decoded at the screen size, not the file's")

            // The default look comes back from the same picker.
            keyClick(Qt.Key_Return)
            tryVerify(() => picker.shown)
            compare(find("wallpaperGrid").currentIndex, 1, "opens on the current tile")
            keyClick(Qt.Key_Left)
            compare(find("wallpaperGrid").currentIndex, 0)
            keyClick(Qt.Key_Return)
            compare(DeviceSettings.wallpaper, "")
            tryCompare(layer, "covering", false)
            tryCompare(layer, "decoded", 0)
            compare(find("backdrop").shown, true)
        }

        function test_picker_is_operable_with_the_controller_keys_only() {
            openPicker()
            const picker = find("wallpaperPicker")
            const grid = find("wallpaperGrid")
            compare(grid.count, 7, "default + six bundled")
            compare(grid.currentIndex, 0)
            keyClick(Qt.Key_Right)
            compare(grid.currentIndex, 1)
            verify(grid.activeFocus)
            keyClick(Qt.Key_Down)
            compare(grid.currentIndex, 5, "one row down")
            verify(grid.activeFocus)
            keyClick(Qt.Key_Down)                        // last row, no buttons: stays
            compare(grid.currentIndex, 5)
            verify(grid.activeFocus)
            keyClick(Qt.Key_Right)
            compare(grid.currentIndex, 6)
            keyClick(Qt.Key_Right)                       // end of the list
            compare(grid.currentIndex, 6)
            keyClick(Qt.Key_Up)
            compare(grid.currentIndex, 2)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)                        // start of the row
            compare(grid.currentIndex, 0)
            keyClick(Qt.Key_Up)
            compare(grid.currentIndex, 0)
            verify(grid.activeFocus)
            keyClick(Qt.Key_HomePage)                    // a modal: Guide does not leak to the shell
            verify(picker.shown && grid.activeFocus)
            keyClick(Qt.Key_Escape)                      // Back closes without choosing
            tryCompare(picker, "shown", false)
            compare(DeviceSettings.wallpaper, "")
            verify(find("rowWallpaper").activeFocus, "focus returns to the row")
        }

        function test_usb_pick_copies_downscales_and_lists_it() {
            openPicker()
            const picker = find("wallpaperPicker")
            const grid = find("wallpaperGrid")
            verify(!find("wallpaperAddUsb").visible, "no drive: no Add row")
            tc.usbRoot = Wallpapers.mockPrepareUsb()
            verify(tc.usbRoot.length > 0)
            Storage.mockPlugStick()
            // Only Wallpapers/ and Pictures/ one level deep, jpg/png/webp, within the limits.
            tryVerify(() => Wallpapers.usbImages.length === 4, 5000)
            compare(Wallpapers.usbImages.map(e => e.name).join(","), "Bright,photo,sunset,tiny")
            for (const e of Wallpapers.usbImages)
                compare(e.volume, "Ruya Stick")
            tryVerify(() => find("wallpaperAddUsb").visible)

            keyClick(Qt.Key_Down)                        // row 1 of the library
            compare(grid.currentIndex, 4)
            keyClick(Qt.Key_Down)                        // the buttons
            verify(find("wallpaperAddUsb").activeFocus, "Add from USB drive takes focus")
            verify(!find("wallpaperDelete").visible, "no copy of ours highlighted: no Delete")
            keyClick(Qt.Key_Up)
            verify(grid.activeFocus)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            compare(picker.mode, "usb")
            verify(grid.activeFocus)
            compare(grid.count, 4)
            compare(find("wallpaperTitle").text, "Pictures on the USB drive")

            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(picker.currentEntry.name, "sunset")
            Wallpapers.mockSetCopyDelay(400)
            keyClick(Qt.Key_Return)
            compare(Wallpapers.copyState, "copying", "the copy runs off the GUI thread")
            verify(find("wallpaperCopying").visible)
            keyClick(Qt.Key_Escape)                      // busy: swallowed
            keyClick(Qt.Key_Return)
            compare(picker.mode, "usb")
            verify(picker.shown)
            tryCompare(Wallpapers, "copyState", "idle", 5000)
            compare(copySpy.count, 1, "one import, the second Accept did nothing")
            compare(copySpy.signalArguments[0][0], "ok")

            compare(Wallpapers.user.length, 1)
            const w = Wallpapers.user[0]
            compare(w.name, "sunset")
            compare(copySpy.signalArguments[0][1], w.id)
            // Downscaled to cover the screen (never enlarged, at most 3840x2160).
            const sw = Screen.width * Screen.devicePixelRatio
            const sh = Screen.height * Screen.devicePixelRatio
            const scale = Math.min(1, Math.max(sw / 3000, sh / 2000), 3840 / 3000, 2160 / 2000)
            verify(Math.abs(w.width - Math.round(3000 * scale)) <= 1, "width " + w.width + " for scale " + scale)
            verify(Math.abs(w.height - Math.round(2000 * scale)) <= 1, "height " + w.height)
            verify(w.width <= 3000 && w.height <= 2000 && w.width <= 3840 && w.height <= 2160)
            verify(w.sizeBytes > 0)
            verify(loadable(w.source), "the copy is a picture")
            verify(w.id.startsWith("user:"))

            compare(DeviceSettings.wallpaper, w.id, "the copy is now the wallpaper")
            compare(picker.mode, "library")
            compare(grid.currentIndex, 7, "listed after the bundled ones, and selected")
            verify(grid.activeFocus)
            verify(find("wallpaperCurrent_" + w.id).visible)
            verify(toastTexts().includes("Wallpaper added"))
            tryVerify(() => find("wallpaperLayer").covering, 5000)
            verify(find("wallpaperLayer").target.endsWith(w.id.substring(5)))

            // Removing the drive keeps the copy.
            Storage.mockReset(false)
            tryVerify(() => Wallpapers.usbImages.length === 0, 5000)
            tryVerify(() => !find("wallpaperAddUsb").visible)
            compare(Wallpapers.user.length, 1)
            compare(DeviceSettings.wallpaper, w.id)
            verify(loadable(w.source), "the copy outlives the stick")
            compare(find("wallpaperLayer").has, true)

            // Delete removes it (and the wallpaper falls back to the default look).
            keyClick(Qt.Key_Down)
            verify(find("wallpaperDelete").activeFocus, "Delete takes focus")
            keyClick(Qt.Key_Return)
            compare(Wallpapers.user.length, 0)
            compare(DeviceSettings.wallpaper, "")
            verify(!loadable(w.source), "the file is gone")
            verify(grid.activeFocus, "focus is back on the grid")
            compare(grid.count, 7)
            tryCompare(find("wallpaperLayer"), "covering", false)
            tryCompare(find("wallpaperLayer"), "decoded", 0)
            verify(toastTexts().includes("Wallpaper deleted"))
        }

        function test_usb_import_refuses_what_it_should() {
            const root = Wallpapers.mockPrepareUsb()
            const dir = root + "/Ruya Stick/Wallpapers/"
            Wallpapers.importFile(dir + "huge.png")
            tryCompare(copySpy, "count", 1, 5000)
            compare(copySpy.signalArguments[0][0], "too-large", "over 40 megapixels")
            Wallpapers.importFile(dir + "broken.jpg")
            tryCompare(copySpy, "count", 2, 5000)
            compare(copySpy.signalArguments[1][0], "unreadable")
            Wallpapers.importFile(dir + "notes.txt")
            tryCompare(copySpy, "count", 3, 5000)
            compare(copySpy.signalArguments[2][0], "unreadable")
            Wallpapers.importFile(dir + "old.bmp")
            tryCompare(copySpy, "count", 4, 5000)
            compare(copySpy.signalArguments[3][0], "unsupported", "a picture, but not jpg/png/webp")
            Wallpapers.importFile(root + "/does-not-exist.jpg")
            tryCompare(copySpy, "count", 5, 5000)
            compare(copySpy.signalArguments[4][0], "unreadable")
            compare(Wallpapers.user.length, 0, "nothing was stored")
            compare(Wallpapers.copyState, "idle")
        }

        function test_the_same_picture_twice_is_one_copy() {
            const root = Wallpapers.mockPrepareUsb()
            Wallpapers.importFile(root + "/Ruya Stick/Pictures/photo.jpg")
            tryCompare(copySpy, "count", 1, 5000)
            Wallpapers.importFile(root + "/Ruya Stick/Pictures/photo.jpg")
            tryCompare(copySpy, "count", 2, 5000)
            compare(copySpy.signalArguments[1][0], "ok")
            compare(copySpy.signalArguments[1][1], copySpy.signalArguments[0][1])
            compare(Wallpapers.user.length, 1)
        }

        function test_the_copy_limit_and_delete_one_to_add_another() {
            const root = Wallpapers.mockPrepareUsb()
            Wallpapers.mockFillUser(12)
            compare(Wallpapers.user.length, 12)
            Wallpapers.importFile(root + "/Ruya Stick/Pictures/photo.jpg")
            tryCompare(copySpy, "count", 1, 5000)
            compare(copySpy.signalArguments[0][0], "limit")
            compare(Wallpapers.user.length, 12)

            // In the picker: the message says what to do, and Delete makes room.
            openPicker()
            Storage.mockPlugStick()
            tryVerify(() => find("wallpaperAddUsb").visible, 5000)
            const grid = find("wallpaperGrid")
            compare(grid.count, 19)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Down)                    // row 4 of 5 (index 4, 8, 12, 16)
            compare(grid.currentIndex, 16)
            keyClick(Qt.Key_Down)                        // 19 tiles: the last row is index 16..18
            verify(find("wallpaperAddUsb").activeFocus)
            keyClick(Qt.Key_Return)
            compare(find("wallpaperPicker").mode, "usb")
            keyClick(Qt.Key_Return)
            tryCompare(Wallpapers, "copyState", "idle", 5000)
            compare(find("wallpaperPicker").mode, "usb", "stays on the drive's pictures")
            compare(find("wallpaperMessage").text, "You can keep up to 12 wallpapers. Delete one first.")
            compare(find("wallpaperMessage").visible, true)
            verify(find("wallpaperGrid").activeFocus)
            verify(toastTexts().includes("Could not add the wallpaper"))
            keyClick(Qt.Key_Escape)                      // back to the library
            compare(find("wallpaperPicker").mode, "library")
            verify(find("wallpaperGrid").activeFocus)
            compare(find("wallpaperGrid").currentIndex, 0)
        }

        function test_a_missing_or_corrupt_file_falls_back_with_a_toast() {
            // A file that is gone.
            DeviceSettings.wallpaper = "user:gone.jpg"
            tryCompare(DeviceSettings, "wallpaper", "", 5000)
            tryVerify(() => toastTexts().includes("Wallpaper could not be loaded"))
            compare(find("wallpaperLayer").has, false)
            compare(find("backdrop").shown, true, "the default look")
            tc.cleanup()

            // A file that is not a picture.
            const id = Wallpapers.mockPlantCorrupt()
            compare(Wallpapers.user.length, 1)
            DeviceSettings.wallpaper = id
            tryCompare(DeviceSettings, "wallpaper", "", 5000)
            tryVerify(() => toastTexts().includes("Wallpaper could not be loaded"))
            compare(find("wallpaperLayer").has, false)
            compare(find("backdrop").shown, true)
            compare(find("wallpaperLayer").decoded, 0, "nothing stays decoded")
        }

        function test_unsafe_ids_are_rejected() {
            DeviceSettings.wallpaper = "dusk"
            ignoreWarning("ruya-shell: rejecting invalid wallpaper '../../etc/passwd'")
            DeviceSettings.wallpaper = "../../etc/passwd"
            ignoreWarning("ruya-shell: rejecting invalid wallpaper 'user:../x.jpg'")
            DeviceSettings.wallpaper = "user:../x.jpg"
            compare(DeviceSettings.wallpaper, "dusk")
            verify(DeviceSettings.isValidWallpaper(""))
            verify(DeviceSettings.isValidWallpaper("aurora"))
            verify(DeviceSettings.isValidWallpaper("user:u-0123456789ab.jpg"))
            verify(!DeviceSettings.isValidWallpaper("user:a/b.jpg"))
            verify(!DeviceSettings.isValidWallpaper("Dusk"))
            tryVerify(() => find("wallpaperLayer").covering, 5000)
        }

        function test_tiers_blur_on_pages_and_the_performance_tier_darkens() {
            setWallpaper("dusk")
            const layer = find("wallpaperLayer")
            // Home: sharp, never blurred.
            compare(layer.blurred, false)
            compare(find("wallpaperBlur").blurMax, 64)
            compare(find("wallpaperBlur").opacity, 0)

            // High: a page blurs the one shared copy.
            keyClick(Qt.Key_Up)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "settings")
            tryCompare(layer, "blurred", true)
            compare(layer.blurActive, true)
            const blur = find("wallpaperBlur")
            compare(blur.blurEnabled, true)
            compare(blur.blurMax, 64)
            tryCompare(blur, "opacity", 1)
            compare(layer.effectiveDim, 0.2, "the owner's dim")

            DeviceSettings.effectsQuality = "balanced"
            compare(find("wallpaperBlur").blurMax, 32)

            // Performance: no blur at all (not even the item), the picture is darkened instead.
            DeviceSettings.effectsQuality = "performance"
            compare(layer.blurActive, false)
            tryVerify(() => find("wallpaperBlur") === null, 2000, "no blur item exists")
            verify(layer.effectiveDim >= Theme.wallpaperDimUnblurred, "darkened: " + layer.effectiveDim)
            compare(layer.has, true, "the wallpaper is still shown")
            tryCompare(find("wallpaperDim"), "opacity", layer.effectiveDim)

            // Back on Home the picture is sharp again and only as dark as the owner chose.
            keyClick(Qt.Key_Escape)                      // list -> Home
            tryCompare(tc.shell, "currentPage", "")
            tryCompare(layer, "blurred", false)
            tryCompare(layer, "effectiveDim", 0.2)
        }

        function test_one_decoded_wallpaper_and_the_old_one_is_released_after_the_fade() {
            setWallpaper("dusk")
            const layer = find("wallpaperLayer")
            tryCompare(layer, "decoded", 1)
            const first = layer.front
            DeviceSettings.wallpaper = "aurora"
            tryVerify(() => layer.decoded === 2, 3000, "the new picture decodes while the old one still shows")
            verify(layer.decoded <= 2)
            tryVerify(() => layer.front !== first && layer.front.source.toString().endsWith("/aurora.jpg"), 3000)
            tryCompare(layer, "decoded", 1, 5000)
            compare(first.source.toString(), "", "the old picture is released")
            compare(layer.covering, true, "never uncovered during the change")
            verify(layer.front.source.toString().endsWith("/aurora.jpg"))
            compare(find("backdrop").shown, false)

            // Under reduced motion there is no fade: the swap is at once and still releases.
            DeviceSettings.reducedMotion = true
            DeviceSettings.wallpaper = "ember"
            tryVerify(() => layer.front.source.toString().endsWith("/ember.jpg") && layer.front.opacity === 1, 3000)
            tryCompare(layer, "decoded", 1, 3000)
        }

        function test_a_bright_wallpaper_is_dimmed_until_text_is_legible() {
            const textLum = lum(Theme.text)
            compare(Wallpapers.requiredDim(0.02), 0, "a dark picture needs none")
            verify(Wallpapers.requiredDim(1.0) > 0.5 && Wallpapers.requiredDim(1.0) <= 0.75)
            for (const b of Wallpapers.bundled) {
                setWallpaper(b.id)
                const layer = find("wallpaperLayer")
                tryCompare(layer, "decoded", 1, 5000)
                // Worst case: white text over the picture's brightest part, darkened by the layer
                // (alpha a leaves (1 - a)^2.2 of the luminance).
                const under = b.peak * Math.pow(1 - layer.effectiveDim, 2.2)
                const contrast = (textLum + 0.05) / (under + 0.05)
                verify(contrast >= 4.5, b.id + ": contrast " + contrast.toFixed(2) + " at dim " + layer.effectiveDim.toFixed(2))
            }
            setWallpaper("daybreak")
            verify(find("wallpaperLayer").requiredDim > 0.4, "the bright one is dimmed hard")
            // The owner's dim never goes below the rule, and may go above it.
            DeviceSettings.wallpaperDim = 0
            compare(find("wallpaperLayer").effectiveDim, find("wallpaperLayer").requiredDim)
            setWallpaper("dusk")
            compare(find("wallpaperLayer").requiredDim, 0)
            DeviceSettings.wallpaperDim = 0.5
            compare(find("wallpaperLayer").effectiveDim, 0.5)
        }

        function test_the_dim_row() {
            openSettingsDisplay()
            verify(!find("rowWallpaperDim").visible, "the default look has nothing to dim")
            DeviceSettings.wallpaper = "dusk"
            tryVerify(() => find("rowWallpaperDim").visible)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("rowWallpaperDim").activeFocus)
            compare(find("rowWallpaperDim").value, 20)
            keyClick(Qt.Key_Right)
            compare(DeviceSettings.wallpaperDim, 0.25)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            compare(DeviceSettings.wallpaperDim, 0.15)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Left)
            compare(DeviceSettings.wallpaperDim, 0, "clamped at 0")
            for (let i = 0; i < 14; ++i)
                keyClick(Qt.Key_Right)
            compare(DeviceSettings.wallpaperDim, 0.6, "clamped at 60 %")
            verify(find("rowWallpaperDim").activeFocus)
            ignoreWarning("ruya-shell: rejecting out-of-range wallpaperDim 0.7")
            DeviceSettings.wallpaperDim = 0.7
            compare(DeviceSettings.wallpaperDim, 0.6)
        }

        function test_home_over_a_wallpaper_shows_it_instead_of_a_colour_field() {
            const artA = find("heroArtA")
            const artB = find("heroArtB")
            compare(artA.bare, false)
            setWallpaper("lagoon")
            compare(artA.bare, true, "an item without art leaves the wallpaper visible")
            compare(artB.bare, true)
            compare(artA.gradient.stops[0].color.a, 0, "the fill is clear")
            compare(artA.gradient.stops[1].color.a, 0)
            compare(find("heroArt").visible, true, "the legibility scrims stay")
            DeviceSettings.wallpaper = ""
            tryCompare(artA, "bare", false)
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            // Home over a dark and a bright wallpaper.
            setWallpaper("dusk")
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-home-dusk.png")
            setWallpaper("daybreak")
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-home-daybreak.png")
            setWallpaper("ember")
            DeviceSettings.effectsQuality = "performance"
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-home-performance.png")
            DeviceSettings.effectsQuality = "high"
            setWallpaper("aurora")

            // A page (Settings, Display) over the blurred wallpaper, dark and bright, and Performance.
            openSettingsDisplay()
            wait(1200)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-page-aurora.png")
            setWallpaper("daybreak")
            wait(1200)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-page-daybreak.png")
            DeviceSettings.effectsQuality = "performance"
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-page-daybreak-performance.png")
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.wallpaper = ""
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-page-default.png")

            // The picker: the library with copies, then the drive's pictures.
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus)
            Wallpapers.mockPrepareUsb()
            Wallpapers.mockFillUser(5)
            Storage.mockPlugStick()
            tryVerify(() => Wallpapers.usbImages.length === 4, 5000)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("wallpaperPicker").shown)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-picker.png")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-picker-scrolled.png")
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(find("wallpaperPicker"), "mode", "usb")
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-picker-usb.png")
            DeviceSettings.language = "tr"
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-picker-usb-tr.png")
            DeviceSettings.language = "en"
        }
    }
}
