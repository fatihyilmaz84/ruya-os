pragma Singleton
import QtQuick
import QtMultimedia

// UI sound cues, preloaded once and shared by every component.
QtObject {
    readonly property SoundEffect navigateEffect: SoundEffect { source: "qrc:/qt/qml/RuyaShell/sounds/navigate.wav"; volume: 0.6 }
    readonly property SoundEffect selectEffect: SoundEffect { source: "qrc:/qt/qml/RuyaShell/sounds/select.wav" }
    readonly property SoundEffect backEffect: SoundEffect { source: "qrc:/qt/qml/RuyaShell/sounds/back.wav" }

    // Cues requested so far; lets tests check that a control takes the sound path.
    property int navigateCount: 0
    property int selectCount: 0
    property int backCount: 0

    function navigate() { navigateCount++; navigateEffect.play() }
    function select() { selectCount++; selectEffect.play() }
    function back() { backCount++; backEffect.play() }
}
