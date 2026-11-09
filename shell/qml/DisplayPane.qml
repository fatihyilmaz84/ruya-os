pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Display & motion. Every row writes straight to DeviceSettings, so changes
// apply live; the Bindings keep each row in step with the setting (e.g. a session override).
// The last rows (T-198) belong to the connected screen and come from the Display service:
// Resolution and Refresh rate (only while a screen is known) open a list (ModePicker) and, once
// chosen, restart the shell on the new mode and ask "Keep this resolution?" (ModeConfirm, hosted by
// the Shell); UI size applies at once, and Reset display settings (these two are always there, so a
// size that is too big can be undone even where the service sees no screen) puts the preferred mode
// and Auto back. They sit after the older rows so that the pane's focus order stays as it was.
SettingsPane {
    id: pane

    property Item overlay        // the shell's modal layer: the wallpaper picker lives there

    // The pickers are built when each first opens (T-349). Until the wallpaper picker is built, the
    // pane looks for pictures on the USB drives in its place (when it is first shown and whenever the
    // volumes change), as when the picker was built with the pane, so "Add from USB drive…" is there
    // on the picker's first opening; once built, the picker does it itself.
    function scanUsbPictures() {
        Wallpapers.scanUsb(Storage.volumes.filter(v => v.mounted && v.removable && v.mountPoint.length > 0).map(v => v.mountPoint))
    }
    Component.onCompleted: Qt.callLater(scanUsbPictures)
    Connections {
        target: Storage
        function onVolumesChanged() {
            if (!pane.picker)
                pane.scanUsbPictures()
        }
    }

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
        value: DisplayText.wallpaperName(DeviceSettings.wallpaper)
        onActivated: {
            pickerSlot.active = true
            pane.picker.open()
        }
    }

    // The least dim the current picture needs for legible text under the current theme (04 §3, T-208).
    function requiredWallpaperDim() {
        let entry = ({})
        for (const list of [Wallpapers.bundled, Wallpapers.user]) {
            for (const w of list) {
                if (w.id === DeviceSettings.wallpaper)
                    entry = w
            }
        }
        return Wallpapers.requiredDim(entry.peak ?? 0, entry.floor ?? 0, Theme.background, Theme.text)
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
        // The dim that is applied: the larger of the slider and the legibility rule for this picture
        // under this theme (WallpaperLayer.effectiveDim without the page-blur tier rule).
        shownValue: Math.max(value, pane.requiredWallpaperDim() * 100)
        // Said when the picture raises the dim: Left/Right then move the slider and nothing visible (T-312).
        caption: shownValue > value ? qsTr("Raised for this picture") : ""
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
        onActivated: {
            resolutionSlot.active = true
            pane.resolutionPicker.open()
        }
    }

    SettingRow {
        id: refresh
        objectName: "rowRefreshRate"
        u: pane.u
        visible: Display.available && pane.refreshEntries.length > 1     // one rate, or none known: nothing to choose
        label: qsTr("Refresh rate")
        value: DisplayText.refreshLabel(Display.currentRefreshMhz)
        onActivated: {
            refreshSlot.active = true
            pane.refreshPicker.open()
        }
    }

    ChoiceRow {
        id: uiSize
        objectName: "rowUiSize"
        u: pane.u
        // Always there: a stored 150 % must stay changeable on a screen that reports nothing.
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

    SettingRow {
        id: resetRow
        objectName: "rowResetDisplay"
        u: pane.u
        label: qsTr("Reset display settings")
        onActivated: {
            // The mode goes back to the preferred one at the next start, which restarts the shell.
            if (Display.available && !Display.currentIsPreferred)
                pane.applyMode(() => Display.resetSettings())
            else
                Display.resetSettings()
        }
    }

    // A mode change restarts the shell, and a running game or app goes with it: ask the owner to
    // close them first instead of losing their unsaved progress.
    function applyMode(apply) {
        if (Session.running.length > 0) {
            Notifications.show(qsTr("Close running games and apps first: changing the screen mode restarts the console."), "warning")
            return
        }
        apply()
    }

    Loader {
        id: resolutionSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            ModePicker {
                objectName: "resolutionPicker"
                u: pane.u
                title: qsTr("Resolution")
                entries: pane.resolutionEntries
                currentKey: Display.currentWidth + "x" + Display.currentHeight
                onChosen: key => {
                    const parts = key.split("x")
                    pane.applyMode(() => Display.chooseResolution(parseInt(parts[0]), parseInt(parts[1])))
                }
            }
        }
    }
    readonly property ModePicker resolutionPicker: resolutionSlot.item as ModePicker

    Loader {
        id: refreshSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            ModePicker {
                objectName: "refreshPicker"
                u: pane.u
                title: qsTr("Refresh rate")
                entries: pane.refreshEntries
                currentKey: String(Display.currentRefreshMhz)
                onChosen: key => pane.applyMode(() => Display.chooseRefresh(parseInt(key)))
            }
        }
    }
    readonly property ModePicker refreshPicker: refreshSlot.item as ModePicker

    Connections {
        target: Display
        function onSetModeFinished(status) {
            // "unchanged" is a pick of what is already in use: nothing to say.
            if (status === "busy")
                Notifications.show(qsTr("Try again in a minute: the console has just restarted several times."), "warning")
            else if (status !== "ok" && status !== "unchanged")
                Notifications.show(qsTr("The screen mode could not be changed."), "error")
        }
        function onResetFinished(status) {
            if (status === "busy")
                Notifications.show(qsTr("Try again in a minute: the console has just restarted several times."), "warning")
            else if (status === "failed")
                Notifications.show(qsTr("The display settings could not be reset."), "error")
            else
                Notifications.show(qsTr("Display settings reset."), "info")
        }
    }

    Loader {
        id: pickerSlot
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        active: false
        sourceComponent: Component {
            WallpaperPicker {
                objectName: "wallpaperPicker"
                u: pane.u
            }
        }
    }
    readonly property WallpaperPicker picker: pickerSlot.item as WallpaperPicker
}
