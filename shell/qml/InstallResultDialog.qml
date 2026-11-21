pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Not installed" (04 §5.4, RUY-98): the dialog a job that ended with a failure shows. PowerConfirm's card on
// `panel`: the error icon, the title, the sentence of the status (PlayCopy.jobStatusText) and one OK button
// that has the focus. A status that connecting can fix (`offline`, RUY-1004) shows "Try again" instead of OK:
// it takes the focus and asks the page to start the job again; Back closes the dialog. Modal: it takes every
// key; Accept or Back closes it and the focus goes back to where it was.
//
//   open(status, toFree)   status: the JobFinished status; toFree: the bytes to free, already formatted (disk-full)
//   closed()              it closed
//   retryRequested()      "Try again" was chosen (the dialog closes first)
FocusScope {
    id: dialog

    property real u: 1
    property bool shown: false
    property string status: ""
    property string toFree: ""
    property Item returnTo: null

    // `offline`: the platform needs the internet once; connecting and trying again can fix it.
    readonly property bool retryable: status === "offline"

    // What the hint bar says while this is open (Shell.modalHintsOf).
    readonly property var modalHints: retryable
        ? [{ action: "accept", text: qsTr("Try again") }, { action: "back", text: qsTr("Back") }]
        : [{ action: "accept", text: qsTr("OK") }]

    signal closed()
    signal retryRequested()

    function open(which, bytes) {
        returnTo = Window.activeFocusItem
        status = which
        toFree = bytes ?? ""
        shown = true
        const focused = retryable ? retryButton : okButton
        focused.forceActiveFocus()
    }

    function close() {
        shown = false
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("Not installed")

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    Rectangle {
        objectName: "installResultPanel"
        anchors.centerIn: parent
        width: Math.max(head.width, sentence.width, dialog.retryable ? retryButton.width : okButton.width) + 120 * dialog.u      // token-ok: PowerConfirm's card, 04 5
        height: card.height + 96 * dialog.u                                               // token-ok: PowerConfirm's card, 04 5
        radius: Theme.radiusL * dialog.u
        color: Theme.panel
        border.color: Theme.glassBorder
    }

    Column {
        id: card
        anchors.centerIn: parent
        spacing: Theme.spaceL * dialog.u

        Row {
            id: head
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spaceM * dialog.u

            Icon {
                anchors.verticalCenter: parent.verticalCenter
                u: dialog.u
                size: Theme.iconL
                name: "error"
                color: Theme.errorText
            }
            Text {
                objectName: "installResultTitle"
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: qsTr("Not installed")
                color: Theme.text
                font.pixelSize: Theme.typeTitle * dialog.u
                font.weight: Theme.weightDemiBold
            }
        }

        Text {
            id: sentence
            objectName: "installResultSentence"
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, 1100 * dialog.u)       // token-ok: PowerConfirm's detail width, 04 5
            textFormat: Text.PlainText
            text: PlayCopy.jobStatusText(dialog.status, dialog.toFree)
            color: Theme.textDim
            font.pixelSize: Theme.typeBody * dialog.u
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }

        PrimaryButton {
            id: retryButton
            objectName: "installResultRetry"
            visible: dialog.retryable
            anchors.horizontalCenter: parent.horizontalCenter
            u: dialog.u
            text: qsTr("Try again")
            onAccepted: {
                Sfx.select()
                dialog.close()
                dialog.retryRequested()
            }
        }

        PrimaryButton {
            id: okButton
            objectName: "installResultOk"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !dialog.retryable
            u: dialog.u
            text: qsTr("OK")
            onAccepted: {
                Sfx.select()
                dialog.close()
            }
        }
    }

    Keys.onPressed: event => {
        if (BackKey.isBackOrBackspace(event.key) && !event.isAutoRepeat) {
            Sfx.back()
            dialog.close()
        }
        event.accepted = true      // modal: nothing leaks to the page underneath
    }
}
