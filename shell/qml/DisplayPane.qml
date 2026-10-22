import QtQuick
import RuyaShell

// Settings -> Display & motion. Every row writes straight to DeviceSettings, so changes
// apply live; the Bindings keep each row in step with the setting (e.g. a session override).
SettingsPane {
    id: pane

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
            quality.value = DeviceSettings.effectsQuality
        }
    }
    Binding { target: quality; property: "value"; value: DeviceSettings.effectsQuality }

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
}
