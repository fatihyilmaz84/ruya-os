pragma Singleton
import QtQuick
import RuyaShell

// The connected controllers as the shell shows them, in one place (RUY-39): the Ruya Hub's
// Controllers panel (02 §1.6) and Settings > Controllers name a pad and say its battery the same
// way. Two sources:
//  - hubPads(): the pads of Devices1 (Bluetooth.gamepads, by Bluetooth address or USB port) with the
//    Bluetooth alias and the battery of UPower or BlueZ (the address match and the like-pad
//    tie-break of T-359);
//  - controllers(): the pads of Input1.ListDevices (stable ids, no address on the bus, 06 §4.1),
//    each matched to the one hub pad with the same kernel name and connection when exactly one of
//    each exists, so it gets the alias and the battery; otherwise its own record's name and battery.
QtObject {
    // Words for a pad's battery (04 §7: the words carry the state, all in `text`).
    // state: "charging" | "full" | "discharging" | "" (UPower's, or the record's).
    function batteryText(percent, state) {
        if (percent < 0)
            return qsTr("Battery not reported")
        if (state === "full")
            return qsTr("Battery full")
        if (state === "charging")
            return qsTr("Battery %1 %, charging").arg(percent)
        if (percent <= 15)
            return qsTr("Battery %1 %, low").arg(percent)
        return qsTr("Battery %1 %").arg(percent)
    }

    // "Bluetooth" | "USB" | "" (another connection has no word).
    function connectionText(connection) {
        return connection === "usb" ? qsTr("USB") : connection === "bluetooth" ? qsTr("Bluetooth") : ""
    }

    // The Hub's pads: [{ id, name, rawName, family, transport, percent, state }], by name then id.
    function hubPads() {
        const batteries = Batteries.devices.filter(b => b.kind === "controller")
        const used = ({})
        const pads = []
        for (const g of Bluetooth.gamepads) {
            const bt = g.transport === "bluetooth"
            const id = bt ? String(g.id).toLowerCase() : g.id
            const paired = bt ? Bluetooth.devices.find(d => String(d.id).toLowerCase() === id) : undefined
            const battery = bt ? batteries.find(b => String(b.address ?? "").toLowerCase() === id) : undefined
            if (battery)
                used[battery.id] = true
            pads.push({ id: id,
                        name: paired ? DeviceIcons.shownName(Bluetooth.devices, paired) : DeviceIcons.plain(g.name),
                        rawName: g.name,
                        family: g.family !== "" ? g.family : (paired ? paired.family : ""),
                        transport: g.transport,
                        percent: battery ? battery.percent : (paired && paired.battery >= 0 ? paired.battery : -1),
                        state: battery ? battery.state : "" })
        }
        for (const p of pads) {
            if (p.transport === "bluetooth" || p.percent >= 0 || p.family === "")
                continue
            const alike = pads.filter(q => q.transport !== "bluetooth" && q.percent < 0 && q.family === p.family)
            const spare = batteries.filter(b => !used[b.id] && String(b.address ?? "") === "" && b.family === p.family)
            if (alike.length === 1 && spare.length === 1) {
                used[spare[0].id] = true
                p.percent = spare[0].percent
                p.state = spare[0].state
            }
        }
        pads.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
        return pads
    }

    // Input1's pads as rows: [{ id, name, family, connection, layout, percent, state, slot }], sorted by
    // player (slot 1..n; none last), then name, then id.
    function controllers() {
        const devices = Input.devices
        const hub = hubPads()
        const key = d => DeviceIcons.plain(d).toLowerCase()
        const out = devices.map(d => {
            const twins = devices.filter(x => x.connection === d.connection && key(x.name) === key(d.name))
            const match = hub.filter(p => p.transport === d.connection && key(p.rawName) === key(d.name))
            const hubPad = twins.length === 1 && match.length === 1 ? match[0] : null
            const own = d.battery >= 0
            return { id: d.id,
                     name: hubPad ? hubPad.name : DeviceIcons.plain(d.name),
                     family: d.family !== "generic" ? d.family : (hubPad ? hubPad.family : ""),
                     connection: d.connection,
                     layout: d.layout ?? "",
                     percent: own ? d.battery : (hubPad ? hubPad.percent : -1),
                     state: own ? (d.charging ? "charging" : (d.battery >= 100 ? "full" : "discharging"))
                                : (hubPad ? hubPad.state : ""),
                     slot: d.slot ?? 0 }
        })
        const rank = s => s > 0 ? s : 1000
        out.sort((a, b) => rank(a.slot) - rank(b.slot) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
                           || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
        return out
    }

    // "Bluetooth · Battery 62 %, charging": the connection word, then the battery (no " · " without a word).
    function detailText(p) {
        const connection = connectionText(p.connection)
        const battery = batteryText(p.percent, p.state)
        return connection === "" ? battery : qsTr("%1 · %2").arg(connection).arg(battery)
    }

    // "Player 2", or "" when the record has no player (slot 0, before T-264).
    function playerText(slot) {
        return slot > 0 ? qsTr("Player %1").arg(slot) : ""
    }
}
