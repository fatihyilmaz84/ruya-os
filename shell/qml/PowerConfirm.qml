pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Restart now?" with Cancel and Confirm. Shared by the Power page and the Guide overlay.
// Cancel has focus when it opens, so a stray Accept never powers the machine off. Confirm
// calls the Power singleton; Cancel and Back call nothing. Modal: it accepts every key.
// Focus returns to the item that had it before open() (checked for still being usable).
FocusScope {
    id: dialog

    property real u: 1
    property string action: ""         // "suspend" | "restart" | "poweroff" | "custom"
    // For action "custom" (e.g. deleting a profile): the caller's own title and explanation;
    // Confirm then only emits confirmed("custom") and the caller does the work.
    property string customTitle: ""
    property string detail: ""
    property bool shown: false
    property Item returnTo: null

    // Emitted after the dialog closed because of Confirm (the action is already requested).
    signal confirmed(string action)
    signal closed()

    readonly property var titles: ({
        suspend: qsTr("Suspend now?"),
        restart: qsTr("Restart now?"),
        poweroff: qsTr("Power off now?")
    })

    function open(which) {
        returnTo = Window.activeFocusItem
        action = which
        shown = true
        cancelButton.forceActiveFocus()
    }

    function close() {
        shown = false
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    function confirm() {
        Sfx.select()
        const done = action
        if (done === "suspend")
            Power.suspend()
        else if (done === "restart")
            Power.restart()
        else if (done === "poweroff")
            Power.powerOff()
        close()
        confirmed(done)
    }

    function cancel() {
        Sfx.back()
        close()
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
        width: Math.max(titleText.width, buttons.width) + 120 * dialog.u
        height: card.height + 96 * dialog.u
        radius: 32 * dialog.u
        color: Theme.panel
        border.color: Theme.glassBorder
    }

    Column {
        id: card
        anchors.centerIn: parent
        spacing: 40 * dialog.u

        Text {
            id: titleText
            objectName: "powerConfirmTitle"
            anchors.horizontalCenter: parent.horizontalCenter
            text: dialog.action === "custom" ? dialog.customTitle : (dialog.titles[dialog.action] ?? "")
            color: Theme.text
            font.pixelSize: 52 * dialog.u
        }

        Text {
            objectName: "powerConfirmDetail"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: dialog.detail.length > 0
            width: Math.min(implicitWidth, 1100 * dialog.u)
            text: dialog.detail
            color: Theme.textDim
            font.pixelSize: 30 * dialog.u
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }

        Row {
            id: buttons
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 28 * dialog.u

            Rectangle {
                id: cancelButton
                objectName: "powerCancel"
                width: 300 * dialog.u
                height: 84 * dialog.u
                radius: height / 2
                color: activeFocus ? Theme.focusFill : Theme.glass
                border.width: activeFocus ? 4 * dialog.u : Math.max(1, dialog.u)
                border.color: activeFocus ? Theme.focusRing : Theme.glassBorder
                Text {
                    anchors.centerIn: parent
                    text: qsTr("Cancel")
                    color: Theme.text
                    font.pixelSize: 32 * dialog.u
                }
                Keys.onReturnPressed: dialog.cancel()
                Keys.onEnterPressed: dialog.cancel()
                Keys.onRightPressed: { Sfx.navigate(); confirmButton.forceActiveFocus() }
            }

            Rectangle {
                id: confirmButton
                objectName: "powerConfirm"
                width: 300 * dialog.u
                height: 84 * dialog.u
                radius: height / 2
                color: dialog.action === "suspend" ? (activeFocus ? Theme.focusFill : Theme.glass) : Theme.dangerFill
                border.width: activeFocus ? 4 * dialog.u : Math.max(1, dialog.u)
                border.color: activeFocus ? Theme.focusRing : Theme.glassBorder
                Text {
                    anchors.centerIn: parent
                    text: qsTr("Confirm")
                    color: Theme.text
                    font.pixelSize: 32 * dialog.u
                }
                Keys.onReturnPressed: dialog.confirm()
                Keys.onEnterPressed: dialog.confirm()
                Keys.onLeftPressed: { Sfx.navigate(); cancelButton.forceActiveFocus() }
            }
        }
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back)
            dialog.cancel()
        event.accepted = true      // modal: nothing leaks to the page or the overlay underneath
    }
}
