import QtQuick
import QtTest
import RuyaShell

// The Audio panel and the microphone tile of Ruya Hub (T-450, 02 §1.6): from the Quick Hub's Audio entry
// the player sets the volume, mutes, picks the output and the microphone and mutes it, without leaving
// the game. Each control changes the mock's state and shows the answer; without a microphone there is no
// microphone row and no tile; Back returns to the entry. Signs in as "Ada" (p2), controller keys only.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A window of an app that takes every key, like a game.
    Component {
        id: appComponent
        Item {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            Keys.onPressed: event => event.accepted = true
        }
    }

    // A "game" with something to look at behind the Hub (screenshots).
    Component {
        id: pictureAppComponent
        Rectangle {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            color: "steelblue"
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: parent.height / 3; color: "darkgreen" }
            Rectangle { x: parent.width * 0.55; y: parent.height * 0.2; width: parent.width * 0.2; height: width; radius: width / 2; color: "gold" }
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }

    TestCase {
        id: tc
        name: "HubAudio"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

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
            tryVerify(() => Library.available)
            tryVerify(() => Library.items.length === 10)
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.reducedMotion = false
            Library.resetMockForTests("")
            Session.mockReset()
            Audio.mockReset()
            tryCompare(Audio, "defaultSink", "hdmi-0")
            tryCompare(Audio, "defaultInput", "mic-0")
            launchedSpy.clear()
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function cleanup() {
            DeviceSettings.reducedMotion = false
        }

        function playRacer() {
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(appComponent, host)
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")
            return app
        }

        function openHub() {
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Hub opens")
        }

        function focusedKey() {
            const list = find("systemActions")
            return list.model[list.currentIndex]
        }

        function goTo(key) {
            for (let i = 0; i < 20 && focusedKey() !== key; ++i)
                keyClick(Qt.Key_Down)
            compare(focusedKey(), key)
            verify(find("quickMenuItem_" + key).focused, key + " has the focus ring")
        }

        // The Hub, then the Audio panel; the focus is on its first row.
        function openAudio() {
            openHub()
            goTo("panel:audio")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "audio")
            tryCompare(find("systemPanel"), "swap", 1)
            compare(focusedKey(), "volume", "the focus lands on the first actionable row")
            verify(find("systemActions").activeFocus)
        }

        function hintVerbs() {
            const bar = find("hintBar")
            const parts = []
            for (const b of ["A", "Left/Right", "B"]) {
                const h = findChild(bar, "hint_" + b)
                if (h)
                    parts.push(b + " " + h.verb)
            }
            return parts.join("|")
        }

        function rowValue(key) { return find("quickMenuItem_" + key).Accessible.name }

        // ---- the entry and Back -----------------------------------------------------------------------

        function test_the_audio_entry_opens_the_panel_and_back_returns_to_it() {
            start()
            const app = playRacer()
            openHub()
            goTo("panel:audio")
            compare(find("quickMenuItem_panel:audio").Accessible.name, "Audio")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "audio")
            const title = find("hubPanelTitle")
            verify(title.visible)
            compare(title.text, "Audio")
            verify(!find("quickMenuApp").visible, "the panel replaces the app part")
            compare(find("systemPanel").itemKeys, ["volume", "audio:mute", "audio:output", "audio:mic", "audio:micmute"])
            compare(focusedKey(), "volume")
            verify(find("systemActions").activeFocus)
            // Back: the Quick Hub again, on the entry that was opened; the Hub stays open.
            keyClick(Qt.Key_Escape)
            tryCompare(find("systemPanel"), "panelId", "")
            verify(find("systemPanel").open, "Back left only the panel")
            compare(focusedKey(), "panel:audio", "the focus is on the entry")
            verify(find("quickMenuItem_panel:audio").focused)
            verify(!title.visible)
            verify(find("quickMenuApp").visible)
            // Back in the Quick Hub resumes the game.
            keyClick(Qt.Key_Escape)
            tryVerify(() => app.activeFocus && !find("systemPanel").open, 2000, "Back leaves the Hub")
        }

        function test_guide_inside_a_panel_closes_the_whole_hub_and_the_next_open_starts_at_the_top() {
            start()
            const app = playRacer()
            openAudio()
            keyClick(Qt.Key_HomePage)
            tryVerify(() => app.activeFocus && !find("systemPanel").open, 2000, "Guide closes the Hub and resumes")
            openHub()
            compare(find("systemPanel").panelId, "", "the last panel is not remembered")
            compare(focusedKey(), "resume")
            keyClick(Qt.Key_Escape)
            tryVerify(() => app.activeFocus, 2000)
        }

        // ---- the controls ---------------------------------------------------------------------------

        function test_volume_left_and_right_adjust_by_five_and_accept_mutes() {
            start()
            openAudio()
            tryCompare(Audio, "volume", 50)
            keyClick(Qt.Key_Right)
            tryCompare(Audio, "volume", 55)
            compare(find("quickMenuVolumeValue").text, "55", "the row shows the answer")
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            tryCompare(Audio, "volume", 45)
            compare(find("quickMenuVolumeValue").text, "45")
            compare(find("quickMenuItem_volume").Accessible.name, "Volume 45")
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "muted", true)
            compare(find("quickMenuVolumeValue").text, "Muted")
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "muted", false)
            verify(find("systemPanel").panelId === "audio" && find("systemActions").activeFocus)
        }

        function test_the_volume_row_hint_is_adjust() {
            start()
            openAudio()
            compare(hintVerbs(), "A Mute|Left/Right Adjust|B Back")
            keyClick(Qt.Key_Escape)
            for (let i = 0; i < 20 && focusedKey() !== "volume"; ++i)
                keyClick(Qt.Key_Up)
            compare(focusedKey(), "volume")
            compare(hintVerbs(), "A Mute|Left/Right Adjust|B Close")
            keyClick(Qt.Key_Escape)
        }

        function test_the_mute_row_toggles_the_master_mute_and_shows_the_answer() {
            start()
            openAudio()
            keyClick(Qt.Key_Down)
            compare(focusedKey(), "audio:mute")
            compare(hintVerbs(), "A Toggle|B Back")
            compare(rowValue("audio:mute"), "Mute, Off")
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "muted", true)
            tryVerify(() => rowValue("audio:mute") === "Mute, On", 2000, "the row shows the answer")
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "muted", false)
            tryVerify(() => rowValue("audio:mute") === "Mute, Off")
        }

        function test_the_output_row_steps_through_the_usable_outputs() {
            start()
            openAudio()
            goTo("audio:output")
            compare(hintVerbs(), "A Next|Left/Right Change|B Back")
            compare(rowValue("audio:output"), "Output, " + Audio.outputs.find(o => o.isDefault).name)
            const first = Audio.defaultSink
            // The headphone jack is empty: not offered. Right goes to the analog output, and the row follows.
            keyClick(Qt.Key_Right)
            tryVerify(() => Audio.defaultSink !== first, 2000, "the output changed")
            compare(Audio.defaultSink, "analog-0")
            tryVerify(() => rowValue("audio:output") === "Output, " + Audio.outputs.find(o => o.id === "analog-0").name)
            verify(find("systemActions").activeFocus && focusedKey() === "audio:output", "the focus stays on the row")
            // Right again wraps past the end (the jack is skipped) to the first one; Left goes back.
            keyClick(Qt.Key_Right)
            tryCompare(Audio, "defaultSink", "hdmi-0")
            keyClick(Qt.Key_Left)
            tryCompare(Audio, "defaultSink", "analog-0")
            // Accept steps forward as Right does.
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "defaultSink", "hdmi-0")
        }

        function test_a_plugged_headset_is_offered_and_chosen_from_the_row() {
            start()
            openAudio()
            goTo("audio:output")
            verify(Audio.mockPlug("usb-headset"))
            tryCompare(Audio, "defaultSink", "usb-headset")      // the policy makes a new headset the default
            tryVerify(() => rowValue("audio:output") === "Output, USB headset")
            keyClick(Qt.Key_Left)
            tryVerify(() => Audio.defaultSink !== "usb-headset", 2000)
            keyClick(Qt.Key_Right)
            tryCompare(Audio, "defaultSink", "usb-headset")
        }

        function test_a_refused_output_change_toasts_and_keeps_the_row() {
            start()
            openAudio()
            goTo("audio:output")
            const before = Audio.defaultSink
            Audio.setOutput("no-such-output")          // the service refuses it
            tryVerify(() => toastTexts().indexOf("Could not switch the audio output.") >= 0, 2000)
            compare(Audio.defaultSink, before)
            verify(find("systemActions").activeFocus && focusedKey() === "audio:output")
        }

        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text)
            return out
        }

        function test_the_microphone_row_chooses_among_the_microphones() {
            start()
            Audio.mockPlugInput("usb-mic")
            tryVerify(() => Audio.inputs.length === 2)
            openAudio()
            goTo("audio:mic")
            compare(hintVerbs(), "A Next|Left/Right Change|B Back")
            compare(rowValue("audio:mic"), "Microphone, Built-in microphone")
            keyClick(Qt.Key_Right)
            tryCompare(Audio, "defaultInput", "usb-mic")
            tryVerify(() => rowValue("audio:mic") === "Microphone, USB headset microphone", 2000, "the row shows the answer")
            keyClick(Qt.Key_Left)
            tryCompare(Audio, "defaultInput", "mic-0")
            verify(find("systemActions").activeFocus && focusedKey() === "audio:mic")
        }

        function test_one_microphone_has_nothing_to_step_through() {
            start()
            openAudio()
            goTo("audio:mic")
            compare(hintVerbs(), "B Back", "no Left/Right or A hint where nothing can change")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            wait(50)
            compare(Audio.defaultInput, "mic-0")
        }

        function test_the_microphone_mute_row_toggles_and_shows_the_answer() {
            start()
            openAudio()
            goTo("audio:micmute")
            compare(rowValue("audio:micmute"), "Mute microphone, Off")
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "inputMuted", true)
            tryVerify(() => rowValue("audio:micmute") === "Mute microphone, On", 2000, "the row shows the answer")
            compare(Audio.muted, false, "the output is not muted")
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "inputMuted", false)
            tryVerify(() => rowValue("audio:micmute") === "Mute microphone, Off")
        }

        // ---- without a microphone -----------------------------------------------------------------------

        function test_without_a_microphone_there_is_no_row_and_no_tile() {
            start()
            Audio.mockUnplugInput("mic-0")
            tryVerify(() => Audio.inputs.length === 0)
            openHub()
            compare(find("systemPanel").tileIds, ["wifi", "bluetooth", "mute"])
            compare(find("quickTile_mic"), null, "no microphone tile")
            compare(find("systemPanel").itemKeys.indexOf("tiles:1"), -1, "and no second line of tiles")
            goTo("panel:audio")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "audio")
            compare(find("systemPanel").itemKeys, ["volume", "audio:mute", "audio:output"])
            compare(find("quickMenuItem_audio:mic"), null)
            compare(find("quickMenuItem_audio:micmute"), null)
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
        }

        function test_a_microphone_that_comes_and_goes_changes_the_open_hub() {
            start()
            Audio.mockUnplugInput("mic-0")
            tryVerify(() => Audio.inputs.length === 0)
            openAudio()
            Audio.mockPlugInput("usb-mic")
            tryVerify(() => find("quickMenuItem_audio:mic") !== null, 2000, "the rows appear")
            goTo("audio:micmute")
            Audio.mockUnplugInput("usb-mic")
            tryVerify(() => find("quickMenuItem_audio:micmute") === null, 2000, "and go")
            verify(find("systemActions").activeFocus, "the list keeps the focus")
            verify(find("quickMenuItem_" + focusedKey()).focused, "on a row that exists")
            keyClick(Qt.Key_Escape)
            keyClick(Qt.Key_Escape)
        }

        function test_the_microphone_tile_mutes_the_microphone_and_shows_the_answer() {
            start()
            openHub()
            goTo("tiles:1")
            const tile = find("quickTile_mic")
            verify(tile, "the tile is there with a microphone")
            verify(tile.focused)
            verify(!tile.on)
            compare(tile.label, "Mute mic")
            compare(tile.detail, "Off")
            compare(tile.Accessible.name, "Mute mic, off")
            compare(hintVerbs(), "A Toggle|B Close")
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "inputMuted", true)
            tryVerify(() => tile.on, 2000, "the tile shows the answer")
            compare(tile.detail, "Muted")
            compare(tile.Accessible.name, "Mute mic, on")
            compare(Audio.muted, false, "the output is not muted")
            verify(find("systemPanel").open, "the Hub stays open")
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "inputMuted", false)
            tryVerify(() => !tile.on)
            keyClick(Qt.Key_Escape)
        }

        function test_the_microphone_tile_appears_when_a_microphone_is_plugged_in() {
            start()
            Audio.mockUnplugInput("mic-0")
            tryVerify(() => Audio.inputs.length === 0)
            openHub()
            compare(find("quickTile_mic"), null)
            Audio.mockPlugInput("usb-mic")
            tryVerify(() => find("quickTile_mic") !== null, 2000, "the tile appears")
            Audio.mockUnplugInput("usb-mic")
            tryVerify(() => find("quickTile_mic") === null, 2000, "and goes")
            verify(find("systemActions").activeFocus)
            keyClick(Qt.Key_Escape)
        }

        // ---- the list's edge fade ------------------------------------------------------------------------

        // The focused row is never under the fade at the edge that hides rows (T-448 review).
        function test_the_focused_row_stays_clear_of_the_fade() {
            start()
            openHub()
            const list = find("systemActions")
            const box = list.parent
            const fade = find("hubMoreBelow").height
            verify(fade > 0)
            verify(find("hubMoreBelow").needed, "the list is longer than the panel")
            let sawBelow = false
            let sawAbove = false
            for (let i = 0; i < 30; ++i) {
                const row = find("quickMenuItem_" + focusedKey())
                const top = row.mapToItem(box, 0, 0).y
                const bottom = top + row.height
                if (find("hubMoreBelow").needed) {
                    sawBelow = true
                    verify(bottom <= box.height - fade + 1, focusedKey() + " ends above the lower fade: " + bottom + " of " + box.height)
                }
                if (find("hubMoreAbove").needed) {
                    sawAbove = true
                    verify(top >= fade - 1, focusedKey() + " starts below the upper fade: " + top)
                }
                if (focusedKey() === "close")
                    break
                keyClick(Qt.Key_Down)
            }
            verify(sawBelow && sawAbove, "both fades were checked")
            for (let i = 0; i < 30 && focusedKey() !== "volume"; ++i) {
                keyClick(Qt.Key_Up)
                const row = find("quickMenuItem_" + focusedKey())
                const top = row.mapToItem(box, 0, 0).y
                if (find("hubMoreAbove").needed)
                    verify(top >= fade - 1, focusedKey() + " going up starts below the upper fade: " + top)
            }
            keyClick(Qt.Key_Escape)
        }

        // The list's height changes after the row was placed (the app header grows when "Paused" arrives, the
        // hint bar changes): the row is moved clear of the fade again.
        function test_the_row_is_moved_clear_of_the_fade_when_the_list_gets_shorter() {
            start()
            openHub()
            goTo("tiles:1")
            const panel = find("systemPanel")
            const box = find("systemActions").parent
            const fade = find("hubMoreBelow").height
            const row = find("quickMenuItem_tiles:1")
            const bottomOf = () => row.mapToItem(box, 0, 0).y + row.height
            verify(bottomOf() <= box.height - fade + 1, "set up: the row is clear")
            panel.bottomReserve += 2 * fade                  // the list is shorter by two fades: the row is under the fade
            tryVerify(() => find("hubMoreBelow").needed && bottomOf() <= box.height - fade + 1, 2000, "the row is clear of the lower fade: " + bottomOf() + " of " + box.height)
            verify(find("systemActions").activeFocus)
            keyClick(Qt.Key_Escape)
        }

        // ---- Screenshots (dev.ps1 shots) ------------------------------------------------------------------

        function test_zz_screenshots_hub_audio_panel() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            start()
            keyClick(Qt.Key_Return)
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(pictureAppComponent, host)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000)
            Audio.mockPlugInput("usb-mic")
            tryVerify(() => Audio.inputs.length === 2)
            keyClick(Qt.Key_HomePage)
            tryVerify(() => find("quickMenuItem_resume").focused, 2000)
            goTo("tiles:1")
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-audio-1-mic-tile.png")
            goTo("panel:audio")
            keyClick(Qt.Key_Return)
            tryCompare(find("systemPanel"), "panelId", "audio")
            tryCompare(find("systemPanel"), "swap", 1)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-audio-2-panel.png")
            goTo("audio:output")
            keyClick(Qt.Key_Right)
            tryCompare(Audio, "defaultSink", "analog-0")
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-audio-3-output.png")
            goTo("audio:micmute")
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "inputMuted", true)
            wait(500)
            grabImage(tc.shell).save(shotsDir + "/hub-audio-4-mic-muted.png")
        }
    }
}
