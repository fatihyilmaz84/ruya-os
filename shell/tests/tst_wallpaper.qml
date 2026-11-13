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
    // A stand-in for a game in front of the shell (T-387).
    Component {
        id: appComponent
        Item { objectName: "standInApp"; Keys.onPressed: event => { event.accepted = true } }
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
        property int lastBakes: -1

        // True when the sheet's capture count has stopped changing: a late height change of the picker
        // (the owner sizes it a moment after it opens) re-bakes once through Qt.callLater, and that bake
        // must have landed before the count is read.
        function bakesSettled(sheet) {
            const stable = sheet.bakeCount === tc.lastBakes
            tc.lastBakes = sheet.bakeCount
            return stable && sheet.bakeCount >= 1
        }

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
            DeviceSettings.theme = "dreamglass"
            tryCompare(Theme, "mix", 1, 3000)
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
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Down)                    // Display & motion
            compare(find("categoryList").currentIndex, 4)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus, 2000, "first row takes focus")
        }

        // The blurred copy of the wallpaper (if there is one) has finished fading to where the page wants it.
        function blurSettled() {
            const blur = find("wallpaperBlur")
            return !blur || blur.opacity === (find("wallpaperLayer").blurred ? 1 : 0)
        }

        // Settings -> Display & motion -> the Wallpaper row -> Accept: the picker, on the current tile.
        function openPicker() {
            openSettingsDisplay()
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Down)                    // Quality, Motion, Screen edge, Theme (T-209), Wallpaper
            verify(find("rowWallpaper").activeFocus, "the Wallpaper row")
            // T-462: the sheet captures L0 once, when the picker opens. Opened while the page's blur is
            // still fading in (pageMs), the capture holds a half-blurred L0 (a few levels off, a different
            // amount each run) and a later opening, on a settled page, differs from it.
            tryVerify(() => blurSettled(), 3000, "the page's blur of the wallpaper has settled")
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

        function contrast(a, b) {
            return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)
        }

        // The contrast of `text` over a grey of luminance `grey` under a layer of colour `layer` at `alpha`,
        // composited in sRGB (what the scene graph does).
        function contrastUnder(text, layer, grey, alpha) {
            const toS = l => l <= 0.0031308 ? 12.92 * l : 1.055 * Math.pow(l, 1 / 2.4) - 0.055
            const s = toS(grey)
            const mixed = Qt.rgba((1 - alpha) * s + alpha * layer.r, (1 - alpha) * s + alpha * layer.g, (1 - alpha) * s + alpha * layer.b, 1)
            return contrast(lum(text), lum(mixed))
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
            Wallpapers.mockImportAny(dir + "huge.png", Theme.background)
            tryCompare(copySpy, "count", 1, 5000)
            compare(copySpy.signalArguments[0][0], "too-large", "over 40 megapixels")
            Wallpapers.mockImportAny(dir + "broken.jpg", Theme.background)
            tryCompare(copySpy, "count", 2, 5000)
            compare(copySpy.signalArguments[1][0], "unreadable")
            Wallpapers.mockImportAny(dir + "notes.txt", Theme.background)
            tryCompare(copySpy, "count", 3, 5000)
            compare(copySpy.signalArguments[2][0], "unreadable")
            Wallpapers.mockImportAny(dir + "old.bmp", Theme.background)
            tryCompare(copySpy, "count", 4, 5000)
            compare(copySpy.signalArguments[3][0], "unsupported", "a picture, but not jpg/png/webp")
            Wallpapers.mockImportAny(root + "/does-not-exist.jpg", Theme.background)
            tryCompare(copySpy, "count", 5, 5000)
            compare(copySpy.signalArguments[4][0], "unreadable")
            compare(Wallpapers.user.length, 0, "nothing was stored")
            compare(Wallpapers.copyState, "idle")
        }

        // The mock stick's pictures, listed (importFile takes only a listed path).
        function scanMock() {
            Wallpapers.scanUsb(["/run/media/mock/Ruya Stick"])
            tryVerify(() => Wallpapers.usbImages.length === 4, 5000)
        }
        function listedPath(name) {
            return Wallpapers.usbImages.find(e => e.name === name).path
        }

        function test_the_same_picture_twice_is_one_copy() {
            Wallpapers.mockPrepareUsb()
            scanMock()
            Wallpapers.importFile(listedPath("photo"), Theme.background)
            tryCompare(copySpy, "count", 1, 5000)
            Wallpapers.importFile(listedPath("photo"), Theme.background)
            tryCompare(copySpy, "count", 2, 5000)
            compare(copySpy.signalArguments[1][0], "ok")
            compare(copySpy.signalArguments[1][1], copySpy.signalArguments[0][1])
            compare(Wallpapers.user.length, 1)
        }

        function test_import_takes_only_a_listed_path() {
            const root = Wallpapers.mockPrepareUsb()
            scanMock()
            Wallpapers.importFile(root + "/Ruya Stick/Other/hidden.jpg", Theme.background)   // a picture, but not listed
            tryCompare(copySpy, "count", 1, 5000)
            compare(copySpy.signalArguments[0][0], "unreadable")
            Wallpapers.importFile("C:/Windows/win.ini", Theme.background)
            tryCompare(copySpy, "count", 2, 5000)
            compare(copySpy.signalArguments[1][0], "unreadable")
            compare(Wallpapers.user.length, 0)
            Wallpapers.importFile(listedPath("tiny"), Theme.background)
            tryCompare(copySpy, "count", 3, 5000)
            compare(copySpy.signalArguments[2][0], "ok")
        }

        function test_the_settings_survive_a_restart() {
            compare(wallpaperPersistence, "", "a restart keeps the wallpaper and dim, a bad stored value falls back: " + wallpaperPersistence)
        }

        function test_the_focused_tile_has_a_ring_outside_the_art() {
            openPicker()
            const u = tc.shell.u
            const grid = find("wallpaperGrid")
            const ring = find("wallpaperRing_")
            const art = find("wallpaperTile_")
            tryVerify(() => ring.visible, 2000, "the focused (default) tile has the ring")
            compare(ring.border.width, Theme.focusRingWidth * u)
            compare(ring.border.color, Theme.focusRing)
            verify(Math.abs((ring.width - art.width) - 2 * Theme.focusRingOffset * u) < 0.01, "outside the art at focusRingOffset")
            compare(find("wallpaperRing_dusk").visible, false)
            keyClick(Qt.Key_Right)
            compare(grid.currentIndex, 1)
            verify(find("wallpaperRing_dusk").visible)
            compare(ring.visible, false, "only the focused tile")
            // The ring is not clipped at the edge: the first tile's ring lies inside the clipping frame.
            keyClick(Qt.Key_Left)
            const frame = find("wallpaperGridFrame")
            const p = ring.mapToItem(frame, 0, 0)
            verify(p.x >= 0 && p.y >= 0, "inside the frame: " + p.x + "," + p.y)
            compare(frame.clip, true)
            compare(grid.count, 7)
            compare(Math.round(grid.width / grid.cellWidth), 4, "four columns")
            // Focus on the buttons: no ring on any tile (the highlighted tile keeps a hairline).
            Wallpapers.mockPrepareUsb()
            Storage.mockPlugStick()
            tryVerify(() => find("wallpaperAddUsb").visible, 5000)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(find("wallpaperAddUsb").activeFocus)
            compare(ring.visible, false)
        }

        // T-387: a tile's picture is not hidden while it loads. An Image that is not ready draws nothing,
        // and one turned visible only after the first frame inside the hidden layer source of the tile's
        // mask never showed on a GPU (every tile blank in `shots`).
        function test_a_tile_picture_is_not_hidden_while_it_loads() {
            openPicker()
            // `visible` is the effective one: wait for the picker's fade-in before reading the pictures'.
            tryVerify(() => find("wallpaperTile_").visible, 2000, "the tiles are shown")
            for (const id of ["", "dusk", "aurora", "daybreak"]) {
                const img = find("wallpaperTileImage_" + id)
                verify(img, "the tile's picture: " + id)
                verify(img.visible, "visible whatever its status (" + img.status + "): " + id)
            }
            compare(find("wallpaperTileImage_").status, Image.Null, "the default look has no picture")
            tryCompare(find("wallpaperTileImage_dusk"), "status", Image.Ready, 5000)
            verify(find("wallpaperTileImage_dusk").visible)
        }

        // T-387: behind an app L0 is at opacity 0 but stays `visible` (an L0 hidden with `visible` and shown
        // again baked an empty crop into the sheet on a GPU), the sheet does not capture it then, and an
        // open sheet captures again once the app has gone.
        function test_the_sheet_captures_again_after_an_app() {
            openPicker()
            const sheet = find("wallpaperPanel")
            const l0 = find("l0")
            sheet.gpu = true                              // the blurred branch, reached offscreen
            verify(sheet.blurred)
            verify(sheet.sourceDrawn, "L0 is drawn under the picker")
            sheet.bake()                                  // the opening's capture was skipped on the software renderer
            tc.lastBakes = -1
            tryVerify(() => tc.bakesSettled(sheet), 3000, "the captures settle")
            const before = sheet.bakeCount
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app)
            tryVerify(() => app.activeFocus, 2000, "the app takes focus")
            compare(l0.opacity, 0, "L0 is not drawn behind the app")
            compare(l0.visible, true, "L0 keeps its place in the scene graph (no visible toggle)")
            compare(sheet.sourceDrawn, false)
            sheet.bake()
            compare(sheet.bakeCount, before, "no capture of L0 while it is not drawn")
            tc.shell.removeApp(app)
            tryVerify(() => sheet.bakeCount === before + 1, 2000, "the open sheet captures L0 again once it is drawn: "
                      + sheet.bakeCount + " vs " + before)
            verify(sheet.sourceDrawn)
        }

        // T-272: the panel is the glass sheet (not a flat `panel` card) and the picture is cut to the radius
        // of the hairline and the ring around it.
        function test_the_panel_is_glass_and_the_thumbnails_are_rounded() {
            DeviceSettings.wallpaper = "dusk"
            openPicker()
            const u = tc.shell.u
            const panel = find("wallpaperPanel")
            verify(panel.layers !== undefined, "the panel is a GlassSheet")
            for (const key of Themes.keys) {
                DeviceSettings.theme = key
                tryCompare(Theme, "mix", 1, 3000)
                compare(panel.fillColor, panel.blurred ? Theme.glassStrong : Theme.glassOpaque, key)
                verify(!Qt.colorEqual(panel.fillColor, Theme.panel), key + ": not the flat panel fill")
                verify(findChild(panel, "glassSheetLayers").tintVisible, key + ": the tint of a modal")
            }
            DeviceSettings.theme = "dreamglass"
            tryCompare(Theme, "mix", 1, 3000)
            compare(panel.radius, Theme.radiusL * u)
            // Every tile: the mask and the hairline have the tile's radius, and the ring hugs it.
            const gpu = host.GraphicsInfo.api !== GraphicsInfo.Software
            for (const id of ["", "dusk", "daybreak"]) {
                const art = find("wallpaperTile_" + id)
                compare(art.radius, Theme.radiusM * u)
                compare(art.maskRadius, Theme.radiusM * u, "the picture is masked to radiusM: " + id)
                compare(find("wallpaperHairline_" + id).radius, art.radius, "the hairline has the picture's radius: " + id)
                // T-314: the cut keeps the mask's antialiased edge (MultiEffect's default makes hard steps).
                checkSmoothCut(find("wallpaperTileMask_" + id), "tile " + id)
                compare(art.masked, gpu, "masked on a GPU only: " + id)
                compare(find("wallpaperTileMask_" + id).visible, gpu, "the mask is drawn on a GPU only: " + id)
            }
            const ring = find("wallpaperRing_")
            compare(ring.radius, find("wallpaperTile_").radius + Theme.focusRingOffset * u, "the ring follows the picture's shape")
            // The blur's mask is handed over only while its layer is on, which is on the blurred branch (T-387).
            panel.gpu = true
            checkSmoothCut(findChild(panel, "glassSheetBlur"), "the sheet's blur")
            panel.gpu = host.GraphicsInfo.api !== GraphicsInfo.Software
            // The Current badge sits inside the tile's corner.
            const badge = find("wallpaperCurrent_dusk")
            verify(badge.visible)
            const at = badge.mapToItem(find("wallpaperTile_dusk"), 0, 0)
            verify(at.x >= Theme.spaceXs * u - 0.01 && at.y >= Theme.spaceXs * u - 0.01, "inside the corner: " + at.x + "," + at.y)
            // The drive's pictures are rounded the same way.
            Wallpapers.mockPrepareUsb()
            Storage.mockPlugStick()
            tryVerify(() => find("wallpaperAddUsb").visible, 5000)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(find("wallpaperPicker"), "mode", "usb")
            compare(find("wallpaperPanel").layers !== undefined, true)
            compare(find("wallpaperTile_0").maskRadius, Theme.radiusM * u, "the USB grid is masked too")
            compare(find("wallpaperHairline_0").radius, Theme.radiusM * u, "the USB hairline")
            checkSmoothCut(find("wallpaperTileMask_0"), "a USB tile")
        }

        function checkSmoothCut(fx, what) {
            verify(fx, what + ": the effect exists")
            compare(fx.maskEnabled, true, what)
            compare(fx.maskThresholdMin, 0.5, what + ": the 50 % point of the mask is the outline")
            compare(fx.maskSpreadAtMin, 1, what + ": a one-pixel ramp, not a step")
            compare(fx.maskSource.layer.smooth, true, what + ": the mask's layer is filtered")
        }

        function test_the_ring_reads_against_the_panel_in_every_theme() {
            for (const key of Themes.keys) {
                DeviceSettings.theme = key
                tryCompare(Theme, "mix", 1, 3000)
                compare(Theme.panel.a, 1, key + ": the panel is opaque")
                const c = contrast(lum(Theme.focusRing), lum(Theme.panel))
                verify(c >= 3, key + ": ring against the panel " + c.toFixed(2))
            }
        }

        function test_pulling_the_drive_moves_focus_off_the_add_button() {
            openPicker()
            Wallpapers.mockPrepareUsb()
            Storage.mockPlugStick()
            tryVerify(() => find("wallpaperAddUsb").visible, 5000)
            for (let i = 0; i < 2; ++i)
                keyClick(Qt.Key_Down)
            verify(find("wallpaperAddUsb").activeFocus)
            Storage.mockReset(false)
            tryVerify(() => !find("wallpaperAddUsb").visible, 5000)
            verify(find("wallpaperGrid").activeFocus, "focus is on the grid, not on a hidden button")
        }

        function test_names_from_a_drive_are_plain_text() {
            openPicker()
            const label = find("wallpaperLabel_dusk")
            compare(label.textFormat, Text.PlainText)
            compare(findChild(find("rowWallpaper"), "value").textFormat, Text.PlainText)
        }

        function test_the_copy_limit_and_delete_one_to_add_another() {
            Wallpapers.mockPrepareUsb()
            scanMock()
            Wallpapers.mockFillUser(12)
            compare(Wallpapers.user.length, 12)
            Wallpapers.importFile(listedPath("photo"), Theme.background)
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

        // T-421: the default look (the blobs, no wallpaper) is blurred on pages as a picture is, so the
        // page's glass never sits over the blobs' sharp edges (04 §3.6; on the Dell the Settings rows
        // showed them). One blurred L0 copy at a time: a wallpaper hides the backdrop and its blur.
        function test_the_default_look_is_blurred_on_pages() {
            const backdrop = find("backdrop")
            compare(DeviceSettings.wallpaper, "")
            verify(backdrop.shown, "the default look")
            // Home: the blurred copy is not drawn.
            compare(backdrop.blurred, false)
            const idle = find("backdropBlur")
            verify(idle !== null, "the blurred copy is ready")
            compare(idle.opacity, 0)
            compare(idle.visible, false)
            compare(find("backdropReduced").hideSource, false, "the sharp fields are drawn on Home")
            compare(find("backdropReduced").live, false, "the texture is not re-rendered on Home (T-434)")

            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList") !== null && find("categoryList").activeFocus, 2000, "the category list has focus")
            compare(backdrop.blurActive, true)
            const blur = find("backdropBlur")
            compare(blur.blurEnabled, true)
            compare(blur.blur, 1)
            // T-434: the blur's passes run at a quarter of the screen and are drawn scaled up; blurMax is
            // in the effect's own pixels, a third of the tier's (matched to the old look in the shots).
            compare(blur.width, Math.round(tc.shell.width / 4))
            compare(blur.height, Math.round(tc.shell.height / 4))
            compare(blur.blurMax, Math.round(64 / 3))
            compare(blur.mapToItem(tc.shell, blur.width, blur.height), Qt.point(tc.shell.width, tc.shell.height), "it covers the screen")
            verify(find("backdropReduced").live, "the texture follows the drifting blobs on a page")
            tryCompare(blur, "opacity", 1)
            verify(blur.visible, "drawn on the page")
            verify(blur.source.sourceItem === find("backdropFields"), "it blurs the backdrop's own fields")
            // tryCompare(opacity, 1) above is fuzzy; hideSource waits for the fade's exact end (CI red once, lead-9).
            tryVerify(() => find("backdropReduced").hideSource, 2000, "the sharp fields are not drawn under the opaque copy")
            compare(find("wallpaperBlur"), null, "no second full-screen blur")

            DeviceSettings.effectsQuality = "balanced"
            compare(find("backdropBlur").blurMax, Math.round(32 / 3))
            DeviceSettings.effectsQuality = "performance"
            tryVerify(() => find("backdropBlur") === null, 2000, "no blur item on the Performance tier")
            DeviceSettings.effectsQuality = "high"
            tryVerify(() => find("backdropBlur") !== null && find("backdropBlur").opacity === 1, 2000, "back with High")

            // A wallpaper covers the backdrop: its blur goes, the picture's blurred copy is the one.
            setWallpaper("dusk")
            verify(!backdrop.shown)
            tryVerify(() => find("backdropBlur") === null, 2000, "the backdrop's blur goes with it")
            tryCompare(find("wallpaperBlur"), "opacity", 1)

            keyClick(Qt.Key_Escape)                      // list -> Home
            tryCompare(tc.shell, "currentPage", "")
            tryVerify(() => find("sectionNav").activeFocus, 2000, "focus back on the section nav")
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

        function test_every_wallpaper_is_legible_under_every_theme() {
            const lines = []
            for (const key of Themes.keys) {
                DeviceSettings.theme = key
                tryCompare(Theme, "mix", 1, 3000)
                const lightTheme = lum(Theme.text) < lum(Theme.background)
                for (const b of Wallpapers.bundled) {
                    DeviceSettings.wallpaper = b.id
                    const layer = find("wallpaperLayer")
                    tryCompare(layer, "target", b.source)
                    // The worst part: the brightest for light text, the darkest for dark text.
                    const worst = lightTheme ? b.floor : b.peak
                    const c = contrastUnder(Theme.text, Theme.background, worst, layer.effectiveDim)
                    verify(c >= 4.5, key + " / " + b.id + ": " + c.toFixed(2) + ":1 at dim " + layer.effectiveDim.toFixed(3))
                    compare(layer.effectiveDim, Math.max(DeviceSettings.wallpaperDim, layer.requiredDim))
                    lines.push(key + "/" + b.id + " dim " + layer.effectiveDim.toFixed(3) + " " + c.toFixed(2))
                }
            }
            console.info(lines.join(" | "))
        }

        function test_the_dim_rule_follows_the_theme() {
            // Dreamglass: a dark picture needs nothing, Daybreak a heavy dim, and the layer is the
            // background colour, not black: the old black model gave 4.30:1 at its 52 %.
            DeviceSettings.wallpaper = "daybreak"
            const layer = find("wallpaperLayer")
            tryCompare(layer, "target", Wallpapers.bundled.find(b => b.id === "daybreak").source)
            verify(layer.requiredDim > 0.52, "more than the black model needs: " + layer.requiredDim)
            verify(contrastUnder(Theme.text, Qt.color("#000000"), 0.8217, 0.523) > 4.5, "black at 52.3 % was the (wrong) model")
            verify(contrastUnder(Theme.text, Theme.background, 0.8217, 0.523) < 4.5, "the real layer at 52.3 % is below 4.5:1")
            DeviceSettings.wallpaperDim = 0
            compare(layer.effectiveDim, layer.requiredDim, "the slider never goes below the rule")
            DeviceSettings.wallpaper = "dusk"
            tryCompare(layer, "target", Wallpapers.bundled.find(b => b.id === "dusk").source)
            compare(layer.requiredDim, 0, "a dark picture under a dark theme needs none")
            DeviceSettings.wallpaperDim = 0.5
            compare(layer.effectiveDim, 0.5, "and the owner may dim it anyway")
            // Daylight turns it round: dark text, a light wash over a dark picture, nothing over a bright one.
            DeviceSettings.wallpaperDim = 0
            DeviceSettings.theme = "daylight"
            tryCompare(Theme, "mix", 1, 3000)
            verify(layer.requiredDim > 0.4, "a light wash over Dusk under Daylight: " + layer.requiredDim)
            DeviceSettings.wallpaper = "daybreak"
            tryCompare(layer, "target", Wallpapers.bundled.find(b => b.id === "daybreak").source)
            compare(layer.requiredDim, 0, "Daybreak's darkest part already carries dark text")
            // The numbers behind it, straight from the function.
            compare(Wallpapers.requiredDim(0.02, 0.01, "#05070d", "#f2f4f8"), 0)
            verify(Wallpapers.requiredDim(1, 1, "#05070d", "#f2f4f8") > 0.5)
            verify(Wallpapers.requiredDim(1, 1, "#05070d", "#f2f4f8") <= 0.85)
            verify(Wallpapers.requiredDim(0.02, 0.01, "#eef1f7", "#0f1420") > 0.4)
        }

        function test_the_theme_fade_moves_the_dim_colour_with_it() {
            Theme.motionFactor = 1.0           // real time: the subject is a sample while the cross-fade runs (T-463; red on CI at 0.1)
            DeviceSettings.wallpaper = "dusk"
            const layer = find("wallpaperLayer")
            tryCompare(layer, "covering", true, 5000)
            const dim = find("wallpaperDim")
            compare(dim.color, Theme.background)
            DeviceSettings.theme = "daylight"
            tryVerify(() => Theme.mix > 0 && Theme.mix < 1, 2000, "the cross-fade runs")
            compare(dim.color, Theme.background, "the dim layer follows the blended background")
            tryCompare(Theme, "mix", 1, 3000)
            compare(dim.color, Theme.background)
            verify(lum(dim.color) > 0.5, "a light wash")
            compare(layer.covering, true, "the picture stays")
        }

        function test_the_dim_row() {
            openSettingsDisplay()
            verify(!find("rowWallpaperDim").visible, "the default look has nothing to dim")
            DeviceSettings.wallpaper = "dusk"
            tryVerify(() => find("rowWallpaperDim").visible)
            for (let i = 0; i < 5; ++i)
                keyClick(Qt.Key_Down)                    // ... Theme, Wallpaper, Dim wallpaper
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

        // T-286: the row shows the dim that is applied. Daybreak is a bright picture: under a dark theme
        // the rule veils it harder than the slider (20 %), and the number follows the layer; a dark
        // picture shows the slider's own value.
        function test_dim_row_shows_effective_dim() {
            openSettingsDisplay()
            const layer = find("wallpaperLayer")
            const row = find("rowWallpaperDim")
            DeviceSettings.wallpaper = "dusk"
            tryVerify(() => row.visible)
            tryCompare(layer, "blurred", true)
            compare(row.value, 20)
            compare(row.shownValue, 20, "a dark picture needs nothing beyond the slider")
            compare(findChild(row, "value").text, "20%")

            DeviceSettings.wallpaper = "daybreak"
            tryVerify(() => layer.requiredDim > 0.5)
            compare(row.value, 20, "the slider keeps the owner's position")
            verify(row.shownValue > row.value, "the bright picture raises the shown value: " + row.shownValue)
            compare(findChild(row, "value").text, Math.round(layer.effectiveDim * 100) + "%")
            verify(row.Accessible.name.indexOf(findChild(row, "value").text) >= 0, "a reader hears the applied dim: " + row.Accessible.name)

            DeviceSettings.wallpaperDim = 0.6
            tryCompare(row, "shownValue", 60)
            compare(findChild(row, "value").text, "60%", "an owner dim above the rule shows as set")

            // The rule can ask for more than the row's scale (up to 85 % against 60): the fill stops at the track.
            const fill = findChild(row, "valueFill")
            verify(fill !== null, "the bar has a named fill")
            verify(fill.width <= fill.parent.width, "the fill is " + fill.width + " of a track " + fill.parent.width)
            row.shownValue = 85
            compare(findChild(row, "value").text, "85%")
            compare(fill.width, fill.parent.width, "a shown value past `to` fills the track and no more")
            row.shownValue = -20
            compare(fill.width, 0, "and one under `from` fills nothing")
        }

        // True when no UTF-16 unit of the string is half of a pair.
        function wellFormed(text) {
            for (let i = 0; i < text.length; ++i) {
                const c = text.charCodeAt(i)
                if (c >= 0xd800 && c <= 0xdbff) {
                    const d = text.charCodeAt(i + 1)
                    if (!(d >= 0xdc00 && d <= 0xdfff))
                        return false
                    ++i
                } else if (c >= 0xdc00 && c <= 0xdfff) {
                    return false
                }
            }
            return true
        }

        // T-286: a name from a drive is cut by code points. An emoji is kept or cut whole; a name of
        // nothing but emoji is not "Wallpaper"; a long name is cut to 40 characters.
        function test_safe_name_code_points() {
            const game = String.fromCodePoint(0x1F3AE)
            const bell = String.fromCharCode(7)
            // The filter itself, for a name that this machine's file system could not hold (300 characters).
            compare(Wallpapers.mockSafeName("a".repeat(300)), "a".repeat(40))
            const edge = Wallpapers.mockSafeName("x".repeat(39) + game + "y".repeat(260))
            verify(wellFormed(edge), "the emoji at the cut is whole")
            compare(edge, "x".repeat(39) + game)
            compare(Wallpapers.mockSafeName("x".repeat(41) + game), "x".repeat(40), "an emoji past the cut goes whole")
            compare(Wallpapers.mockSafeName("a" + bell + "b" + String.fromCharCode(10) + game), "ab" + game, "control characters go, the emoji stays")
            compare(Wallpapers.mockSafeName(""), "Wallpaper")
            compare(Wallpapers.mockSafeName(bell + bell), "Wallpaper")

            // Copies of files with such names: the copy succeeds and the name keeps its emoji.
            const names = ["Holiday " + game + " 2026", game + game + game, "n".repeat(150)]
            const expected = ["Holiday " + game + " 2026", game + game + game, "n".repeat(40)]
            for (let i = 0; i < names.length; ++i) {
                const path = Wallpapers.mockPlantPicture(names[i])
                verify(path.length > 0, "a picture was planted for " + i)
                copySpy.clear()
                Wallpapers.mockImportAny(path, Theme.background)
                tryCompare(copySpy, "count", 1, 5000)
                compare(copySpy.signalArguments[0][0], "ok", "the copy of name " + i + " succeeds")
                const w = Wallpapers.user[Wallpapers.user.length - 1]
                verify(wellFormed(w.name), "no lone surrogate in " + i)
                compare(w.name, expected[i], "name " + i + " became [" + w.name + "] (" + w.name.length + " units)")
            }
            compare(Wallpapers.user.length, 3)
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

        // Samples of the sheet's glass in its left margin (no content there), as [r, g, b] in 0..255.
        function sheetSamples(sheet) {
            const img = grabImage(tc.shell)
            const scale = img.width / tc.shell.width
            const at = sheet.mapToItem(tc.shell, 0, 0)
            const x = Math.round((at.x + Theme.spaceXl * sheet.u / 2) * scale)
            const out = []
            for (let i = 1; i < 12; ++i) {
                const y = Math.round((at.y + sheet.height * i / 12) * scale)
                out.push([img.red(x, y), img.green(x, y), img.blue(x, y)])
            }
            return out
        }

        // The largest per-channel difference between two sample sets.
        function sampleDistance(a, b) {
            let d = 0
            for (let i = 0; i < a.length; ++i)
                for (let c = 0; c < 3; ++c)
                    d = Math.max(d, Math.abs(a[i][c] - b[i][c]))
            return d
        }

        // T-387: after a game was in front, the picker's glass sheet is the blurred wallpaper again, the
        // same as a fresh opening (the baked crop of L0 came out empty: flat grey with grain).
        function test_zz_sheet_after_an_app_data() {
            return [{ tag: "reopened", app: false }, { tag: "app", app: true }]
        }

        function test_zz_sheet_after_an_app(data) {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            setWallpaper("daybreak")
            openPicker()
            const sheet = find("wallpaperPanel")
            compare(sheet.blurred, true, "the sheet draws the blur")
            tc.lastBakes = -1
            tryVerify(() => tc.bakesSettled(sheet), 3000, "the captures settle")
            wait(900)
            const fresh = sheetSamples(sheet)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-picker-fresh-" + data.tag + ".png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("wallpaperPicker").shown)
            tryVerify(() => !sheet.engaged, 3000, "the sheet let its crop go")
            tryVerify(() => find("rowWallpaper").activeFocus, 2000)

            if (data.app) {
                const app = createTemporaryObject(appComponent, host)
                tc.shell.addApp(app)
                tryVerify(() => app.activeFocus, 2000, "the app takes focus")
                wait(1500)
                tc.shell.removeApp(app)
                tryVerify(() => find("rowWallpaper").activeFocus, 2000, "the page has the focus back")
            }
            wait(600)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("wallpaperPicker").shown)
            tc.lastBakes = -1
            tryVerify(() => tc.bakesSettled(sheet), 3000, "the captures settle")
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-picker-again-" + data.tag + ".png")
            const after = sheetSamples(sheet)
            const d = sampleDistance(fresh, after)
            verify(d <= 12, data.tag + ": the sheet matches a fresh opening (max channel difference " + d
                   + "): " + JSON.stringify(fresh) + " vs " + JSON.stringify(after))
        }

        // T-421 (GPU): on a page the default look is blurred, so no blob edge is sharp behind the page's
        // glass. The blobs are held still (reduced motion) with the first blob's edge crossing the
        // left margin, where only L0 is drawn; along that row the largest step between neighbouring
        // pixels is a sharp edge's height without the blur and a few levels with it.
        function test_zz_default_look_page_is_blurred() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            compare(DeviceSettings.wallpaper, "")
            DeviceSettings.reducedMotion = true          // the blobs stand still
            const blob = find("blobA")
            tryVerify(() => !find("backdrop").drifting, 2000, "the blobs rest")
            blob.driftX = 0
            blob.driftY = 0
            openSettingsDisplay()
            tryCompare(find("backdrop"), "blurred", true)      // instant under reduced motion (pageMs 0)
            const r = blob.width / 2
            const cx = blob.x + r
            const cy = blob.y + r
            const xt = tc.shell.marginX / 2
            verify(Math.abs(cx - xt) < r, "the blob's edge crosses the margin")
            const y = cy + Math.sqrt(r * r - (cx - xt) * (cx - xt))
            verify(y > tc.shell.height * 0.2 && y < tc.shell.height * 0.85, "below the header and above the hint bar: " + y)
            waitForRendering(tc.shell)
            wait(300)
            const img = grabImage(tc.shell)
            img.save(shotsDir + "/70-wallpaper-page-default-blurred.png")
            const scale = img.width / tc.shell.width
            const py = Math.round(y * scale)
            let step = 0
            for (let x = 2; x < Math.round((tc.shell.marginX - 4) * scale); ++x) {
                step = Math.max(step, Math.abs(img.red(x + 1, py) - img.red(x, py)),
                                Math.abs(img.green(x + 1, py) - img.green(x, py)),
                                Math.abs(img.blue(x + 1, py) - img.blue(x, py)))
            }
            verify(step < 6, "no sharp blob edge on the page (largest step " + step + " on row " + py + ")")
            keyClick(Qt.Key_Escape)                      // pane -> list
            tryVerify(() => find("categoryList").activeFocus)
        }

        // T-434 (GPU): on the Performance tier nothing is blurred, so the Settings rows are opaque glass
        // (glassOpaque) over the sharp blobs, never translucent (04 §3.6). The shot is for review.
        function test_zz_performance_page_rows_are_opaque() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            compare(DeviceSettings.wallpaper, "")
            DeviceSettings.effectsQuality = "performance"
            openSettingsDisplay()
            tryVerify(() => find("backdropBlur") === null, 2000, "no blur on Performance")
            const fill = findChild(find("rowWallpaper"), "rowFill")
            tryCompare(fill, "color", Theme.glassOpaque, 2000, "an unfocused row is opaque glass")
            verify(find("rowQuality").activeFocus, "the first row keeps focus")
            waitForRendering(tc.shell)
            wait(300)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-page-default-performance.png")
            keyClick(Qt.Key_Escape)                      // pane -> list
            tryVerify(() => find("categoryList").activeFocus)
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

            // Daylight (a light theme): Dusk gets a light wash, Daybreak none; Home and a page.
            DeviceSettings.theme = "daylight"
            tryCompare(Theme, "mix", 1, 3000)
            setWallpaper("dusk")
            wait(1200)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-page-dusk-daylight.png")
            setWallpaper("daybreak")
            wait(1200)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-page-daybreak-daylight.png")
            keyClick(Qt.Key_Escape)                      // pane -> list
            tryVerify(() => find("categoryList").activeFocus)
            keyClick(Qt.Key_Escape)                      // list -> Home
            tryCompare(tc.shell, "currentPage", "")
            wait(1200)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-home-daybreak-daylight.png")
            setWallpaper("dusk")
            wait(1200)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-home-dusk-daylight.png")
            DeviceSettings.theme = "dreamglass"
            tryCompare(Theme, "mix", 1, 3000)
            DeviceSettings.wallpaper = ""
            tryVerify(() => find("sectionNav").activeFocus)
            keyClick(Qt.Key_Return)                      // the nav is on Settings
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Down)                    // Display & motion
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)

            // The picker: the library with copies, then the drive's pictures.
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus)
            Wallpapers.mockPrepareUsb()
            Wallpapers.mockFillUser(5)
            Storage.mockPlugStick()
            tryVerify(() => Wallpapers.usbImages.length === 4, 5000)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("rowQuality").activeFocus)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("wallpaperPicker").shown)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            wait(900)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-picker.png")
            // On a GPU the sheet blurs L0 (found on the modal layer) and bakes it once for this opening.
            const sheet = find("wallpaperPanel")
            compare(sheet.blurred, true, "the sheet found L0 and draws the blur")
            tc.lastBakes = -1
            tryVerify(() => tc.bakesSettled(sheet), 3000, "the captures settle")
            const settled = sheet.bakeCount
            verify(settled <= 2, "one capture for the opening, at most one more for a late resize: " + settled)
            wait(500)                                    // frames are drawn meanwhile
            compare(sheet.bakeCount, settled, "captured once per size, not per frame")
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
            // Daylight: the dark ring on the white and the dark thumbnails.
            DeviceSettings.theme = "daylight"
            tryCompare(Theme, "mix", 1, 3000)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-picker-usb-daylight.png")
            keyClick(Qt.Key_Escape)                      // back to the library
            compare(find("wallpaperPicker").mode, "library")
            keyClick(Qt.Key_Right)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/70-wallpaper-picker-daylight.png")
        }
    }
}
