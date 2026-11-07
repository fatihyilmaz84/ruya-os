pragma ComponentBehavior: Bound
import QtQuick
import QtMultimedia
import RuyaShell

// The ambient bed (T-227, 02 §5): a quiet loop from the sound theme behind Home and the menus.
//
//  - It plays while `wanted` (the shell: no app in front, no screen saver, display off or sleep) and
//    the Ambient sound switch is on, at the Ambient channel's level times the theme's own gain.
//  - It fades out over `SoundThemes.ambientFadeMs` (800 ms) when `wanted` goes false and in again on
//    return; once the fade has finished the players are paused, so nothing is decoded while an app is
//    in front. Reduced motion does not shorten it: this is sound, not motion.
//  - It is lowered by `SoundThemes.duckGain` (-8 dB) while a UI cue sounds (`Sfx.ducking`).
//  - The loop is two players that take turns: the second one starts at the loop start
//    `crossMs` before the first reaches the loop end, and the two are cross-faded, so the join never
//    clicks, whatever the codec does at the end of a file. A theme's loop is a whole number of cycles
//    (docs/developers/sound-themes.md), so the two copies agree in phase.
//
// Tests assert the properties (`wanted`, `fade`, `playing`, `outputVolume`, `ducked`): there is no
// sound to listen to in the offscreen run. With RUYA_SOUNDS_DRY=1 (tests) the players get no file.
Item {
    id: bed

    // Set by Shell: nothing in front of the menus.
    property bool wanted: true

    readonly property bool switchedOn: DeviceSettings.ambientSound
    readonly property bool available: SoundThemes.ambientUrl !== ""
    readonly property real level: (Audio.channelVolumes.ambient ?? 100) / 100
    readonly property bool wantsSound: switchedOn && available && level > 0 && wanted
    // 0..1: the fade in and out. Reaches 0 when the bed has gone quiet.
    property real fade: 0
    Behavior on fade { NumberAnimation { duration: SoundThemes.ambientFadeMs; easing.type: Easing.InOutQuad } }
    // True while the players run (also during the fades); false once faded out and paused.
    readonly property bool playing: wantsSound || fade > 0
    readonly property bool ducked: Sfx.ducking
    // 1, or the duck gain: it follows quickly (a cue is short).
    property real duck: ducked ? SoundThemes.duckGain : 1
    Behavior on duck { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }   // token-ok: audio ramp, not motion
    // What the players are set to.
    readonly property real outputVolume: fade * level * SoundThemes.ambientGain * duck
    // The cross-fade between the two players at the loop seam.
    readonly property int crossMs: 1500
    // Which player sounds now: 0 or 1; `blend` goes 0 -> 1 while the other one comes in.
    property int current: 0
    property real blend: 0
    // The loop has been restarted this many times (tests).
    property int loopCount: 0

    onWantsSoundChanged: fade = wantsSound ? 1 : 0
    Component.onCompleted: fade = wantsSound ? 1 : 0     // the first fade in, at start-up

    component Voice: MediaPlayer {
        id: voice
        required property int index
        // This player's share of the bed: 1 alone, fading to 0 while the other comes in.
        readonly property real share: bed.current === voice.index ? 1 - bed.blend : bed.blend
        source: SoundThemes.dry ? "" : SoundThemes.ambientUrl
        audioOutput: AudioOutput { volume: bed.outputVolume * voice.share }
        loops: MediaPlayer.Once
    }
    Voice { id: voiceA; index: 0 }
    Voice { id: voiceB; index: 1 }

    function player(i) { return i === 0 ? voiceA : voiceB }

    function startLoop() {
        const first = player(current)
        first.position = SoundThemes.ambientLoopStart
        first.play()
    }
    function pauseLoop() {
        voiceA.pause()
        voiceB.pause()
    }
    function restartFromScratch() {
        voiceA.stop()
        voiceB.stop()
        current = 0
        blend = 0
        if (playing)
            startLoop()
    }

    onPlayingChanged: {
        if (playing) {
            const p = player(current)
            if (p.position < SoundThemes.ambientLoopStart || p.mediaStatus === MediaPlayer.NoMedia || p.playbackState === MediaPlayer.StoppedState)
                startLoop()
            else
                p.play()
            if (blend > 0)
                player(1 - current).play()
        } else {
            pauseLoop()
        }
    }
    Connections {
        target: SoundThemes
        function onActiveChanged() { bed.restartFromScratch() }
    }
    // Another file: the old position means nothing.
    Connections {
        target: voiceA
        function onMediaStatusChanged() {
            if (voiceA.mediaStatus === MediaPlayer.LoadedMedia && bed.playing && voiceA.playbackState !== MediaPlayer.PlayingState && bed.current === 0)
                bed.startLoop()
        }
    }
    Connections {
        target: voiceB
        function onMediaStatusChanged() {
            if (voiceB.mediaStatus === MediaPlayer.LoadedMedia && bed.playing && voiceB.playbackState !== MediaPlayer.PlayingState && bed.current === 1)
                bed.startLoop()
        }
    }

    // Watches the position of the player that sounds and starts the next one `crossMs` before the loop end.
    Timer {
        id: watch
        interval: 50                 // token-ok: polling the player, not motion
        repeat: true
        running: bed.playing && !SoundThemes.dry
        onTriggered: {
            const now = bed.player(bed.current)
            if (bed.blend === 0 && now.position >= SoundThemes.ambientLoopEnd - bed.crossMs && now.playbackState === MediaPlayer.PlayingState)
                bed.beginCross()
        }
    }
    function beginCross() {
        const next = player(1 - current)
        next.position = SoundThemes.ambientLoopStart
        next.play()
        cross.restart()
    }
    NumberAnimation {
        id: cross
        target: bed
        property: "blend"
        from: 0
        to: 1
        duration: bed.crossMs
        onFinished: {
            const old = bed.player(bed.current)
            old.pause()
            bed.current = 1 - bed.current
            bed.blend = 0                 // the share of each player swaps with `current`, so the sound does not change
            bed.loopCount++
        }
    }
}
