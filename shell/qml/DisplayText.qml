pragma Singleton
import QtQuick

// The words for a screen mode and the UI size, shared by the Display pane, its pickers and the
// "Keep this resolution?" dialog (T-198). Functions, not a model: the labels follow the language.
QtObject {
    // "3840 × 2160"
    function resolutionLabel(width, height) {
        return qsTr("%1 × %2").arg(width).arg(height)
    }

    // 60000 -> "60 Hz", 59940 -> "59.94 Hz", 0 (the display does not say) -> "".
    function refreshLabel(refreshMhz) {
        if (refreshMhz <= 0)
            return ""
        const hz = refreshMhz % 1000 === 0 ? String(refreshMhz / 1000)
                                           : (refreshMhz / 1000).toFixed(2).replace(/0+$/, "")
        return qsTr("%1 Hz").arg(hz)
    }

    // "3840 × 2160, 60 Hz", or just the size when the rate is unknown.
    function modeLabel(width, height, refreshMhz) {
        const size = resolutionLabel(width, height)
        const rate = refreshLabel(refreshMhz)
        return rate.length > 0 ? qsTr("%1, %2").arg(size).arg(rate) : size
    }

    // The UI size choices: 0 is Auto.
    function uiScaleLabel(percent) {
        return percent === 0 ? qsTr("Auto") : qsTr("%1 %").arg(percent)
    }
}
