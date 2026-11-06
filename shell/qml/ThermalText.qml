pragma Singleton
import QtQuick
import RuyaShell

// Words for the console's sensors (Thermal), shared by Settings -> System, the category mark in
// Settings and the heat policy's messages. The service sends an English role and a class; the
// shell names things by class so the words follow the UI language.
QtObject {
    function className(cls) {
        switch (cls) {
        case "cpu": return qsTr("Processor")
        case "gpu": return qsTr("Graphics")
        case "ssd":
        case "hdd": return qsTr("Drive")
        case "fan": return qsTr("Fan")
        }
        return cls
    }

    // "Processor", or "Drive 2" when several sensors share the name (in the service's order).
    function nameOf(id) {
        const list = Thermal.sensors
        const sensor = list.find(s => s.id === id)
        if (!sensor)
            return ""
        const name = className(sensor.cls)
        const same = list.filter(s => className(s.cls) === name)
        return same.length > 1 ? qsTr("%1 %2").arg(name).arg(same.findIndex(s => s.id === id) + 1) : name
    }

    // "41 °C" or "1820 rpm".
    function valueText(sensor) {
        return sensor.cls === "fan" ? qsTr("%1 rpm").arg(Math.round(sensor.value))
                                    : qsTr("%1 °C").arg(Math.round(sensor.value))
    }

    // "" for normal: nothing to say.
    function levelText(level) {
        switch (level) {
        case "warm": return qsTr("Warm")
        case "hot": return qsTr("Hot")
        case "critical": return qsTr("Critical")
        }
        return ""
    }

    // The mark's colour: amber for warm, red from hot on.
    function levelColor(level) {
        return level === "warm" ? Theme.warningText : Theme.errorText
    }
}
