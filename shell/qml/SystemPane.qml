import QtQuick
import RuyaShell

// Settings -> System. The language row writes straight to DeviceSettings, which installs the
// translator and retranslates the UI at once. Language names are shown in their own language.
SettingsPane {
    id: pane

    ChoiceRow {
        id: language
        objectName: "rowLanguage"
        u: pane.u
        label: qsTr("Language")
        options: [
            { value: "en", label: "English" },
            { value: "tr", label: "Türkçe" },
        ]
        onEdited: v => {
            DeviceSettings.language = v
            language.value = DeviceSettings.language
        }
    }
    Binding { target: language; property: "value"; value: DeviceSettings.language }
}
