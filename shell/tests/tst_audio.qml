import QtQuick
import QtTest
import RuyaShell

// Audio: the output policy (hot-plug), Settings -> Audio, the channel volumes and the volume
// keys. Driven with controller/media keys only, against the mock backend. Signs in as "Ada"
// (p2, no PIN). The mock is reset before every test.
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
        name: "Audio"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Audio.mockReset()
            tryCompare(Audio, "defaultSink", "hdmi-0")
            tryCompare(Audio, "volume", 50)
            tryCompare(Audio, "muted", false)
            tryVerify(() => Audio.channelVolumes.ui === 100)
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
        }

        function cleanup() {
            DeviceSettings.language = "en"
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

        function test_initial_state() {
            compare(Audio.sinks.length, 2)
            compare(Audio.sinks[0].id, "hdmi-0")
            compare(Audio.sinks[0].kind, "hdmi")
            verify(Audio.sinks[0].isDefault)
            compare(Audio.sinks[1].id, "analog-0")
            compare(Audio.sinks[1].kind, "analog")
            verify(!Audio.sinks[1].isDefault)
            compare(Audio.channelVolumes.ui, 100)
            compare(Audio.channelVolumes.ambient, 100)
            compare(Audio.channelVolumes.media, 100)
            compare(toastTexts().length, 0, "the initial read is not a change: no toast")
        }

        function test_hotplug_policy() {
            verify(Audio.mockPlug("usb-headset"))
            tryCompare(Audio, "defaultSink", "usb-headset")
            compare(Audio.defaultSinkName, "USB headset")
            tryVerify(() => tc.toastTexts().includes("Sound moved to USB headset"), 2000, "a toast names the output")
            compare(Audio.sinks.length, 3)

            verify(Audio.mockPlug("bt-headphones"))     // the most recent headset wins
            tryCompare(Audio, "defaultSink", "bt-headphones")
            tryVerify(() => tc.toastTexts().includes("Sound moved to BT headphones"))

            Audio.mockUnplug("usb-headset")             // not the default: nothing changes
            tryVerify(() => Audio.sinks.length === 3)
            compare(Audio.defaultSink, "bt-headphones")

            Audio.mockUnplug("bt-headphones")           // the default left: back to HDMI
            tryCompare(Audio, "defaultSink", "hdmi-0")
            tryVerify(() => tc.toastTexts().includes("Sound moved to TV (HDMI)"))
            compare(Audio.sinks.length, 2)
            verify(!Audio.mockPlug("no-such-device"))
        }

        function test_unplug_returns_to_previous_default() {
            Audio.setDefaultSink("analog-0")
            tryCompare(Audio, "defaultSink", "analog-0")
            Audio.mockPlug("usb-headset")
            tryCompare(Audio, "defaultSink", "usb-headset")
            Audio.mockUnplug("usb-headset")
            tryCompare(Audio, "defaultSink", "analog-0", 2000, "the previous default, not the first output")
        }

        function test_unknown_sink_is_refused() {
            const spy = createTemporaryObject(spyComponent, host, { target: Audio, signalName: "setDefaultSinkFinished" })
            Audio.setDefaultSink("nope")
            tryCompare(spy, "count", 1)
            compare(spy.signalArguments[0][1], "unknown-sink")
            compare(Audio.defaultSink, "hdmi-0")
        }

        // T-322: the outputs of the cards, the player's choice and the test sound, over the same
        // contract the service speaks (ListOutputs, SetOutput, TestOutput).
        function test_outputs_list_choose_and_test() {
            tryVerify(() => Audio.outputs.length === 3)
            compare(Audio.outputs[0].id, "hdmi-0")
            compare(Audio.outputs[0].kind, "hdmi")
            verify(Audio.outputs[0].isDefault)
            verify(Audio.outputs[0].active)
            compare(Audio.outputs[1].kind, "speaker")
            compare(Audio.outputs[2].id, "headphones-0")
            compare(Audio.outputs[2].available, "no")
            verify(!Audio.outputs[2].active)
            verify(Audio.outputs.every(o => !o.isSaved), "nothing chosen yet")

            const choose = createTemporaryObject(spyComponent, host, { target: Audio, signalName: "setOutputFinished" })
            Audio.setOutput("analog-0")
            tryCompare(choose, "count", 1)
            compare(choose.signalArguments[0][1], "ok")
            tryCompare(Audio, "defaultSink", "analog-0")
            tryVerify(() => Audio.outputs.find(o => o.id === "analog-0").isSaved)
            verify(Audio.outputs.find(o => o.id === "analog-0").isDefault)

            // A tone does not move the default or the choice.
            const test = createTemporaryObject(spyComponent, host, { target: Audio, signalName: "testOutputFinished" })
            Audio.testOutput("hdmi-0")
            tryCompare(test, "count", 1)
            compare(test.signalArguments[0][1], "ok")
            compare(Audio.defaultSink, "analog-0")
            verify(!Audio.outputs.find(o => o.id === "hdmi-0").isSaved)

            // The empty jack has no sink yet; an unknown id is refused.
            Audio.testOutput("headphones-0")
            tryCompare(test, "count", 2)
            compare(test.signalArguments[1][1], "inactive")
            Audio.setOutput("nope")
            tryCompare(choose, "count", 2)
            compare(choose.signalArguments[1][1], "unknown-output")

            Audio.resetOutputChoice()
            tryVerify(() => Audio.outputs.every(o => !o.isSaved))
        }

        Component { id: spyComponent; SignalSpy {} }

        function focusedOutputRow(id) {
            for (let i = 0; i < 6 && !find("sink_" + id).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            verify(find("sink_" + id).activeFocus, "focus reached " + id)
        }

        function test_output_list_marks_the_current_one() {
            openAudioPane()
            compare(find("sink_hdmi-0").value, "Current")
            compare(find("sink_analog-0").value, "")
            compare(find("sink_hdmi-0").iconName, "volume_up")
            compare(find("sink_analog-0").iconName, "speaker")
            compare(find("sink_headphones-0").iconName, "headphones")
            verify(!find("sink_hdmi-0").dimmed)
            Audio.setOutput("analog-0")
            tryCompare(find("sink_analog-0"), "value", "Current")
            compare(find("sink_hdmi-0").value, "")
        }

        function test_unavailable_output_is_greyed_with_its_reason_and_cannot_be_chosen() {
            openAudioPane()
            const row = find("sink_headphones-0")
            verify(row.dimmed, "greyed")
            compare(row.value, "Not connected")
            verify(!find("sink_analog-0").dimmed)
            const spy = createTemporaryObject(spyComponent, host, { target: Audio, signalName: "setOutputFinished" })
            focusedOutputRow("headphones-0")
            keyClick(Qt.Key_Return)
            tryVerify(() => tc.toastTexts().includes("Headphones: Not connected."), 2000, "the reason is said")
            compare(spy.count, 0, "no SetOutput call")
            compare(Audio.defaultSink, "hdmi-0")
            verify(find("sink_headphones-0").activeFocus, "focus stays")
        }

        function test_choosing_an_output_calls_set_output_and_refreshes() {
            openAudioPane()
            const spy = createTemporaryObject(spyComponent, host, { target: Audio, signalName: "setOutputFinished" })
            keyClick(Qt.Key_Down)
            tryVerify(() => find("sink_analog-0").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(spy, "count", 1)
            compare(spy.signalArguments[0][0], "analog-0")
            compare(spy.signalArguments[0][1], "ok")
            tryCompare(find("sink_analog-0"), "value", "Current")
            tryVerify(() => Audio.outputs.find(o => o.id === "analog-0").isSaved)
            verify(find("sink_analog-0").activeFocus, "focus stays on the chosen output")
        }

        function test_test_sound_row_plays_on_the_focused_output_without_choosing_it() {
            openAudioPane()
            const spy = createTemporaryObject(spyComponent, host, { target: Audio, signalName: "testOutputFinished" })
            const choose = createTemporaryObject(spyComponent, host, { target: Audio, signalName: "setOutputFinished" })
            keyClick(Qt.Key_Down)                        // the speaker
            tryVerify(() => find("sink_analog-0").activeFocus)
            keyClick(Qt.Key_Down)                        // the empty jack
            keyClick(Qt.Key_Down)                        // Test sound
            tryVerify(() => find("rowTestSound").activeFocus)
            tryCompare(find("rowTestSound"), "value", "Analog output")
            keyClick(Qt.Key_Return)
            tryCompare(spy, "count", 1)
            compare(spy.signalArguments[0][0], "analog-0", "the empty jack on the way down is not the target")
            compare(Audio.defaultSink, "hdmi-0", "the default is untouched")
            compare(choose.count, 0)
        }

        function test_an_inactive_but_available_output_can_be_chosen() {
            Audio.mockSetJackPlugged(true)
            openAudioPane()
            tryVerify(() => find("sink_headphones-0").value === "")
            verify(!find("sink_headphones-0").dimmed, "not greyed: a plug is in, only its profile is not active")
            const spy = createTemporaryObject(spyComponent, host, { target: Audio, signalName: "setOutputFinished" })
            focusedOutputRow("headphones-0")
            keyClick(Qt.Key_Return)
            tryCompare(spy, "count", 1)
            compare(spy.signalArguments[0][0], "headphones-0", "setOutput was called")
            compare(spy.signalArguments[0][1], "inactive")
            tryVerify(() => tc.toastTexts().includes("Could not switch the audio output."))
            verify(!tc.toastTexts().includes("Headphones: Not connected."))
        }

        function test_moved_toast_when_the_default_changes() {
            openAudioPane()
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "defaultSink", "analog-0")
            tryVerify(() => tc.toastTexts().includes("Sound moved to Analog output"), 2000, "the toast names the output")
        }

        function test_select_output() {
            openAudioPane()
            compare(find("sink_hdmi-0").value, "Current")
            compare(find("sink_analog-0").value, "")

            keyClick(Qt.Key_Down)
            tryVerify(() => find("sink_analog-0").activeFocus)
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "defaultSink", "analog-0")
            tryCompare(find("sink_analog-0"), "value", "Current")
            compare(find("sink_hdmi-0").value, "")
            verify(find("sink_analog-0").activeFocus, "focus stays on the chosen output")
            tryVerify(() => tc.toastTexts().includes("Sound moved to Analog output"))
        }

        function test_pane_follows_hotplug() {
            openAudioPane()
            verify(find("sink_usb-headset") === null)
            Audio.mockPlug("usb-headset")
            tryVerify(() => find("sink_usb-headset") !== null, 2000, "a row appears")
            compare(find("sink_usb-headset").value, "Current")
            compare(find("sink_hdmi-0").value, "")

            keyClick(Qt.Key_Down)                       // rows: hdmi, analog, usb
            keyClick(Qt.Key_Down)
            tryVerify(() => find("sink_usb-headset").activeFocus)
            Audio.mockUnplug("usb-headset")             // the focused row goes away
            tryVerify(() => find("sink_usb-headset") === null, 2000, "the row disappears")
            tryVerify(() => find("sink_hdmi-0").value === "Current")
            tryVerify(() => find("paneAudio").activeFocus, 2000, "focus stays in the pane")
            keyClick(Qt.Key_Down)                       // and the pane still navigates
            tryVerify(() => find("sink_analog-0").activeFocus || find("sink_hdmi-0").activeFocus)
        }

        function test_sliders_and_mute_in_pane() {
            openAudioPane()
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)                       // master (after analog, the jack, Test sound)
            tryVerify(() => find("rowMaster").activeFocus)
            compare(find("rowMaster").value, 50)
            keyClick(Qt.Key_Right)
            tryCompare(Audio, "volume", 55)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            tryCompare(Audio, "volume", 45)

            Audio.setVolume(70)                         // from outside (the volume keys): the row follows
            tryCompare(find("rowMaster"), "value", 70)

            keyClick(Qt.Key_Down)                       // UI sounds
            keyClick(Qt.Key_Down)                       // Ambient
            tryVerify(() => find("rowAmbient").activeFocus)
            keyClick(Qt.Key_Left)
            tryVerify(() => Audio.channelVolumes.ambient === 95)
            keyClick(Qt.Key_Down)                       // Ambient sound (T-227, the switch under its slider)
            tryVerify(() => find("rowAmbientSound").activeFocus)
            keyClick(Qt.Key_Down)                       // Media
            tryVerify(() => find("rowMedia").activeFocus)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            tryVerify(() => Audio.channelVolumes.media === 90)
            compare(Audio.channelVolumes.ui, 100)

            keyClick(Qt.Key_Down)                       // Mute
            tryVerify(() => find("rowMute").activeFocus)
            verify(!find("rowMute").checked)
            keyClick(Qt.Key_Return)
            tryCompare(Audio, "muted", true)
            verify(find("rowMute").checked)
            Audio.toggleMute()                          // the mute key
            tryCompare(find("rowMute"), "checked", false)
            verify(find("rowMute").activeFocus)
        }

        function test_channel_volume_does_not_show_the_volume_osd() {
            const osd = find("volumeOsd")
            Audio.setChannelVolume("media", 30)
            tryVerify(() => Audio.channelVolumes.media === 30)
            wait(100)
            verify(!osd.shown, "a channel is not the master volume")
            Audio.setVolume(60)
            tryCompare(osd, "shown", true)
        }

        function test_ui_channel_drives_sfx() {
            compare(Sfx.gain, 1)
            Audio.setChannelVolume("ui", 40)
            tryCompare(Sfx, "gain", 0.4)
            tryVerify(() => Math.abs(Sfx.navigateEffect.volume - 0.24) < 0.001, 2000, "navigate keeps its 0.6 base")
            compare(Sfx.selectEffect.volume, 0.4)
            compare(Sfx.backEffect.volume, 0.4)
            Audio.setChannelVolume("ui", 0)
            tryCompare(Sfx.selectEffect, "volume", 0)

            // And through the slider in Settings.
            Audio.setChannelVolume("ui", 100)
            tryCompare(Sfx.selectEffect, "volume", 1)
            openAudioPane()
            for (let i = 0; i < 5; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => find("rowUiSounds").activeFocus)
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            tryVerify(() => Audio.channelVolumes.ui === 90)
            tryVerify(() => Math.abs(Sfx.selectEffect.volume - 0.9) < 0.001)
        }

        function test_volumes_clamp() {
            Audio.setChannelVolume("ui", 250)
            tryVerify(() => Audio.channelVolumes.ui === 100)
            Audio.setChannelVolume("ui", -5)
            tryVerify(() => Audio.channelVolumes.ui === 0)
            Audio.setChannelVolume("ambient", 101)
            tryVerify(() => Audio.channelVolumes.ambient === 100)
            Audio.setChannelVolume("media", -1)
            tryVerify(() => Audio.channelVolumes.media === 0)
            Audio.setVolume(300)
            tryCompare(Audio, "volume", 100)
            Audio.setVolume(-3)
            tryCompare(Audio, "volume", 0)

            ignoreWarning("ruya-shell: audio: unknown channel 'bogus'")
            Audio.setChannelVolume("bogus", 10)         // ignored, other channels untouched
            wait(50)
            compare(Audio.channelVolumes.bogus, undefined)
            compare(Audio.channelVolumes.ui, 0)
        }

        function test_volume_keys_while_muted() {
            const osd = find("volumeOsd")
            keyClick(Qt.Key_VolumeMute)
            tryCompare(Audio, "muted", true)
            tryCompare(osd, "shown", true)

            keyClick(Qt.Key_VolumeDown)                 // stays muted, level untouched
            wait(100)
            compare(Audio.muted, true)
            compare(Audio.volume, 50)
            verify(osd.shown, "the OSD still shows")

            keyClick(Qt.Key_VolumeUp)                   // unmutes and raises
            tryCompare(Audio, "muted", false)
            tryCompare(Audio, "volume", 55)

            keyClick(Qt.Key_VolumeMute)                 // Mute toggles only mute
            tryCompare(Audio, "muted", true)
            compare(Audio.volume, 55)
            keyClick(Qt.Key_VolumeMute)
            tryCompare(Audio, "muted", false)
            compare(Audio.volume, 55)
        }

        function test_osd_shows_a_speaker_icon_and_muted_in_words() {
            const osd = find("volumeOsd")
            const icon = find("volumeIcon")
            const label = find("volumeLabel")
            keyClick(Qt.Key_VolumeUp)
            tryCompare(osd, "shown", true)
            tryVerify(() => osd.visible)
            compare(icon.name, "volume_up")
            verify(icon.implicitWidth > 0)
            verify(!label.visible, "no word beside the icon while sound is on")

            keyClick(Qt.Key_VolumeMute)
            tryCompare(Audio, "muted", true)
            compare(icon.name, "volume_off")
            tryVerify(() => label.visible, 2000, "the word Muted appears beside the icon")
            compare(label.text, "Muted")

            keyClick(Qt.Key_VolumeMute)
            tryCompare(Audio, "muted", false)
            compare(icon.name, "volume_up")
        }

        function test_an_older_reply_arriving_late_is_dropped() {
            // Volume 50 on the TV. Ask again (the replies, a snapshot of that, are held back), then
            // the volume is raised and a headset plugged in: the late replies must not put 50 and
            // the TV back. The state, the sink list and the output list are three kinds of reply.
            Audio.mockRefreshDelayed(150)
            compare(Audio.mockPendingReplies(), 3)
            Audio.setVolume(70)
            verify(Audio.mockPlug("usb-headset"))
            tryCompare(Audio, "volume", 70)
            tryCompare(Audio, "defaultSink", "usb-headset")
            tryVerify(() => Audio.mockPendingReplies() === 0)
            compare(Audio.volume, 70, "the late state was dropped")
            compare(Audio.defaultSink, "usb-headset", "the late output list was dropped")
            compare(Audio.sinks.length, 3)
            compare(Audio.outputs.length, 4, "the late output list was dropped too")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Audio.mockPlug("usb-headset")
            tryCompare(Audio, "defaultSink", "usb-headset")
            Audio.setChannelVolume("ambient", 60)
            Audio.setChannelVolume("media", 85)
            clearToasts()
            openAudioPane()
            tryCompare(find("volumeOsd"), "shown", false, 5000, "the OSD is not in the shot")
            for (let i = 0; i < 3; ++i)                  // usb headset (current), the jack (greyed)
                keyClick(Qt.Key_Down)
            tryVerify(() => find("sink_headphones-0").activeFocus)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/22-settings-audio.png")
            keyClick(Qt.Key_Down)                        // Test sound
            tryVerify(() => find("rowTestSound").activeFocus)
            wait(600)
            grabImage(tc.shell).save(shotsDir + "/22-settings-audio-test.png")
        }

        function test_zz_screenshots_tr() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.language = "tr"
            openAudioPane()
            tryCompare(find("sink_headphones-0"), "value", "Bağlı değil")
            tryCompare(find("sink_hdmi-0"), "value", "Geçerli")
            focusedOutputRow("headphones-0")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("rowTestSound").activeFocus)
            tryCompare(find("volumeOsd"), "shown", false, 5000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/22-settings-audio-tr.png")
        }
    }
}
