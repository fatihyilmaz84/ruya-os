pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell
import "controls"

// "Uninstall <app>?" (04 §5 Dialog card and Dialog buttons, 02 §1.7, RUY-499): the one dialog of the
// Options menu's Uninstall… row and of the app page's Uninstall button. A scrim and a `panel` card with
// the question, one line about the saved data (the warning while "Also delete saved data" is on), the
// toggle, and Cancel (where the focus starts) next to the danger pill, or above it when the two do not
// fit one row (Turkish at a big UI size). A profile that is not an admin then enters an admin's PIN (the
// PIN pad's own admin mode: the attempts message, the lockout and its countdown), and the dialog asks
// the Store to uninstall (`Store.uninstall(appId, deleteData)`); the owner follows the job.
//
//   open(appId, name, context)   opens it; the focus returns to the item that had it when it closes;
//                        `context` is the caller's own note, handed back by started()
//   started(appId, deleteData, context)   Store.uninstall was asked (the dialog has closed)
//   closed()             it closed, for any reason
//
// Modal: it accepts every key. Back is Cancel, on the PIN pad too (which cancels everything).
FocusScope {
    id: dialog

    property real u: 1
    property string appId: ""
    property string appName: ""
    property var context: null
    property bool shown: false
    property Item returnTo: null
    // "confirm" | "pin": the PIN pad is up (the card is hidden behind its own scrim).
    property string step: "confirm"
    property bool pendingWipe: false

    // What the hint bar says while this is open (Shell.modalHintsOf).
    readonly property var modalHints: step === "pin" ? [{ button: "B", text: qsTr("Cancel") }]
                                                     : [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Cancel") }]

    signal started(string appId, bool deleteData, var context)
    signal closed()

    // ---- geometry (pixels). The card is the widest child (the 900 u toggle row) plus 120 u, and
    // never wider than the screen minus `spaceXl` each side, so at a big UI size the texts wrap. ----
    readonly property real contentWidth: Math.max(240 * u, Math.min(900 * u, width - (120 + 2 * Theme.spaceXl) * u))
    readonly property real cancelWidth: 300 * u
    readonly property real buttonPad: Theme.spaceL * u
    readonly property string goLabel: deleteData.checked ? qsTr("Uninstall and delete data") : qsTr("Uninstall")
    // The danger pill grows with its label (never narrower than Cancel, as in PowerConfirm); Cancel, `spaceM`
    // and the pill on one row, else stacked.
    readonly property real goWidth: Math.max(cancelWidth, goMetrics.advanceWidth + 2 * buttonPad)
    readonly property bool stacked: cancelWidth + Theme.spaceM * u + goWidth > contentWidth

    // The band the card lives in: from the top safe-area edge down to the hint bar's band (the same bound the
    // Options menu clamps to: screen height - safe area - glyphSize - spaceM). The card is centred in it, and at a
    // big UI size, where stacked buttons and the warning make it taller, scaled down about its centre until it
    // fits (1 whenever it already does), so it never overlaps the hint bar.
    readonly property real bandTop: height * Theme.safeArea
    readonly property real bandBottom: height - height * Theme.safeArea - (Theme.glyphSize + Theme.spaceM) * u
    readonly property real fit: Math.min(1, (bandBottom - bandTop) / (card.height + 96 * u))
    readonly property real bandShift: (bandTop + bandBottom) / 2 - height / 2

    function open(id, name, note) {
        returnTo = Window.activeFocusItem
        appId = id
        appName = name
        context = note ?? null
        deleteData.checked = false         // off on every opening
        step = "confirm"
        shown = true
        cancelButton.forceActiveFocus()
    }

    function close() {
        shown = false
        step = "confirm"
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    function cancel() {
        Sfx.back()
        close()
    }

    // Closes it for good, whatever step it is on (nobody is signed in any more): no sound, nothing asked.
    function dismiss() {
        if (pad.shown)
            pad.close()
        if (shown)
            close()
    }

    // The danger pill: an admin goes straight on, anyone else enters an admin's PIN first.
    function confirm() {
        const wipe = deleteData.checked
        if ((Profiles.active.role ?? "") === "admin") {
            start(wipe)
            return
        }
        const admin = Profiles.profiles.find(p => p.role === "admin")
        if (!admin) {
            Sfx.error()
            close()
            Notifications.show(ProfileStatus.describe("not-allowed", 0, 0), "error")
            return
        }
        pendingWipe = wipe
        step = "pin"
        pad.verifyAdmin(qsTr("Enter an admin's PIN"), admin.id)
    }

    function start(wipe) {
        const id = appId
        close()
        Store.uninstall(id, wipe)
        started(id, wipe, context)
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Rectangle {
        anchors.fill: parent
        visible: dialog.step === "confirm"
        color: Theme.scrim
    }

    Rectangle {
        objectName: "uninstallPanel"
        anchors { horizontalCenter: parent.horizontalCenter; verticalCenter: parent.verticalCenter; verticalCenterOffset: dialog.bandShift }
        scale: dialog.fit
        visible: dialog.step === "confirm"
        width: dialog.contentWidth + 120 * dialog.u
        height: card.height + 96 * dialog.u
        radius: Theme.radiusL * dialog.u
        color: Theme.panel
        border.color: Theme.glassBorder
    }

    // The label of the danger pill, measured: the pill grows with it.
    TextMetrics {
        id: goMetrics
        font.pixelSize: Theme.typeHeadline * dialog.u
        font.weight: Theme.weightDemiBold
        text: dialog.goLabel
    }
    // Only the app's name is cut, so the question always survives ("%1 kaldırılsın mı?").
    TextMetrics {
        id: frameMetrics
        font: title.font
        text: qsTr("Uninstall %1?").arg("")
    }
    TextMetrics {
        id: nameMetrics
        font: title.font
        elide: Text.ElideRight
        elideWidth: Math.max(0, dialog.contentWidth - frameMetrics.advanceWidth)
        text: dialog.appName
    }

    Column {
        id: card
        objectName: "uninstallCard"
        anchors { horizontalCenter: parent.horizontalCenter; verticalCenter: parent.verticalCenter; verticalCenterOffset: dialog.bandShift }
        scale: dialog.fit
        visible: dialog.step === "confirm"
        width: dialog.contentWidth
        spacing: Theme.spaceL * dialog.u

        Text {
            id: title
            objectName: "uninstallTitle"
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: qsTr("Uninstall %1?").arg(nameMetrics.elidedText)
            color: Theme.text
            font.pixelSize: Theme.typeTitle * dialog.u
            font.weight: Theme.weightDemiBold
            Accessible.role: Accessible.StaticText
            Accessible.name: qsTr("Uninstall %1?").arg(dialog.appName)
        }

        // The data line; with the toggle on, the warning takes its place.
        Item {
            width: parent.width
            height: deleteData.checked ? warning.height : dataLine.height

            Text {
                id: dataLine
                objectName: "uninstallLine"
                visible: !deleteData.checked
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                text: qsTr("Saved data stays on this console.")
                color: Theme.textDim
                font.pixelSize: Theme.typeBody * dialog.u
            }

            Row {
                id: warning
                objectName: "uninstallWarning"
                visible: deleteData.checked
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spaceS * dialog.u

                Icon {
                    id: warningIcon
                    anchors.verticalCenter: parent.verticalCenter
                    u: dialog.u
                    name: "warning"
                    color: Theme.warningText
                }
                Text {
                    objectName: "uninstallWarningText"
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, dialog.contentWidth - warningIcon.width - Theme.spaceS * dialog.u)
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: qsTr("Saved data of every profile is deleted too. This can't be undone.")
                    color: Theme.warningText
                    font.pixelSize: Theme.typeBody * dialog.u
                }
            }
        }

        ToggleRow {
            id: deleteData
            objectName: "uninstallDeleteData"
            width: parent.width
            u: dialog.u
            label: qsTr("Also delete saved data")
            Keys.onDownPressed: { Sfx.navigate(); cancelButton.forceActiveFocus() }
        }

        Grid {
            id: buttons
            objectName: "uninstallButtons"
            anchors.horizontalCenter: parent.horizontalCenter
            columns: dialog.stacked ? 1 : 2
            columnSpacing: Theme.spaceM * dialog.u
            rowSpacing: Theme.spaceS * dialog.u

            DialogButton {
                id: cancelButton
                objectName: "uninstallCancel"
                width: dialog.stacked ? dialog.contentWidth : dialog.cancelWidth
                text: qsTr("Cancel")
                onActivated: dialog.cancel()
                Keys.onUpPressed: { Sfx.navigate(); deleteData.forceActiveFocus() }
                Keys.onRightPressed: if (!dialog.stacked) { Sfx.navigate(); goButton.forceActiveFocus() }
                Keys.onDownPressed: if (dialog.stacked) { Sfx.navigate(); goButton.forceActiveFocus() }
            }

            DialogButton {
                id: goButton
                objectName: "uninstallGo"
                width: dialog.stacked ? dialog.contentWidth : Math.min(dialog.goWidth, dialog.contentWidth - dialog.cancelWidth - Theme.spaceM * dialog.u)
                danger: true
                text: dialog.goLabel
                onActivated: dialog.confirm()
                Keys.onUpPressed: { Sfx.navigate(); (dialog.stacked ? cancelButton : deleteData).forceActiveFocus() }
                Keys.onLeftPressed: if (!dialog.stacked) { Sfx.navigate(); cancelButton.forceActiveFocus() }
            }
        }
    }

    PinPad {
        id: pad
        objectName: "uninstallPinPad"
        anchors.fill: parent
        u: dialog.u
        onVerified: dialog.start(dialog.pendingWipe)
        onCancelled: dialog.close()        // Back on the PIN pad cancels everything
    }

    component DialogButton: Rectangle {
        id: button

        property string text
        property bool danger: false
        signal activated()

        height: Theme.buttonHeight * dialog.u
        radius: height / 2
        color: danger ? Theme.dangerFill : (activeFocus ? Theme.focusFill : Theme.glass)
        border.width: activeFocus ? Theme.focusRingWidth * dialog.u : Theme.hairlineAt(dialog.u)
        border.color: activeFocus ? Theme.focusRing : Theme.glassBorder
        Accessible.role: Accessible.Button
        Accessible.name: text
        Accessible.focusable: true

        Text {
            anchors.centerIn: parent
            width: Math.min(implicitWidth, parent.width - 2 * dialog.buttonPad)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: button.text
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * dialog.u
            font.weight: Theme.weightDemiBold
        }

        function accept() {
            Sfx.select()
            activated()
        }
        Keys.onReturnPressed: accept()
        Keys.onEnterPressed: accept()
    }

    Keys.onPressed: event => {
        if (BackKey.isBackOrBackspace(event.key))
            dialog.cancel()
        event.accepted = true      // modal: nothing leaks to the page or the overlay underneath
    }
}
