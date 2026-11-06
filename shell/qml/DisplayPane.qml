import QtQuick
import RuyaShell

// Settings -> Display & motion. Every row writes straight to DeviceSettings, so changes
// apply live; the Bindings keep each row in step with the setting (e.g. a session override).
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

    WallpaperPicker {
        id: picker
        objectName: "wallpaperPicker"
        parent: pane.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: pane.u
    }
}
