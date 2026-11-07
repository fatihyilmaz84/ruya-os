import QtQuick
import RuyaShell

// Settings -> Display & motion. Every row writes straight to DeviceSettings, so changes
// apply live; the Bindings keep each row in step with the setting (e.g. a session override).
// The last three rows (T-198) belong to the connected screen and come from the Display service:
// Resolution and Refresh rate open a list (ModePicker) and, once chosen, restart the shell on the
// new mode and ask "Keep this resolution?" (ModeConfirm, hosted by the Shell); UI size applies at
// once. They sit after the older rows so that the pane's focus order stays as it was.
SettingsPane {
    id: pane

    property Item overlay        // the shell's modal layer: the wallpaper picker lives there

    ChoiceRow {
        id: quality
        objectName: "rowQuality"
        u: pane.u
        label: qsTr("Effects quality")
        options: [
            { value: "high", label: qsTr("High") },
            { value: "balanced", label: qsTr("Balanced") },
            { value: "performance", label: qsTr("Performance") },
        ]
        onEdited: v => {
            DeviceSettings.effectsQuality = v
            quality.value = DeviceSettings.storedEffectsQuality
        }
    }
    Binding { target: quality; property: "value"; value: DeviceSettings.storedEffectsQuality }

    ToggleRow {
        id: motion
        objectName: "rowReducedMotion"
        u: pane.u
        label: qsTr("Reduced motion")
        onToggled: checked => {
            DeviceSettings.reducedMotion = checked
            motion.checked = DeviceSettings.reducedMotion
        }
    }
    Binding { target: motion; property: "checked"; value: DeviceSettings.reducedMotion }

    SliderRow {
        id: overscan
        objectName: "rowOverscan"
        u: pane.u
        label: qsTr("Screen edge")
        from: 0
        to: 10
        stepSize: 1
        unit: "%"
        onEdited: v => {
            DeviceSettings.overscan = v / 100
            overscan.value = Math.round(DeviceSettings.overscan * 100)
        }
    }
    Binding { target: overscan; property: "value"; value: Math.round(DeviceSettings.overscan * 100) }

    ThemeRow {
        id: themeRow
        objectName: "rowTheme"
        u: pane.u
        label: qsTr("Theme")
        onEdited: v => {
            DeviceSettings.theme = v
            themeRow.value = DeviceSettings.theme
        }
    }
    Binding { target: themeRow; property: "value"; value: DeviceSettings.theme }

    SettingRow {
        id: wallpaper
        objectName: "rowWallpaper"
        u: pane.u
        label: qsTr("Wallpaper")
        value: picker.nameOf(DeviceSettings.wallpaper)
        onActivated: picker.open()
    }

    SliderRow {
        id: dim
        objectName: "rowWallpaperDim"
        u: pane.u
        visible: DeviceSettings.wallpaper !== ""      // the default look has nothing to dim
        label: qsTr("Dim wallpaper")
        from: 0
        to: 60
        stepSize: 5
        unit: "%"
        onEdited: v => {
            DeviceSettings.wallpaperDim = v / 100
            dim.value = Math.round(DeviceSettings.wallpaperDim * 100)
        }
    }
    Binding { target: dim; property: "value"; value: Math.round(DeviceSettings.wallpaperDim * 100) }

    // --- The connected screen (T-198) ---

    readonly property var resolutionEntries: {
        const list = []
        for (const r of Display.resolutions) {
            const notes = []
            if (r.preferred)
                notes.push(qsTr("Recommended"))
            if (r.current)
                notes.push(qsTr("Current"))
            list.push({ key: r.width + "x" + r.height, label: DisplayText.resolutionLabel(r.width, r.height),
                        note: notes.join(" · ") })
        }
        return list
    }
    readonly property var refreshEntries: {
        const list = []
        Display.currentRefreshMhz     // the rates follow the mode in use
        for (const r of Display.refreshRates(Display.currentWidth, Display.currentHeight)) {
            if (r.refreshMhz <= 0)
                continue
            const notes = []
            if (r.preferred)
                notes.push(qsTr("Recommended"))
            if (r.current)
                notes.push(qsTr("Current"))
            list.push({ key: String(r.refreshMhz), label: DisplayText.refreshLabel(r.refreshMhz), note: notes.join(" · ") })
        }
        return list
    }

    SettingRow {
        id: resolution
        objectName: "rowResolution"
        u: pane.u
        visible: Display.available
        label: qsTr("Resolution")
        value: DisplayText.resolutionLabel(Display.currentWidth, Display.currentHeight)
        onActivated: resolutionPicker.open()
    }

    SettingRow {
        id: refresh
        objectName: "rowRefreshRate"
        u: pane.u
        visible: Display.available && pane.refreshEntries.length > 1     // one rate, or none known: nothing to choose
        label: qsTr("Refresh rate")
        value: DisplayText.refreshLabel(Display.currentRefreshMhz)
        onActivated: refreshPicker.open()
    }

    ChoiceRow {
        id: uiSize
        objectName: "rowUiSize"
        u: pane.u
        visible: Display.available
        label: qsTr("UI size")
        options: [
            { value: 0, label: DisplayText.uiScaleLabel(0) },
            { value: 100, label: DisplayText.uiScaleLabel(100) },
            { value: 125, label: DisplayText.uiScaleLabel(125) },
            { value: 150, label: DisplayText.uiScaleLabel(150) },
            { value: 200, label: DisplayText.uiScaleLabel(200) },
        ]
        onEdited: v => {
            Display.setUiScale(v)
            uiSize.value = Display.uiScalePercent
        }
    }
    Binding { target: uiSize; property: "value"; value: Display.uiScalePercent }

    // A mode change restarts the shell, and a running game or app goes with it: ask the owner to
    // close them first instead of losing their unsaved progress.
    function applyMode(apply) {
        if (Session.running.length > 0) {
            Notifications.show(qsTr("Close running games and apps first: changing the screen mode restarts the console."), "warning")
            return
        }
        apply()
    }

    ModePicker {
        id: resolutionPicker
        objectName: "resolutionPicker"
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: pane.u
        title: qsTr("Resolution")
        entries: pane.resolutionEntries
        currentKey: Display.currentWidth + "x" + Display.currentHeight
        onChosen: key => {
            const parts = key.split("x")
            pane.applyMode(() => Display.chooseResolution(parseInt(parts[0]), parseInt(parts[1])))
        }
    }

    ModePicker {
        id: refreshPicker
        objectName: "refreshPicker"
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: pane.u
        title: qsTr("Refresh rate")
        entries: pane.refreshEntries
        currentKey: String(Display.currentRefreshMhz)
        onChosen: key => pane.applyMode(() => Display.chooseRefresh(parseInt(key)))
    }

    Connections {
        target: Display
        function onSetModeFinished(status) {
            // "unchanged" is a pick of what is already in use: nothing to say.
            if (status !== "ok" && status !== "unchanged")
                Notifications.show(qsTr("The screen mode could not be changed."), "error")
        }
    }

    WallpaperPicker {
        id: picker
        objectName: "wallpaperPicker"
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: pane.u
    }
}
