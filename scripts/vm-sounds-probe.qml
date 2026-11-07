// Run by vm-sounds-check.sh as ruya-shell (`ruya-shell --load`, offscreen): the image's own Qt Multimedia
// loads the bundled theme's ambient loop (FLAC) at volume 0 and says what it saw. T-227.
import QtQuick
import QtMultimedia

QtObject {
    id: root

    property bool loaded: false
    property bool playing: false
    property int duration: 0
    property string error: ""

    property MediaPlayer player: MediaPlayer {
        source: "file:///usr/share/ruyaos/sounds/dreamglass/ambient.flac"
        audioOutput: AudioOutput { volume: 0 }
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia) {
                root.loaded = true
                root.duration = duration
                play()
            }
        }
        onPlaybackStateChanged: if (playbackState === MediaPlayer.PlayingState) root.playing = true
        onErrorOccurred: (e, text) => root.error = text
    }

    property Timer report: Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: console.warn("sounds-probe: loaded=" + root.loaded + " duration=" + root.duration
                                  + " playing=" + root.playing + " position=" + root.player.position + " error=" + root.error)
    }
    property Timer stop: Timer {
        interval: 6000
        running: true
        onTriggered: Qt.quit()
    }
}
