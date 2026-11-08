pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Storage. First "This console" (T-196): how full the console's own storage is (the
// free space with a usage bar, then what the apps and games take and the rest ("Other"; with the
// profile data known, "Profile data" and "System");
// Storage.internal, from Devices1.Storage.GetSystemUsage). Then one row per volume (USB drives,
// and an internal disk mounted outside the system paths) with its
// filesystem and "x GB free of y GB", and an "Eject" row for each mounted removable one. Accept
// on a removable volume moves to its Eject row; on a drive whose filesystem is not supported it
// says why it can't be used.
//
// Under each mounted removable volume (T-331) come the rows of what RuyaOS finds on it, in the
// style of "This console": "Scanning…" while the service walks the drive, then one row per
// category (Games, Backups, ...) with its size, "Other" for the rest, or the one line "Nothing
// from RuyaOS on this drive"; a partial result reads "at least". The scan (Storage.scan) starts
// when the pane is shown, one drive at a time (the focused drive first), and is cancelled when the
// pane hides or the drive is ejected. Rows are updated in place, so focus stays on its row.
//
// The service only reads names and sizes: nothing on a volume is opened or run from here.
// Everything goes through the Storage singleton (org.ruyaos.Devices1.Storage); sizes come from
// Storage.formatBytes. The "safe to remove" and "drive inserted" toasts are in ToastLayer.
SettingsPane {
    id: pane

    readonly property var internal: Storage.internal

    // Only a drive's own row and its Eject row do something on Accept; the "This console" rows and
    // the scan rows are facts, so while one has focus the hint bar offers Back only (04 section 5).
    // Each row says so when it takes focus.
    property bool actionFocused: false
    hints: actionFocused ? [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Back") }]
                         : [{ button: "B", text: qsTr("Back") }]
    // Less than this much free and the usage bar turns to the warning colour.
    readonly property real lowFreeFraction: 0.10

    // The profile data is unknown today (the profile homes are 0700 users' directories the service
    // cannot read): the rest is then shown as one row, "Other".
    function dataKnown() {
        return internal.dataBytes >= 0
    }

    function internalKnown() {
        return internal.valid && internal.totalBytes > 0 && internal.freeBytes >= 0
    }

    // The part of the disk that is used, 0..1; 0 while it is not known.
    function usedFraction() {
        return internalKnown() ? Math.min(1, Math.max(0, 1 - internal.freeBytes / internal.totalBytes)) : 0
    }

    function isLow() {
        return internalKnown() && internal.freeBytes / internal.totalBytes < lowFreeFraction
    }

    function freeText() {
        return internalKnown()
            ? qsTr("%1 free of %2").arg(Storage.formatBytes(internal.freeBytes)).arg(Storage.formatBytes(internal.totalBytes))
            : "—"
    }

    // A size that may not be known (-1): a dash until it is.
    function sizeText(bytes) {
        return bytes >= 0 ? Storage.formatBytes(bytes) : "—"
    }

    // A settings row with a usage bar between the label and the value. Read-only.
    component UsageRow: SettingControl {
        id: usage
        property string value
        property real fraction          // used part, 0..1
        property bool low               // turns the bar to the warning colour
        readonly property color fillColor: low ? Theme.warningText : Theme.text
        accessibleValue: value

        Text {
            id: usageValue
            objectName: "value"
            anchors { right: parent.right; rightMargin: Theme.spaceL * usage.u; verticalCenter: parent.verticalCenter }
            text: usage.value
            color: Theme.text
            font.pixelSize: Theme.typeBody * usage.u
        }

        Rectangle {
            objectName: "usageTrack"
            anchors { right: usageValue.left; rightMargin: Theme.spaceM * usage.u; verticalCenter: parent.verticalCenter }
            width: 260 * usage.u
            height: Theme.spaceS * usage.u
            radius: height / 2
            color: Theme.glass
            border.width: Theme.hairlineAt(usage.u)
            border.color: Theme.glassBorder

            Rectangle {
                objectName: "usageFill"
                width: parent.width * usage.fraction
                height: parent.height
                radius: height / 2
                color: usage.fillColor
                Behavior on width { NumberAnimation { duration: Theme.focusMs } }
            }
        }
    }

    // One flat list of the rows under "Drives", in display order: per volume its row, the rows of
    // its scan and its Eject row. Rows are matched by `rowKey` and updated in place, so focus
    // stays on a row when the list is re-published (free space changed) or a scan reports.
    ListModel { id: rowModel }

    // The name of a category of the service (Devices1.Storage.GetVolumeScan); "" for a key this
    // shell does not know, which then counts as "Other".
    function categoryName(key) {
        switch (key) {
        case "games": return qsTr("Games")
        case "backups": return qsTr("Backups")
        case "captures": return qsTr("Captures")
        case "packages": return qsTr("Packages")
        case "pictures": return qsTr("Pictures")
        case "reports": return qsTr("System reports")
        }
        return ""
    }

    // A size from a scan: "at least" when the walk could not see everything.
    function scanSize(bytes, partial) {
        const text = Storage.formatBytes(bytes)
        return partial ? qsTr("at least %1").arg(text) : text
    }

    // The rows of one volume's scan.
    function scanRows(id) {
        const e = Storage.scans[id]
        const row = (sub, name, value) => ({ rowKey: "scan:" + id + ":" + sub, kind: "scan", sub: sub, volId: id,
                                             name: name, valueText: value, shown: true, removable: true, mounted: true })
        // A refusal other than "busy" (another scan runs; asked again soon) is final for now.
        const refused = e && e.status !== "" && e.status !== "busy"
        if (!e || (e.state !== "done" && e.state !== "failed" && !refused))
            return [row("wait", qsTr("Scanning…"), "")]
        if (e.state === "failed" || refused)
            return [row("failed", qsTr("Could not read this drive"), qsTr("Plug it in again"))]
        const rows = []
        let other = e.otherBytes
        for (const c of e.categories) {
            const name = categoryName(c.key)
            if (name === "")
                other += c.bytes             // a category this shell does not know
            else
                rows.push(row("cat:" + c.key, name, scanSize(c.bytes, e.partial)))
        }
        if (other > 0 && rows.length > 0)
            rows.push(row("other", qsTr("Other"), scanSize(other, e.partial)))
        // A partial walk may simply not have got to it yet.
        if (rows.length === 0)
            rows.push(row("none", e.partial ? qsTr("Nothing found so far") : qsTr("Nothing found here"), ""))
        return rows
    }

    function desiredRows() {
        const out = []
        for (const v of Storage.volumes) {
            const usable = v.removable && v.mounted
            out.push({ rowKey: "vol:" + v.id, kind: "volume", sub: "", volId: v.id, name: v.label,
                       valueText: volumeValue(v.filesystem, v.mounted, v.readOnly, v.freeBytes, v.sizeBytes),
                       shown: true, removable: v.removable, mounted: v.mounted })
            if (usable)
                out.push(...scanRows(v.id))
            out.push({ rowKey: "eject:" + v.id, kind: "eject", sub: "", volId: v.id, name: qsTr("Eject %1").arg(v.label),
                       valueText: "", shown: usable, removable: v.removable, mounted: v.mounted })
        }
        return out
    }

    function syncRows() {
        // Where focus is now, to put it on a neighbour if its row goes away (Eject).
        const before = pane.activeFocus ? focusableRows().findIndex(r => r.activeFocus) : -1
        const list = desiredRows()
        for (let i = rowModel.count - 1; i >= 0; --i) {
            const key = rowModel.get(i).rowKey
            if (!list.some(r => r.rowKey === key))
                rowModel.remove(i)
        }
        for (let i = 0; i < list.length; ++i) {
            let at = -1
            for (let j = 0; j < rowModel.count; ++j) {
                if (rowModel.get(j).rowKey === list[i].rowKey) {
                    at = j
                    break
                }
            }
            if (at < 0) {
                rowModel.insert(i, list[i])
            } else {
                rowModel.set(at, list[i])
                if (at !== i)
                    rowModel.move(at, i, 1)
            }
        }
        // (Qt.callLater keeps only the newest arguments of a pending call: a second sync after the
        // focused row went must not cancel the refocus the first one asked for.)
        if (before >= 0)
            Qt.callLater(pane.refocus, before)
        // Rows created or removed: lay them out now, so the view follows the focused row (SettingsPane.reflow).
        reflow()
    }

    // After a list update: if the focused row vanished, focus the row now at its place (or the
    // last one).
    function refocus(index) {
        if (!pane.activeFocus || index < 0)
            return
        const rows = focusableRows()
        if (rows.length > 0 && !rows.some(r => r.activeFocus))
            rows[Math.min(index, rows.length - 1)].forceActiveFocus()
        ensureFocusedVisible()
    }

    // The scan: one drive at a time, the one with the focus first, then the others. A drive is asked
    // for when it has no result yet (or was cancelled); `scanPending` is the one asked for whose first
    // reply has not come, so no second is asked meanwhile.
    property string scanPending

    function scanRunning() {
        return scanPending !== "" || Object.values(Storage.scans).some(e => e.state === "running")
    }

    function needsScan(id, retryBusy) {
        const e = Storage.scans[id]
        if (!e)
            return true
        if (e.status === "busy")
            return retryBusy
        return e.status === "" && (e.state === "cancelled" || e.state === "idle")
    }

    function focusedVolume() {
        const row = focusableRows().find(r => r.activeFocus)
        return row && row.volId ? row.volId : ""
    }

    function pumpScan(retryBusy) {
        if (!visible || scanRunning())
            return
        const first = focusedVolume()
        const wanted = Storage.volumes.filter(v => v.removable && v.mounted && v.id !== ejectingId && needsScan(v.id, retryBusy))
        wanted.sort((a, b) => (b.id === first) - (a.id === first))
        if (wanted.length > 0) {
            scanPending = wanted[0].id
            Storage.scan(wanted[0].id)
        }
    }

    // The pane left the screen: stop walking the drives.
    function stopScans() {
        for (const id of Object.keys(Storage.scans)) {
            if (Storage.scans[id].state === "running")
                Storage.cancelScan(id)
        }
        if (scanPending !== "") {
            Storage.cancelScan(scanPending)
            scanPending = ""
        }
    }

    // A refused scan ("busy": another one runs) is asked again in a moment.
    Timer {
        id: busyRetry
        interval: 1500
        onTriggered: pane.pumpScan(true)
    }

    // Free space changes without a signal: read the numbers when this pane is shown (not when
    // Settings opens: the pane is created then, hidden).
    onVisibleChanged: {
        if (visible) {
            Storage.refreshInternal()
            pumpScan(false)
        } else {
            busyRetry.stop()
            stopScans()
        }
    }

    Component.onCompleted: {
        syncRows()
        if (visible) {
            Storage.refreshInternal()
            pumpScan(false)
        }
    }

    function labelOf(id) {
        const v = Storage.volumes.find(x => x.id === id)
        return v ? v.label : ""
    }

    function filesystemName(fs) {
        switch (fs) {
        case "exfat": return "exFAT"
        case "vfat": return "FAT32"
        case "ntfs": return "NTFS"
        case "btrfs": return "Btrfs"
        }
        return fs
    }

    // The single mapping from a service status to text.
    function statusText(status, label) {
        switch (status) {
        case "busy": return qsTr("%1 is still in use. Close what uses it and try again.").arg(label)
        case "unknown-volume": return qsTr("That drive is no longer connected.")
        case "unsupported": return unsupportedText()
        }
        return qsTr("Could not eject %1.").arg(label)
    }

    function unsupportedText() {
        return qsTr("This drive's format is not supported. Format it as exFAT on a computer to use it here.")
    }

    function volumeValue(fs, mounted, readOnly, free, size) {
        if (!mounted)
            return qsTr("Not supported")
        const parts = [filesystemName(fs), qsTr("%1 free of %2").arg(Storage.formatBytes(free)).arg(Storage.formatBytes(size))]
        if (readOnly)
            parts.push(qsTr("Read-only"))
        return parts.join(" · ")
    }

    property string ejectingId         // the volume being ejected, "" if none

    function ejectVolume(id) {
        if (id === ejectingId)
            return                     // already ejecting: a second Accept or a key repeat does nothing
        ejectingId = id
        Storage.cancelScan(id)         // a walk of the drive must not keep it busy
        if (scanPending === id)
            scanPending = ""
        Storage.eject(id)
    }

    function activate(id, removable, mounted) {
        if (!mounted) {
            Notifications.show(unsupportedText(), "warning")
        } else if (removable) {
            const eject = findEject(id)
            if (eject)
                eject.forceActiveFocus()
            ensureFocusedVisible()
        }
    }

    function findEject(id) {
        return focusableRows().find(r => r.objectName === "storageEject_" + id) ?? null
    }

    Connections {
        target: Storage
        function onFinished(op, id, status) {
            if (op === "eject" && id === pane.ejectingId) {
                pane.ejectingId = ""
                pane.pumpScan(false)   // it stayed (busy): its numbers are wanted again
            }
            if (status === "ok")
                return
            Notifications.show(pane.statusText(status, pane.labelOf(id)), "warning")
        }
        function onVolumesChanged() {
            pane.syncRows()
            pane.pumpScan(false)
        }
        function onScansChanged() {
            // The first reply of the drive that was asked for has come.
            if (pane.scanPending !== "" && Storage.scans[pane.scanPending] !== undefined)
                pane.scanPending = ""
            pane.syncRows()
            if (Object.values(Storage.scans).some(e => e.status === "busy"))
                busyRetry.restart()
            pane.pumpScan(false)
        }
    }

    Text {
        objectName: "storageHeadingInternal"
        width: parent ? parent.width : 0
        text: qsTr("This console")
        color: Theme.text
        font.pixelSize: Theme.typeBody * pane.u
    }

    UsageRow {
        objectName: "storageInternal"
        onActiveFocusChanged: if (activeFocus) pane.actionFocused = false
        u: pane.u
        label: qsTr("Free space")
        value: pane.freeText()
        fraction: pane.usedFraction()
        low: pane.isLow()
    }

    SettingRow {
        objectName: "storageApps"
        inert: true
        onActiveFocusChanged: if (activeFocus) pane.actionFocused = false
        u: pane.u
        label: qsTr("Apps and games")
        value: pane.sizeText(pane.internal.appsBytes)
    }

    SettingRow {
        objectName: "storageData"
        inert: true
        onActiveFocusChanged: if (activeFocus) pane.actionFocused = false
        visible: pane.dataKnown()
        u: pane.u
        label: qsTr("Profile data")
        value: pane.sizeText(pane.internal.dataBytes)
    }

    SettingRow {
        objectName: "storageSystem"
        inert: true
        onActiveFocusChanged: if (activeFocus) pane.actionFocused = false
        u: pane.u
        label: pane.dataKnown() ? qsTr("System") : qsTr("Other")
        value: pane.sizeText(pane.internal.systemBytes)
    }

    Text {
        objectName: "storageHeadingDrives"
        width: parent ? parent.width : 0
        visible: Storage.volumes.length > 0
        topPadding: Theme.spaceS * pane.u
        text: qsTr("Drives")
        color: Theme.text
        font.pixelSize: Theme.typeBody * pane.u
    }

    Repeater {
        model: rowModel
        SettingRow {
            required property string rowKey
            required property string kind          // "volume" | "scan" | "eject"
            required property string sub           // a scan row: "wait", "cat:games", "other", ...
            required property string volId
            required property string name
            required property string valueText
            required property bool shown
            required property bool removable
            required property bool mounted
            objectName: kind === "volume" ? "storageVol_" + volId
                      : kind === "eject" ? "storageEject_" + volId
                      : "storageScan_" + volId + "_" + sub
            visible: shown
            inert: kind === "scan"
            onActiveFocusChanged: if (activeFocus) pane.actionFocused = kind !== "scan"
            u: pane.u
            // What was found on a drive sits a step in from the drive's own row.
            x: kind === "scan" ? Theme.spaceL * pane.u : 0
            width: parent ? parent.width - x : 0
            label: name
            value: valueText
            onActivated: {
                if (kind === "volume")
                    pane.activate(volId, removable, mounted)
                else if (kind === "eject")
                    pane.ejectVolume(volId)
            }
        }
    }
}
