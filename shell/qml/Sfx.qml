pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import QtMultimedia
import RuyaShell

// UI sound cues (T-227, 02 §5), preloaded once and shared by every component. Which file a cue plays
// comes from the sound theme (SoundThemes.cues: the chosen theme's file, else the bundled theme's; a
// cue with no file anywhere is silent). One function per cue, and a counter for each that tests read:
// the counter counts requests, `playedCount` the cues that really sounded.
//
//   navigate  focus moves             select   Accept              back    Back
//   error     wrong PIN, refused      notification  a toast        warning a sticky or warning toast
//   open/close  the Guide overlay     page     a page changes      volume  the volume OSD
//   startup   once, at the first frame            toggleOn/toggleOff  a switch changes
QtObject {
    id: sfx

    // The "UI sounds" channel (Settings -> Audio), 0..1; scales every cue. Reduced motion does not
    // silence sound; a channel at 0 does.
    readonly property real gain: (Audio.channelVolumes.ui ?? 100) / 100

    // No cue sounds while the screen saver, the dark screen or sleep is up (T-202): nobody is looking,
    // and the input that wakes the console is eaten.
    readonly property bool quiet: IdleClock.covered

    // True for a moment after a cue starts: the ambient bed lowers itself (AmbientLoop, -8 dB).
    property bool ducking: false
    // How many times the bed was asked to duck (tests).
    property int duckCount: 0
    property int playedCount: 0

    component Cue: SoundEffect {
        required property string cue
        property real base: 1.0
        source: sfx.themeCues[cue] ?? ""
        volume: base * sfx.gain
    }

    // The cue files of the active theme, with the bundled theme's for the cues it does not name.
    readonly property var themeCues: SoundThemes.cues

    // Follows the Settings choice: the checker decides whether it is usable.
    readonly property Connections themeFollows: Connections {
        target: DeviceSettings
        function onSoundThemeChanged() { SoundThemes.selectedId = DeviceSettings.soundTheme }
    }
    Component.onCompleted: SoundThemes.selectedId = DeviceSettings.soundTheme

    readonly property Cue navigateEffect: Cue { cue: "navigate"; base: 0.6 }
    readonly property Cue selectEffect: Cue { cue: "select" }
    readonly property Cue backEffect: Cue { cue: "back" }
    readonly property Cue errorEffect: Cue { cue: "error" }
    readonly property Cue notificationEffect: Cue { cue: "notification" }
    readonly property Cue warningEffect: Cue { cue: "warning" }
    readonly property Cue openEffect: Cue { cue: "open" }
    readonly property Cue closeEffect: Cue { cue: "close" }
    readonly property Cue pageEffect: Cue { cue: "page" }
    readonly property Cue volumeEffect: Cue { cue: "volume"; base: 0.8 }
    readonly property Cue startupEffect: Cue { cue: "startup" }
    readonly property Cue toggleOnEffect: Cue { cue: "toggle-on" }
    readonly property Cue toggleOffEffect: Cue { cue: "toggle-off" }

    // Cues requested so far; lets tests check that a control takes the sound path.
    property int navigateCount: 0
    property int selectCount: 0
    property int backCount: 0
    property int errorCount: 0
    property int notificationCount: 0
    property int warningCount: 0
    property int openCount: 0
    property int closeCount: 0
    property int pageCount: 0
    property int volumeCount: 0
    property int startupCount: 0
    property int toggleOnCount: 0
    property int toggleOffCount: 0

    function navigate() { navigateCount++; fire(navigateEffect, 0) }
    function select() { selectCount++; fire(selectEffect, 0) }
    function back() { backCount++; fire(backEffect, 0) }
    function error() { errorCount++; fire(errorEffect, 0) }
    function notification() { notificationCount++; fire(notificationEffect, 0) }
    function warning() { warningCount++; fire(warningEffect, 0) }
    function open() { openCount++; fire(openEffect, 0) }
    function close() { closeCount++; fire(closeEffect, 0) }
    function page() { pageCount++; fire(pageEffect, 0) }
    function volume() { volumeCount++; fire(volumeEffect, 0) }
    function startup() { startupCount++; fire(startupEffect, SoundThemes.duckMs * 3) }
    function toggleOn() { toggleOnCount++; fire(toggleOnEffect, 0) }
    function toggleOff() { toggleOffCount++; fire(toggleOffEffect, 0) }
    // A switch changed: the cue says which way.
    function toggled(checked) { if (checked) toggleOn(); else toggleOff() }

    // Plays one cue unless the console is dark or the channel is at 0 (nothing to hear, nothing to duck).
    function fire(effect, holdMs) {
        if (quiet || gain <= 0)
            return
        effect.play()
        playedCount++
        duckCount++
        ducking = true
        duckTimer.interval = Math.max(SoundThemes.duckMs, holdMs)
        duckTimer.restart()
    }

    readonly property Timer duckTimer: Timer {
        onTriggered: sfx.ducking = false
    }
}
