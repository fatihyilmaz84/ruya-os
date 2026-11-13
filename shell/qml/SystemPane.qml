pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> System. The language row writes straight to DeviceSettings, which installs the
// translator and retranslates the UI at once. Language names are shown in their own language.
//
// The Updates group (org.ruyaos.Update1) is one row that follows the update state: check,
// download (with progress), "Restart to finish". A rollback to the previous image, the
// channel and "Restart automatically for updates" are for admins; the rollback asks for the admin's PIN (Profiles.verifyAdmin), then
// a confirmation, then calls Update.rollback().
//
// The Time zone row (T-213) is for admins: Accept opens ZonePicker (region, then city), which asks
// Devices1.Time to set the zone. The clock and the update restart window follow at once.
//
// The Device health section (T-200, Thermal, org.ruyaos.Devices1.Thermal) comes last: one read-only
// row per sensor ("Processor 33 °C", "Fan 1820 rpm", "Drive 41 °C") with a mark when its level is
// not normal. Rows follow Thermal.sensors by id and are updated in place, so focus stays on a row
// while the values change.
SettingsPane {
    id: pane

    // Full-screen layer for the PIN pad and the confirmations (the Settings page's modal layer).
    property Item overlay

    readonly property bool isAdmin: (Profiles.active.role ?? "") === "admin"
    readonly property string updateState: Update.state

    property string message: ""
    property bool messageIsError: false
    property bool zoneAsked: false         // a zone chosen in this pane's picker is on its way
    property string rollbackStep: "idle"     // idle | pin | confirm | working
    property Item returnTo: null

    // A sensor row: label, a mark and its word when the level is not normal, and the value.
    component HealthRow: SettingControl {
        id: health
        property string value
        property string level: "normal"
        readonly property bool marked: level !== "normal"
        accessibleValue: marked ? value + ", " + ThermalText.levelText(level) : value

        Text {
            id: healthValue
            objectName: "value"
            anchors { right: parent.right; rightMargin: Theme.spaceL * health.u; verticalCenter: parent.verticalCenter }
            text: health.value
            color: Theme.text
            font.pixelSize: Theme.typeBody * health.u
        }

        Text {
            id: healthLevel
            objectName: "levelText"
            visible: health.marked
            anchors { right: healthValue.left; rightMargin: Theme.spaceM * health.u; verticalCenter: parent.verticalCenter }
            text: ThermalText.levelText(health.level)
            color: ThermalText.levelColor(health.level)
            font.pixelSize: Theme.typeBody * health.u
        }

        Rectangle {
            objectName: "levelMark"
            visible: health.marked
            anchors { right: healthLevel.left; rightMargin: Theme.spaceS * health.u; verticalCenter: parent.verticalCenter }
            width: Theme.spaceM * health.u
            height: width
            radius: width / 2
            color: ThermalText.levelColor(health.level)
        }
    }

    // Rows follow Thermal.sensors by id (updated in place), so focus stays on a row while the
    // numbers change.
    ListModel { id: sensorModel }

    function syncSensors() {
        const before = pane.activeFocus ? focusableRows().findIndex(r => r.activeFocus) : -1
        const list = Thermal.sensors
        for (let i = sensorModel.count - 1; i >= 0; --i) {
            const id = sensorModel.get(i).sensorId
            if (!list.some(s => s.id === id))
                sensorModel.remove(i)
        }
        for (let i = 0; i < list.length; ++i) {
            const s = list[i]
            const entry = { sensorId: s.id, sensorClass: s.cls, reading: s.value, sensorLevel: s.level }
            let at = -1
            for (let j = 0; j < sensorModel.count; ++j) {
                if (sensorModel.get(j).sensorId === s.id) {
                    at = j
                    break
                }
            }
            if (at < 0) {
                sensorModel.insert(i, entry)
            } else {
                sensorModel.set(at, entry)
                if (at !== i)
                    sensorModel.move(at, i, 1)
            }
        }
        Qt.callLater(pane.refocus, before)
    }

    // After a list update: if the focused row vanished, focus the row now at its place (or the last).
    function refocus(index) {
        if (!pane.activeFocus || index < 0)
            return
        const rows = focusableRows()
        if (rows.length > 0 && !rows.some(r => r.activeFocus))
            rows[Math.min(index, rows.length - 1)].forceActiveFocus()
        ensureFocusedVisible()
    }

    // One line for the worst level, so a warm console is told as such (no toast, nothing changes).
    function healthLine() {
        switch (Thermal.level) {
        case "warm": return qsTr("The console is warm. Nothing needs to be done.")
        case "hot": return qsTr("The console is running hot. Visual effects are reduced until it cools down.")
        case "critical": return qsTr("The console is too hot. Apps are closed and it powers off if it does not cool down.")
        }
        return ""
    }

    Connections {
        target: Thermal
        function onSensorsChanged() { pane.syncSensors() }
    }
    Component.onCompleted: syncSensors()

    function channelLabel(channel) {
        return channel === "beta" ? qsTr("Beta") : qsTr("Stable")
    }

    function lastCheckText() {
        return Update.lastCheck > 0
            ? qsTr("Last checked %1").arg(Qt.formatDateTime(new Date(Update.lastCheck * 1000), "d MMM, hh:mm"))
            : qsTr("Never checked")
    }

    function updateLabel() {
        switch (updateState) {
        case "checking": return qsTr("Checking for updates…")
        case "downloading": return qsTr("Downloading version %1").arg(Update.available || Update.staged)
        case "staged": return qsTr("Restart to finish")
        default:
            return Update.available.length > 0 ? qsTr("Download version %1").arg(Update.available)
                                               : qsTr("Check for updates")
        }
    }

    function updateValue() {
        switch (updateState) {
        case "checking": return ""
        case "downloading": return qsTr("%1 %").arg(Update.progress)
        case "staged": return qsTr("Version %1 is ready").arg(Update.staged)
        case "up-to-date": return qsTr("Up to date")
        case "failed": return qsTr("Failed")
        default: return Update.available.length > 0 ? qsTr("Update found") : pane.lastCheckText()
        }
    }

    function activateUpdate() {
        message = ""
        if (updateState === "staged") {
            beginModal()
            restartSlot.active = true
            restartConfirm.open("restart")
        } else if (updateState === "idle" && Update.available.length > 0) {
            Update.download()
        } else if (updateState === "idle" || updateState === "up-to-date" || updateState === "failed") {
            Update.check()
        }
    }

    function report(text, isError) {
        message = text
        messageIsError = isError
    }

    function beginModal() {
        returnTo = Window.activeFocusItem
    }
    function restoreFocus() {
        const target = returnTo
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        Qt.callLater(keepFocus)
    }
    // The rollback row disappears once the rollback is done: move to the update row.
    function keepFocus() {
        if (!activeFocus)
            return
        if (!focusableRows().some(r => r.activeFocus))
            updateRow.forceActiveFocus()
        ensureFocusedVisible()
    }

    function startRollback() {
        report("", false)
        beginModal()
        rollbackStep = "pin"
        padSlot.active = true
        pad.collect(qsTr("Enter your PIN"), false)
    }

    function abortRollback() {
        rollbackStep = "idle"
        restoreFocus()
    }

    // The PIN pad, the confirmations and the time zone picker are built when each first opens (T-349).
    Loader {
        id: padSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            PinPad {
                objectName: "updatePinPad"
                u: pane.u
                onCollected: pin => {
                    if (pane.rollbackStep === "pin") {
                        pane.rollbackStep = "working"
                        Profiles.verifyAdmin(Profiles.activeProfile, pin)
                    }
                }
                onCancelled: if (pane.rollbackStep === "pin") pane.abortRollback()
                onClosed: if (pane.rollbackStep === "idle") pane.restoreFocus()
            }
        }
    }
    readonly property PinPad pad: padSlot.item as PinPad

    Loader {
        id: restartSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            PowerConfirm {
                objectName: "updateRestartConfirm"
                u: pane.u
                onClosed: pane.restoreFocus()
            }
        }
    }
    readonly property PowerConfirm restartConfirm: restartSlot.item as PowerConfirm

    Loader {
        id: rollbackSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            PowerConfirm {
                objectName: "updateRollbackConfirm"
                u: pane.u
                onConfirmed: {
                    if (pane.rollbackStep === "confirm") {
                        pane.rollbackStep = "working"
                        Update.rollback()
                    }
                }
                onClosed: {
                    // Cancel and Back close without confirmed(); Confirm emits it after closed().
                    Qt.callLater(() => {
                        if (pane.rollbackStep === "confirm")
                            pane.abortRollback()
                        else
                            pane.restoreFocus()
                    })
                }
            }
        }
    }
    readonly property PowerConfirm rollbackConfirm: rollbackSlot.item as PowerConfirm

    Connections {
        target: Profiles

        function onVerifyAdminFinished(adminId, status, attemptsLeft, retryAfterSecs) {
            if (pane.rollbackStep !== "working")
                return
            if (status === "ok") {
                pane.rollbackStep = "confirm"
                rollbackSlot.active = true
                pane.rollbackConfirm.customTitle = qsTr("Roll back to the previous version?")
                pane.rollbackConfirm.detail = qsTr("The console starts the previous version the next time it restarts.")
                pane.rollbackConfirm.customConfirmName = qsTr("Roll back now")
                pane.rollbackConfirm.open("custom")
            } else {
                Sfx.error()
                pane.rollbackStep = "idle"
                pane.report(ProfileStatus.describe(status, attemptsLeft, retryAfterSecs), true)
                pane.restoreFocus()
            }
        }
    }

    Connections {
        target: Update

        function onRequestFinished(method, status) {
            if (method === "setAutoRestart" && status !== "ok")
                autoRestartRow.checked = Update.autoRestart
            if (method === "rollback" && pane.rollbackStep === "working") {
                pane.rollbackStep = "idle"
                if (status === "ok") {
                    pane.report(qsTr("The previous version starts after the next restart."), false)
                } else {
                    Sfx.error()
                    pane.report(status === "forbidden" ? qsTr("Only an admin can do this.")
                                                       : qsTr("Could not roll back."), true)
                }
                pane.restoreFocus()
            } else if (status !== "ok" && (method === "check" || method === "download" || method === "setChannel"
                                            || method === "setAutoRestart")) {
                Sfx.error()
                pane.report(status === "busy" ? qsTr("An update is already in progress.")
                            : status === "forbidden" ? qsTr("Only an admin can do this.")
                                                     : qsTr("The update could not be started."), true)
            }
        }
        function onStatusChanged() {
            if (Update.state === "failed" && Update.error.length > 0)
                pane.report(Update.error, true)
        }
    }

    ChoiceRow {
        id: language
        objectName: "rowLanguage"
        u: pane.u
        label: qsTr("Language")
        options: [
            { value: "en", label: "English" },
            { value: "tr", label: "Türkçe" },
        ]
        onEdited: v => {
            DeviceSettings.language = v
            language.value = DeviceSettings.language
        }
    }
    Binding { target: language; property: "value"; value: DeviceSettings.language }

    // Time zone (T-213): admins only. The service checks the caller again (an admin profile).
    SettingRow {
        id: zoneRow
        objectName: "rowTimezone"
        u: pane.u
        visible: pane.isAdmin
        label: qsTr("Time zone")
        value: TimeZone.timezone.replace(/_/g, " ")
        onActivated: {
            zoneSlot.active = true
            pane.zonePicker.open()
        }
    }

    Text {
        objectName: "timeNtpNote"
        width: parent ? parent.width : 0
        visible: !TimeZone.ntpSynchronised
        text: qsTr("The clock has not been set from the internet yet, so the time may be wrong.")
        color: Theme.text
        font.pixelSize: Theme.typeCaption * pane.u
        wrapMode: Text.Wrap
    }

    Loader {
        id: zoneSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            ZonePicker {
                objectName: "zonePicker"
                u: pane.u
                onRequested: zone => {
                    pane.zoneAsked = true
                    TimeZone.setTimezone(zone)
                }
            }
        }
    }
    readonly property ZonePicker zonePicker: zoneSlot.item as ZonePicker

    Connections {
        target: TimeZone
        function onSetTimezoneFinished(name, status) {
            if (!pane.zoneAsked)
                return
            pane.zoneAsked = false
            if (status === "ok") {
                Notifications.show(qsTr("Time zone set to %1").arg(name.replace(/_/g, " ")), "success")
            } else {
                Notifications.show(status === "forbidden" ? qsTr("Only an admin can do this.")
                                                          : qsTr("Could not change the time zone."), "error")
            }
        }
    }

    // The Ruya Hub pauses the game (T-457, 02 §1.6). For every profile: a device setting.
    ToggleRow {
        id: pauseRow
        objectName: "rowPauseGames"
        u: pane.u
        label: qsTr("Pause games when Ruya Hub opens")
        onToggled: checked => DeviceSettings.pauseGamesInHub = checked
    }
    Binding { target: pauseRow; property: "checked"; value: DeviceSettings.pauseGamesInHub }

    Text {
        objectName: "pauseGamesNote"
        width: parent ? parent.width : 0
        text: qsTr("Online games can lose their connection while paused.")
        color: Theme.text
        font.pixelSize: Theme.typeCaption * pane.u
        wrapMode: Text.Wrap
    }

    Text {
        objectName: "updatesHeading"
        width: parent ? parent.width : 0
        topPadding: Theme.spaceS * pane.u
        text: qsTr("Updates")
        color: Theme.text
        font.pixelSize: Theme.typeBody * pane.u
    }

    SettingRow {
        objectName: "rowVersion"
        u: pane.u
        label: qsTr("Version")
        value: Update.current + " · " + pane.channelLabel(Update.channel)
    }

    ChoiceRow {
        id: channelRow
        objectName: "rowChannel"
        u: pane.u
        visible: pane.isAdmin
        label: qsTr("Update channel")
        options: [
            { value: "stable", label: qsTr("Stable") },
            { value: "beta", label: qsTr("Beta") },
        ]
        onEdited: v => {
            pane.report("", false)
            Update.setChannel(v)
        }
    }
    Binding { target: channelRow; property: "value"; value: Update.channel }

    ToggleRow {
        id: autoRestartRow
        objectName: "rowAutoRestart"
        u: pane.u
        visible: pane.isAdmin
        label: qsTr("Restart automatically for updates")
        onToggled: checked => {
            pane.report("", false)
            Update.setAutoRestart(checked)
        }
    }
    Binding { target: autoRestartRow; property: "checked"; value: Update.autoRestart }

    SettingRow {
        id: updateRow
        objectName: "rowUpdate"
        u: pane.u
        label: pane.updateLabel()
        value: pane.updateValue()
        onActivated: pane.activateUpdate()
    }

    SettingRow {
        id: rollbackRow
        objectName: "rowRollback"
        u: pane.u
        visible: pane.isAdmin && Update.rollbackAvailable
        label: qsTr("Roll back to the previous version")
        onActivated: pane.startRollback()
    }

    Text {
        objectName: "updateMessage"
        width: parent ? parent.width : 0
        visible: pane.message.length > 0
        textFormat: Text.PlainText
        text: pane.message
        color: pane.messageIsError ? Theme.errorText : Theme.toastSuccess
        font.pixelSize: Theme.typeBody * pane.u
        wrapMode: Text.Wrap
    }

    Text {
        objectName: "healthHeading"
        width: parent ? parent.width : 0
        topPadding: Theme.spaceS * pane.u
        text: qsTr("Device health")
        color: Theme.text
        font.pixelSize: Theme.typeBody * pane.u
    }

    Text {
        objectName: "healthLine"
        width: parent ? parent.width : 0
        visible: Thermal.level !== "normal"
        textFormat: Text.PlainText
        text: pane.healthLine()
        color: ThermalText.levelColor(Thermal.level)
        font.pixelSize: Theme.typeBody * pane.u
        wrapMode: Text.Wrap
    }

    Text {
        objectName: "healthNone"
        width: parent ? parent.width : 0
        visible: sensorModel.count === 0
        text: qsTr("No temperature sensors were found on this device.")
        color: Theme.textDim
        font.pixelSize: Theme.typeBody * pane.u
        wrapMode: Text.Wrap
    }

    Repeater {
        model: sensorModel
        HealthRow {
            required property string sensorId
            required property string sensorClass
            required property real reading
            required property string sensorLevel
            objectName: "health_" + sensorId
            u: pane.u
            // Bindings, not model data: the words follow the UI language live.
            label: ThermalText.nameOf(sensorId)
            value: ThermalText.valueText({ cls: sensorClass, value: reading })
            level: sensorLevel
        }
    }
}
