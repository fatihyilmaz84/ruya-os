pragma Singleton
import QtQuick

// What a wireless device looks like and what it is called in words (T-199, 04 §3.7): the one place
// that maps the contract's `kind`, `family` and `model` (Devices1.Bluetooth.ListDevices, ListGamepads,
// Devices1.Batteries, Input1 device records) to an icon name from the bundled font and to an accessible
// word. The Bluetooth pane, the status cluster's battery chips, Settings > Controllers, the controller
// page and the device toasts all ask here, so a new kind is added once.
//
// An unknown kind (a newer service) is the generic Bluetooth glyph and the word "device". A controller
// is drawn as its own silhouette when the service names its `model` (a file stem of shell/art/pads/,
// RUY-491: "dualsense", "wiiu_pro"), else as its family's (PlayStation: the DualSense, Xbox: the Series
// pad, Nintendo: the Switch Pro), else as the generic gamepad. The silhouettes are our own drawings
// (`scripts/add-pad-glyphs.py` puts them in the icon font as `pad_<model>`), not vendor art.
QtObject {
    id: icons

    // Every model there is a glyph for: the stems of shell/art/pads/. `scripts/lint-icons.ps1` keeps this list,
    // the folder, icons.txt and the table of Icon.qml in step; the service's table (services/ruya-pads) is
    // tested against the same folder.
    readonly property var padModels: [
        "8bitdo_pro2",
        "8bitdo_sn30pro",
        "8bitdo_ultimate",
        "arcade_stick",
        "dualsense",
        "dualsense_edge",
        "dualshock3",
        "dualshock4",
        "gamecube",
        "generic_pad",
        "joycon_left",
        "joycon_pair",
        "joycon_right",
        "keyboard",
        "n64",
        "retro_pad",
        "stadia",
        "steam_controller",
        "steam_deck",
        "switch_pro",
        "wii_remote",
        "wii_remote_nunchuk",
        "wiiu_pro",
        "xbox_360",
        "xbox_adaptive",
        "xbox_elite",
        "xbox_one",
        "xbox_series"
    ]

    // The model a family is drawn as when the service names none.
    function familyModel(family) {
        switch (family) {
        case "playstation": return "dualsense"
        case "xbox": return "xbox_series"
        case "nintendo": return "switch_pro"
        }
        return ""
    }

    // The icon name of a controller: its model's silhouette, else its family's, else the generic gamepad.
    // A model this shell has no glyph for (a newer service) counts as none.
    function padIcon(family, model) {
        const own = String(model ?? "")
        if (own !== "" && padModels.indexOf(own) >= 0)
            return "pad_" + own
        const byFamily = familyModel(family)
        return byFamily !== "" ? "pad_" + byFamily : "sports_esports"
    }

    // The icon name for a device. `family` and `model` only matter for a controller.
    function iconFor(kind, family, model) {
        switch (kind) {
        case "controller": return padIcon(family, model)
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
        const parts = shownParts(list, d)
        return parts.name + parts.tail
    }

    // The same name in two parts, { name, tail }: tail is " (00:05)" for a like-named device, else "". A line that
    // can be too long (TailText) cuts the name and keeps the tail.
    function shownParts(list, d) {
        const name = plain(d.name)
        const key = name.toLowerCase()
        const twins = list.filter(x => plain(x.name).toLowerCase() === key).length
        if (twins <= 1)
            return { name: name, tail: "" }
        // The tail is put into the format apart from the name, so an alias that contains "%2" or "$&" comes out
        // as typed (QString.arg() would read it as the next placeholder).
        const address = addressTail(d.id)
        return { name: name, tail: qsTr("%1 (%2)").replace("%1", () => "").replace("%2", () => address) }
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
        const parts = batteryParts(d)
        return parts.name + parts.tail
    }

    // `batteryName` in two parts, { name, tail } (see shownParts).
    function batteryParts(d) {
        const address = String(d.address ?? "")
        if (address === "")
            return { name: plain(d.name), tail: "" }
        const wanted = address.toLowerCase()
        const paired = Bluetooth.devices.find(x => x.id.toLowerCase() === wanted)
        if (paired)
            return shownParts(Bluetooth.devices, paired)
        const withAddress = Batteries.devices.filter(x => String(x.address ?? "") !== "")
                                    .map(x => ({ id: x.address, name: x.name }))
        return shownParts(withAddress, { id: address, name: d.name })
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
