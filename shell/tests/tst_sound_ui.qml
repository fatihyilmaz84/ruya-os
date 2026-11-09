import QtQuick
import QtTest
import QtMultimedia
import RuyaShell

// The ambient bed and Settings -> Audio -> Ambient sound / Sound theme (T-227, 02 §5.3), driven with
// controller keys against the mock services. The checker and the cues are in tst_sounds.qml. Signs in as
// "Ada" (p2, no PIN). RUYA_SOUNDS_DRY gives the ambient players no file: the tests read the bed's properties.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }
    Component {
        id: appComponent
        Item { objectName: "standInApp"; Keys.onPressed: event => { event.accepted = true } }
    }

    // ---------------------------------------------------------------- the ambient bed and Settings
    TestCase {
        id: tc
        name: "SoundAmbient"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Audio.mockReset()
            SoundThemes.mockReset()
            Storage.mockReset(false)
            DeviceSettings.ambientSound = true
            DeviceSettings.soundTheme = "dreamglass"
            DeviceSettings.reducedMotion = false
            IdleClock.now = () => 1000000000000     // a frozen clock: a slow machine must not read lag as sleep (IdleClock.gapMs) and end a stage
            IdleClock.reset()
            tryVerify(() => Audio.channelVolumes.ambient === 100)
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
            clearToasts()
            tryCompare(Sfx, "ducking", false, 3000)
        }

        function cleanup() {
            DeviceSettings.language = "en"
            IdleClock.now = () => MonotonicClock.ms()
            IdleClock.reset()
            DeviceSettings.ambientSound = true
            DeviceSettings.soundTheme = "dreamglass"
            Notifications.durationMs = Theme.toastMs
            clearToasts()
        }

        function clearToasts() {
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

        function test_the_cues_are_wired_to_their_events() {
            // A toast says how much attention it wants; a sticky one and a warning have their own cue.
            const n = Sfx.notificationCount
            const w = Sfx.warningCount
            Notifications.show("one", "info")
            compare(Sfx.notificationCount, n + 1, "a toast")
            Notifications.show("two", "success")
            compare(Sfx.notificationCount, n + 2)
            clearToasts()                       // the layer shows three at a time; the cue plays when a toast appears
            Notifications.show("three", "warning")
            compare(Sfx.warningCount, w + 1, "a warning toast")
            Notifications.show("four", "error")
            compare(Sfx.warningCount, w + 2)
            clearToasts()
            Notifications.showSticky("cue-test", "five", "info")
            compare(Sfx.warningCount, w + 3, "a sticky toast")
            Notifications.remove("cue-test")
            clearToasts()

            // The Guide overlay: open on the way in, close on the way out.
            const o = Sfx.openCount
            const c = Sfx.closeCount
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemPanel").open, 2000)
            compare(Sfx.openCount, o + 1)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("systemPanel").open, 2000)
            compare(Sfx.closeCount, c + 1)
            tryVerify(() => find("homePlay").activeFocus, 2000)

            // A section changes.
            const p = Sfx.pageCount
            keyClick(Qt.Key_PageDown)
            tryVerify(() => tc.shell.currentPage !== "", 2000, "RB leaves Home")
            compare(Sfx.pageCount, p + 1)

            // The volume bar ticks, but not while muted.
            const v = Sfx.volumeCount
            Audio.stepVolume(5)
            tryCompare(Sfx, "volumeCount", v + 1)
            Audio.setMuted(true)                // muting is silent, too
            tryCompare(Audio, "muted", true)
            wait(150)
            const during = Sfx.volumeCount
            Audio.stepVolume(-5)                // Volume Down while muted: the OSD, no tick
            wait(150)
            compare(Sfx.volumeCount, during, "no tick while muted")
            Audio.setMuted(false)
        }

        function test_plays_on_home() {
            const bed = find("ambientBed")
            verify(bed)
            verify(SoundThemes.ambientUrl.length > 0)
            tryCompare(bed, "wantsSound", true)
            tryCompare(bed, "fade", 1, 3000)
            verify(bed.playing)
            verify(bed.outputVolume > 0)
            compare(SoundThemes.crossMs, 1500)
            compare(SoundThemes.ambientFadeMs, 800)
        }

        function test_stops_when_an_app_is_in_front_and_returns() {
            const bed = find("ambientBed")
            tryCompare(bed, "fade", 1, 3000)
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app)
            tryVerify(() => app.activeFocus, 2000, "the app takes focus")
            compare(bed.wanted, false)
            tryVerify(() => bed.fade === 0, 3000, "faded out")
            verify(!bed.playing, "paused once the fade has finished")
            compare(bed.outputVolume, 0)
            tc.shell.removeApp(app)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            tryCompare(bed, "wantsSound", true)
            tryCompare(bed, "fade", 1, 3000)
            verify(bed.playing)
        }

        function test_stops_when_the_saver_starts_and_returns() {
            const bed = find("ambientBed")
            tryCompare(bed, "fade", 1, 3000)
            for (const stage of ["saver", "off", "sleep"]) {
                IdleClock.stage = stage
                tryVerify(() => bed.fade === 0, 3000, stage)
                verify(!bed.playing, stage + ": fade " + bed.fade + ", wantsSound " + bed.wantsSound + ", wanted " + bed.wanted)
                IdleClock.stage = "active"
                tryCompare(bed, "fade", 1, 3000, "back from " + stage)
            }
        }

        function test_the_fade_takes_800_ms_and_reduced_motion_does_not_shorten_it() {
            const bed = find("ambientBed")
            tryCompare(bed, "fade", 1, 3000)
            DeviceSettings.reducedMotion = true
            tryCompare(Theme, "reducedMotion", true)
            DeviceSettings.ambientSound = false
            wait(150)
            verify(bed.fade > 0 && bed.fade < 1, "still fading after 150 ms: " + bed.fade)
            tryVerify(() => bed.fade === 0, 3000, "faded out")
        }

        function test_the_switch_and_the_level_take_effect() {
            const bed = find("ambientBed")
            tryCompare(bed, "fade", 1, 3000)
            DeviceSettings.ambientSound = false
            tryVerify(() => bed.fade === 0, 3000, "faded out")
            verify(!bed.playing, "fade " + bed.fade + ", wantsSound " + bed.wantsSound + ", switch " + bed.switchedOn)
            DeviceSettings.ambientSound = true
            tryCompare(bed, "fade", 1, 3000)
            Audio.setChannelVolume("ambient", 50)
            tryVerify(() => Math.abs(bed.outputVolume - 0.5 * SoundThemes.ambientGain) < 0.02, 2000, "level " + bed.outputVolume)
            Audio.setChannelVolume("ambient", 0)
            tryCompare(bed, "wantsSound", false)
            tryVerify(() => bed.fade === 0, 3000, "faded out")
            Audio.setChannelVolume("ambient", 100)
            tryCompare(bed, "fade", 1, 3000)
        }

        function test_ambient_bed_stops_under_an_app_and_restarts() {
            const bed = find("ambientBed")
            tryCompare(bed, "fade", 1, 3000)
            const stops = bed.stopCount
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app)
            tryVerify(() => app.activeFocus, 2000, "the app takes focus")
            tryVerify(() => !bed.playing, 3000, "the bed has faded out")
            compare(bed.stopCount, stops + 1, "the players were stopped, not paused")
            compare(bed.player(0).playbackState, MediaPlayer.StoppedState)
            compare(bed.player(1).playbackState, MediaPlayer.StoppedState)
            tc.shell.removeApp(app)
            tryCompare(bed, "playing", true, 3000, "and it starts again on return")
            tryCompare(bed, "fade", 1, 3000)
        }

        function test_l0_is_hidden_behind_a_focused_app() {
            const names = ["backdrop", "wallpaperLayer", "heroArt"]
            for (const n of names)
                verify(find(n).visible, n + " is drawn on Home")
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app)
            tryVerify(() => app.activeFocus, 2000, "the app takes focus")
            for (const n of names)
                compare(find(n).visible, false, n + " is not drawn behind an app")
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemPanel").open, 2000, "the Guide overlay opens over the app")
            for (const n of names)
                compare(find(n).visible, false, n + " stays hidden under the Guide overlay")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("systemPanel").open, 2000)
            tc.shell.removeApp(app)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            for (const n of ["backdrop", "wallpaperLayer"])
                verify(find(n).visible, n + " is back on Home")
            tryVerify(() => find("heroArt").visible, 2000, "the hero art is back")
        }

        function test_no_effect_samples_a_hidden_layer() {
            const l0 = find("l0")
            const pill = find("statusGlass")
            verify(pill.visible, "the status glass samples L0 on Home")
            compare(pill.source, l0)
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app)
            tryVerify(() => app.activeFocus, 2000, "the app takes focus")
            compare(l0.visible, false)
            compare(pill.visible, false, "the glass pill that blurs L0 is not drawn while L0 is hidden")
            tryVerify(() => !find("sectionNav").visible, 2000, "nor the nav glass, once it has faded")
            tc.shell.removeApp(app)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            verify(pill.visible)
        }

        function test_a_cue_ducks_the_bed_by_8_dB() {
            const bed = find("ambientBed")
            tryCompare(bed, "fade", 1, 3000)
            tryVerify(() => Math.abs(bed.duck - 1) < 0.001, 2000, "not ducked before the cue")
            verify(Math.abs(SoundThemes.duckGain - Math.pow(10, -8 / 20)) < 0.001)
            const ducks = Sfx.duckCount
            Sfx.select()
            compare(Sfx.duckCount, ducks + 1, "ducking is requested")
            tryVerify(() => bed.ducked, 1000)
            tryVerify(() => Math.abs(bed.duck - SoundThemes.duckGain) < 0.02, 2000, "the bed is lowered: " + bed.duck)
            tryCompare(Sfx, "ducking", false, 3000)
            tryVerify(() => Math.abs(bed.duck - 1) < 0.02, 2000, "and comes back")
        }

        function test_a_theme_without_ambient_has_none() {
            const bed = find("ambientBed")
            tryCompare(bed, "fade", 1, 3000)
            SoundThemes.mockPrepareDrive()
            SoundThemes.refresh(["/run/media/mock/Ruya Stick"])
            tryVerify(() => SoundThemes.themes.some(t => t.kind === "drive" && t.id.endsWith("/Plain")), 5000)
            const plain = SoundThemes.themes.find(t => t.kind === "drive" && t.id.endsWith("/Plain"))
            SoundThemes.importTheme(plain.path)
            tryVerify(() => SoundThemes.themes.some(t => t.id === "user:Plain"), 5000)
            DeviceSettings.soundTheme = "user:Plain"
            tryCompare(bed, "available", false)
            tryVerify(() => bed.fade === 0, 3000, "faded out")
            DeviceSettings.soundTheme = "dreamglass"
            tryCompare(bed, "fade", 1, 3000)
        }

        function test_a_broken_chosen_theme_says_so_once() {
            DeviceSettings.soundTheme = "user:Nothing"
            tryVerify(() => tc.toastTexts().some(t => t.startsWith("The chosen sound theme can't be used")), 2000)
            tryCompare(SoundThemes, "activeId", "dreamglass")
            DeviceSettings.soundTheme = "dreamglass"
        }

        function openAudioPane() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus, 2000, "category list has focus")
            for (let i = 0; i < 20 && list.currentIndex < 4; ++i)     // Audio
                keyClick(Qt.Key_Down)
            compare(list.currentIndex, 4)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneAudio").visible)
            tryVerify(() => find("sink_hdmi-0").activeFocus, 2000, "the first output takes focus")
        }

        function test_the_rows_work_with_a_controller() {
            openAudioPane()
            for (let i = 0; i < 7; ++i)                  // analog, the jack, Test sound, master, UI sounds, Ambient, Ambient sound
                keyClick(Qt.Key_Down)
            tryVerify(() => find("rowAmbientSound").activeFocus, 2000, "the switch sits under the Ambient slider")
            verify(find("rowAmbientSound").checked, "on by default")
            const off = Sfx.toggleOffCount
            keyClick(Qt.Key_Return)
            tryCompare(DeviceSettings, "ambientSound", false)
            compare(Sfx.toggleOffCount, off + 1)
            verify(find("rowAmbientSound").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(DeviceSettings, "ambientSound", true)
            for (let i = 0; i < 3; ++i)                  // Media, Mute, Sound theme
                keyClick(Qt.Key_Down)
            tryVerify(() => find("rowSoundTheme").activeFocus, 2000, "the sound theme row")
            compare(find("rowSoundTheme").currentLabel, "Dreamglass")
            keyClick(Qt.Key_Right)                       // one theme only: stays, and keeps focus
            compare(find("rowSoundTheme").currentLabel, "Dreamglass")
            verify(find("rowSoundTheme").activeFocus)
            keyClick(Qt.Key_Up)
            tryVerify(() => find("rowMute").activeFocus)
        }

        function test_a_drive_theme_is_copied_and_focus_survives_the_drive_list_changing() {
            SoundThemes.mockPrepareDrive()
            openAudioPane()
            for (let i = 0; i < 10; ++i)
                keyClick(Qt.Key_Down)                    // to the sound theme row
            tryVerify(() => find("rowSoundTheme").activeFocus, 2000)
            verify(!find("driveTheme_drive:Ruya Stick/Glassy"), "no drive yet")

            Storage.mockPlugStick()
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Glassy") !== null, 5000, "the stick's theme gets a row")
            verify(find("driveTheme_drive:Ruya Stick/Plain"))
            verify(!find("driveTheme_drive:Ruya Stick/Broken"), "a broken theme is not offered")
            verify(find("rowSoundTheme").activeFocus, "focus stays when rows appear")

            keyClick(Qt.Key_Down)
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Glassy").activeFocus, 2000, "Down reaches the first drive theme")
            keyClick(Qt.Key_Return)
            tryCompare(DeviceSettings, "soundTheme", "user:Glassy", 5000)
            tryVerify(() => tc.toastTexts().includes("Sound theme: Glassy"), 3000)
            tryCompare(SoundThemes, "activeId", "user:Glassy")
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Glassy") === null, 3000, "the copied theme is no longer offered")
            tryVerify(() => find("rowSoundTheme").currentLabel === "Glassy", 3000)
            tryVerify(() => find("rowSoundTheme").activeFocus, 2000, "focus lands on the Sound theme row, not on the first row")

            // It keeps working with the stick gone.
            const url = SoundThemes.cues.select
            verify(url.includes("/Glassy/select.wav"))
            Storage.eject("vol-stick")
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Plain") === null, 5000, "the stick's rows go with it")
            compare(SoundThemes.activeId, "user:Glassy")
            verify(SoundThemes.check(url.replace(/^file:\/\/\/([A-Za-z]:)/, "$1").replace(/^file:\/\//, "").replace("/select.wav", "")).ok,
                   "the copy is a complete theme in the console's own directory")
        }

        function test_the_drive_row_that_has_focus_going_away_leaves_focus_in_the_pane() {
            SoundThemes.mockPrepareDrive()
            openAudioPane()
            Storage.mockPlugStick()
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Plain") !== null, 5000)
            for (let i = 0; i < 20 && !find("driveTheme_drive:Ruya Stick/Plain").activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(find("driveTheme_drive:Ruya Stick/Plain").activeFocus)
            Storage.eject("vol-stick")
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Plain") === null, 5000)
            tryVerify(() => find("rowSoundTheme").activeFocus, 2000, "focus lands on the Sound theme row")
        }

        function test_only_the_pressed_row_says_copying() {
            SoundThemes.mockPrepareDrive()
            SoundThemes.mockSetCopyDelay(1500)
            openAudioPane()
            Storage.mockPlugStick()
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Glassy") !== null, 5000)
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Plain") !== null, 5000)
            for (let i = 0; i < 20 && !find("driveTheme_drive:Ruya Stick/Glassy").activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(find("driveTheme_drive:Ruya Stick/Glassy").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(SoundThemes, "importState", "copying")
            compare(find("driveTheme_drive:Ruya Stick/Glassy").value, "Copying…")
            compare(find("driveTheme_drive:Ruya Stick/Plain").value, "", "the other row does not claim to copy")
            tryCompare(SoundThemes, "importState", "idle", 5000)
            tryCompare(DeviceSettings, "soundTheme", "user:Glassy")
        }

        // Down (else Up) until the row named has focus (the pane is long and rows come and go).
        function goTo(name) {
            const row = find(name)
            for (let i = 0; i < 30 && !row.activeFocus; ++i)
                keyClick(Qt.Key_Down)
            for (let i = 0; i < 30 && !row.activeFocus; ++i)
                keyClick(Qt.Key_Up)
            tryVerify(() => row.activeFocus, 2000, name + " has focus")
        }

        function inConfirm(name) { return findChild(find("soundDeleteConfirm"), name) }

        // Copies a theme of the mock stick through its row; the copy becomes the chosen theme.
        function copyFromStick(folder) {
            goTo("driveTheme_drive:Ruya Stick/" + folder)
            keyClick(Qt.Key_Return)
            tryCompare(DeviceSettings, "soundTheme", "user:" + folder, 5000)
            tryVerify(() => find("driveTheme_drive:Ruya Stick/" + folder) === null, 3000, "the copied theme is no longer offered")
            tryVerify(() => find("rowSoundTheme").activeFocus, 2000, "focus lands on the Sound theme row")
        }

        function test_delete_saved_theme() {
            SoundThemes.mockPrepareDrive()
            openAudioPane()
            Storage.mockPlugStick()
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Glassy") !== null, 5000)
            tryVerify(() => tc.toastTexts().includes("Drive inserted: Ruya Stick"), 5000, "the stick's own toast has come (it is not ours to count)")
            verify(!find("rowDeleteSoundTheme").visible, "nothing to delete while the bundled theme is chosen")
            copyFromStick("Glassy")
            const glassyPath = SoundThemes.themes.find(t => t.id === "user:Glassy").path     // a string: an entry read from the list changes with it
            copyFromStick("Plain")
            tryCompare(SoundThemes, "activeId", "user:Plain")
            compare(find("rowSoundTheme").options.length, 3, "the bundled theme and two copies")

            // The row is under the choice row and names the chosen copy.
            const del = find("rowDeleteSoundTheme")
            tryVerify(() => del.visible, 2000, "a saved theme can be deleted")
            compare(del.label, "Delete “Plain”")
            keyClick(Qt.Key_Down)
            tryVerify(() => del.activeFocus, 2000, "Down from the choice row reaches Delete")

            // Back leaves the confirmation and nothing is deleted.
            keyClick(Qt.Key_Return)
            tryVerify(() => find("soundDeleteConfirm").shown, 2000, "the confirmation is up")
            compare(inConfirm("powerConfirmTitle").text, "Delete “Plain”?")
            tryVerify(() => inConfirm("powerCancel").activeFocus, 2000, "Cancel has focus first")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("soundDeleteConfirm").shown, 2000)
            tryVerify(() => del.activeFocus, 2000, "Back returns to the Delete row")
            compare(DeviceSettings.soundTheme, "user:Plain")
            compare(find("rowSoundTheme").options.length, 3)

            // Confirm: the copy is gone, the bundled theme plays, no cue other than the button's own click.
            const plainPath = SoundThemes.themes.find(t => t.id === "user:Plain").path
            verify(SoundThemes.check(plainPath).ok)
            const startups = Sfx.startupCount
            const notes = Sfx.notificationCount
            const warns = Sfx.warningCount
            clearToasts()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("soundDeleteConfirm").shown, 2000)
            tryVerify(() => inConfirm("powerCancel").activeFocus, 2000)
            keyClick(Qt.Key_Right)
            tryVerify(() => inConfirm("powerConfirm").activeFocus)
            compare(inConfirm("powerConfirm").Accessible.name, "Delete “Plain”")
            keyClick(Qt.Key_Return)
            tryVerify(() => !find("soundDeleteConfirm").shown, 2000)
            tryCompare(DeviceSettings, "soundTheme", "dreamglass")
            tryCompare(SoundThemes, "activeId", "dreamglass")
            tryVerify(() => find("rowSoundTheme").options.length === 2, 2000, "the list shrank")
            verify(!SoundThemes.themes.some(t => t.id === "user:Plain"))
            verify(SoundThemes.themes.some(t => t.id === "user:Glassy"), "the other copy stays")
            verify(!SoundThemes.check(plainPath).ok, "the folder of the deleted copy is gone")
            verify(SoundThemes.check(glassyPath).ok, "the other copy is intact on disk")
            tryVerify(() => !del.visible, 2000, "the bundled theme has no Delete row")
            tryVerify(() => find("rowSoundTheme").activeFocus, 2000, "focus lands on the Sound theme row")
            tryCompare(find("rowSoundTheme"), "currentLabel", "Dreamglass")
            compare(Sfx.startupCount, startups, "the start-up cue is not replayed")
            compare(Sfx.notificationCount, notes, "no toast, no notification cue: " + tc.toastTexts().join(" | "))
            compare(Sfx.warningCount, warns)
            compare(tc.toastTexts().length, 0, "and nothing is said")
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Plain") !== null, 3000, "the deleted theme is on the stick still and offered again")

            // Back from the pane still works.
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Back leaves the pane")
        }

        function test_deleting_a_copy_that_is_not_chosen_leaves_the_choice_alone() {
            // The row only ever names the chosen copy; this is the C++ side of "a stale answer": a copy removed while
            // another is chosen keeps the choice.
            SoundThemes.mockPrepareDrive()
            SoundThemes.refresh(["/run/media/mock/Ruya Stick"])
            tryVerify(() => SoundThemes.themes.filter(t => t.kind === "drive").length === 2, 5000)
            SoundThemes.importTheme(SoundThemes.themes.find(t => t.id.endsWith("/Plain")).path)
            tryVerify(() => SoundThemes.themes.some(t => t.id === "user:Plain"), 5000)
            SoundThemes.importTheme(SoundThemes.themes.find(t => t.id.endsWith("/Glassy")).path)
            tryVerify(() => SoundThemes.themes.some(t => t.id === "user:Glassy"), 5000)
            DeviceSettings.soundTheme = "user:Glassy"
            tryCompare(SoundThemes, "activeId", "user:Glassy")
            verify(SoundThemes.removeTheme("user:Plain"))
            compare(SoundThemes.activeId, "user:Glassy")
            verify(!SoundThemes.themes.some(t => t.id === "user:Plain"))
        }

        function test_bundled_theme_has_no_delete() {
            openAudioPane()
            const del = find("rowDeleteSoundTheme")
            verify(del, "the row exists")
            verify(!del.visible, "but is not shown for the bundled theme")
            verify(!SoundThemes.removeTheme("dreamglass"))
            for (let i = 0; i < 10; ++i)
                keyClick(Qt.Key_Down)                    // to the sound theme row, the last one
            tryVerify(() => find("rowSoundTheme").activeFocus, 2000)
            keyClick(Qt.Key_Down)
            verify(!del.activeFocus, "Down never lands on a hidden row")
            verify(find("rowSoundTheme").activeFocus)
            compare(find("rowSoundTheme").currentLabel, "Dreamglass")
        }

        function test_a_refused_drive_theme_says_why() {
            SoundThemes.mockPrepareDrive()
            openAudioPane()
            Storage.mockPlugStick()
            const row = "driveRefused_drive:Ruya Stick/Broken"
            tryVerify(() => find(row) !== null, 5000, "the refused folder gets a row")
            verify(!find("driveTheme_drive:Ruya Stick/Broken"), "and is not offered as a theme")
            compare(find(row).label, "Can't use “Broken”")
            compare(find(row).value, "The theme.json file has a mistake")
            goTo(row)
            clearToasts()
            keyClick(Qt.Key_Return)
            tryVerify(() => tc.toastTexts().includes("“Broken” can't be used. The theme.json file has a mistake."), 2000)
            verify(find(row).activeFocus, "focus stays on the row")
            DeviceSettings.language = "tr"
            tryCompare(find(row), "value", "theme.json dosyasında bir hata var")
            DeviceSettings.language = "en"
            Storage.eject("vol-stick")
            tryVerify(() => find(row) === null, 5000, "the row goes with the stick")
            tryVerify(() => find("rowSoundTheme").activeFocus, 2000, "focus lands on the Sound theme row")
        }

        function test_a_theme_over_the_limits_says_how() {
            SoundThemes.mockPrepareDrive()
            verify(SoundThemes.mockAddDriveTheme("Heavy", SoundThemes.maxCopyFiles + 1, 200000))
            openAudioPane()
            Storage.mockPlugStick()
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Heavy") !== null, 5000)
            goTo("driveTheme_drive:Ruya Stick/Heavy")
            clearToasts()
            keyClick(Qt.Key_Return)
            tryVerify(() => tc.toastTexts().includes("That sound theme has more than 100 files."), 5000)
            compare(DeviceSettings.soundTheme, "dreamglass", "nothing was chosen")
            verify(find("driveTheme_drive:Ruya Stick/Heavy").activeFocus)
            const pane = find("paneAudio")
            verify(pane.importFailure("too-large", []).includes("larger than 12 MB"))
            verify(pane.importFailure("limit", []).includes("Delete one first"), pane.importFailure("limit", []))
            verify(pane.importFailure("limit", []).includes("copy over one with the same name"))
            compare(pane.importFailure("invalid", ["cue 'select': peak above -3 dBFS"]), "That sound theme can't be used. A cue is louder than allowed.")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            SoundThemes.mockPrepareDrive()
            openAudioPane()
            Storage.mockPlugStick()
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Glassy") !== null, 5000)
            for (let i = 0; i < 11; ++i)
                keyClick(Qt.Key_Down)                    // down to the first drive theme
            tryVerify(() => find("driveTheme_drive:Ruya Stick/Glassy").activeFocus, 2000)
            tryCompare(find("volumeOsd"), "shown", false, 5000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/sound-settings-en.png")
            // A saved theme: the Delete row, and its confirmation.
            clearToasts()
            tryCompare(find("toastList"), "count", 0, 3000)
            copyFromStick("Glassy")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowDeleteSoundTheme").activeFocus, 2000)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/sound-delete-row-en.png")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("soundDeleteConfirm").shown, 2000)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/sound-delete-confirm-en.png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("soundDeleteConfirm").shown, 2000)
        }

        // The Guide overlay over an app, and Home again after the app closed (T-376): L0 is hidden behind the app
        // and is back, without a gap, when it goes.
        function test_zz_screenshots_app() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            const app = createTemporaryObject(appComponent, host)
            tc.shell.addApp(app)
            tryVerify(() => app.activeFocus, 2000)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemPanel").open, 2000)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/guide-over-app.png")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("systemPanel").open, 2000)
            tc.shell.removeApp(app)
            tryVerify(() => find("homePlay").activeFocus, 2000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/home-after-app.png")
        }

        // Settings -> Audio in Turkish, with the stick plugged in after the language was chosen: a toast keeps
        // the language it was written in, so the "Drive inserted" toast on this shot is Turkish (T-294).
        function test_zz_screenshots_tr() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.language = "tr"
            Notifications.durationMs = 60000             // the toast is still up when the key presses have reached the row
            SoundThemes.mockPrepareDrive()
            openAudioPane()
            Storage.mockPlugStick()
            tryVerify(() => find("driveRefused_drive:Ruya Stick/Broken") !== null, 5000)
            tryVerify(() => tc.toastTexts().includes("Sürücü takıldı: Ruya Stick"), 3000, "the toast is Turkish: " + tc.toastTexts().join(" | "))
            goTo("driveRefused_drive:Ruya Stick/Broken")
            tryCompare(find("rowSoundTheme"), "label", "Ses teması")
            tryCompare(find("driveRefused_drive:Ruya Stick/Broken"), "value", "theme.json dosyasında bir hata var")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/sound-settings-tr.png")
        }
    }
}
