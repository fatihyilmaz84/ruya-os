pragma Singleton
import QtQuick
import QtMultimedia

// UI sound cues, preloaded once and shared by every component.
QtObject {
    readonly property SoundEffect navigateEffect: SoundEffect { source: "qrc:/qt/qml/RuyaShell/sounds/navigate.wav"; volume: 0.6 }
    readonly property SoundEffect selectEffect: SoundEffect { source: "qrc:/qt/qml/RuyaShell/sounds/select.wav" }
    readonly property SoundEffect backEffect: SoundEffect { source: "qrc:/qt/qml/RuyaShell/sounds/back.wav" }

    function navigate() { navigateEffect.play() }
    function select() { selectEffect.play() }
    function back() { backEffect.play() }
}
