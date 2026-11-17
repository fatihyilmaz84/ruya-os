pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Rename and Forget for one Bluetooth device, shared by Settings > Bluetooth (BluetoothPane) and the
// controller page (ControllerPage, RUY-504): the on-screen keyboard (maxLength 48, titled with the
// name the row shows, the address tail kept whole), `Bluetooth.rename` and its failure toast, and the
// "Forget %1?" PowerConfirm (Cancel focused, Back cancels) with `Bluetooth.forget`. Both are built when
// first opened. `forgetConfirmed(id)` fires just before `Bluetooth.forget`, so a page can tell its own
// act from a pad that left. Focus returns to the row that opened the modal (TextEntry and PowerConfirm
// remember it).
Item {
    id: actions

    property real u: 1
    property Item overlay      // where the keyboard and the confirmation are parented

    signal forgetConfirmed(string id)

    // The device the confirmation and the keyboard are for.
    property string forgetId: ""
    property string renameId: ""

    function askForget(id, name) {
        forgetSlot.active = true
        forgetConfirm.customTitle = qsTr("Forget %1?").arg(name)
        forgetConfirm.detail = qsTr("It will have to be paired again to be used.")
        forgetConfirm.customConfirmName = qsTr("Forget %1").arg(name)
        actions.forgetId = id
        forgetConfirm.open("custom")
    }

    // `shown`: the name the row shows (two like pads are told apart by the end of the address), the
    // keyboard's title; `name` is the pad's alias, what the field starts with.
    function askRename(id, name, shown) {
        actions.renameId = id
        renameSlot.active = true
        // The part of the shown name that is the end of the address stays whole when the title is cut.
        const base = DeviceIcons.plain(name)
        renameEntry.open(shown, name, { maxLength: 48, layout: "text", titleTail: shown.startsWith(base) ? shown.slice(base.length) : "" })
    }

    Connections {
        target: Bluetooth
        function onFinished(op, id, status) {
            if (op === "rename" && status !== "ok") {
                Notifications.show(status === "invalid" ? qsTr("That name does not work. Try another.")
                                                          : qsTr("Could not rename the controller."), "warning")
            }
        }
    }

    Loader {
        id: renameSlot
        parent: actions.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            TextEntry {
                objectName: "btRenameEntry"
                u: actions.u
                onAccepted: text => Bluetooth.rename(actions.renameId, text)
            }
        }
    }
    readonly property TextEntry renameEntry: renameSlot.item as TextEntry

    Loader {
        id: forgetSlot
        parent: actions.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            PowerConfirm {
                objectName: "btForgetConfirm"
                u: actions.u
                onConfirmed: {
                    actions.forgetConfirmed(actions.forgetId)
                    Bluetooth.forget(actions.forgetId)
                }
            }
        }
    }
    readonly property PowerConfirm forgetConfirm: forgetSlot.item as PowerConfirm
}
