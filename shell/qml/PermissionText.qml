pragma Singleton
import QtQuick
import RuyaShell

// The words for the permission keys of org.ruyaos.Store1 (the App record's `permissions` and GetPermissions,
// 03 §4.4): what an installed Flatpak app may do, read from its metadata. The game page's "This app can" and
// Settings -> Privacy -> App permissions (RUY-744) read them here, so a key reads the same everywhere. The .play
// request vocabulary has its own words (PlayTrust).
//
// Every function reads `language`, so a binding that calls one is evaluated again when the UI language changes.
QtObject {
    id: root

    readonly property string language: DeviceSettings.language

    // The keys in the contract's plain-language order.
    readonly property var order: ["network", "home-files", "host-files", "all-devices", "audio", "gamepad", "session-bus"]
    // Keys that get the warning "High risk" (and, for a Standard profile, the admin's PIN at install).
    readonly property var highRisk: ["all-devices", "host-files", "session-bus"]
    // The file keys: withdrawing one can take saves or settings the app keeps outside its own folder.
    readonly property var fileKeys: ["home-files", "host-files"]

    function isHighRisk(key) {
        return highRisk.indexOf(key) >= 0
    }

    // `keys` in the contract's order; a key the shell does not know comes last, in the order given.
    function sorted(keys) {
        const known = order.filter(k => keys.indexOf(k) >= 0)
        return known.concat(keys.filter(k => order.indexOf(k) < 0))
    }

    // What the app may do, in words; an unknown key shows as it is.
    function words(key) {
        if (language === undefined)
            return ""
        switch (key) {
        case "audio": return qsTr("Plays sound")
        case "gamepad": return qsTr("Uses game controllers")
        case "network": return qsTr("Uses the network")
        case "home-files": return qsTr("Reads and writes files in your home folder")
        case "host-files": return qsTr("Reads and writes all files on this device")
        case "all-devices": return qsTr("Accesses all devices")
        case "session-bus": return qsTr("Can control other programs on this device")
        }
        return key
    }

    // The label of a key's row on the App permissions page: sound carries the microphone too, so it says so.
    function rowLabel(key) {
        if (language === undefined)
            return ""
        return key === "audio" ? qsTr("Sound and microphone") : words(key)
    }

    // Why a key cannot be withdrawn here (the row's second line). The service says which keys can
    // (GetPermissions `withdrawable`); this is only the reason, by key. Any other key (all devices on a Flatpak
    // that cannot keep the controllers, a key an override written outside the console added) has the general one.
    function fixedReason(key) {
        if (language === undefined)
            return ""
        switch (key) {
        case "audio": return qsTr("Not controllable yet: sound and microphone share one connection")
        case "gamepad": return qsTr("Always allowed: a console needs its controllers")
        case "session-bus": return qsTr("Can't be withdrawn yet: apps break without it")
        }
        return qsTr("Can't be withdrawn on this console")
    }
}
