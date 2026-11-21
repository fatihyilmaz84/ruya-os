pragma Singleton
import QtQuick
import RuyaShell

// The words of a .play game's runner (RUY-905, 05 §6.2): the per-game choice, where the runner comes from,
// and why a launch would refuse. The game page's Compatibility row and the Compatibility page read them here.
// A refusal is worded by its stable code (Library1 play_resolve_code, 05 §4.5), never by Library1's English
// play_resolve_error.
//
// Every function reads `language`, so a binding that calls one is evaluated again when the UI language changes.
QtObject {
    readonly property string language: DeviceSettings.language

    // The three choices Library1 stores, in the Runner row's order.
    readonly property var choices: ["package", "bundled", "system"]

    function choiceWord(choice) {
        if (language === undefined)
            return ""
        switch (choice) {
        case "bundled": return qsTr("Bundled")
        case "system": return qsTr("System")
        }
        return qsTr("Package default")
    }

    // The second line of Starts with: which copy runs.
    function sourceWord(source) {
        if (language === undefined)
            return ""
        return source === "bundled" ? qsTr("Bundled copy") : source === "system" ? qsTr("System copy") : ""
    }

    // Why the launch would refuse, by Library1's code. A code without its own sentence (the format's
    // problem codes, launch.damaged) means the package's files are damaged.
    function refusal(code) {
        if (language === undefined)
            return ""
        switch (code) {
        case "resolve.no_system_runner": return qsTr("This console has no runner for this game.")
        case "resolve.system_too_old": return qsTr("The system runner is older than this game needs.")
        case "resolve.system_too_new": return qsTr("The system runner is newer than this game allows.")
        case "resolve.no_bundled": return qsTr("This game has no bundled runner to fall back on.")
        case "launch.runner_missing": return qsTr("The system runner can't be found.")
        case "launch.runner_kind": return qsTr("The system runner is the wrong kind for this game.")
        }
        return qsTr("This game's files are damaged. Reinstall it.")
    }

    // The note under the Runner row when the choice can't be honoured (Library1 play_fallback).
    function fallbackNote(choice) {
        if (language === undefined)
            return ""
        return choice === "bundled" ? qsTr("This game has no bundled runner, so it uses the package default.")
                                    : qsTr("The system runner can't be used for this game, so it uses the package default.")
    }
}
