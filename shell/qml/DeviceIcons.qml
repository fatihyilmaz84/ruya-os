pragma Singleton
import QtQuick

// What a wireless device looks like and what it is called in words (T-199, 04 §3.7): the one place
// that maps the contract's `kind` and `family` (Devices1.Bluetooth.ListDevices, Devices1.Batteries)
// to an icon name from the bundled font and to an accessible word. The Bluetooth pane, the status
// cluster's battery chips and the device toasts all ask here, so a new kind is added once.
//
// An unknown kind (a newer service) is the generic Bluetooth glyph and the word "device"; a
// controller of an unknown or missing family is the generic gamepad. The three family glyphs are our
// own silhouettes (`scripts/add-pad-glyphs.py`), not vendor art.
QtObject {
    id: icons

    // The icon name for a device. `family` only matters for a controller.
    function iconFor(kind, family) {
        switch (kind) {
        case "controller":
            switch (family) {
            case "playstation": return "pad_playstation"
            case "xbox": return "pad_xbox"
            case "nintendo": return "pad_switch"
            }
            return "sports_esports"
        case "headset": return "headphones"
        case "speaker": return "speaker"
        case "keyboard": return "keyboard"
        case "mouse": return "mouse"
        case "phone": return "smartphone"
        }
        return "bluetooth"
    }

    // A name a device gave itself, made fit for one line: control characters (a newline), bidirectional
    // controls and zero-width characters become nothing, runs of white space one space. It is still
    // text from outside: draw it with `textFormat: Text.PlainText`, never as markup.
    // Keep in step with `pairing::clean_name` / `is_format_char` (services/ruya-devices/src/pairing.rs).
    function plain(raw) {
        let out = ""
        for (const ch of String(raw ?? "")) {
            const c = ch.codePointAt(0)
            const hidden = c < 32 || (c >= 127 && c <= 159) || c === 0xad || c === 0x61c || c === 0x180e
                           || (c >= 0x200b && c <= 0x200f) || (c >= 0x202a && c <= 0x202e)
                           || (c >= 0x2060 && c <= 0x206f) || c === 0xfeff
            out += hidden ? " " : ch
        }
        return out.replace(/ +/g, " ").trim()
    }

    // The end of a Bluetooth address, the part that tells two like pads apart ("00:05"). An id that
    // is not an address (the mock's) gives its last five characters.
    function addressTail(id) {
        const text = String(id ?? "")
        const m = /([0-9A-Fa-f]{2}:[0-9A-Fa-f]{2})$/.exec(text)
        return m ? m[1].toUpperCase() : text.slice(-5)
    }

    // The name a list or a toast shows for the device `d` of `list` (T-334): its alias; when another
    // device of the list has the same alias (two DualSense pads are both "Wireless Controller"), the
    // end of its address is added so the two can be told apart: "Wireless Controller (00:05)". The
    // alias itself, which the user edits, is never changed.
    function shownName(list, d) {
        const name = plain(d.name)
        const key = name.toLowerCase()
        const twins = list.filter(x => plain(x.name).toLowerCase() === key).length
        if (twins <= 1)
            return name
        // The tail goes in first and the name last, as functions: an alias that contains "%2" or "$&"
        // must come out as typed (QString.arg() would read it as the next placeholder).
        const tail = addressTail(d.id)
        return qsTr("%1 (%2)").replace("%2", () => tail).replace("%1", () => name)
    }

    // What to call a pad that connected: the alias of the Bluetooth device with that address (what the
    // user renamed it to; the end of its address is added when another device has the same name),
    // else the family's words, else the name the pad gave itself.
    function padName(id, name, family) {
        const wanted = String(id).toLowerCase()
        const paired = Bluetooth.devices.find(d => d.id.toLowerCase() === wanted)
        if (paired)
            return shownName(Bluetooth.devices, paired)
        if (family !== "")
            return kindText("controller", family)
        return plain(name)
    }

    // What to call a device in the battery chips and in "More devices" (T-359): the alias of the Bluetooth
    // device with the address the service gave (the name the user chose, with the end of its address
    // when another device has the same name, like the Bluetooth pane), else the name UPower gave, with
    // the end of its address when another battery of the same name has one. A battery without an address
    // (a wired pad) keeps its name.
    function batteryName(d) {
        const address = String(d.address ?? "")
        if (address === "")
            return plain(d.name)
        const wanted = address.toLowerCase()
        const paired = Bluetooth.devices.find(x => x.id.toLowerCase() === wanted)
        if (paired)
            return shownName(Bluetooth.devices, paired)
        const withAddress = Batteries.devices.filter(x => String(x.address ?? "") !== "")
                                    .map(x => ({ id: x.address, name: x.name }))
        return shownName(withAddress, { id: address, name: d.name })
    }

    // The kind in words, for a screen reader and for text ("PlayStation controller", "Headset").
    function kindText(kind, family) {
        switch (kind) {
        case "controller":
            switch (family) {
            case "playstation": return qsTr("PlayStation controller")
            case "xbox": return qsTr("Xbox controller")
            case "nintendo": return qsTr("Nintendo controller")
            case "8bitdo": return qsTr("8BitDo controller")
            }
            return qsTr("Controller")
        case "headset": return qsTr("Headset")
        case "speaker": return qsTr("Speaker")
        case "keyboard": return qsTr("Keyboard")
        case "mouse": return qsTr("Mouse")
        case "phone": return qsTr("Phone")
        }
        return qsTr("Bluetooth device")
    }
}
