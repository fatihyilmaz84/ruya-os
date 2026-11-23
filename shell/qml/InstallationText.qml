pragma Singleton
import QtQuick
import RuyaShell

// The words of a game's installations (RUY-137, Library1 "Installation record"): which source installed it,
// its row in the Options menu's installation list, and the game page's line when a game has several. The
// Shell's game rows, the Home hero's meta line and the game page read them here.
//
// Every function reads `language`, so a binding that calls one is evaluated again when the UI language changes.
QtObject {
    readonly property string language: DeviceSettings.language

    // A source's name: a product name, the same in every language.
    function sourceName(source) {
        if (language === undefined)
            return ""
        switch (source) {
        case "steam": return "Steam"
        case "flatpak": return "Flatpak"
        }
        return source ?? ""
    }

    // An installation's name: a .play app says .play (it is a Flatpak underneath).
    function name(installation) {
        if (!installation)
            return ""
        return installation.play === true ? ".play" : sourceName(installation.source)
    }

    // Its row: the name and, when known, the version (else the runner a .play app would start with).
    function label(installation) {
        const detail = (installation.version ?? "") !== "" ? installation.version : (installation.runner ?? "")
        return detail !== "" ? qsTr("%1 · %2", "An installation: its source, then its version or runner").arg(name(installation)).arg(detail)
                             : name(installation)
    }

    // The installation Play uses (the preferred one), or undefined.
    function preferredOf(installations) {
        return (installations ?? []).find(i => i.preferred === true)
    }

    // The game page's line for a game with two or more installations.
    function playUses(installations) {
        if (language === undefined)
            return ""
        const list = installations ?? []
        return qsTr("%n installations, Play uses %1", "The game page: a game installed more than once", list.length).arg(name(preferredOf(list)))
    }
}
