pragma ComponentBehavior: Bound
import QtQuick
import QtMultimedia
import RuyaShell

// The trailer in the screenshot viewer's box (04 §5.4, RUY-802): the video fitted into the box (`MediaPlayer`
// and `VideoOutput`, with sound), a control bar inside it (play or pause icon, a progress bar, "m:ss / m:ss")
// and, when the source cannot play, the poster with "The trailer can't play." on it. The viewer owns the
// keys and calls `toggle()`, `seek(ms)` and `wake()`; this item is never a focus stop.
//
//  - `trailer` is { video, poster, name, seconds }; it plays only while `active` (the viewer is shown in
//    trailer mode). It starts on opening, never on its own on the page.
//  - `covered` (the Hub or "Who's playing?" is open, ModalLayer.covered) pauses it; it goes on when the
//    cover goes unless the player paused it.
//  - The bar shows on any input (`wake()`), fades out (`overlayMs`) 3 s after the last one (the delay runs at
//    `Theme.motionFactor` like every timing, so a test can shorten it) and stays while paused.
//
// Tests assert `player.playbackState`, `player.position`, `wantsPlay`, `barShown` and `failed`: there are no
// pixels to look at in the offscreen run.
Item {
    id: root

    property real u: 1
    property var trailer: null
    property bool active: false
    property bool covered: false

    // The player's intent: false after the player paused it with A.
    property bool wantsPlay: true
    property bool barShown: true
    readonly property alias player: player
    readonly property bool shouldPlay: active && wantsPlay && !covered && !failed
    readonly property bool failed: (trailer !== null && (trailer.video ?? "") === "")
                                   || player.error !== MediaPlayer.NoError
                                   || player.mediaStatus === MediaPlayer.InvalidMedia
    readonly property real seekMs: 10000          // token-ok: 04 §5.4, A seeks 10 s
    readonly property int hideMs: Math.max(1, Math.round(3000 * Theme.motionFactor))     // token-ok: 04 §5.4, 3 s
    readonly property real position: player.position
    readonly property real length: player.duration > 0 ? player.duration : (trailer ? (trailer.seconds ?? 0) * 1000 : 0)

    function url(path) {
        if (!path)
            return ""
        return path.startsWith("/") ? "file://" + path : /^[A-Za-z]:\//.test(path) ? "file:///" + path : path
    }

    function toggle() {
        wantsPlay = !wantsPlay
        wake()
    }

    function seek(deltaMs) {
        const end = player.duration > 0 ? player.duration : Number.MAX_VALUE
        player.position = Math.max(0, Math.min(end, player.position + deltaMs))
        wake()
    }

    // Any input: the bar is there and the 3 s start again.
    function wake() {
        barShown = true
        hideTimer.restart()
    }

    function begin() {
        wantsPlay = true
        wake()
    }

    onActiveChanged: if (active) begin()
    onShouldPlayChanged: apply()
    onTrailerChanged: if (active) begin()

    function apply() {
        if (!active) {
            player.stop()
        } else if (shouldPlay) {
            player.play()
        } else if (!failed) {
            player.pause()
        }
    }

    Timer {
        id: hideTimer
        interval: root.hideMs
        onTriggered: if (root.wantsPlay) root.barShown = false
    }

    // Paused: the bar stays.
    onWantsPlayChanged: if (!wantsPlay) barShown = true

    MediaPlayer {
        id: player
        source: root.active && root.trailer ? root.url(root.trailer.video) : ""
        audioOutput: AudioOutput {}
        videoOutput: video
        onMediaStatusChanged: if (mediaStatus === MediaPlayer.LoadedMedia) root.apply()
        onSourceChanged: if (source.toString() === "") position = 0
    }

    // The box: rounded on a GPU (the software renderer draws no mask), the poster under the video.
    Item {
        id: frame
        objectName: "trailerFrame"
        anchors.fill: parent
        readonly property bool masked: GraphicsInfo.api !== GraphicsInfo.Software
        layer.enabled: masked
        layer.smooth: true
        layer.effect: SmoothMask { maskSource: frameMask }

        Rectangle {
            anchors.fill: parent
            color: "black"
        }
        Image {
            objectName: "trailerPoster"
            anchors.fill: parent
            visible: root.failed || player.playbackState === MediaPlayer.StoppedState
            source: root.trailer ? root.url(root.trailer.poster) : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
        }
        VideoOutput {
            id: video
            objectName: "trailerVideo"
            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectFit
            visible: !root.failed
        }
    }
    Rectangle {
        id: frameMask
        anchors.fill: parent
        radius: Theme.radiusM * root.u
        visible: false
        layer.enabled: frame.masked
        layer.smooth: true
    }

    // It cannot play: the poster stays and the line says so.
    Rectangle {
        objectName: "trailerFailed"
        anchors.centerIn: parent
        visible: root.failed
        width: Math.min(parent.width, failedText.implicitWidth + 2 * Theme.spaceL * root.u)
        height: Theme.rowHeight * root.u
        radius: height / 2
        color: Theme.glassOpaque
        border.width: Theme.hairlineAt(root.u)
        border.color: Theme.glassBorder

        Text {
            id: failedText
            objectName: "trailerFailedText"
            anchors.centerIn: parent
            width: parent.width - 2 * Theme.spaceL * root.u
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: qsTr("The trailer can't play.")
            color: Theme.text
            font.pixelSize: Theme.typeBody * root.u
        }
    }

    // The control bar: 24 u from the box's left, right and bottom.
    Rectangle {
        id: bar
        objectName: "trailerBar"
        readonly property real inset: 24 * root.u      // token-ok: 04 §5.4 Screenshots and trailer
        x: inset
        y: parent.height - inset - height
        width: parent.width - 2 * inset
        height: Theme.rowHeight * root.u
        radius: height / 2
        color: Theme.glassOpaque
        border.width: Theme.hairlineAt(root.u)
        border.color: Theme.glassBorder
        opacity: root.barShown && !root.failed ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Theme.overlayMs } }

        Row {
            x: Theme.spaceL * root.u
            height: parent.height
            width: parent.width - 2 * Theme.spaceL * root.u
            spacing: Theme.spaceM * root.u

            Icon {
                id: stateIcon
                objectName: "trailerStateIcon"
                anchors.verticalCenter: parent.verticalCenter
                u: root.u
                name: root.wantsPlay ? "pause" : "play_arrow"
                filled: true
                color: Theme.text
            }
            ProgressBar {
                objectName: "trailerProgress"
                anchors.verticalCenter: parent.verticalCenter
                u: root.u
                width: parent.width - stateIcon.width - timeText.width - 2 * parent.spacing
                value: root.length > 0 ? root.position / root.length : 0
                trackColor: Theme.glass
                animated: false
            }
            Text {
                id: timeText
                objectName: "trailerTime"
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: PlayTrust.clock(root.position / 1000) + " / " + PlayTrust.clock(root.length / 1000)
                color: Theme.text
                font.pixelSize: Theme.typeBody * root.u
                font.features: { "tnum": 1 }
            }
        }
    }
}
