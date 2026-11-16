pragma Singleton
import QtQuick
import RuyaShell

// The SMART state of the internal drives (RUY-737), from the System information's `storage.drives`
// (SystemDetails; the service reads udisks2 and tells the shell when a value changes, so this needs
// no polling). One entry per drive that has a verdict: "ok", "warning" or "failing". A drive whose
// SMART is "unsupported" (the VM's virtio disk) or not known has no entry: nothing is shown for it.
// Shared by Settings -> System (Device health rows, the category's mark) and the failing notice.
QtObject {
    id: health

    // [{ key, model, state, hours?, wear?, temperature? }] in the service's order. `key` is the model
    // and size (and the nth such drive), the same across reads, so rows and the notice follow a drive.
    readonly property var drives: {
        const list = SystemDetails.info["storage.drives"] ?? []
        const seen = {}
        const out = []
        for (const d of list) {
            const base = (d.model ?? "") + "|" + (d.size_bytes ?? 0)
            seen[base] = (seen[base] ?? 0) + 1
            if (d.smart !== "ok" && d.smart !== "warning" && d.smart !== "failing")
                continue
            out.push({ key: base + "#" + seen[base], model: d.model ?? "", state: d.smart,
                       hours: d.power_on_hours, wear: d.wear_percent, temperature: d.temperature_c })
        }
        return out
    }

    // The worst state: "failing", "warning", "ok", or "" without any drive verdict.
    readonly property string worst: {
        if (drives.some(d => d.state === "failing"))
            return "failing"
        if (drives.some(d => d.state === "warning"))
            return "warning"
        return drives.length > 0 ? "ok" : ""
    }

    // A drive turned out to be failing; sent once per drive and run of the shell (the shell starts
    // at boot). `model` is the drive's name as the service gave it.
    signal failing(string model)

    property var notified: ({})

    function check() {
        for (const d of drives) {
            if (d.state === "failing" && !(d.key in notified)) {
                const next = Object.assign({}, notified)
                next[d.key] = true
                notified = next
                failing(d.model)
            }
        }
    }
    onDrivesChanged: check()
    Component.onCompleted: check()

    // "Good", "Check soon" or "Failing": the word beside the mark, so colour is never alone.
    function stateText(state) {
        switch (state) {
        case "ok": return qsTr("Good")
        case "warning": return qsTr("Check soon")
        case "failing": return qsTr("Failing")
        }
        return ""
    }

    // Amber for "Check soon", red for "Failing"; "" has no mark.
    function markColor(state) {
        return state === "warning" ? Theme.warningText : Theme.errorText
    }

    // "Drive", or "Drive 2" when several drives have a verdict, like the sensors.
    function nameOf(index) {
        const name = ThermalText.className("ssd")
        return drives.length > 1 ? qsTr("%1 %2").arg(name).arg(index + 1) : name
    }

    // Whether Thermal measures a drive itself (drivetemp, NVMe): then the SMART temperature is not
    // repeated.
    readonly property bool thermalHasDrive: Thermal.sensors.some(s => s.cls === "ssd" || s.cls === "hdd")

    // The row's second line: the model, and the SMART temperature where Thermal has no drive sensor.
    function detailOf(d) {
        const parts = []
        if (d.model !== "")
            parts.push(d.model)
        if (!thermalHasDrive && d.temperature !== undefined)
            parts.push(qsTr("%1 °C").arg(d.temperature))
        return parts.length === 2 ? qsTr("%1 · %2").arg(parts[0]).arg(parts[1]) : parts.join("")
    }
}
