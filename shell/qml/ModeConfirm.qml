pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Keep this resolution?" (T-198): shown by the shell, on top of everything, while the screen runs
// on a mode that is not confirmed yet (Display.confirming). The countdown runs from
// Display.confirmSeconds; when it reaches zero, or on Back, the previous mode is restored
// (Display.revert, which restarts the shell, whatever the service answers).
//
// A screen that cannot show the mode shows nothing, and the owner presses buttons blind. So the
// default focus is **Revert**: a blind Accept goes back to the old mode; Keep needs a Right and
// then Accept. Accept is ignored for the first `Display.acceptGraceMs` after the dialog appears (a
// double press on the picker's row must not keep a mode nobody has seen); Back and the countdown
// work at once. A Keep the service refuses shows a toast and the countdown goes on, so it still
// reverts. The hint bar's A names the focused button (`modalHints`).
// Modal: it accepts every key, so nothing leaks to the page underneath.
FocusScope {
    id: dialog

    property real u: 1
    // True while the shell runs on a mode nobody has confirmed; the Shell sets it (it first opens
    // the page the owner made the change on, so that focus returns there).
    property bool shown: false
    property int secondsLeft: Display.confirmSeconds
    property Item returnTo: null
    // Accept counts only once the grace time has passed since the dialog appeared.
    property bool acceptReady: false
    // A Keep is on its way to the service: the countdown must not revert under it.
    property bool keeping: false

    // What the buttons do while it is open (Shell.hintList): A follows the focused button.
    readonly property var modalHints: [{ button: "A", text: keepButton.activeFocus ? qsTr("Keep") : qsTr("Revert") },
                                       { button: "B", text: qsTr("Revert") }]

    // The mode on trial, for the text: "3840 × 2160, 60 Hz".
    readonly property string modeText: DisplayText.modeLabel(Display.pendingWidth, Display.pendingHeight,
                                                              Display.pendingRefreshMhz)

    // The widest text the card may hold: the screen minus the card's own padding and a margin.
    readonly property real textMax: Math.max(200 * u, Math.min(1100 * u, width - (120 + 2 * Theme.spaceXl) * u))

    signal closed()

    function keep() {
        Sfx.select()
        keeping = true
        Display.keep()
    }

    function revert() {
        Sfx.back()
        countdown.stop()
        Display.revert()
    }

    // The Accept key on a button: ignored until the grace time has passed.
    function accept(button) {
        if (!acceptReady)
            return
        if (button === "keep")
            keep()
        else
            revert()
    }

    onShownChanged: {
        if (shown) {
            returnTo = Window.activeFocusItem
            secondsLeft = Display.confirmSeconds
            keeping = false
            acceptReady = false
            revertButton.forceActiveFocus()
            countdown.restart()
            grace.restart()
        } else {
            countdown.stop()
            grace.stop()
            const target = returnTo
            returnTo = null
            if (target && target.visible && target.enabled)
                target.forceActiveFocus()
            closed()
        }
    }

    Timer {
        id: grace
        objectName: "modeGrace"
        interval: Display.acceptGraceMs
        onTriggered: dialog.acceptReady = true
    }

    // One step per Display.countdownTickMs; the last one reverts (unless a Keep is being answered).
    Timer {
        id: countdown
        objectName: "modeCountdown"
        interval: Display.countdownTickMs
        repeat: true
        onTriggered: {
            dialog.secondsLeft = Math.max(0, dialog.secondsLeft - 1)
            if (dialog.secondsLeft === 0 && !dialog.keeping) {
                stop()
                dialog.revert()
            }
        }
    }

    Connections {
        target: Display
        function onKeepFinished(status) {
            if (!dialog.shown)
                return
            dialog.keeping = false
            if (status === "ok")
                return
            // The service did not take it: say so, and let the countdown revert.
            Notifications.show(qsTr("The setting could not be kept. The previous one comes back when the time is up."), "error")
            if (dialog.secondsLeft === 0)
                dialog.revert()
        }
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    Rectangle {
        objectName: "modeConfirmPanel"
        anchors.centerIn: parent
        // The shared dialog card (04 §5): the widest child plus 120 u, the content plus 96 u, and never
        // wider than the screen minus a margin.
        width: Math.min(Math.max(titleText.width, modeLine.width, detailText.width, buttons.width) + 120 * dialog.u,
                        dialog.width - 2 * Theme.spaceXl * dialog.u)
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
            id: titleText
            objectName: "modeConfirmTitle"
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, dialog.textMax)
            text: qsTr("Keep this resolution?")
            color: Theme.text
            font.pixelSize: Theme.typeTitle * dialog.u
            font.weight: Theme.weightDemiBold
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }

        Text {
            id: modeLine
            objectName: "modeConfirmMode"
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, dialog.textMax)
            text: dialog.modeText
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * dialog.u
            font.weight: Theme.weightDemiBold
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }

        Text {
            id: detailText
            objectName: "modeConfirmDetail"
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, dialog.textMax)
            text: qsTr("If you do nothing, the previous setting comes back in %n second(s).", "", dialog.secondsLeft)
            color: Theme.textDim
            font.pixelSize: Theme.typeBody * dialog.u
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }

        Row {
            id: buttons
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spaceM * dialog.u

            SecondaryButton {
                id: revertButton
                objectName: "modeRevert"
                u: dialog.u
                text: qsTr("Revert")
                onAccepted: dialog.accept("revert")
                Keys.onRightPressed: { Sfx.navigate(); keepButton.forceActiveFocus() }
            }

            PrimaryButton {
                id: keepButton
                objectName: "modeKeep"
                u: dialog.u
                text: qsTr("Keep")
                onAccepted: dialog.accept("keep")
                Keys.onLeftPressed: { Sfx.navigate(); revertButton.forceActiveFocus() }
            }
        }
    }

    Keys.onPressed: event => {
        if (BackKey.isBackOrBackspace(event.key))
            dialog.revert()
        event.accepted = true      // modal: nothing leaks to the page or the overlay underneath
    }
}
