pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell
import "controls"

// App page of the Store (spec 03 §4.4): art, source, controller support, permissions in plain
// words (high risk flagged), and Install / Update / Open and Uninstall with progress.
// Opened as Shell.openPage("appDetail", { appId }) from the Store.
Page {
    id: page

    readonly property string appId: params.appId ?? ""
    readonly property var app: Store.catalogue.find(a => a.id === appId) ?? ({})
    readonly property var job: Store.jobs[appId] ?? null
    readonly property bool installed: app.installed ?? false
    readonly property bool hasUpdate: app.updateAvailable ?? false
    readonly property var highRisk: ["all-devices", "host-files", "session-bus"]

    // A Standard profile needs an admin's PIN to install an app with a high-risk permission, and to
    // update one whose update adds a high-risk permission (03 §4.4).
    readonly property var newPermissions: installed && hasUpdate ? (app.newPermissions ?? []) : []
    readonly property bool hasHighRisk: (app.permissions ?? []).some(p => highRisk.indexOf(p) >= 0)
    readonly property bool addsHighRisk: newPermissions.some(p => highRisk.indexOf(p) >= 0)
    readonly property bool needsAdminPin: (installed ? addsHighRisk : hasHighRisk) && (Profiles.active.role ?? "") !== "admin"

    // The permissions are read from the service when the page opens; Install and Update wait for
    // them, because the PIN gate depends on them.
    property bool detailsReady: false
    property bool detailsFailed: false
    property bool actionPending: false

    property string pinStep: "idle"    // idle | pin | working
    property string adminId: ""
    // A request of this page is unanswered (it may be queued behind another job, with no progress
    // yet), or a job of this app runs: started here, by another page, or found by the Store when
    // the shell started (Store.jobs, T-191).
    property bool requested: false
    readonly property bool working: requested || job !== null
    property string kind: ""       // "install" | "update" | "uninstall" while requested
    property string errorText: ""

    title: app.name ?? ""

    function sourceKind(source) {
        return source === "official" ? "success" : source === "developer" ? "warning" : "info"
    }

    function sourceText(source) {
        return source === "official" ? qsTr("Official") : source === "developer" ? qsTr("Developer") : qsTr("Community")
    }

    function controllerText(level) {
        return level === "full" ? qsTr("Full controller support")
             : level === "partial" ? qsTr("Partial controller support")
             : qsTr("Needs a keyboard or mouse")
    }

    function ageText(rating) {
        return rating === "all" || !rating ? qsTr("All ages") : qsTr("Ages %1").arg(rating)
    }

    function permissionText(id) {
        switch (id) {
        case "audio": return qsTr("Plays sound")
        case "gamepad": return qsTr("Uses game controllers")
        case "network": return qsTr("Uses the network")
        case "home-files": return qsTr("Reads and writes files in your home folder")
        case "host-files": return qsTr("Reads and writes all files on this device")
        case "all-devices": return qsTr("Accesses all devices")
        case "session-bus": return qsTr("Can control other programs on this device")
        }
        return id
    }

    function phaseText() {
        if (!page.job)
            return qsTr("Waiting…")
        switch (page.job.phase) {
        case "download": return qsTr("Downloading…")
        case "install": return qsTr("Installing…")
        case "update": return qsTr("Updating…")
        case "remove": return qsTr("Removing…")
        }
        return qsTr("Working…")
    }

    function describe(status) {
        switch (status) {
        case "network": return qsTr("No network connection. Check it and try again.")
        case "signature": return qsTr("This app could not be verified, so it was not installed.")
        case "missing-runtime": return qsTr("A part this app needs could not be found.")
        case "disk-full": return qsTr("There is not enough space on this device.")
        case "busy": return qsTr("Another change is running. Try again in a moment.")
        }
        return qsTr("Something went wrong. You can try again.")
    }

    function start(what) {
        if (page.working)
            return
        page.errorText = ""
        page.kind = what
        page.requested = true
        if (what === "install")
            Store.install(page.appId)
        else if (what === "update")
            Store.update(page.appId)
    }

    function startAdminPin() {
        const admin = Profiles.profiles.find(p => p.role === "admin")
        if (!admin) {
            page.errorText = ProfileStatus.describe("not-allowed", 0, 0)
            return
        }
        page.errorText = ""
        page.pinStep = "pin"
        page.adminId = admin.id
        pad.collect(qsTr("Enter an admin's PIN"), false)
    }

    function loadDetails() {
        page.detailsReady = false
        page.detailsFailed = false
        Store.loadApp(page.appId)
    }

    function primaryAction() {
        if (page.working || page.pinStep !== "idle")
            return
        if (!page.detailsReady) {
            // Not known yet whether a PIN is needed: do it as soon as the permissions are in.
            page.actionPending = true
            if (page.detailsFailed)
                page.loadDetails()
            return
        }
        if (!page.installed) {
            if (page.needsAdminPin)
                page.startAdminPin()
            else
                page.start("install")
        } else if (page.hasUpdate) {
            if (page.needsAdminPin)
                page.startAdminPin()
            else
                page.start("update")
        }
        // "Open" waits for the session service (T-130).
    }

    function confirmUninstall(deleteData) {
        page.errorText = ""
        page.kind = "uninstall"
        page.requested = true
        Store.uninstall(page.appId, deleteData)
    }

    Component.onCompleted: loadDetails()
    onHasUpdateChanged: loadDetails()      // an update just finished: its permissions are the app's now

    Connections {
        target: Store
        function onAppLoaded(id) {
            if (id !== page.appId)
                return
            page.detailsReady = true
            if (page.actionPending) {
                page.actionPending = false
                page.primaryAction()
            }
        }
        function onAppLoadFailed(id) {
            if (id !== page.appId)
                return
            page.detailsFailed = true
            if (page.actionPending) {
                page.actionPending = false
                page.errorText = page.describe("failed")
            }
        }
        function onJobFinished(id, status) {
            if (id !== page.appId)
                return
            page.requested = false
            page.errorText = status === "ok" ? "" : page.describe(status)
        }
    }

    PinPad {
        id: pad
        objectName: "detailPinPad"
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: page.u
        onCollected: pin => {
            if (page.pinStep === "pin") {
                page.pinStep = "working"
                Profiles.verifyAdmin(page.adminId, pin)
            }
        }
        onCancelled: {
            if (page.pinStep === "pin") {
                page.pinStep = "idle"
                primary.forceActiveFocus()
            }
        }
    }

    Connections {
        target: Profiles
        function onVerifyAdminFinished(adminId, status, attemptsLeft, retryAfterSecs) {
            if (page.pinStep !== "working")
                return
            page.pinStep = "idle"
            primary.forceActiveFocus()
            if (status === "ok") {
                page.start(page.installed ? "update" : "install")
            } else {
                Sfx.back()
                page.errorText = ProfileStatus.describe(status, attemptsLeft, retryAfterSecs)
            }
        }
    }

    component ActionButton: Rectangle {
        id: button

        property string text
        property bool danger: false
        property bool active: true
        signal activated()

        width: 560 * page.u
        height: Theme.buttonHeight * page.u
        radius: height / 2
        opacity: active ? 1 : Theme.disabledOpacity
        color: danger ? Theme.dangerFill : (activeFocus ? Theme.focusFill : Theme.glass)
        border.width: activeFocus ? Theme.focusRingWidth * page.u : Theme.hairlineAt(page.u)
        border.color: activeFocus ? Theme.focusRing : Theme.glassBorder
        Accessible.role: Accessible.Button
        Accessible.name: text

        Text {
            anchors.centerIn: parent
            text: button.text
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * page.u
            font.weight: Theme.weightDemiBold
        }

        function accept() {
            if (!active)
                return
            Sfx.select()
            activated()
        }
        Keys.onReturnPressed: accept()
        Keys.onEnterPressed: accept()
    }

    Item {
        id: left
        width: 560 * page.u
        height: parent.height

        AppArt {
            id: hero
            objectName: "detailHero"
            width: parent.width
            height: 315 * page.u
            u: page.u
            appId: page.appId
            appName: page.app.name ?? ""
            picture: page.app.hero ?? ""
        }

        Column {
            anchors { top: hero.bottom; topMargin: Theme.spaceM * page.u }
            spacing: Theme.spaceS * page.u

            ActionButton {
                id: primary
                objectName: "detailPrimary"
                focus: true
                text: page.working ? page.phaseText()
                    : !page.installed ? qsTr("Install")
                    : page.hasUpdate ? qsTr("Update")
                    : qsTr("Open")
                active: !page.working && (!page.installed || page.hasUpdate)
                onActivated: page.primaryAction()
                Keys.onDownPressed: if (uninstall.visible) { Sfx.navigate(); uninstall.forceActiveFocus() }
            }

            ActionButton {
                id: uninstall
                objectName: "detailUninstall"
                visible: page.installed && !page.working
                text: qsTr("Uninstall")
                onActivated: confirm.open()
                Keys.onUpPressed: { Sfx.navigate(); primary.forceActiveFocus() }
                Keys.onDownPressed: if (activity.visible) { Sfx.navigate(); activity.forceActiveFocus() }
                onVisibleChanged: if (!visible) primary.forceActiveFocus()
            }

            // What this profile played of the app (T-247): private to the active profile.
            ActionButton {
                id: activity
                objectName: "detailActivity"
                visible: page.installed && !page.working
                text: qsTr("Your activity")
                onActivated: page.openRequested("activityGame", ({ appId: page.appId }))
                Keys.onUpPressed: { Sfx.navigate(); (uninstall.visible ? uninstall : primary).forceActiveFocus() }
                onVisibleChanged: if (!visible) primary.forceActiveFocus()
            }

            Item {
                width: 560 * page.u
                height: 90 * page.u

                Text {
                    objectName: "detailPhase"
                    visible: page.working
                    text: page.phaseText() + (page.job ? "  " + page.job.percent + "%" : "")
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * page.u
                }

                Rectangle {
                    objectName: "detailProgress"
                    visible: page.working
                    y: 40 * page.u
                    width: parent.width
                    height: Theme.spaceS * page.u
                    radius: height / 2
                    color: Theme.glass
                    border.width: Theme.hairlineAt(page.u)
                    border.color: Theme.glassBorder

                    Rectangle {
                        objectName: "detailProgressFill"
                        width: parent.width * (page.job ? page.job.percent : 0) / 100
                        height: parent.height
                        radius: height / 2
                        color: Theme.text
                        Behavior on width { NumberAnimation { duration: Theme.focusMs } }
                    }
                }

                Text {
                    objectName: "detailError"
                    visible: page.errorText.length > 0
                    width: parent.width
                    textFormat: Text.PlainText
                    text: page.errorText
                    color: Theme.errorText
                    font.pixelSize: Theme.typeCaption * page.u
                    wrapMode: Text.Wrap
                }
            }
        }
    }

    Column {
        id: info
        x: left.width + Theme.spaceXl * page.u
        width: parent.width - x
        spacing: Theme.spaceS * page.u

        Text {
            objectName: "detailDeveloper"
            textFormat: Text.PlainText
            text: page.app.developer ?? ""
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
        }

        Row {
            spacing: Theme.spaceS * page.u

            Badge {
                objectName: "detailSource"
                u: page.u
                text: page.sourceText(page.app.source ?? "")
                kind: page.sourceKind(page.app.source ?? "")
            }
            Badge {
                u: page.u
                text: page.ageText(page.app.ageRating)
            }
        }

        Text {
            objectName: "detailController"
            text: page.controllerText(page.app.controller ?? "none")
            color: Theme.text
            font.pixelSize: Theme.typeCaption * page.u
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: page.app.description ?? ""
            color: Theme.text
            font.pixelSize: Theme.typeCaption * page.u
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
        }

        Text {
            topPadding: Theme.spaceS * page.u
            text: qsTr("This app can")
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * page.u
            font.weight: Theme.weightDemiBold
        }

        Repeater {
            model: page.app.permissions ?? []

            delegate: Row {
                id: perm

                required property string modelData
                readonly property bool risky: page.highRisk.indexOf(modelData) >= 0

                objectName: "permission_" + modelData
                spacing: Theme.spaceS * page.u

                Badge {
                    objectName: "riskFlag_" + perm.modelData
                    visible: perm.risky
                    anchors.verticalCenter: parent.verticalCenter
                    u: page.u
                    kind: "warning"
                    text: qsTr("High risk")
                }

                Text {
                    textFormat: Text.PlainText      // an id the service sent shows raw
                    text: page.permissionText(perm.modelData)
                    color: perm.risky ? Theme.warningText : Theme.text
                    font.pixelSize: Theme.typeCaption * page.u
                }
            }
        }

        Text {
            objectName: "detailUpdateAdds"
            visible: page.newPermissions.length > 0
            width: parent.width
            textFormat: Text.PlainText
            text: qsTr("The update adds: %1").arg(page.newPermissions.map(p => page.permissionText(p)).join(", "))
            color: page.addsHighRisk ? Theme.warningText : Theme.text
            font.pixelSize: Theme.typeCaption * page.u
            wrapMode: Text.Wrap
        }

        Text {
            objectName: "detailAdminNote"
            visible: page.needsAdminPin
            width: parent.width
            text: page.installed ? qsTr("An admin's PIN is needed to update this app.")
                                 : qsTr("An admin's PIN is needed to install this app.")
            color: Theme.text
            font.pixelSize: Theme.typeCaption * page.u
            wrapMode: Text.Wrap
        }
    }

    // "Uninstall <app>?" with the data toggle. Cancel has focus when it opens.
    FocusScope {
        id: confirm
        objectName: "uninstallConfirm"
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        visible: opacity > 0
        opacity: shown ? 1 : 0
        enabled: shown
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

        property bool shown: false
        property Item returnTo: null

        function open() {
            returnTo = Window.activeFocusItem
            deleteData.checked = false
            shown = true
            cancel.forceActiveFocus()
        }

        function close() {
            shown = false
            const target = returnTo
            returnTo = null
            if (target && target.visible && target.enabled)
                target.forceActiveFocus()
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.scrim
        }

        Rectangle {
            anchors.centerIn: parent
            width: 1000 * page.u
            height: dialogColumn.height + 2 * Theme.spaceXl * page.u
            radius: Theme.radiusL * page.u
            color: Theme.panel
            border.color: Theme.glassBorder
        }

        Column {
            id: dialogColumn
            anchors.centerIn: parent
            width: 900 * page.u
            spacing: Theme.spaceL * page.u

            Text {
                objectName: "uninstallTitle"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: qsTr("Uninstall %1?").arg(page.app.name ?? "")
                color: Theme.text
                font.pixelSize: Theme.typeTitle * page.u
                font.weight: Theme.weightDemiBold
                elide: Text.ElideRight
            }

            ToggleRow {
                id: deleteData
                objectName: "uninstallDeleteData"
                u: page.u
                label: qsTr("Also delete my data")
                Keys.onDownPressed: { Sfx.navigate(); cancel.forceActiveFocus() }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spaceM * page.u

                ActionButton {
                    id: cancel
                    objectName: "uninstallCancel"
                    width: 300 * page.u
                    text: qsTr("Cancel")
                    onActivated: confirm.close()
                    Keys.onUpPressed: { Sfx.navigate(); deleteData.forceActiveFocus() }
                    Keys.onRightPressed: { Sfx.navigate(); go.forceActiveFocus() }
                }

                ActionButton {
                    id: go
                    objectName: "uninstallGo"
                    width: 300 * page.u
                    danger: true
                    text: qsTr("Uninstall")
                    onActivated: {
                        const wipe = deleteData.checked
                        confirm.close()
                        page.confirmUninstall(wipe)
                    }
                    Keys.onUpPressed: { Sfx.navigate(); deleteData.forceActiveFocus() }
                    Keys.onLeftPressed: { Sfx.navigate(); cancel.forceActiveFocus() }
                }
            }
        }

        Keys.onPressed: event => {
            if (BackKey.isBackOrBackspace(event.key)) {
                Sfx.back()
                confirm.close()
            }
            event.accepted = true      // modal: nothing leaks to the page underneath
        }
    }
}
