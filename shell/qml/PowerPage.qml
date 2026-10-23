import QtQuick
import RuyaShell

// Power: Suspend, Restart, Power off. Accept opens the confirmation (PowerConfirm, parented
// to the shell's modal layer); only Confirm reaches systemd-logind through Power.
Page {
    id: page

    title: qsTr("Power")

    // What logind allows; a row stays focusable either way, so focus never gets stuck.
    function allowed(action) {
        return action === "suspend" ? Power.canSuspend : action === "restart" ? Power.canRestart : Power.canPowerOff
    }

    function request(action) {
        if (allowed(action))
            confirm.open(action)
        else
            Sfx.back()
    }

    PowerConfirm {
        id: confirm
        objectName: "powerConfirmDialog"
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: page.u
    }

    SettingsPane {
        id: pane
        objectName: "powerPane"
        anchors.fill: parent
        focus: true
        u: page.u
        onExitRequested: page.backRequested()

        SettingRow {
            objectName: "powerSuspend"
            u: page.u
            label: qsTr("Suspend")
            value: Power.canSuspend ? "" : qsTr("Not available")
            onActivated: page.request("suspend")
        }
        SettingRow {
            objectName: "powerRestart"
            u: page.u
            label: qsTr("Restart")
            value: Power.canRestart ? "" : qsTr("Not available")
            onActivated: page.request("restart")
        }
        SettingRow {
            objectName: "powerOff"
            u: page.u
            label: qsTr("Power off")
            value: Power.canPowerOff ? "" : qsTr("Not available")
            onActivated: page.request("poweroff")
        }
    }
}
