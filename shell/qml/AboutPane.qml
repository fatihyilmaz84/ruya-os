import QtQuick
import RuyaShell

// Settings -> About: read-only facts about this build, and the way to the full System information
// page (T-226).
SettingsPane {
    id: pane

    property string version

    // The last row was activated: the Settings page opens the System information page.
    signal systemInfoRequested()

    // Only the last row does anything on Accept; the fact rows are read-only (hint bar: Back only).
    hints: systemInfoRow.activeFocus ? [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Back") }]
                                     : [{ button: "B", text: qsTr("Back") }]

    SettingRow {
        objectName: "aboutVersion"
        u: pane.u
        label: qsTr("Image version")
        value: pane.version
    }
    SettingRow {
        objectName: "aboutQt"
        u: pane.u
        label: qsTr("Qt version")
        value: SystemInfo.qtVersion
    }
    SettingRow {
        objectName: "aboutServices"
        u: pane.u
        label: qsTr("System services")
        value: Profiles.mock ? qsTr("Mock (in-memory)") : qsTr("D-Bus")
    }
    SettingRow {
        objectName: "aboutLicence"
        u: pane.u
        label: qsTr("Licence")
        value: qsTr("GPL-3.0-or-later; icon font Apache-2.0; Inter typeface OFL-1.1")
    }
    SettingRow {
        id: systemInfoRow
        objectName: "aboutSystemInfo"
        u: pane.u
        label: qsTr("System information")
        value: qsTr("Processor, memory, graphics, storage…")
        onActivated: pane.systemInfoRequested()
    }
}
