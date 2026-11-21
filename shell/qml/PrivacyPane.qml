pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Privacy (RUY-744, 02 §1.2): the console-wide privacy settings. Today one group, App permissions:
// the installed apps (the Store's installed list: every Flatpak app on the console, a .play game too, RUY-854), by name, each a page row
// that opens its permissions (AppPermissionsPage, through appRequested). A row's value says how many of the
// app's permissions are withdrawn, once the service has answered (each app's permissions are read when the
// pane is shown). RUY-80 adds the privacy statement, network visibility and Your activity as further groups.
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

    // Bumped when an answer about any app arrives: the values follow it.
    property int tick: 0
    Connections {
        target: Store
        function onPermissionsLoaded() { pane.tick++ }
    }
    function withdrawnCount(appId) {
        const p = tick >= 0 ? Store.permissions(appId) : ({})
        return p.status === "ok" ? p.withdrawn.length : 0
    }
    // Read every app's permissions while the pane is shown (a page closed over it may have changed some). A hidden
    // pane reads nothing, whatever changes in the Library or the Store meanwhile.
    function loadAll() {
        if (!visible)
            return
        for (const id of appIds)
            Store.loadPermissions(id)
    }
    // The list is read again when the pane is shown: an app installed since (a .play game) is in the service's
    // answer, not in what the shell held; its permissions are read when the list arrives.
    onVisibleChanged: if (visible) {
        Store.refreshInstalled()
        Qt.callLater(loadAll)
    }
    // The list changed: the new apps' permissions are read.
    onAppIdsChanged: Qt.callLater(loadAll)
    Component.onCompleted: Qt.callLater(loadAll)

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
