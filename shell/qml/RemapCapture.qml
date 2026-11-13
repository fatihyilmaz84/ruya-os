pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Remap buttons -> the capture dialog (RUY-465, 06 §7): "Press the new button for <name>". A dialog
// card (04 §5) with the source's glyph at 80 u (`glyphSize` × 2, a literal of this dialog), an
// arrow and an 80 u empty slot ringed in `focusRing` with "?", a 480 u ProgressBar draining over
// 5 s, and "Any button on the <pad>. Nothing for 5 seconds cancels.".
//
// It reads the pad's live test stream (Input.startTest when it opens, stopTest when it closes), not
// the navigation keys: the first press of a remappable input (a trigger past a quarter) is the new
// target (captured(input)). Every key is taken while it is open. Esc or Backspace on a keyboard,
// 5 s without a press, the test ending or refused cancel it silently (cancelled()); a refused start
// also says "Controllers can't be read right now.". A pad's B sends Esc as well as its press on the
// stream: Esc waits `escGraceMs` for a press before it cancels. After a capture the dialog keeps the
// keys until that input is released (at least `guardMs`, at most `guardMaxMs`), so the key the same
// press sent (Enter for A) never reaches the row and opens the capture again.
FocusScope {
    id: dialog

    property real u: 1
    property string padId: ""
    property string padName: ""         // the short name: "DualSense"
    property string family: ""
    property string source: ""          // the input being remapped
    property bool shown: false
    property Item returnTo: null

    readonly property int timeoutMs: 5000   // the capture's window (not a Theme duration: a time limit)
    readonly property int escGraceMs: 150
    readonly property int guardMs: 250
    readonly property int guardMaxMs: 1500

    // The capture is over (captured or cancelled), the dialog fades out but may still hold the keys.
    property bool closing: false
    property string captured: ""
    property bool capturedReleased: false
    property double capturedAt: 0
    // The time left, 1 -> 0 over timeoutMs (the bar).
    property real remaining: 1

    readonly property var modalHints: [{ button: "Esc", text: qsTr("Cancel") }]

    signal capturedInput(string input)
    signal cancelled()
    signal closed()

    function open(source, padId, padName, family) {
        returnTo = Window.activeFocusItem
        dialog.source = source
        dialog.padId = padId
        dialog.padName = padName
        dialog.family = family
        captured = ""
        capturedReleased = false
        closing = false
        shown = true
        dialog.forceActiveFocus()
        remaining = 1
        drain.restart()
        timeout.restart()
        Input.startTest(padId, false)
    }

    // The inputs that can be a target, and whether this event presses one.
    function pressOf(input, value) {
        if (!GameControls.sources.includes(input))
            return false
        return GameControls.isAxis(input) ? value >= 8192 : value !== 0
    }

    function capture(input) {
        if (closing)
            return
        closing = true
        captured = input
        capturedReleased = false
        capturedAt = Date.now()
        timeout.stop()
        escTimer.stop()
        drain.stop()
        shown = false
        guard.start()
        dialog.capturedInput(input)
    }

    function cancel() {
        if (closing)
            return
        closing = true
        timeout.stop()
        escTimer.stop()
        drain.stop()
        shown = false
        finish()
        dialog.cancelled()
    }

    // The end of the dialog: the stream stops, the focus goes back.
    function finish() {
        guard.stop()
        Input.stopTest(padId)
        closing = false
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    Timer {
        id: timeout
        interval: dialog.timeoutMs
        onTriggered: dialog.cancel()
    }
    Timer {
        id: escTimer
        interval: dialog.escGraceMs        // a pad's B press on the stream wins over its Esc key
        onTriggered: dialog.cancel()
    }
    Timer {
        id: guard
        interval: 50
        repeat: true
        onTriggered: {
            const held = Date.now() - dialog.capturedAt
            if ((dialog.capturedReleased && held >= dialog.guardMs) || held >= dialog.guardMaxMs)
                dialog.finish()
        }
    }
    NumberAnimation {
        id: drain
        target: dialog
        property: "remaining"
        from: 1
        to: 0
        duration: dialog.timeoutMs          // the time left, not a motion token
    }

    Connections {
        target: Input
        function onTestInput(deviceId, input, value, source) {
            if (deviceId !== dialog.padId)
                return
            if (dialog.closing) {
                if (dialog.captured === input && !dialog.pressOf(input, value))
                    dialog.capturedReleased = true
                return
            }
            if (dialog.shown && dialog.pressOf(input, value))
                dialog.capture(input)
        }
        function onTestStartFinished(deviceId, status) {
            if (deviceId !== dialog.padId || !dialog.shown || dialog.closing || status === "ok" || status === "busy")
                return
            dialog.cancel()
            Notifications.show(qsTr("Controllers can't be read right now."), "error")
        }
        function onTestEnded(deviceId, reason) {
            if (deviceId === dialog.padId && dialog.shown && !dialog.closing && reason !== "stopped")
                dialog.cancel()
        }
    }

    // Still there (transparent) while it holds the keys after a capture.
    visible: opacity > 0 || closing
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    Rectangle {
        objectName: "remapCapturePanel"
        anchors.centerIn: parent
        width: Math.max(880 * dialog.u, card.width + 120 * dialog.u)
        height: card.height + 96 * dialog.u
        radius: Theme.radiusL * dialog.u
        color: Theme.panel
        border.color: Theme.glassBorder
    }

    Column {
        id: card
        anchors.centerIn: parent
        spacing: Theme.spaceL * dialog.u

        Text {
            objectName: "remapCaptureTitle"
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, 1100 * dialog.u)
            textFormat: Text.PlainText
            text: qsTr("Press the new button for %1").arg(GameControls.buttonName(dialog.source, dialog.family))
            color: Theme.text
            font.pixelSize: Theme.typeTitle * dialog.u
            font.weight: Theme.weightDemiBold
            elide: Text.ElideRight
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spaceL * dialog.u

            ButtonGlyph {
                objectName: "remapCaptureSource"
                anchors.verticalCenter: parent.verticalCenter
                u: 2 * dialog.u                    // 80 u: glyphSize × 2, this dialog's literal (04 §5)
                button: GameControls.glyphOf(dialog.source, dialog.family)
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "→"
                color: Theme.text
                font.pixelSize: Theme.typeTitle * dialog.u
                font.weight: Theme.weightLight
            }
            Rectangle {
                objectName: "remapCaptureSlot"
                anchors.verticalCenter: parent.verticalCenter
                width: 2 * Theme.glyphSize * dialog.u          // 80 u, as the source glyph
                height: width
                radius: width / 2
                color: "transparent"
                border.width: Theme.focusRingWidth * dialog.u
                border.color: Theme.focusRing
                Text {
                    anchors.centerIn: parent
                    text: "?"
                    color: Theme.text
                    font.pixelSize: Theme.typeTitle * dialog.u
                    font.weight: Theme.weightLight
                }
            }
        }

        ProgressBar {
            objectName: "remapCaptureTimer"
            fillName: "remapCaptureTimerFill"
            anchors.horizontalCenter: parent.horizontalCenter
            width: 480 * dialog.u
            u: dialog.u
            animated: false                  // drained by `remaining`, frame by frame
            value: dialog.remaining
        }

        Text {
            objectName: "remapCaptureDetail"
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, 1100 * dialog.u)
            textFormat: Text.PlainText          // a pad's own name
            text: qsTr("Any button on the %1. Nothing for 5 seconds cancels.").arg(dialog.padName)
            color: Theme.textDim
            font.pixelSize: Theme.typeBody * dialog.u
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }
    }

    // Modal: every key stops here. Esc or Backspace (a keyboard) cancels after the grace period.
    Keys.onPressed: event => {
        event.accepted = true
        if (BackKey.isBackOrBackspace(event.key) && !event.isAutoRepeat && dialog.shown && !dialog.closing
                && !escTimer.running)
            escTimer.start()
    }
    Keys.onReleased: event => { event.accepted = true }
}
