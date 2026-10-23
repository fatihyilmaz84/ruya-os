pragma Singleton
import QtQuick
import QtMultimedia
import RuyaShell

// UI sound cues, preloaded once and shared by every component.
QtObject {
    id: sfx

    // The "UI sounds" channel (Settings -> Audio), 0..1; scales every cue.
    readonly property real gain: (Audio.channelVolumes.ui ?? 100) / 100

    readonly property SoundEffect navigateEffect: SoundEffect { source: "qrc:/qt/qml/RuyaShell/sounds/navigate.wav"; volume: 0.6 * sfx.gain }
    readonly property SoundEffect selectEffect: SoundEffect { source: "qrc:/qt/qml/RuyaShell/sounds/select.wav"; volume: sfx.gain }
    readonly property SoundEffect backEffect: SoundEffect { source: "qrc:/qt/qml/RuyaShell/sounds/back.wav"; volume: sfx.gain }

    // Cues requested so far; lets tests check that a control takes the sound path.
    property int navigateCount: 0
    property int selectCount: 0
    property int backCount: 0

    function navigate() { navigateCount++; navigateEffect.play() }
    function select() { selectCount++; selectEffect.play() }
    function back() { backCount++; backEffect.play() }
}
