pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Keep this resolution?" (T-198): shown by the shell, on top of everything, while the screen runs
// on a mode that is not confirmed yet (Display.confirming). The countdown runs from
// Display.confirmSeconds; when it reaches zero, or on Back or "Revert", the previous mode is
// restored (Display.revert, which restarts the shell). Accept on "Keep" (it has focus when the
// dialog opens, so a stray Accept at worst keeps a picture the owner can see) stores the mode.
// A TV that cannot show the mode shows nothing at all: the countdown then reverts without anybody
// pressing a button, and the service's guard covers a shell that never got here (display.rs).
// Modal: it accepts every key, so nothing leaks to the page underneath.
FocusScope {
    id: dialog

    property real u: 1
    // True while the shell runs on a mode nobody has confirmed; the Shell sets it (it first opens
    // the page the owner made the change on, so that focus returns there).
    property bool shown: false
    property int secondsLeft: Display.confirmSeconds
    property Item returnTo: null

    // What the buttons do while it is open (Shell.hintList).
    readonly property var modalHints: [{ button: "A", text: qsTr("Keep") }, { button: "B", text: qsTr("Revert") }]

    // The mode on trial, for the text: "3840 × 2160, 60 Hz".
    readonly property string modeText: DisplayText.modeLabel(Display.pendingWidth, Display.pendingHeight,
                                                              Display.pendingRefreshMhz)

    signal closed()

    function keep() {
        Sfx.select()
        countdown.stop()
        Display.keep()
    }

    function revert() {
        Sfx.back()
        countdown.stop()
        Display.revert()
    }

    onShownChanged: {
        if (shown) {
            returnTo = Window.activeFocusItem
            secondsLeft = Display.confirmSeconds
            keepButton.forceActiveFocus()
            countdown.restart()
        } else {
            countdown.stop()
            const target = returnTo
            returnTo = null
            if (target && target.visible && target.enabled)
                target.forceActiveFocus()
            closed()
        }
    }

    // One step per Display.countdownTickMs; the last one reverts.
    Timer {
        id: countdown
        objectName: "modeCountdown"
        interval: Display.countdownTickMs
        repeat: true
        onTriggered: {
            dialog.secondsLeft = Math.max(0, dialog.secondsLeft - 1)
            if (dialog.secondsLeft === 0) {
                stop()
                dialog.revert()
            }
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
        width: Math.max(titleText.width, modeLine.width, detailText.width, buttons.width) + 120 * dialog.u
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
            text: qsTr("Keep this resolution?")
            color: Theme.text
            font.pixelSize: Theme.typeTitle * dialog.u
            font.weight: Theme.weightDemiBold
        }

        Text {
            id: modeLine
            objectName: "modeConfirmMode"
            anchors.horizontalCenter: parent.horizontalCenter
            text: dialog.modeText
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * dialog.u
            font.weight: Theme.weightDemiBold
        }

        Text {
            id: detailText
            objectName: "modeConfirmDetail"
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, 1100 * dialog.u)
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
                onAccepted: dialog.revert()
                Keys.onRightPressed: { Sfx.navigate(); keepButton.forceActiveFocus() }
            }

            PrimaryButton {
                id: keepButton
                objectName: "modeKeep"
                u: dialog.u
                text: qsTr("Keep")
                onAccepted: dialog.keep()
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
