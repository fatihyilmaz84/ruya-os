pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Storage: one row per volume (the internal disk and USB drives) with its
// filesystem and "x GB free of y GB", and an "Eject" row for each mounted removable one. Accept
// on a removable volume moves to its Eject row; on a drive whose filesystem is not supported it
// says why it can't be used. Nothing on a volume is opened or run from here. Everything goes
// through the Storage singleton (org.ruyaos.Devices1.Storage); sizes come from
// Storage.formatBytes. The "safe to remove" and "drive inserted" toasts are in ToastLayer.
SettingsPane {
    id: pane

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

    Component.onCompleted: syncVolumes()

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
            Sfx.back()
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
            Sfx.back()
            Notifications.show(pane.statusText(status, pane.labelOf(id)), "warning")
        }
        function onVolumesChanged() { pane.syncVolumes() }
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
