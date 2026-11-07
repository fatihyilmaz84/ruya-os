pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The rows of the System information page (T-226) and of its report, built from
// org.ruyaos.Devices1.System (SystemDetails) with the numbers other services already own put next to
// them, never repeated: temperatures (Thermal, T-200), how full the console's storage is (Storage,
// T-196), controller batteries (Batteries, T-223), the connection (Network), outputs (Audio), the
// adapter (Bluetooth) and the update channel (Update).
//
// `sections` is a binding: [{ id, title, rows: [{ uid, key, label, value, raw, sensitive, fraction }] }]
// in the language of the UI, re-evaluated when any source changes (the live values, the language).
// A row exists only when its value is known: absent, never 0. `uid` is stable per row, so the page
// can update rows in place. `sensitive` marks the rows that name this console on a network (MAC, IP,
// Wi-Fi name, Bluetooth address); the report leaves them out unless the user opts in.
// `reportSections(includeAddresses)` is the same in English, for a file that someone else reads.
QtObject {
    id: rows

    readonly property var sections: build(false, true)
    // The same rows by uid, for the page's delegates.
    readonly property var byUid: {
        const out = {}
        for (const s of rows.sections) {
            for (const r of s.rows)
                out[r.uid] = r
        }
        return out
    }

    // The section titles by id, for the page's headings.
    readonly property var titles: {
        const out = {}
        for (const s of rows.sections)
            out[s.id] = s.title
        return out
    }

    // English, without the rows that are sensitive unless asked for. Not a binding.
    function reportSections(includeAddresses) {
        return build(true, includeAddresses)
    }

    // The report as plain text.
    function reportText(includeAddresses) {
        const out = ["RuyaOS system report", ""]
        for (const s of reportSections(includeAddresses)) {
            out.push(s.title)
            for (const r of s.rows)
                out.push("  " + r.label + ": " + r.value)
            out.push("")
        }
        if (!includeAddresses)
            out.push("Network addresses (MAC, IP, Wi-Fi name) are not included.")
        else
            out.push("This report includes network addresses (MAC, IP, Wi-Fi name).")
        return out.join("\n") + "\n"
    }

    // The report as JSON: { report, includesNetworkAddresses, sections: { id: { key: value } } } with
    // the values as the service gave them (numbers stay numbers; sizes are bytes).
    function reportJson(includeAddresses) {
        const sections = {}
        for (const s of reportSections(includeAddresses)) {
            const group = {}
            for (const r of s.rows)
                group[r.key] = r.raw
            sections[s.id] = group
        }
        return JSON.stringify({
            report: "RuyaOS system report",
            includesNetworkAddresses: includeAddresses,
            sections: sections
        }, null, 2) + "\n"
    }

    function sizeText(bytes) {
        return Storage.formatBytes(bytes)
    }

    function uptimeText(seconds, en) {
        const minutes = Math.floor(seconds / 60)
        const days = Math.floor(minutes / 1440)
        const hours = Math.floor((minutes % 1440) / 60)
        const mins = minutes % 60
        if (en) {
            if (days > 0)
                return days + " d " + hours + " h"
            return hours > 0 ? hours + " h " + mins + " min" : mins + " min"
        }
        if (days > 0)
            return qsTr("%1 d %2 h").arg(days).arg(hours)
        return hours > 0 ? qsTr("%1 h %2 min").arg(hours).arg(mins) : qsTr("%1 min").arg(mins)
    }

    function build(en, includeAddresses) {
        const info = SystemDetails.info
        const has = key => info[key] !== undefined && info[key] !== null && info[key] !== ""
        // Text in the language of the UI, or the English source for the report.
        const tx = s => en ? s : qsTr(s)
        const result = []
        let section = null
        const begin = (id, title) => {
            section = { id: id, title: tx(title), rows: [] }
            result.push(section)
        }
        // One row; `value` is the shown text, `raw` what the JSON carries (the service's value).
        const row = (key, label, value, raw, options) => {
            const o = options || {}
            if (o.sensitive && !includeAddresses)
                return
            section.rows.push({
                uid: section.id + "/" + key,
                key: key,
                label: o.plainLabel ? label : tx(label),
                value: value,
                raw: raw === undefined ? value : raw,
                sensitive: o.sensitive === true,
                fraction: o.fraction === undefined ? -1 : o.fraction
            })
        }
        const sensor = cls => Thermal.sensors.find(s => s.cls === cls)
        const degrees = s => en ? Math.round(s.value) + " °C" : qsTr("%1 °C").arg(Math.round(s.value))

        // ---- Console
        begin("console", QT_TR_NOOP("Console"))
        if (has("console.name") || has("console.version")) {
            const text = (has("console.name") ? info["console.name"] : "RuyaOS")
                         + (has("console.version") ? " " + info["console.version"] : "")
            row("version", QT_TR_NOOP("System"), text, text)
        }
        if (Update.channel !== "") {
            const stable = Update.channel !== "beta"
            row("channel", QT_TR_NOOP("Update channel"), stable ? tx(QT_TR_NOOP("Stable")) : tx(QT_TR_NOOP("Beta")), Update.channel)
        }
        if (has("console.image"))
            row("image", QT_TR_NOOP("Image"), info["console.image"])
        if (has("console.image_digest"))
            row("image_digest", QT_TR_NOOP("Image digest"), String(info["console.image_digest"]).slice(0, 19))
        if (has("console.deployment"))
            row("deployment", QT_TR_NOOP("Deployment"), info["console.deployment"])
        if (has("console.kernel"))
            row("kernel", QT_TR_NOOP("Kernel"), info["console.kernel"])
        if (has("console.uptime_s"))
            row("uptime", QT_TR_NOOP("Uptime"), uptimeText(info["console.uptime_s"], en), info["console.uptime_s"])
        if (has("console.installed"))
            row("installed", QT_TR_NOOP("Installed"), info["console.installed"])
        if (has("console.firmware"))
            row("firmware", QT_TR_NOOP("Firmware"), info["console.firmware"] === "uefi" ? "UEFI" : "BIOS", info["console.firmware"])
        if (info["console.secure_boot"] !== undefined)
            row("secure_boot", QT_TR_NOOP("Secure Boot"),
                info["console.secure_boot"] ? tx(QT_TR_NOOP("On")) : tx(QT_TR_NOOP("Off")), info["console.secure_boot"])
        if (has("console.vendor") || has("console.model")) {
            const maker = has("console.vendor") ? info["console.vendor"] : ""
            const model = has("console.model") ? info["console.model"] : ""
            // The model often starts with the maker's name already.
            const text = model.toLowerCase().startsWith(maker.toLowerCase()) ? model : (maker + " " + model).trim()
            row("machine", QT_TR_NOOP("Machine"), text)
        }

        // ---- Processor
        begin("cpu", QT_TR_NOOP("Processor"))
        if (has("cpu.model"))
            row("model", QT_TR_NOOP("Model"), info["cpu.model"])
        if (has("cpu.cores"))
            row("cores", QT_TR_NOOP("Cores"), String(info["cpu.cores"]), info["cpu.cores"])
        if (has("cpu.threads"))
            row("threads", QT_TR_NOOP("Threads"), String(info["cpu.threads"]), info["cpu.threads"])
        if (has("cpu.freq_mhz")) {
            const max = has("cpu.freq_max_mhz") ? info["cpu.freq_max_mhz"] : 0
            const now = info["cpu.freq_mhz"]
            const text = max > 0
                ? (en ? now + " MHz (up to " + max + " MHz)" : qsTr("%1 MHz (up to %2 MHz)").arg(now).arg(max))
                : (en ? now + " MHz" : qsTr("%1 MHz").arg(now))
            row("clock", QT_TR_NOOP("Clock"), text, now)
        } else if (has("cpu.freq_max_mhz")) {
            row("clock_max", QT_TR_NOOP("Highest clock"), en ? info["cpu.freq_max_mhz"] + " MHz" : qsTr("%1 MHz").arg(info["cpu.freq_max_mhz"]), info["cpu.freq_max_mhz"])
        }
        const cpuTemp = sensor("cpu")
        if (cpuTemp)
            row("temperature", QT_TR_NOOP("Temperature"), degrees(cpuTemp), cpuTemp.value)

        // ---- Memory
        begin("memory", QT_TR_NOOP("Memory"))
        if (has("memory.total_bytes"))
            row("total", QT_TR_NOOP("Total"), sizeText(info["memory.total_bytes"]), info["memory.total_bytes"])
        if (has("memory.used_bytes")) {
            const total = has("memory.total_bytes") ? info["memory.total_bytes"] : 0
            row("used", QT_TR_NOOP("In use"), sizeText(info["memory.used_bytes"]), info["memory.used_bytes"],
                { fraction: total > 0 ? Math.min(1, info["memory.used_bytes"] / total) : undefined })
        }
        if (has("memory.available_bytes"))
            row("available", QT_TR_NOOP("Available"), sizeText(info["memory.available_bytes"]), info["memory.available_bytes"])
        if (has("memory.swap_total_bytes")) {
            const used = has("memory.swap_used_bytes") ? info["memory.swap_used_bytes"] : -1
            const text = used >= 0
                ? (en ? sizeText(info["memory.swap_total_bytes"]) + ", " + sizeText(used) + " used"
                      : qsTr("%1, %2 used").arg(sizeText(info["memory.swap_total_bytes"])).arg(sizeText(used)))
                : sizeText(info["memory.swap_total_bytes"])
            row("swap", QT_TR_NOOP("Swap"), text, info["memory.swap_total_bytes"])
        }
        if (has("memory.zram_bytes"))
            row("zram", QT_TR_NOOP("Compressed memory (zram)"), sizeText(info["memory.zram_bytes"]), info["memory.zram_bytes"])

        // ---- Graphics
        begin("graphics", QT_TR_NOOP("Graphics"))
        if (has("graphics.vendor") || has("graphics.model")) {
            const text = ((has("graphics.vendor") ? info["graphics.vendor"] : "") + " "
                          + (has("graphics.model") ? info["graphics.model"] : "")).trim()
            row("gpu", QT_TR_NOOP("Graphics processor"), text)
        }
        if (has("graphics.driver")) {
            const text = info["graphics.driver"] + (has("graphics.driver_version") ? " " + info["graphics.driver_version"] : "")
            row("driver", QT_TR_NOOP("Driver"), text)
        }
        if (has("graphics.mesa_version"))
            row("mesa", QT_TR_NOOP("Mesa"), info["graphics.mesa_version"])
        if (has("graphics.nvidia_version"))
            row("nvidia", QT_TR_NOOP("NVIDIA driver"), info["graphics.nvidia_version"])
        if (has("graphics.api") || has("graphics.renderer")) {
            const text = ((has("graphics.api") ? info["graphics.api"] : "") + " "
                          + (has("graphics.renderer") ? info["graphics.renderer"] : "")).trim()
            row("renderer", QT_TR_NOOP("Renderer"), text)
        }
        {
            const tier = DeviceSettings.effectsQuality
            const names = { high: tx(QT_TR_NOOP("High")), balanced: tx(QT_TR_NOOP("Balanced")), performance: tx(QT_TR_NOOP("Performance")) }
            row("effects", QT_TR_NOOP("Visual effects"), names[tier] ?? tier, tier)
        }
        if (has("graphics.connector"))
            row("connector", QT_TR_NOOP("Display connector"), info["graphics.connector"])
        if (has("display.width") && has("display.height")) {
            const hz = has("display.refresh_hz") ? Math.round(info["display.refresh_hz"] * 10) / 10 : 0
            const text = info["display.width"] + " × " + info["display.height"] + (hz > 0 ? " @ " + hz + " Hz" : "")
            row("mode", QT_TR_NOOP("Resolution"), text)
        } else if (has("graphics.preferred_mode")) {
            row("mode", QT_TR_NOOP("Display's preferred mode"), info["graphics.preferred_mode"])
        }
        const gpuTemp = sensor("gpu")
        if (gpuTemp)
            row("temperature", QT_TR_NOOP("Temperature"), degrees(gpuTemp), gpuTemp.value)

        // ---- Storage
        begin("storage", QT_TR_NOOP("Storage"))
        const drives = info["storage.drives"] ?? []
        const kindName = k => k === "nvme" ? "NVMe" : k === "ssd" ? "SSD" : k === "hdd" ? tx(QT_TR_NOOP("Hard disk")) : k === "emmc" ? "eMMC" : k
        for (let i = 0; i < drives.length; ++i) {
            const d = drives[i]
            const parts = []
            if (d.model)
                parts.push(d.model)
            if (d.type)
                parts.push(kindName(d.type))
            if (d.size_bytes)
                parts.push(sizeText(d.size_bytes))
            const label = drives.length > 1 ? (en ? "Drive " + (i + 1) : qsTr("Drive %1").arg(i + 1)) : tx(QT_TR_NOOP("Drive"))
            section.rows.push({ uid: "storage/drive" + i, key: "drive" + i, label: label, value: parts.join(" · "),
                                raw: d, sensitive: false, fraction: -1 })
            // Health only where the drive reports it (NVMe).
            if (d.health) {
                const word = d.health === "ok" ? tx(QT_TR_NOOP("Healthy")) : tx(QT_TR_NOOP("Failing"))
                section.rows.push({ uid: "storage/drive" + i + "health", key: "drive" + i + "_health",
                                    label: drives.length > 1 ? (en ? "Drive " + (i + 1) + " health" : qsTr("Drive %1 health").arg(i + 1))
                                                              : tx(QT_TR_NOOP("Drive health")),
                                    value: word, raw: d.health, sensitive: false, fraction: -1 })
            }
        }
        if (Storage.internal.valid && Storage.internal.totalBytes > 0) {
            const free = Storage.internal.freeBytes
            const total = Storage.internal.totalBytes
            const used = total - free
            row("free", QT_TR_NOOP("Console storage free"),
                en ? sizeText(free) + " of " + sizeText(total) : qsTr("%1 of %2").arg(sizeText(free)).arg(sizeText(total)),
                { freeBytes: free, totalBytes: total }, { fraction: total > 0 ? Math.min(1, used / total) : undefined })
        }

        // ---- Network
        begin("network", QT_TR_NOOP("Network"))
        {
            const primary = Network.primary
            const connected = Network.state === "connected" || Network.state === "limited"
            if (connected && primary.kind) {
                const wifi = primary.kind === "wifi"
                row("connection", QT_TR_NOOP("Connection"), wifi ? tx(QT_TR_NOOP("Wi-Fi")) : tx(QT_TR_NOOP("Wired")), primary.kind)
                if (wifi && primary.name)
                    row("ssid", QT_TR_NOOP("Wi-Fi network"), primary.name, primary.name, { sensitive: true })
                if (primary.ip)
                    row("ip", QT_TR_NOOP("IP address"), primary.ip, primary.ip, { sensitive: true })
                if (wifi && primary.signal !== undefined)
                    row("signal", QT_TR_NOOP("Signal"), en ? primary.signal + " %" : qsTr("%1 %").arg(primary.signal), primary.signal)
            } else {
                row("connection", QT_TR_NOOP("Connection"), tx(QT_TR_NOOP("Not connected")), "disconnected")
            }
            if (has("network.mac"))
                row("mac", QT_TR_NOOP("MAC address"), info["network.mac"], info["network.mac"], { sensitive: true })
            if (has("network.link_mbps") && connected)
                row("link", QT_TR_NOOP("Link speed"), en ? info["network.link_mbps"] + " Mb/s" : qsTr("%1 Mb/s").arg(info["network.link_mbps"]), info["network.link_mbps"])
        }

        // ---- Bluetooth
        begin("bluetooth", QT_TR_NOOP("Bluetooth"))
        if (has("bluetooth.chipset"))
            row("chipset", QT_TR_NOOP("Adapter"), info["bluetooth.chipset"])
        if (has("bluetooth.usb_id"))
            row("usb_id", QT_TR_NOOP("USB id"), info["bluetooth.usb_id"])
        if (has("bluetooth.address"))
            row("address", QT_TR_NOOP("Address"), info["bluetooth.address"], info["bluetooth.address"], { sensitive: true })
        if (section.rows.length > 0 || Bluetooth.powered)
            row("power", QT_TR_NOOP("Bluetooth"), Bluetooth.powered ? tx(QT_TR_NOOP("On")) : tx(QT_TR_NOOP("Off")), Bluetooth.powered)

        // ---- Audio
        begin("audio", QT_TR_NOOP("Audio"))
        for (const s of Audio.sinks) {
            const text = s.isDefault ? s.name + " (" + tx(QT_TR_NOOP("default")) + ")" : s.name
            row("sink " + s.id, QT_TR_NOOP("Output"), text, s.name)
        }

        // ---- Controllers
        begin("controllers", QT_TR_NOOP("Controllers"))
        {
            const seen = []
            for (const b of Batteries.devices) {
                if (b.kind !== "controller")
                    continue
                seen.push(b.name)
                row("pad " + b.id, b.name, en ? b.percent + " %" : qsTr("%1 %").arg(b.percent), b.percent, { plainLabel: true })
            }
            for (const d of Bluetooth.devices) {
                if (d.kind !== "controller" || !d.connected || seen.includes(d.name))
                    continue
                // The battery when the controller reports one (-1: none).
                const known = d.battery !== undefined && d.battery >= 0
                row("pad " + d.id, d.name,
                    known ? (en ? d.battery + " %" : qsTr("%1 %").arg(d.battery)) : tx(QT_TR_NOOP("Connected")),
                    known ? d.battery : "connected", { plainLabel: true })
            }
        }

        // A section without rows is not shown.
        return result.filter(s => s.rows.length > 0)
    }
}
