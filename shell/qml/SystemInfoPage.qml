pragma ComponentBehavior: Bound
import QtQuick
import QtQml.Models
import RuyaShell

// Settings -> About -> System information (T-226): what the console is made of and how it is doing,
// read-only, grouped (Console, Processor, Memory, Graphics, Storage, Network, Bluetooth, Audio,
// Controllers). The rows come from SystemInfoRows (org.ruyaos.Devices1.System plus the numbers other
// services own). Every row can take focus, only so that Up/Down scroll; nothing can be changed here.
//
// While the page is visible it asks for the live values (clock, memory use) every
// SystemDetails.liveIntervalMs and never when hidden; the rows are updated in place, so focus stays
// where it is. The model holds the row ids only (the order and which rows exist); the texts are
// bindings, so they follow the UI language and the live values.
//
// "Save report to USB drive" writes RuyaOS-system-report.txt and .json through Devices1.Storage
// (SaveReport). Network addresses (MAC, IP, Wi-Fi name, Bluetooth address) are left out unless
// "Include network addresses" is switched on; it starts off every time the page opens. The report is a
// local file: nothing is sent anywhere.
Page {
    id: page

    title: qsTr("System information")

    hints: body.hints

    readonly property string reportTextName: "RuyaOS-system-report.txt"
    readonly property string reportJsonName: "RuyaOS-system-report.json"
    readonly property bool includeAddresses: addressesRow.checked

    // "idle" | "saving" | "ok" | "no-drive" | a failure status of Storage.SaveReport
    property string saveState: "idle"
    property string saveDrive: ""
    // The message line comes and goes: lay the rows out again so the viewport ends on a whole row.
    onSaveStateChanged: Qt.callLater(body.reflow)

    SystemInfoRows { id: sysRows }

    function saveMessage() {
        switch (saveState) {
        case "saving": return qsTr("Saving the report…")
        // The drive's label is whatever the stick says (and is shown as plain text); "the USB drive" when it has none.
        case "ok": return qsTr("Saved %1 and %2 to %3.").arg(reportTextName).arg(reportJsonName).arg(saveDrive.length > 0 ? saveDrive : qsTr("the USB drive"))
        case "no-drive": return qsTr("No USB drive found. Plug one in and try again.")
        case "read-only": return qsTr("This drive is read-only. Try another one.")
        case "full": return qsTr("This drive is full. Free some space or try another one.")
        case "unknown-volume":
        case "unsupported": return qsTr("This drive cannot be written to. Try another one.")
        case "idle": return ""
        }
        return qsTr("The report could not be saved.")
    }

    // The first removable drive that is mounted and writable; the drive the report goes to.
    function targetDrive() {
        return Storage.volumes.find(v => v.removable && v.mounted && !v.readOnly)
    }

    function saveReport() {
        if (saveState === "saving")
            return
        const drive = targetDrive()
        if (!drive) {
            saveState = "no-drive"
            return
        }
        saveDrive = drive.label
        saveState = "saving"
        const files = {}
        files[reportTextName] = sysRows.reportText(includeAddresses)
        files[reportJsonName] = sysRows.reportJson(includeAddresses)
        Storage.saveReport(drive.id, files)
    }

    Connections {
        target: Storage
        function onFinished(op, id, status) {
            if (op === "saveReport" && page.saveState === "saving")
                page.saveState = status
        }
    }

    // ---- the rows: ids only
    ListModel { id: rowModel }

    function desired() {
        const out = []
        for (const s of sysRows.sections) {
            out.push({ kind: "heading", uid: "h/" + s.id, sectionId: s.id })
            for (const r of s.rows)
                out.push({ kind: "row", uid: r.uid, sectionId: s.id })
        }
        return out
    }

    // Makes the model equal to `desired()` with as few changes as possible: a live value changes
    // nothing here (it is a binding), a row going away is removed and a row appearing is inserted
    // where it belongs. Never a move: a Repeater does not reorder its items on a move, and the
    // order of the rows in the pane is the order in which the items were created.
    function syncRows() {
        const before = body.activeFocus ? body.focusableRows().findIndex(r => r.activeFocus) : -1
        const want = desired()
        const wanted = {}
        for (const w of want)
            wanted[w.uid] = true
        for (let i = rowModel.count - 1; i >= 0; --i) {
            if (!wanted[rowModel.get(i).uid])
                rowModel.remove(i)
        }
        // What is left is in the right relative order (the sections and their rows have a fixed order).
        for (let i = 0; i < want.length; ++i) {
            if (i >= rowModel.count || rowModel.get(i).uid !== want[i].uid)
                rowModel.insert(i, want[i])
        }
        body.reflow()
        Qt.callLater(page.refocus, before)
    }

    // After rows went away: if the focused row is gone, focus the row now at its place.
    function refocus(index) {
        if (!body.activeFocus || index < 0)
            return
        const list = body.focusableRows()
        if (list.length > 0 && !list.some(r => r.activeFocus))
            list[Math.min(index, list.length - 1)].forceActiveFocus()
        body.ensureFocusedVisible()
    }

    Connections {
        target: sysRows
        function onSectionsChanged() { page.syncRows() }
    }

    // ---- live values: only while the page is shown
    function refreshAll() {
        SystemDetails.probeLocal(page.Window.window as Window)
        SystemDetails.refresh()
        Storage.refreshInternal()
    }

    Timer {
        objectName: "sysLiveTimer"
        interval: SystemDetails.liveIntervalMs
        repeat: true
        // Nothing is asked for while the page is hidden, an app is in front or the window is not shown.
        running: page.visible && LiquidGate.screenShown && !LiquidGate.appOpen
        onTriggered: SystemDetails.refresh()
    }

    onVisibleChanged: {
        if (visible)
            refreshAll()
    }

    Component.onCompleted: {
        syncRows()
        if (visible)
            refreshAll()
    }

    // A read-only row with the value on the right; with `fraction` >= 0 a usage bar before the value.
    component InfoRow: SettingControl {
        id: info
        required property string uid
        readonly property var entry: sysRows.byUid[uid]
        label: entry ? entry.label : ""
        readonly property string value: entry ? entry.value : ""
        readonly property real fraction: entry ? entry.fraction : -1
        accessibleValue: value
        Accessible.role: Accessible.StaticText
        flat: true                      // the fact look (04 section 5); the pane draws the hairlines
        hintKind: "info"

        Text {
            id: valueText
            objectName: "value"
            anchors { right: parent.right; rightMargin: Theme.spaceL * info.u; verticalCenter: parent.verticalCenter }
            width: Math.min(implicitWidth, info.width * 0.6 - (track.visible ? track.width + Theme.spaceM * info.u : 0))
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideMiddle
            textFormat: Text.PlainText       // a name from a drive or a network: never markup
            text: info.value
            color: Theme.text
            font.pixelSize: Theme.typeBody * info.u
        }

        ProgressBar {
            id: track
            objectName: "usageTrack"
            fillName: "usageFill"
            visible: info.fraction >= 0
            anchors { right: valueText.left; rightMargin: Theme.spaceM * info.u; verticalCenter: parent.verticalCenter }
            width: 260 * info.u
            u: info.u
            value: Math.max(0, info.fraction)
            fillColor: info.fraction > 0.9 ? Theme.warningText : Theme.text
        }
    }

    SettingsPane {
        id: body
        objectName: "sysBody"
        anchors.fill: parent
        u: page.u
        focus: true
        onExitRequested: page.backRequested()

        SettingRow {
            id: saveRow
            objectName: "sysSave"
            kind: "action"
            u: page.u
            label: qsTr("Save report to USB drive")
            value: page.saveState === "saving" ? qsTr("Saving…") : ""
            onActivated: page.saveReport()
        }
        ToggleRow {
            id: addressesRow
            objectName: "sysAddresses"
            u: page.u
            label: qsTr("Include network addresses")
            checked: false
        }
        Text {
            objectName: "sysSaveMessage"
            width: parent ? parent.width : 0
            visible: page.saveState !== "idle"
            text: page.saveMessage()
            color: page.saveState === "ok" ? Theme.toastSuccess
                 : page.saveState === "saving" ? Theme.text : Theme.errorText
            font.pixelSize: Theme.typeBody * page.u
            wrapMode: Text.Wrap
            textFormat: Text.PlainText       // carries the stick's label: never markup
        }
        Text {
            objectName: "sysNote"
            width: parent ? parent.width : 0
            text: qsTr("The report is a text file and a JSON file on the drive. It is only a file: nothing is sent anywhere. Network addresses (MAC, IP, Wi-Fi name, Bluetooth address) are left out unless you include them.")
            color: Theme.textDim
            font.pixelSize: Theme.typeBody * page.u
            wrapMode: Text.Wrap
        }

        Repeater {
            model: rowModel
            delegate: DelegateChooser {
                role: "kind"
                DelegateChoice {
                    roleValue: "heading"
                    GroupLabel {
                        required property string sectionId
                        objectName: "sysHeading_" + sectionId
                        u: page.u
                        text: sysRows.titles[sectionId] ?? ""
                    }
                }
                DelegateChoice {
                    roleValue: "row"
                    InfoRow {
                        required property string sectionId
                        objectName: "sysRow_" + uid
                        u: page.u
                    }
                }
            }
        }
    }
}
