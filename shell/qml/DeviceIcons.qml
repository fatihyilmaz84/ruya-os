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

    // What to call a pad that connected: the alias of the Bluetooth device with that address (what the
    // user renamed it to), else the family's words, else the name the pad gave itself.
    function padName(id, name, family) {
        const wanted = String(id).toLowerCase()
        const paired = Bluetooth.devices.find(d => d.id.toLowerCase() === wanted)
        if (paired)
            return plain(paired.name)
        if (family !== "")
            return kindText("controller", family)
        return plain(name)
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
