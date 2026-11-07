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
