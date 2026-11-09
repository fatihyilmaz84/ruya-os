pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Audio: pick the output (Accept makes it the default), the master level, the
// three channel levels (UI sounds, Ambient, Media), the Ambient switch, Mute and the sound theme
// (T-227: the bundled one or a copy, and the themes found on a USB drive; T-294: a copy can be deleted, and
// a drive theme the checker refused says why). Everything goes through the
// Audio singleton (org.ruyaos.Devices1.Audio), so changes apply live; the Bindings keep each
// row in step with the service, e.g. after the volume keys or a hot-plugged headset.
SettingsPane {
    id: pane

    property Item overlay      // where the confirmation of "Delete" is parented

    // The output rows follow Audio.outputs by id (updated in place), so focus stays on a row
    // when the list is re-published, e.g. after choosing an output (T-348).
    ListModel { id: sinkModel }

    function syncSinks() {
        const list = Audio.outputs
        for (let i = sinkModel.count - 1; i >= 0; --i) {
            const id = sinkModel.get(i).sinkId
            if (!list.some(s => s.id === id))
                sinkModel.remove(i)
        }
        for (let i = 0; i < list.length; ++i) {
            const s = list[i]
            const entry = { sinkId: s.id, sinkName: s.name, sinkKind: s.kind, sinkAvailable: s.available,
                            sinkActive: s.active, sinkDefault: s.isDefault }
            let at = -1
            for (let j = 0; j < sinkModel.count; ++j) {
                if (sinkModel.get(j).sinkId === s.id) {
                    at = j
                    break
                }
            }
            if (at < 0) {
                sinkModel.insert(i, entry)
            } else {
                sinkModel.set(at, entry)
                if (at !== i)
                    sinkModel.move(at, i, 1)
            }
        }
        Qt.callLater(pane.settleFocus)   // the focused row may have been removed
    }
    // The icon of an output: a name from the bundled set (the kinds without a glyph of their own share the speaker's).
    function outputIcon(kind) {
        switch (kind) {
        case "headphones": return "headphones"
        case "bluetooth": return "bluetooth"
        case "speaker": return "speaker"
        }
        return "volume_up"
    }
    // What the value of an output row says: why it cannot be used, else "Current" for the default.
    function outputValue(active, available, isDefault) {
        if (available === "no")
            return qsTr("Not connected")
        if (!active)
            return qsTr("Not available now")
        return isDefault ? qsTr("Current") : ""
    }
    // The output the Test sound row plays on: the one whose row had focus last (the default before any did).
    property string focusedOutputId: ""
    readonly property string testOutputId: pane.focusedOutputId.length > 0 && Audio.outputs.some(o => o.id === pane.focusedOutputId)
                                           ? pane.focusedOutputId : Audio.defaultSink
    readonly property string testOutputName: {
        const o = Audio.outputs.find(e => e.id === pane.testOutputId)
        return o ? o.name : ""
    }
    // The first output is where focus lands when the pane is first entered (the base pane
    // picks the first row it finds, which is a slider while the list is still empty).
    Component.onCompleted: {
        syncSinks()
        const first = sinkRepeater.itemAt(0)
        if (first)
            first.focus = true
        Qt.callLater(pane.refreshThemes)     // off the frame that builds the pane (T-349)
    }

    // The sound themes on USB drives follow the drives in place, like the outputs, so focus stays on a
    // row when a stick comes or goes. Each is a row of its own: copying one while only browsing the
    // choice row would be a surprise.
    ListModel { id: driveModel }
    // The toast for a copy that did not happen: the first thing wrong, in plain words (SoundThemeText).
    function importFailure(status, problems) {
        switch (status) {
        case "limit":
            return qsTr("The console keeps up to %1 sound themes. Delete one first, or copy over one with the same name to replace it.").arg(SoundThemes.installedLimit)
        case "too-many-files":
            return qsTr("That sound theme has more than %1 files.").arg(SoundThemes.maxCopyFiles)
        case "too-large":
            return qsTr("That sound theme is larger than %1 MB.").arg(SoundThemes.maxCopyMb)
        case "invalid":
            return qsTr("That sound theme can't be used. %1.").arg(SoundThemeText.describe(problems))
        }
        return qsTr("That sound theme could not be used.")
    }
    function usbMounts() {
        return Storage.volumes.filter(v => v.mounted && v.removable && v.mountPoint.length > 0).map(v => v.mountPoint)
    }
    function refreshThemes() { SoundThemes.refresh(pane.usbMounts()) }
    // The path of the drive theme being copied: only its row says "Copying…".
    property string copyingPath: ""
    function driveRowHasFocus() {
        for (const repeater of [driveRepeater, refusedRepeater]) {
            for (let i = 0; i < repeater.count; ++i) {
                if (repeater.itemAt(i)?.activeFocus)
                    return true
            }
        }
        return false
    }
    // After the drive rows changed: when the row that had focus has gone, focus goes to the Sound theme row
    // (the nearest row above), not to the first row of the pane.
    // (A second change right after the first must not forget that a drive row had focus: Qt.callLater keeps
    // only the arguments of the last call, so the fact is a property.)
    property bool driveFocusLost: false
    function afterDriveSync() {
        const lost = pane.driveFocusLost
        pane.driveFocusLost = false
        pane.reflow()                    // rows came or went (drive rows, Delete): lay the column out now (SettingsPane.reflow)
        if (lost && pane.activeFocus && !pane.driveRowHasFocus() && themeRow.visible && themeRow.enabled)
            themeRow.forceActiveFocus()
        else
            pane.settleFocus()
    }
    function syncDriveThemes() {
        if (pane.driveRowHasFocus())
            pane.driveFocusLost = true
        const list = SoundThemes.themes.filter(t => t.kind === "drive")
        for (let i = driveModel.count - 1; i >= 0; --i) {
            const id = driveModel.get(i).themeId
            if (!list.some(t => t.id === id))
                driveModel.remove(i)
        }
        for (let i = 0; i < list.length; ++i) {
            const t = list[i]
            let at = -1
            for (let j = 0; j < driveModel.count; ++j) {
                if (driveModel.get(j).themeId === t.id)
                    at = j
            }
            if (at < 0)
                driveModel.insert(i, { themeId: t.id, themeName: t.name, themePath: t.path })
        }
        // The folders the checker refused: a row each, saying why.
        const refused = SoundThemes.driveProblems
        for (let i = refusedModel.count - 1; i >= 0; --i) {
            const id = refusedModel.get(i).refusedId
            if (!refused.some(p => p.id === id))
                refusedModel.remove(i)
        }
        for (let i = 0; i < refused.length; ++i) {
            const p = refused[i]
            let at = -1
            for (let j = 0; j < refusedModel.count; ++j) {
                if (refusedModel.get(j).refusedId === p.id)
                    at = j
            }
            if (at < 0)
                refusedModel.insert(i, { refusedId: p.id, folder: p.folder, firstProblem: p.problems.length > 0 ? p.problems[0] : "" })
        }
        Qt.callLater(pane.afterDriveSync)
    }
    ListModel { id: refusedModel }
    // A folder name from a drive, short enough for the row (it can be 64 characters).
    function shortName(name) { return name.length > 24 ? name.slice(0, 23) + "…" : name }
    // The choice row lists the themes the console holds: the bundled one and the copies.
    readonly property var themeOptions: SoundThemes.themes.filter(t => t.kind !== "drive").map(t => ({ value: t.id, label: t.name }))
    Connections {
        target: SoundThemes
        function onThemesChanged() { pane.syncDriveThemes() }
        function onImportFinished(status, id, problems) {
            pane.copyingPath = ""
            if (status === "ok") {
                DeviceSettings.soundTheme = id
                const t = SoundThemes.themes.find(e => e.id === id)
                Notifications.show(qsTr("Sound theme: %1").arg(t ? t.name : id), "success")
            } else {
                Notifications.show(pane.importFailure(status, problems), "warning")
            }
        }
    }
    Connections {
        target: Storage
        function onVolumesChanged() { pane.refreshThemes() }
    }
    Connections {
        target: Audio
        function onOutputsChanged() { pane.syncSinks() }
        function onSetOutputFinished(id, status) {
            if (status !== "ok")
                Notifications.show(qsTr("Could not switch the audio output."), "warning")
        }
        function onTestOutputFinished(id, status) {
            if (status !== "ok")
                Notifications.show(qsTr("Could not play the test sound."), "warning")
        }
    }

    Repeater {
        id: sinkRepeater
        model: sinkModel
        SettingRow {
            required property string sinkId
            required property string sinkName
            required property string sinkKind
            required property string sinkAvailable
            required property bool sinkActive
            required property bool sinkDefault
            objectName: "sink_" + sinkId
            u: pane.u
            label: sinkName
            iconName: pane.outputIcon(sinkKind)
            dimmed: !sinkActive
            value: pane.outputValue(sinkActive, sinkAvailable, sinkDefault)
            onActiveFocusChanged: if (activeFocus) pane.focusedOutputId = sinkId
            onActivated: {
                if (!sinkActive)
                    Notifications.show(qsTr("%1: %2.").arg(sinkName).arg(value), "warning")
                else
                    Audio.setOutput(sinkId)
            }
        }
    }

    // Plays a short tone on the output whose row was focused last, without choosing it.
    SettingRow {
        id: testSound
        objectName: "rowTestSound"
        u: pane.u
        visible: Audio.outputs.length > 0
        label: qsTr("Test sound")
        iconName: "volume_up"
        value: pane.testOutputName
        onActivated: Audio.testOutput(pane.testOutputId)
    }

    SliderRow {
        id: master
        objectName: "rowMaster"
        u: pane.u
        label: qsTr("Master volume")
        from: 0
        to: 100
        stepSize: 5
        unit: "%"
        onEdited: v => Audio.setVolume(v)
    }
    Binding { target: master; property: "value"; value: Audio.volume }

    SliderRow {
        id: uiVolume
        objectName: "rowUiSounds"
        u: pane.u
        label: qsTr("UI sounds")
        from: 0
        to: 100
        stepSize: 5
        unit: "%"
        onEdited: v => Audio.setChannelVolume("ui", v)
    }
    Binding { target: uiVolume; property: "value"; value: Audio.channelVolumes.ui ?? 100 }

    SliderRow {
        id: ambient
        objectName: "rowAmbient"
        u: pane.u
        label: qsTr("Ambient")
        from: 0
        to: 100
        stepSize: 5
        unit: "%"
        onEdited: v => Audio.setChannelVolume("ambient", v)
    }
    Binding { target: ambient; property: "value"; value: Audio.channelVolumes.ambient ?? 100 }

    ToggleRow {
        id: ambientSwitch
        objectName: "rowAmbientSound"
        u: pane.u
        label: qsTr("Ambient sound")
        onToggled: checked => DeviceSettings.ambientSound = checked
    }
    Binding { target: ambientSwitch; property: "checked"; value: DeviceSettings.ambientSound }

    SliderRow {
        id: media
        objectName: "rowMedia"
        u: pane.u
        label: qsTr("Media")
        from: 0
        to: 100
        stepSize: 5
        unit: "%"
        onEdited: v => Audio.setChannelVolume("media", v)
    }
    Binding { target: media; property: "value"; value: Audio.channelVolumes.media ?? 100 }

    ToggleRow {
        id: mute
        objectName: "rowMute"
        u: pane.u
        label: qsTr("Mute")
        onToggled: checked => Audio.setMuted(checked)
    }
    Binding { target: mute; property: "checked"; value: Audio.muted }

    ChoiceRow {
        id: themeRow
        objectName: "rowSoundTheme"
        u: pane.u
        label: qsTr("Sound theme")
        options: pane.themeOptions
        onEdited: v => DeviceSettings.soundTheme = v
    }
    // The theme that plays (the bundled one when the chosen one cannot be used).
    Binding { target: themeRow; property: "value"; value: SoundThemes.activeId }

    // The chosen theme when it is a copy (the bundled theme cannot be deleted); Delete is offered only then.
    readonly property var savedTheme: SoundThemes.themes.find(t => t.kind === "installed" && t.id === SoundThemes.activeId)
    SettingRow {
        id: deleteRow
        objectName: "rowDeleteSoundTheme"
        u: pane.u
        visible: pane.savedTheme !== undefined
        label: pane.savedTheme ? qsTr("Delete “%1”").arg(pane.savedTheme.name) : ""
        onActivated: pane.askDelete()
    }
    function askDelete() {
        const t = pane.savedTheme
        if (!t)
            return
        pane.deletingId = t.id
        deleteSlot.active = true
        deleteConfirm.customTitle = qsTr("Delete “%1”?").arg(t.name)
        deleteConfirm.detail = qsTr("You can copy it again from a USB drive.")
        deleteConfirm.customConfirmName = qsTr("Delete “%1”").arg(t.name)
        deleteConfirm.open("custom")
    }
    // The theme the confirmation is for; the confirmation is built when it first opens (T-349).
    property string deletingId: ""
    Loader {
        id: deleteSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            PowerConfirm {
                objectName: "soundDeleteConfirm"
                u: pane.u
                onConfirmed: {
                    // The setting first (so nothing holds on to the folder), then the folder; the bundled theme plays,
                    // quietly: no cue and no toast. Focus goes to the Sound theme row, the nearest row that is left.
                    if (DeviceSettings.soundTheme === pane.deletingId)
                        DeviceSettings.soundTheme = SoundThemes.bundledId
                    SoundThemes.removeTheme(pane.deletingId)
                    themeRow.forceActiveFocus()
                }
            }
        }
    }
    readonly property PowerConfirm deleteConfirm: deleteSlot.item as PowerConfirm

    Repeater {
        id: driveRepeater
        model: driveModel
        SettingRow {
            required property string themeId
            required property string themeName
            required property string themePath
            objectName: "driveTheme_" + themeId
            u: pane.u
            label: qsTr("Use “%1” from the USB drive").arg(themeName)
            value: SoundThemes.importState === "copying" && pane.copyingPath === themePath ? qsTr("Copying…") : ""
            onActivated: {
                if (SoundThemes.importState !== "copying") {
                    pane.copyingPath = themePath
                    SoundThemes.importTheme(themePath)
                }
            }
        }
    }

    // A theme on the drive that the checker refused: the row says why; Accept says it again as a toast (a long
    // reason can run past the row).
    Repeater {
        id: refusedRepeater
        model: refusedModel
        SettingRow {
            required property string refusedId
            required property string folder
            required property string firstProblem
            objectName: "driveRefused_" + refusedId
            u: pane.u
            label: qsTr("Can't use “%1”").arg(pane.shortName(folder))
            value: SoundThemeText.describe(firstProblem)
            onActivated: Notifications.show(qsTr("“%1” can't be used. %2.").arg(pane.shortName(folder)).arg(SoundThemeText.describe(firstProblem)), "warning")
        }
    }
}
