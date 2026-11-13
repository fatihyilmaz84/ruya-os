import QtQuick
import QtTest
import RuyaShell

// System UI: toasts and the volume OSD. Neither may ever take focus; the volume keys work
// in every state. Driven with controller/media keys only. Signs in as "Ada" (p2, no PIN),
// except where a test needs the PIN pad (Player One, PIN 1234).
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
        name: "SystemUi"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            Audio.setVolume(50)
            if (Audio.muted)
                Audio.toggleMute()
            tryCompare(Audio, "volume", 50)
            tryCompare(Audio, "muted", false)
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
        }

        function cleanup() {
            Notifications.durationMs = Theme.toastMs
            Notifications.appInFront = false
            DeviceSettings.reducedMotion = false
            DeviceSettings.language = "en"
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
            NotificationCentre.mockReset()
            tryCompare(NotificationCentre, "dontInterruptGames", true)
        }

        // activeFocus is false everywhere when the OS deactivates the test window (another
        // window grabbing focus during a long test). The item's own `focus` flag still shows
        // that the shell kept focus where it belongs, so fall back to it only in that case.
        function hasFocus(item) {
            return item.activeFocus || (!host.Window.window.active && item.focus)
        }

        function signInAsAda() {
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function test_toast_never_steals_focus() {
            keyClick(Qt.Key_Return)                    // Player One has a PIN: the pad opens
            tryVerify(() => find("pinPad").shown)
            tryVerify(() => find("pinKeys").activeFocus)
            const before = host.Window.activeFocusItem
            verify(before)

            Notifications.show("Controller connected", "info")
            tryCompare(Notifications.model, "count", 1)
            tryVerify(() => find("toastList").count === 1)
            compare(host.Window.activeFocusItem, before)

            Notifications.show("Update ready", "success", "!")
            Notifications.show("Low battery", "warning")
            Notifications.show("Disk error", "error")
            compare(host.Window.activeFocusItem, before)
            verify(find("pinKeys").activeFocus)
            keyClick(Qt.Key_Right)                     // the pad still gets the keys
            compare(find("pinKeys").currentIndex, 1)
        }

        function test_toast_queue() {
            signInAsAda()
            Notifications.durationMs = 400
            const base = Notifications.shownCount      // cumulative across tests
            for (let i = 1; i <= 5; ++i)
                Notifications.show("Toast " + i, "info")
            compare(Notifications.model.count, 3, "at most 3 visible")
            compare(Notifications.pendingCount, 2)
            verify(find("toastList").count <= 3)

            tryCompare(Notifications, "shownCount", base + 5, 5000, "all five are shown eventually")
            verify(Notifications.model.count <= 3)
            tryCompare(Notifications.model, "count", 0, 5000, "and each goes away by itself")
            compare(Notifications.pendingCount, 0)
            verify(tc.hasFocus(find("homePlay")))
        }

        function test_toast_kind_falls_back_to_info() {
            Notifications.show("Hello", "bogus")
            compare(Notifications.model.get(0).kind, "info")
        }

        // The card of the toast at `index` in the list.
        function toastItem(index) {
            const list = find("toastList")
            tryVerify(() => list.itemAtIndex(index) !== null)
            return list.itemAtIndex(index)
        }
        function child(item, name) { return findChild(item, name) }

        function test_toast_title_detail_plain_text() {
            const lng = "Wireless Controller of the Very Long Name Number 12345 <b>x</b>"
            compare(lng.length >= 60, true)
            Notifications.show(lng, "info", "", "", lng)
            Notifications.showSticky("k", lng, "warning", "", lng, lng, "A")
            tryCompare(Notifications.model, "count", 2)
            for (const i of [0, 1]) {
                const t = toastItem(i)
                for (const n of ["toastText", "toastDetail"]) {
                    const label = child(t, n)
                    compare(label.textFormat, Text.PlainText)
                    compare(label.maximumLineCount, 1)
                    compare(label.elide, Text.ElideRight)
                    verify(label.truncated, n + " is cut, not wrapped")
                    compare(label.text, lng)
                }
            }
            const sticky = toastItem(1)
            verify(child(sticky, "toastFooter").visible)
            const footer = child(sticky, "toastFooterText")
            compare(footer.textFormat, Text.PlainText)
            compare(footer.maximumLineCount, 1)
            compare(footer.elide, Text.ElideRight)
            verify(!child(toastItem(0), "toastFooter").visible)
            const layer = find("toastLayer")
            compare(toastItem(0).height, 112 * layer.u)
            compare(toastItem(0).width, 600 * layer.u)
            Notifications.show("No detail", "info")
            Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.dismiss(Notifications.model.get(0).toastId)
            tryCompare(Notifications.model, "count", 1)
            tryVerify(() => toastItem(0).height === 96 * layer.u)
            verify(!child(toastItem(0), "toastDetail").visible)
        }

        function test_toast_default_glyph_per_kind() {
            const want = { info: "info", success: "check_circle", warning: "warning", error: "error" }
            for (const kind of Object.keys(want))
                Notifications.show(kind, kind)
            Notifications.durationMs = 60000
            tryCompare(Notifications.model, "count", 3)
            compare(child(toastItem(0), "toastIcon").name, "info")
            compare(child(toastItem(1), "toastIcon").name, "check_circle")
            compare(child(toastItem(2), "toastIcon").name, "warning")
            Notifications.dismiss(Notifications.model.get(0).toastId)
            tryCompare(Notifications.model, "count", 3)
            tryVerify(() => child(toastItem(2), "toastIcon").name === "error")
            Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.show("pad", "success", "", "pad_xbox")
            tryVerify(() => Notifications.model.count === 3)
            tryVerify(() => child(toastItem(2), "toastIcon").name === "pad_xbox", 2000, "a device icon wins")
            verify(child(toastItem(2), "toastBadge").width > 0)
        }

        function test_toast_timer_line() {
            Notifications.show("Timed", "info")
            Notifications.showSticky("s", "Sticky", "info")
            tryCompare(Notifications.model, "count", 2)
            verify(child(toastItem(0), "toastTimer").visible, "a timed toast has the line")
            compare(child(toastItem(1), "toastTimer").visible, false, "a sticky one has none")
            DeviceSettings.reducedMotion = true
            compare(child(toastItem(0), "toastTimer").visible, false, "none under reduced motion")
            DeviceSettings.reducedMotion = false
            Notifications.remove("s")
        }

        // The compact look, with "Don't interrupt games" off: then warnings and errors show over an app
        // (with it on, the default, only critical items do: tst_notifications, RUY-413).
        function test_toast_compact_when_app_in_front() {
            const layer = find("toastLayer")
            const list = find("toastList")
            NotificationCentre.setDontInterruptGames(false)
            tryCompare(NotificationCentre, "dontInterruptGames", false)
            Notifications.show("Info toast", "info")
            Notifications.show("Warn toast", "warning", "", "", "with a detail")
            compare(list.width, 600 * layer.u)
            Notifications.appInFront = true
            tryCompare(Notifications.model, "count", 1, 2000, "only the warning stays")
            compare(Notifications.pendingCount, 1)
            compare(list.width, 480 * layer.u)
            const t = toastItem(0)
            compare(t.height, 80 * layer.u)
            compare(child(t, "toastBadge").width, 48 * layer.u)
            verify(!child(t, "toastDetail").visible, "title only")
            compare(find("toastOverflow").visible, false, "no chip over an app")
            Notifications.appInFront = false
            compare(list.width, 600 * layer.u)
            tryCompare(Notifications.model, "count", 2)
            tc.cleanup()
            NotificationCentre.setDontInterruptGames(false)
            tryCompare(NotificationCentre, "dontInterruptGames", false)
            Notifications.showSticky("s", "Sticky", "warning", "", "detail", "Press any button to wait", "A")
            Notifications.appInFront = true
            tryCompare(Notifications.model, "count", 1)
            tryVerify(() => child(toastItem(0), "toastFooter").visible, 2000, "a sticky toast keeps its footer over an app")
            compare(child(toastItem(0), "toastDetail").visible, false)
            Notifications.appInFront = false
        }

        function test_toast_turkish_restart_notice_is_whole_over_an_app() {
            DeviceSettings.language = "tr"
            Update.mockAnnounceRestart(Math.floor(Date.now() / 1000) + 120)
            Notifications.appInFront = true
            tryCompare(Notifications.model, "count", 1)
            const t = toastItem(0)
            tryVerify(() => child(t, "toastFooter").visible)
            compare(child(t, "toastText").text, "2 dakikada yeniden başlıyor")
            verify(!child(t, "toastText").truncated, "the title is not cut")
            verify(!child(t, "toastFooterText").truncated, "the footer is not cut")
            compare(child(t, "toastFooter").x, t.pad, "the footer spans the card")
            Update.mockAnnounceRestart(0)
            Notifications.appInFront = false
        }

        function test_toast_overflow_chip() {
            const chip = find("toastOverflow")
            verify(!chip.visible)
            for (let i = 1; i <= 5; ++i)
                Notifications.show("Toast " + i, "info")
            compare(Notifications.pendingCount, 2)
            verify(chip.visible)
            compare(find("toastOverflowText").text, "2 more in Notifications")
            Notifications.dismiss(Notifications.model.get(0).toastId)
            compare(find("toastOverflowText").text, "1 more in Notifications")
            Notifications.dismiss(Notifications.model.get(0).toastId)
            verify(!chip.visible, "hidden at 0")
        }

        function test_volume_keys() {
            signInAsAda()
            const osd = find("volumeOsd")
            verify(!osd.shown)

            keyClick(Qt.Key_VolumeUp)
            tryCompare(Audio, "volume", 55)
            tryCompare(osd, "shown", true)
            verify(find("homePlay").activeFocus, "focus does not move")

            keyClick(Qt.Key_VolumeDown)
            tryCompare(Audio, "volume", 50)

            keyClick(Qt.Key_VolumeMute)
            tryCompare(Audio, "muted", true)
            keyClick(Qt.Key_VolumeMute)
            tryCompare(Audio, "muted", false)

            tryCompare(osd, "shown", false, 4000, "the OSD hides by itself")
            verify(tc.hasFocus(find("homePlay")))
        }

        function test_volume_keys_in_modal() {
            keyClick(Qt.Key_Return)                    // PIN pad
            tryVerify(() => find("pinPad").shown)
            tryVerify(() => find("pinKeys").activeFocus)
            keyClick(Qt.Key_VolumeDown)
            tryCompare(Audio, "volume", 45)
            verify(find("pinKeys").activeFocus, "the PIN pad keeps focus")

            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("pinPad").shown)
            tryVerify(() => find("profileList").activeFocus)
            signInAsAda()

            keyClick(Qt.Key_HomePage)                  // the Guide overlay is modal too
            tryVerify(() => find("systemActions").activeFocus)
            keyClick(Qt.Key_VolumeUp)
            tryCompare(Audio, "volume", 50)
            verify(find("systemActions").activeFocus, "the overlay keeps focus")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("homePlay").activeFocus)
        }

        function test_volume_clamps() {
            signInAsAda()
            Audio.setVolume(98)
            tryCompare(Audio, "volume", 98)
            keyClick(Qt.Key_VolumeUp)
            keyClick(Qt.Key_VolumeUp)
            tryCompare(Audio, "volume", 100)
            tryCompare(find("volumeOsd"), "shown", true)

            Audio.setVolume(3)
            tryCompare(Audio, "volume", 3)
            keyClick(Qt.Key_VolumeDown)
            keyClick(Qt.Key_VolumeDown)
            tryCompare(Audio, "volume", 0)
            Audio.setVolume(250)
            tryCompare(Audio, "volume", 100)
            Audio.setVolume(-5)
            tryCompare(Audio, "volume", 0)
        }

        // One set of toast shots: the stack with the chip, a compact error over an app, and the sticky
        // restart notice (its footer and A glyph) in front and over an app.
        // True when the list shows exactly `titles`, in order: every delegate at rest (opacity 1, x 0, y in
        // its place), none of a removed toast left behind, and the title text on screen.
        function listSettled(titles) {
            const list = find("toastList")
            const delegates = list.contentItem.children.filter(c => c.toastId !== undefined)
            if (list.count !== titles.length || delegates.length !== titles.length)
                return false
            let y = 0
            for (let i = 0; i < titles.length; ++i) {
                const t = list.itemAtIndex(i)
                if (!t || t.opacity !== 1 || t.x !== 0 || Math.abs(t.y - y) > 1)
                    return false
                if (findChild(t, "toastText").text !== titles[i])
                    return false
                y += t.height + list.spacing
            }
            return true
        }

        function toastStack(texts) {
            Notifications.durationMs = 60000
            Notifications.show(texts[0], "success", "", "pad_playstation", texts[1])
            Notifications.show(texts[2], "info", "", "", texts[3])
            Notifications.show(texts[4], "warning", "", "pad_xbox", texts[5])
            Notifications.show(texts[6], "info")
            keyClick(Qt.Key_VolumeUp)
            tryCompare(Audio, "volume", 55)
            tryVerify(() => listSettled([texts[0], texts[2], texts[4]]), 5000, "the three toasts are at rest")
            tryVerify(() => find("toastOverflow").visible && find("volumeOsd").shown, 5000, "the chip and the OSD are up")
        }

        function toastRest(suffix, texts) {
            tc.clearToasts()
            tryVerify(() => listSettled([]), 5000, "the stack is gone")
            NotificationCentre.setDontInterruptGames(false)       // the compact error: the rule with it off
            tryCompare(NotificationCentre, "dontInterruptGames", false)
            Notifications.show(texts[7], "error", "", "", texts[8])
            Notifications.appInFront = true
            tryVerify(() => listSettled([texts[7]]) && find("toastList").width === 480 * find("toastLayer").u, 5000, "the compact error is at rest")
            grabImage(tc.shell).save(shotsDir + "/14b-toast-over-app" + suffix + ".png")
            tc.clearToasts()
            Notifications.appInFront = false
            NotificationCentre.setDontInterruptGames(true)
            tryCompare(NotificationCentre, "dontInterruptGames", true)
            tryVerify(() => listSettled([]), 5000, "the error is gone")
            Update.mockAnnounceRestart(Math.floor(Date.now() / 1000) + 120)
            tryVerify(() => Notifications.model.count === 1 && Notifications.model.get(0).key === "update-restart")
            const restart = Notifications.model.get(0).text
            tryVerify(() => listSettled([restart]) && find("toastList").width === 600 * find("toastLayer").u, 5000, "the restart notice is at rest")
            grabImage(tc.shell).save(shotsDir + "/14c-toast-restart-notice" + suffix + ".png")
            Notifications.appInFront = true
            tryVerify(() => listSettled([restart]) && find("toastList").width === 480 * find("toastLayer").u, 5000, "the compact restart notice is at rest")
            grabImage(tc.shell).save(shotsDir + "/14d-toast-restart-notice-over-app" + suffix + ".png")
            Notifications.appInFront = false
            Update.mockAnnounceRestart(0)
            tc.clearToasts()
        }

        function clearToasts() {
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            signInAsAda()
            const texts = ["DualSense connected", "Battery 62% · Bluetooth", "Update ready", "Restart to finish",
                           "Controller battery low", "Xbox controller · 12%", "Fourth toast", "Crashy could not start", "Try again."]
            toastStack(texts)
            grabImage(tc.shell).save(shotsDir + "/14-toast-and-osd.png")
            toastRest("", texts)
        }

        function test_zz_screenshots_performance() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            signInAsAda()
            const quality = DeviceSettings.effectsQuality
            DeviceSettings.effectsQuality = "performance"
            const texts = ["DualSense connected", "Battery 62% · Bluetooth", "Update ready", "Restart to finish",
                           "Controller battery low", "Xbox controller · 12%", "Fourth toast", "Crashy could not start", "Try again."]
            toastStack(texts)
            grabImage(tc.shell).save(shotsDir + "/14-toast-and-osd-performance.png")
            toastRest("-performance", texts)
            DeviceSettings.effectsQuality = quality
        }

        function test_zz_screenshots_tr() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            signInAsAda()
            DeviceSettings.language = "tr"
            const texts = ["DualSense bağlandı", "Pil 62% · Bluetooth", "Güncelleme hazır", "Bitirmek için yeniden başlat",
                           "Kumanda pili zayıf", "Xbox kumandası · 12%", "Dördüncü bildirim", "Crashy başlatılamadı", "Tekrar dene."]
            toastStack(texts)
            grabImage(tc.shell).save(shotsDir + "/14-toast-and-osd-tr.png")
            toastRest("-tr", texts)
            DeviceSettings.language = "en"
        }
    }
}
