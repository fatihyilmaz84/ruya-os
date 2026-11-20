pragma ComponentBehavior: Bound
import QtQuick
import QtQml.Models
import RuyaShell

// Settings -> Privacy -> App permissions -> an app, and the game page's Permissions row (RUY-744, 02 §1.2,
// 03 §4.4): what an installed Flatpak app may do on this console, and what an admin has withdrawn from it.
// Opened with params { appId }. One row per permission the app has (GetPermissions: effective and withdrawn,
// in the contract's order): a switch for a key the service can withdraw here (`withdrawable`) while an admin
// is signed in, else a fact (Allowed / Withdrawn) with the reason it stays under it. A change is written at
// once and the page reads the permissions again; a row whose state differs from the one the page opened
// with says when it applies (the app's next start: a running app keeps what it started with). Then Reset to
// the app's defaults (an admin, while something is withdrawn) and the one line about the console's own
// services. Permissions are per console, not per profile. Back (or Left) closes the page.
Page {
    id: page

    readonly property string appId: String((params ?? {}).appId ?? "")
    // The installed list carries the name; an app it no longer lists keeps the last name seen.
    property string lastName: ""
    readonly property string shownName: (Store.installed.find(a => a.id === appId) ?? {}).name ?? ""
    onShownNameChanged: if (shownName !== "") lastName = shownName
    title: lastName !== "" ? lastName : appId

    readonly property bool isAdmin: (Profiles.active.role ?? "") === "admin"
    readonly property bool running: Session.running.some(r => r.appId === page.appId && r.state !== "stopping")

    // ---- The service's answer (Store.permissions), read when the page opens and after every change ----
    property int tick: 0
    // Whether this page has had an answer yet (the Store keeps the last one of an earlier visit).
    property bool answered: false
    readonly property var perms: tick >= 0 ? Store.permissions(appId) : ({})
    readonly property string status: answered ? (perms.status ?? "") : ""
    readonly property bool ok: status === "ok"
    readonly property var effective: ok ? perms.effective : []
    readonly property var withdrawn: ok ? perms.withdrawn : []
    readonly property var withdrawable: ok ? perms.withdrawable : []
    readonly property var keys: PermissionText.sorted(effective.concat(withdrawn.filter(k => effective.indexOf(k) < 0)))
    // The withdrawn keys of the first answer: a row whose state differs waits for the app's next start.
    property var openedWithdrawn: null
    // Bumped after every answer: the switches take their state from it (a switch flips itself first, and a
    // refused change must flip it back).
    property int resync: 0
    // The key whose change is asked for and not answered yet ("" none; "*" the reset). A press meanwhile is
    // ignored.
    property string busyKey: ""
    property string errorText: ""

    function canSwitch(key) {
        return isAdmin && withdrawable.indexOf(key) >= 0
    }
    function pending(key) {
        return openedWithdrawn !== null && (openedWithdrawn.indexOf(key) >= 0) !== (withdrawn.indexOf(key) >= 0)
    }
    // The note under a key's row: the warning of a file key's switch, and when a change applies.
    function noteFor(key) {
        const parts = []
        if (canSwitch(key) && PermissionText.fileKeys.indexOf(key) >= 0)
            parts.push(qsTr("The app may lose its saves or settings outside its own folder."))
        if (pending(key))
            parts.push(running ? qsTr("Takes effect after the app is closed and opened again.")
                               : qsTr("Takes effect next time you open it."))
        return parts.join(" ")
    }
    // The second line of a fact row: the risk, and why it stays.
    function factDetail(key) {
        const reason = withdrawable.indexOf(key) >= 0 ? "" : PermissionText.fixedReason(key)
        if (!PermissionText.isHighRisk(key))
            return reason
        return reason !== "" ? qsTr("High risk · %1").arg(reason) : qsTr("High risk")
    }
    function describe(status) {
        switch (status) {
        case "forbidden": return qsTr("Only an admin can change this.")
        case "not-withdrawable": return qsTr("This permission can't be withdrawn.")
        case "unknown-app": return qsTr("This app is not installed any more.")
        }
        return qsTr("The permission could not be changed. Try again.")
    }

    function change(key, allowed) {
        if (busyKey !== "") {
            resync++                    // one change at a time: the switch goes back to what is true
            return
        }
        busyKey = key
        errorText = ""
        if (allowed)
            Store.restorePermission(appId, key)
        else
            Store.withdrawPermission(appId, key)
    }
    function resetAll() {
        if (busyKey !== "")
            return
        busyKey = "*"
        errorText = ""
        Store.resetPermissions(appId)
    }

    Connections {
        target: Store
        function onPermissionsLoaded(id) {
            if (id !== page.appId)
                return
            page.answered = true
            page.tick++
            const now = Store.permissions(id)
            if (page.openedWithdrawn === null && now.status === "ok")
                page.openedWithdrawn = now.withdrawn
            page.syncRows()
            page.resync++
        }
        function onPermissionChanged(id, key, status) {
            if (id !== page.appId)
                return
            page.busyKey = ""
            if (status !== "ok") {
                Sfx.back()
                page.errorText = page.describe(status)
            }
            // Store reads the permissions again whatever the answer: onPermissionsLoaded follows.
        }
    }
    Component.onCompleted: Store.loadPermissions(appId)

    // ---- Rows: one model entry per row kind and key, keys only (the text is bindings, PATTERNS.md) ----
    ListModel { id: rowModel }
    property string modelKeys: ""
    function syncRows() {
        const wanted = keys.join("|")
        if (wanted === modelKeys)
            return
        modelKeys = wanted
        rowModel.clear()
        for (const key of keys) {
            rowModel.append({ kind: "switch", key: key })
            rowModel.append({ kind: "fact", key: key })
            rowModel.append({ kind: "note", key: key })
        }
        body.reflow()
    }

    hints: body.hints

    SettingsPane {
        id: body
        objectName: "appPermissionsBody"
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.min(parent.width, 1100 * page.u)
        u: page.u
        focus: true
        onExitRequested: page.backRequested()

        SettingRow {
            objectName: "permLoading"
            kind: "info"
            enabled: false
            u: page.u
            visible: !page.answered
            label: qsTr("Loading…")
        }
        SettingRow {
            objectName: "permUnreadable"
            kind: "info"
            enabled: false
            u: page.u
            visible: page.answered && !page.ok
            label: page.status === "unknown-app" ? qsTr("This app is not installed any more.")
                                                 : qsTr("Permissions can't be read right now.")
        }
        SettingRow {
            objectName: "permRetry"
            kind: "action"
            u: page.u
            visible: page.answered && !page.ok && page.status !== "unknown-app"
            label: qsTr("Try again")
            onActivated: Store.loadPermissions(page.appId)
        }
        SettingRow {
            objectName: "permNone"
            kind: "info"
            enabled: false
            u: page.u
            visible: page.ok && page.keys.length === 0
            label: qsTr("This app asks for no special permissions.")
        }

        Repeater {
            model: rowModel
            delegate: DelegateChooser {
                role: "kind"
                DelegateChoice {
                    roleValue: "switch"
                    ToggleRow {
                        id: toggle
                        required property string key
                        objectName: "permSwitch_" + key
                        u: page.u
                        visible: page.canSwitch(key)
                        label: PermissionText.rowLabel(key)
                        detail: PermissionText.isHighRisk(key) ? qsTr("High risk") : ""
                        checked: page.withdrawn.indexOf(key) < 0
                        onToggled: on => page.change(key, on)
                        Connections {
                            target: page
                            function onResyncChanged() { toggle.checked = page.withdrawn.indexOf(toggle.key) < 0 }
                        }
                    }
                }
                DelegateChoice {
                    roleValue: "fact"
                    SettingRow {
                        required property string key
                        objectName: "permFact_" + key
                        kind: "info"
                        u: page.u
                        visible: !page.canSwitch(key)
                        label: PermissionText.rowLabel(key)
                        value: page.withdrawn.indexOf(key) >= 0 ? qsTr("Withdrawn") : qsTr("Allowed")
                        detail: page.factDetail(key)
                    }
                }
                DelegateChoice {
                    roleValue: "note"
                    SettingNote {
                        required property string key
                        objectName: "permNote_" + key
                        u: page.u
                        text: page.noteFor(key)
                        visible: text !== ""
                    }
                }
            }
        }

        SettingRow {
            objectName: "permReset"
            kind: "action"
            u: page.u
            visible: page.isAdmin && page.withdrawn.length > 0
            label: qsTr("Reset to the app's defaults")
            onActivated: page.resetAll()
        }
        SettingNote {
            objectName: "permError"
            u: page.u
            visible: page.errorText !== ""
            text: page.errorText
            color: Theme.errorText
        }
        SettingNote {
            objectName: "permAdminNote"
            u: page.u
            visible: !page.isAdmin && page.keys.length > 0
            text: qsTr("Only an admin can change these.")
        }
        SettingNote {
            objectName: "permServicesNote"
            u: page.u
            visible: page.answered
            text: qsTr("Apps can't reach the console's own services.")
        }
    }
}
