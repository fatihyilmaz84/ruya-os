pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> About: read-only facts about this build, and the way to the full System information
// page (T-226).
SettingsPane {
    id: pane

    property string version

    // The last row was activated: the Settings page opens the System information page.
    signal systemInfoRequested()

    SettingRow {
        objectName: "aboutVersion"
        kind: "info"
        u: pane.u
        label: qsTr("Image version")
        value: pane.version
    }
    SettingRow {
        objectName: "aboutQt"
        kind: "info"
        u: pane.u
        label: qsTr("Qt version")
        value: SystemInfo.qtVersion
    }
    SettingRow {
        objectName: "aboutServices"
        kind: "info"
        u: pane.u
        label: qsTr("System services")
        value: Profiles.mock ? qsTr("Mock (in-memory)") : qsTr("D-Bus")
    }
    SettingRow {
        objectName: "aboutLicence"
        kind: "info"
        u: pane.u
        label: qsTr("Licence")
        value: qsTr("GPL-3.0-or-later")
    }
    SettingNote {
        objectName: "aboutLicenceNote"
        u: pane.u
        text: qsTr("Icon font: Apache-2.0. Inter typeface: OFL-1.1.")
    }
    // The Windows runners the image carries (ADR-025, ADR-038): their versions, then one licence and
    // source note each. They update with the OS; Library1 lists them (ListRunners, RUY-959).
    readonly property var windowsRunners: Library.runners.filter(r => r.kind === "wine" || r.kind === "proton")
    SettingRow {
        objectName: "aboutWindowsRunner"
        kind: "info"
        u: pane.u
        visible: pane.windowsRunners.length > 0
        label: qsTr("Windows compatibility")
        value: pane.windowsRunners.map(r => r.version).join(", ")
    }
    Repeater {
        model: pane.windowsRunners
        SettingNote {
            required property var modelData
            required property int index
            objectName: "aboutRunnerNote" + index
            u: pane.u
            visible: modelData.licence !== "" && modelData.sourceUrl !== ""
            //: %1 is a runner's version (GE-Proton11-13), %2 its licences (SPDX), %3 the web address of its source.
            text: qsTr("%1: %2. Source: %3").arg(modelData.version).arg(modelData.licence).arg(modelData.sourceUrl)
        }
    }
    SettingRow {
        id: systemInfoRow
        objectName: "aboutSystemInfo"
        kind: "page"
        u: pane.u
        label: qsTr("System information")
        value: qsTr("Processor, memory, graphics, storage…")
        onActivated: pane.systemInfoRequested()
    }
}
