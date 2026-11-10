import QtQuick
import QtTest
import RuyaShell

// T-449: the microphones of Devices1.Audio as the Audio singleton shows them (list, default,
// mute), against the mock backend. No UI yet (T-450); the mock is reset before every test.
Item {
    id: host
    width: 320
    height: 240

    TestCase {
        id: tc
        name: "AudioInput"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Audio.mockReset()
            tryCompare(Audio, "defaultInput", "mic-0")
            tryCompare(Audio, "inputMuted", false)
        }

        function ids() { return Audio.inputs.map(i => i.id) }

        function test_the_built_in_microphone_is_listed_and_the_default() {
            compare(Audio.inputs.length, 1)
            const mic = Audio.inputs[0]
            compare(mic.id, "mic-0")
            compare(mic.name, "Built-in microphone")
            compare(mic.kind, "analog")
            compare(mic.available, "unknown")
            verify(mic.isDefault)
        }

        function test_a_plugged_microphone_is_listed_without_taking_the_default() {
            verify(Audio.mockPlugInput("usb-mic"))
            tryCompare(Audio.inputs, "length", 2)
            compare(ids().join(), "mic-0,usb-mic")
            compare(Audio.inputs[1].kind, "usb")
            compare(Audio.defaultInput, "mic-0")
            verify(!Audio.mockPlugInput("no-such-mic"))
        }

        function test_set_input_makes_a_listed_microphone_the_default() {
            Audio.mockPlugInput("usb-mic")
            tryCompare(Audio.inputs, "length", 2)
            const spy = createTemporaryObject(spyComponent, host)
            Audio.setInput("usb-mic")
            tryCompare(Audio, "defaultInput", "usb-mic")
            tryCompare(spy, "count", 1)
            compare(spy.signalArguments[0][1], "ok")
            verify(Audio.inputs.find(i => i.id === "usb-mic").isDefault)
            verify(!Audio.inputs.find(i => i.id === "mic-0").isDefault)
        }

        function test_an_unlisted_id_is_refused_and_changes_nothing() {
            const spy = createTemporaryObject(spyComponent, host)
            Audio.setInput("hdmi-0")                      // an output, not a microphone
            tryCompare(spy, "count", 1)
            compare(spy.signalArguments[0][1], "unknown-input")
            compare(Audio.defaultInput, "mic-0")
        }

        function test_mute_round_trips_and_the_output_mute_is_separate() {
            Audio.setInputMuted(true)
            tryCompare(Audio, "inputMuted", true)
            compare(Audio.muted, false)
            Audio.toggleInputMute()
            tryCompare(Audio, "inputMuted", false)
            Audio.setMuted(true)
            tryCompare(Audio, "muted", true)
            compare(Audio.inputMuted, false)
            Audio.setMuted(false)
            tryCompare(Audio, "muted", false)
        }

        function test_the_mute_belongs_to_the_microphone() {
            Audio.mockPlugInput("usb-mic")
            tryCompare(Audio.inputs, "length", 2)
            Audio.setInputMuted(true)
            tryCompare(Audio, "inputMuted", true)
            Audio.setInput("usb-mic")
            tryCompare(Audio, "defaultInput", "usb-mic")
            tryCompare(Audio, "inputMuted", false)         // the USB microphone was never muted
            Audio.setInput("mic-0")
            tryCompare(Audio, "inputMuted", true)          // the built-in one still is
        }

        function test_a_console_without_a_microphone_has_an_empty_list_and_no_mute() {
            Audio.mockUnplugInput("mic-0")
            tryCompare(Audio.inputs, "length", 0)
            compare(Audio.defaultInput, "")
            compare(Audio.inputMuted, false)
            Audio.setInputMuted(true)                      // nothing to mute: nothing changes
            wait(50)
            compare(Audio.inputMuted, false)
            const spy = createTemporaryObject(spyComponent, host)
            Audio.setInput("mic-0")
            tryCompare(spy, "count", 1)
            compare(spy.signalArguments[0][1], "unknown-input")
        }

        function test_unplugging_the_default_hands_it_to_the_next_one() {
            Audio.mockPlugInput("usb-mic")
            tryCompare(Audio.inputs, "length", 2)
            Audio.mockUnplugInput("mic-0")
            tryCompare(Audio, "defaultInput", "usb-mic")
            compare(Audio.inputs.length, 1)
        }

        Component {
            id: spyComponent
            SignalSpy { target: Audio; signalName: "setInputFinished" }
        }
    }
}
