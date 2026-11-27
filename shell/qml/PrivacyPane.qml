pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Privacy (RUY-744, 02 §1.2): the console-wide privacy settings. Today one group, App permissions:
// the installed apps (the Store's installed list: every Flatpak app on the console, a .play game too, RUY-854), by name, each a page row
// that opens its permissions (AppPermissionsPage, through appRequested). A row's value says how many of the
// app's permissions are withdrawn, once the service has answered (one call for all the apps when the pane is
// shown, RUY-1190). RUY-80 adds the privacy statement, network visibility and Your activity as further groups.
SettingsPane {
    id: pane

    // An app row was accepted: the Settings page opens that app's permissions page.
    signal appRequested(string appId)

    // The installed apps by name (ids only: the rows read their name and value through bindings).
    readonly property var appIds: Store.installed.slice()
        .sort((a, b) => pane.appName(a.id).localeCompare(pane.appName(b.id)) || a.id.localeCompare(b.id))
        .map(a => a.id)
    function appName(appId) {
        return AppName.of(appId) || appId
    }

    // Bumped when the Store's counts change: the values follow it.
    property int tick: 0
    Connections {
        target: Store
        function onWithdrawnCountsChanged() { pane.tick++ }
    }
    function withdrawnCount(appId) {
        return tick >= 0 ? Store.withdrawnCount(appId) : 0
    }
    // One call reads the counts of every installed app (a page closed over the pane may have changed some), however
    // many apps there are and whatever the list does meanwhile: the service reads its own installed set. A hidden
    // pane reads nothing, whatever changes in the Library or the Store meanwhile. Shown and completed can both
    // fire for one visit; callLater makes them one call.
    function loadCounts() {
        if (visible)
            Store.loadWithdrawnCounts()
    }
    // The list is read again when the pane is shown: an app installed since (a .play game) is in the service's
    // answer, not in what the shell held.
    onVisibleChanged: if (visible) {
        Store.refreshInstalled()
        Qt.callLater(loadCounts)
    }
    Component.onCompleted: Qt.callLater(loadCounts)

    GroupLabel {
        u: pane.u
        text: qsTr("App permissions")
    }

    SettingRow {
        objectName: "rowPrivacyNoApps"
        kind: "info"
        enabled: false
        u: pane.u
        visible: pane.appIds.length === 0
        label: qsTr("No apps are installed.")
    }

    Repeater {
        model: pane.appIds
        SettingRow {
            required property string modelData
            objectName: "rowPrivacyApp_" + modelData
            kind: "page"
            u: pane.u
            label: pane.appName(modelData)
            value: pane.withdrawnCount(modelData) > 0 ? qsTr("%n withdrawn", "", pane.withdrawnCount(modelData)) : ""
            onActivated: pane.appRequested(modelData)
        }
    }

    SettingNote {
        objectName: "privacyAppsNote"
        u: pane.u
        text: qsTr("What each app may do on this console, for every profile. An admin can withdraw an app's network, devices and files.")
    }
}
