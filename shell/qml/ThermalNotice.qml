pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The notice for a critical temperature (T-200): says what is happening (apps are being closed,
// the console powers off if it does not cool down) with the seconds that are left. One button,
// "OK", which only hides the notice; the policy goes on. Modal: it accepts every key. Focus
// returns to the item that had it before open() (checked for still being usable).
FocusScope {
    id: dialog

    property real u: 1
    property bool shown: false
    property string sensorText: ""     // "Processor is at 96 °C"
    property int secondsLeft: 0        // until the console powers off; < 0: not counting
    property Item returnTo: null

    signal dismissed()

    function open() {
        if (shown)
            return
        returnTo = Window.activeFocusItem
        shown = true
        okButton.forceActiveFocus()
    }

    function close() {
        if (!shown)
            return
        shown = false
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
    }

    function dismiss() {
        Sfx.select()
        close()
        dismissed()
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.OutCubic } }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.max(card.width, 700 * dialog.u) + 120 * dialog.u
        height: card.height + 96 * dialog.u
        radius: Theme.radiusL * dialog.u
        color: Theme.panel
        border.color: Theme.glassBorder
    }

    Column {
        id: card
        anchors.centerIn: parent
        width: 1000 * dialog.u
        spacing: Theme.spaceL * dialog.u

        Text {
            objectName: "thermalNoticeTitle"
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("The console is too hot")
            color: Theme.errorText
            font.pixelSize: Theme.typeTitle * dialog.u
            font.weight: Theme.weightDemiBold
        }

        Text {
            objectName: "thermalNoticeSensor"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: dialog.sensorText.length > 0
            text: dialog.sensorText
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * dialog.u
            font.weight: Theme.weightDemiBold
        }

        Text {
            objectName: "thermalNoticeDetail"
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            text: dialog.secondsLeft >= 0
                  ? qsTr("Apps are being closed. If the console does not cool down, it powers off in %n second(s).", "", dialog.secondsLeft)
                  : qsTr("Apps are being closed.")
            color: Theme.textDim
            font.pixelSize: Theme.typeBody * dialog.u
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }

        Rectangle {
            id: okButton
            objectName: "thermalNoticeOk"
            anchors.horizontalCenter: parent.horizontalCenter
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("OK")
            Accessible.focusable: true
            width: 300 * dialog.u
            height: Theme.buttonHeight * dialog.u
            radius: height / 2
            color: activeFocus ? Theme.focusFill : Theme.glass
            border.width: activeFocus ? Theme.focusRingWidth * dialog.u : Theme.hairlineAt(dialog.u)
            border.color: activeFocus ? Theme.focusRing : Theme.glassBorder
            Text {
                anchors.centerIn: parent
                text: qsTr("OK")
                color: Theme.text
                font.pixelSize: Theme.typeHeadline * dialog.u
                font.weight: Theme.weightDemiBold
            }
            Keys.onReturnPressed: dialog.dismiss()
            Keys.onEnterPressed: dialog.dismiss()
        }
    }

    Keys.onPressed: event => {
        if (BackKey.isBackOrBackspace(event.key))
            dialog.dismiss()
        event.accepted = true      // modal: nothing leaks to the page or the apps underneath
    }
}
