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
// says why it can't be used. Nothing on a volume is opened or run from here. Everything goes
// through the Storage singleton (org.ruyaos.Devices1.Storage); sizes come from
// Storage.formatBytes. The "safe to remove" and "drive inserted" toasts are in ToastLayer.
SettingsPane {
    id: pane

    readonly property var internal: Storage.internal
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

    // Rows follow Storage.volumes by id (updated in place), so focus stays on a row when the
    // list is re-published, e.g. after free space changes.
    ListModel { id: volumeModel }

    function syncVolumes() {
        // Where focus is now, to put it on a neighbour if its row goes away (Eject).
        const before = pane.activeFocus ? focusableRows().findIndex(r => r.activeFocus) : -1
        const list = Storage.volumes
        for (let i = volumeModel.count - 1; i >= 0; --i) {
            const id = volumeModel.get(i).volId
            if (!list.some(v => v.id === id))
                volumeModel.remove(i)
        }
        for (let i = 0; i < list.length; ++i) {
            const v = list[i]
            const entry = { volId: v.id, name: v.label, filesystem: v.filesystem, sizeBytes: v.sizeBytes,
                            freeBytes: v.freeBytes, removable: v.removable, mounted: v.mounted, readOnly: v.readOnly }
            let at = -1
            for (let j = 0; j < volumeModel.count; ++j) {
                if (volumeModel.get(j).volId === v.id) {
                    at = j
                    break
                }
            }
            if (at < 0) {
                volumeModel.insert(i, entry)
            } else {
                volumeModel.set(at, entry)
                if (at !== i)
                    volumeModel.move(at, i, 1)
            }
        }
        Qt.callLater(pane.refocus, before)
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

    // Free space changes without a signal: read the numbers when this pane is shown (not when
    // Settings opens: the pane is created then, hidden).
    onVisibleChanged: if (visible) Storage.refreshInternal()

    Component.onCompleted: {
        syncVolumes()
        if (visible)
            Storage.refreshInternal()
    }

    function labelOf(id) {
        for (let i = 0; i < volumeModel.count; ++i) {
            if (volumeModel.get(i).volId === id)
                return volumeModel.get(i).name
        }
        return ""
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
            if (op === "eject" && id === pane.ejectingId)
                pane.ejectingId = ""
            if (status === "ok")
                return
            Notifications.show(pane.statusText(status, pane.labelOf(id)), "warning")
        }
        function onVolumesChanged() { pane.syncVolumes() }
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
        u: pane.u
        label: qsTr("Free space")
        value: pane.freeText()
        fraction: pane.usedFraction()
        low: pane.isLow()
    }

    SettingRow {
        objectName: "storageApps"
        u: pane.u
        label: qsTr("Apps and games")
        value: pane.sizeText(pane.internal.appsBytes)
    }

    SettingRow {
        objectName: "storageData"
        visible: pane.dataKnown()
        u: pane.u
        label: qsTr("Profile data")
        value: pane.sizeText(pane.internal.dataBytes)
    }

    SettingRow {
        objectName: "storageSystem"
        u: pane.u
        label: pane.dataKnown() ? qsTr("System") : qsTr("Other")
        value: pane.sizeText(pane.internal.systemBytes)
    }

    Text {
        objectName: "storageHeadingDrives"
        width: parent ? parent.width : 0
        visible: volumeModel.count > 0
        topPadding: Theme.spaceS * pane.u
        text: qsTr("Drives")
        color: Theme.text
        font.pixelSize: Theme.typeBody * pane.u
    }

    Repeater {
        model: volumeModel
        SettingRow {
            required property string volId
            required property string name
            required property string filesystem
            required property real sizeBytes
            required property real freeBytes
            required property bool removable
            required property bool mounted
            required property bool readOnly
            objectName: "storageVol_" + volId
            u: pane.u
            label: name
            value: pane.volumeValue(filesystem, mounted, readOnly, freeBytes, sizeBytes)
            onActivated: pane.activate(volId, removable, mounted)
        }
    }

    Repeater {
        model: volumeModel
        SettingRow {
            required property string volId
            required property string name
            required property bool removable
            required property bool mounted
            objectName: "storageEject_" + volId
            visible: removable && mounted
            u: pane.u
            label: qsTr("Eject %1").arg(name)
            onActivated: pane.ejectVolume(volId)
        }
    }
}
