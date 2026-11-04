import QtQuick
import RuyaShell

// Settings -> About: read-only facts about this build.
SettingsPane {
    id: pane

    property string version

    // Nothing to select here.
    hints: [{ button: "B", text: qsTr("Back") }]

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
        value: qsTr("GPL-3.0-or-later; icon font Apache-2.0")
    }
}
