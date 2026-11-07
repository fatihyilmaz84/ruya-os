pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Restart now?" with Cancel and a button that names the action ("Restart now"). Shared by the Power page and the Guide overlay.
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
    // Label and accessible name of the Confirm button for action "custom" (e.g. "Delete Ada").
    // Empty falls back to the generic "Confirm".
    property string customConfirmName: ""
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

    // The Confirm button's visible label and its accessible name (T-194): the action, not the
    // word "Confirm" (WCAG 2.5.3: the visible label is the name).
    readonly property string confirmName: {
        if (action === "suspend")
            return qsTr("Suspend now")
        if (action === "restart")
            return qsTr("Restart now")
        if (action === "poweroff")
            return qsTr("Power off now")
        if (action === "custom" && customConfirmName.length > 0)
            return customConfirmName
        return qsTr("Confirm")
    }

    // Widths (design px times u): Cancel is fixed; the action button grows with its label and
    // stops where the dialog (90 % of the window, minus the card padding) stops; beyond that
    // the label elides on the right, the full text stays in the accessible name.
    readonly property real cancelWidth: 300 * u
    readonly property real buttonPad: Theme.spaceL * u
    readonly property real confirmMaxWidth: Math.max(cancelWidth, 0.9 * width - 120 * u - cancelWidth - Theme.spaceM * u)
    readonly property real confirmWidth: Math.min(confirmMaxWidth, Math.max(cancelWidth, confirmLabel.implicitWidth + 2 * buttonPad))

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
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    Rectangle {
        objectName: "powerConfirmPanel"
        anchors.centerIn: parent
        width: Math.max(titleText.width, buttons.width) + 120 * dialog.u
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
            objectName: "powerConfirmTitle"
            anchors.horizontalCenter: parent.horizontalCenter
            text: dialog.action === "custom" ? dialog.customTitle : (dialog.titles[dialog.action] ?? "")
            color: Theme.text
            font.pixelSize: Theme.typeTitle * dialog.u
            font.weight: Theme.weightDemiBold
        }

        Text {
            objectName: "powerConfirmDetail"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: dialog.detail.length > 0
            width: Math.min(implicitWidth, 1100 * dialog.u)
            text: dialog.detail
            color: Theme.textDim
            font.pixelSize: Theme.typeBody * dialog.u
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
        }

        Row {
            id: buttons
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spaceM * dialog.u

            Rectangle {
                id: cancelButton
                objectName: "powerCancel"
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Cancel")
                Accessible.focusable: true
                width: dialog.cancelWidth
                height: Theme.buttonHeight * dialog.u
                radius: height / 2
                color: activeFocus ? Theme.focusFill : Theme.glass
                border.width: activeFocus ? Theme.focusRingWidth * dialog.u : Theme.hairlineAt(dialog.u)
                border.color: activeFocus ? Theme.focusRing : Theme.glassBorder
                Text {
                    anchors.centerIn: parent
                    text: qsTr("Cancel")
                    color: Theme.text
                    font.pixelSize: Theme.typeHeadline * dialog.u
                    font.weight: Theme.weightDemiBold
                }
                Keys.onReturnPressed: dialog.cancel()
                Keys.onEnterPressed: dialog.cancel()
                Keys.onRightPressed: { Sfx.navigate(); confirmButton.forceActiveFocus() }
            }

            Rectangle {
                id: confirmButton
                objectName: "powerConfirm"
                Accessible.role: Accessible.Button
                Accessible.name: dialog.confirmName
                Accessible.focusable: true
                width: dialog.confirmWidth
                height: Theme.buttonHeight * dialog.u
                radius: height / 2
                color: dialog.action === "suspend" ? (activeFocus ? Theme.focusFill : Theme.glass) : Theme.dangerFill
                border.width: activeFocus ? Theme.focusRingWidth * dialog.u : Theme.hairlineAt(dialog.u)
                border.color: activeFocus ? Theme.focusRing : Theme.glassBorder
                Text {
                    id: confirmLabel
                    objectName: "powerConfirmLabel"
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - 2 * dialog.buttonPad)
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                    text: dialog.confirmName
                    color: Theme.text
                    font.pixelSize: Theme.typeHeadline * dialog.u
                    font.weight: Theme.weightDemiBold
                }
                Keys.onReturnPressed: dialog.confirm()
                Keys.onEnterPressed: dialog.confirm()
                Keys.onLeftPressed: { Sfx.navigate(); cancelButton.forceActiveFocus() }
            }
        }
    }

    Keys.onPressed: event => {
        if (BackKey.isBackOrBackspace(event.key))
            dialog.cancel()
        event.accepted = true      // modal: nothing leaks to the page or the overlay underneath
    }
}
