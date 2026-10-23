pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Audio: pick the output (Accept makes it the default), the master level, the
// three channel levels (UI sounds, Ambient, Media) and Mute. Everything goes through the
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
    }
    Connections {
        target: Audio
        function onSinksChanged() { pane.syncSinks() }
        function onSetDefaultSinkFinished(id, status) {
            if (status !== "ok") {
                Sfx.back()
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
}
