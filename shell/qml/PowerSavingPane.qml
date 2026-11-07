pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Power saving (T-202, 02 "Power saving"): when the console dims to a screen saver,
// turns the screen off, goes to sleep, and switches idle controllers off. Every row writes to
// DeviceSettings at once and the idle clock (IdleClock) follows, so nothing restarts. The times
// are minutes without input; Off / Never skips the step. The Sleep row exists only where the
// console can suspend and that is known to work (`Power.sleepAllowed`). The last row says what is
// keeping the console awake right now, so a stuck inhibitor is easy to find.
SettingsPane {
    id: pane

    hints: [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Back") }]

    function minutesLabel(minutes, zeroLabel) {
        if (minutes === 0)
            return zeroLabel
        if (minutes % 60 === 0)
            return qsTr("%n hour(s)", "", minutes / 60)
        return qsTr("%n minute(s)", "", minutes)
    }

    function options(minutes, zeroLabel) {
        return minutes.map(m => ({ value: m, label: pane.minutesLabel(m, zeroLabel) }))
    }

    // Plain words for IdleInhibit's reasons ("wayland:3" is an app's idle-inhibitor).
    function heldText(reasons) {
        const words = []
        for (const r of reasons) {
            const w = r === "job" ? qsTr("a download or install")
                    : r === "update" ? qsTr("a system update")
                    : r === "audio" ? qsTr("audio playing")
                    : qsTr("an app")
            if (!words.includes(w))
                words.push(w)
        }
        return words.join(", ")
    }

    ChoiceRow {
        id: saver
        objectName: "rowScreenSaver"
        u: pane.u
        label: qsTr("Screen saver")
        options: pane.options([0, 5, 10, 15, 30], qsTr("Off"))
        onEdited: v => DeviceSettings.saverMinutes = v
    }
    Binding { target: saver; property: "value"; value: DeviceSettings.saverMinutes }

    ChoiceRow {
        id: screenOff
        objectName: "rowScreenOff"
        u: pane.u
        label: qsTr("Turn the screen off")
        options: pane.options([0, 15, 30, 60], qsTr("Never"))
        onEdited: v => DeviceSettings.screenOffMinutes = v
    }
    Binding { target: screenOff; property: "value"; value: DeviceSettings.screenOffMinutes }

    ChoiceRow {
        id: sleep
        objectName: "rowSleep"
        u: pane.u
        visible: Power.sleepAllowed
        label: qsTr("Sleep")
        options: pane.options([0, 30, 60, 120, 240], qsTr("Never"))
        onEdited: v => DeviceSettings.sleepMinutes = v
    }
    Binding { target: sleep; property: "value"; value: DeviceSettings.sleepMinutes }

    ChoiceRow {
        id: pads
        objectName: "rowControllersOff"
        u: pane.u
        label: qsTr("Controllers turn off")
        options: pane.options([0, 5, 10, 15, 30], qsTr("Never"))
        onEdited: v => DeviceSettings.padIdleMinutes = v
    }
    Binding { target: pads; property: "value"; value: DeviceSettings.padIdleMinutes }

    SettingRow {
        objectName: "rowKeepingAwake"
        u: pane.u
        label: qsTr("Keeping the console awake")
        value: IdleClock.held ? pane.heldText(IdleInhibit.reasons) : qsTr("Nothing")
    }
}
