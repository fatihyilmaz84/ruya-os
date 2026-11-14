pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Settings -> Power saving (T-202, 02 "Power saving"): when the console dims to a screen saver,
// turns the screen off, goes to sleep, and switches idle controllers off. Every row writes to
// DeviceSettings at once and the idle clock (IdleClock) follows, so nothing restarts. The times
// are minutes without input; Off / Never skips the step. The Sleep row works only where the
// console can suspend and that is known to work (`Power.sleepAllowed`); where logind allows it but
// it is not verified yet the row says "Sleep is not available on this console yet" and is disabled. The last row says what is
// keeping the console awake right now, so a stuck inhibitor is easy to find.
SettingsPane {
    id: pane

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
                    : r === "audio" ? qsTr("sound playing (the screen saver can still start)")
                    : qsTr("an app")
            if (!words.includes(w))
                words.push(w)
        }
        return words.join(", ")
    }

    // One row when a later step is set at or before an earlier one: the earlier step never shows.
    // (The choices stay free: a user may want exactly that.) A label and a value, because a row does
    // not wrap.
    function orderNote() {
        const saverOn = DeviceSettings.saverMinutes > 0
        const offOn = DeviceSettings.screenOffMinutes > 0
        const sleepOn = Power.sleepAllowed && DeviceSettings.sleepMinutes > 0
        if (saverOn && offOn && DeviceSettings.screenOffMinutes <= DeviceSettings.saverMinutes)
            return [qsTr("The screen saver never shows"), qsTr("The screen turns off first")]
        if (saverOn && sleepOn && DeviceSettings.sleepMinutes <= DeviceSettings.saverMinutes)
            return [qsTr("The screen saver never shows"), qsTr("The console sleeps first")]
        if (offOn && sleepOn && DeviceSettings.sleepMinutes <= DeviceSettings.screenOffMinutes)
            return [qsTr("The screen is not turned off"), qsTr("The console sleeps instead")]
        return ["", ""]
    }
    readonly property var note: orderNote()

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
        // Where logind allows suspend but the image does not yet vouch for it (no suspend-verified
        // marker, T-166) the row stays, says so, and takes no focus: Sleep is never silently missing.
        visible: Power.canSuspend
        enabled: Power.sleepAllowed
        label: Power.sleepAllowed ? qsTr("Sleep") : qsTr("Sleep is not available on this console yet")
        valueText.visible: Power.sleepAllowed
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
        objectName: "rowOrderNote"
        kind: "info"
        u: pane.u
        visible: pane.note[0].length > 0
        label: pane.note[0]
        value: pane.note[1]
    }

    SettingRow {
        objectName: "rowKeepingAwake"
        kind: "info"
        u: pane.u
        label: qsTr("Keeping the console awake")
        value: IdleClock.held ? pane.heldText(IdleInhibit.reasons) : qsTr("Nothing")
    }
}
