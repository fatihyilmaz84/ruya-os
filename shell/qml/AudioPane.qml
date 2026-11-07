pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Audio: pick the output (Accept makes it the default), the master level, the
// three channel levels (UI sounds, Ambient, Media), the Ambient switch, Mute and the sound theme
// (T-227: the bundled one or a copy, and the themes found on a USB drive). Everything goes through the
// Audio singleton (org.ruyaos.Devices1.Audio), so changes apply live; the Bindings keep each
// row in step with the service, e.g. after the volume keys or a hot-plugged headset.
SettingsPane {
    id: pane

    // The output rows follow Audio.sinks by id (updated in place), so focus stays on a row
    // when the list is re-published, e.g. after choosing an output.
    ListModel { id: sinkModel }

    function syncSinks() {
        const list = Audio.sinks
        for (let i = sinkModel.count - 1; i >= 0; --i) {
            const id = sinkModel.get(i).sinkId
            if (!list.some(s => s.id === id))
                sinkModel.remove(i)
        }
        for (let i = 0; i < list.length; ++i) {
            const s = list[i]
            const entry = { sinkId: s.id, sinkName: s.name, sinkDefault: s.isDefault }
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
    // The first output is where focus lands when the pane is first entered (the base pane
    // picks the first row it finds, which is a slider while the list is still empty).
    Component.onCompleted: {
        syncSinks()
        const first = sinkRepeater.itemAt(0)
        if (first)
            first.focus = true
        pane.refreshThemes()
    }

    // The sound themes on USB drives follow the drives in place, like the outputs, so focus stays on a
    // row when a stick comes or goes. Each is a row of its own: copying one while only browsing the
    // choice row would be a surprise.
    ListModel { id: driveModel }
    function usbMounts() {
        return Storage.volumes.filter(v => v.mounted && v.removable && v.mountPoint.length > 0).map(v => v.mountPoint)
    }
    function refreshThemes() { SoundThemes.refresh(pane.usbMounts()) }
    function syncDriveThemes() {
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
        Qt.callLater(pane.settleFocus)
    }
    // The choice row lists the themes the console holds: the bundled one and the copies.
    readonly property var themeOptions: SoundThemes.themes.filter(t => t.kind !== "drive").map(t => ({ value: t.id, label: t.name }))
    Connections {
        target: SoundThemes
        function onThemesChanged() { pane.syncDriveThemes() }
        function onImportFinished(status, id) {
            if (status === "ok") {
                DeviceSettings.soundTheme = id
                const t = SoundThemes.themes.find(e => e.id === id)
                Notifications.show(qsTr("Sound theme: %1").arg(t ? t.name : id), "success")
            } else {
                Notifications.show(status === "limit" ? qsTr("Too many sound themes are saved on this console.")
                                                       : qsTr("That sound theme could not be used."), "warning")
            }
        }
    }
    Connections {
        target: Storage
        function onVolumesChanged() { pane.refreshThemes() }
    }
    Connections {
        target: Audio
        function onSinksChanged() { pane.syncSinks() }
        function onSetDefaultSinkFinished(id, status) {
            if (status !== "ok") {
                Notifications.show(qsTr("Could not switch the audio output."), "warning")
            }
        }
    }

    Repeater {
        id: sinkRepeater
        model: sinkModel
        SettingRow {
            required property string sinkId
            required property string sinkName
            required property bool sinkDefault
            objectName: "sink_" + sinkId
            u: pane.u
            label: sinkName
            value: sinkDefault ? qsTr("Default") : ""
            onActivated: Audio.setDefaultSink(sinkId)
        }
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

    Repeater {
        model: driveModel
        SettingRow {
            required property string themeId
            required property string themeName
            required property string themePath
            objectName: "driveTheme_" + themeId
            u: pane.u
            label: qsTr("Use “%1” from the USB drive").arg(themeName)
            value: SoundThemes.importState === "copying" ? qsTr("Copying…") : ""
            onActivated: {
                if (SoundThemes.importState !== "copying")
                    SoundThemes.importTheme(themePath)
            }
        }
    }
}
