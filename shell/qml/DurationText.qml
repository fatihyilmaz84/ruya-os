pragma Singleton
import QtQuick
import RuyaShell

// Durations and moments in plain words (T-247, 04 §5): "1 h 20 min", "45 min", "Yesterday 19:40".
// Used by the Activity pages and the chart's text alternative. Minutes are rounded to the nearest;
// there is no seconds form, because play time is for people, not for a stopwatch.
//
// Every function reads `language`, so a binding that calls one is evaluated again when the UI
// language changes (QML tracks the reads inside called functions); the words are `qsTr` strings,
// so Turkish gets "1 sa 20 dk" and its own word order.
QtObject {
    id: root

    readonly property string language: DeviceSettings.language

    // 4800 -> "1 h 20 min", 2700 -> "45 min", 7200 -> "2 h", 20 -> "Under 1 min", 0 -> "0 min".
    function plain(seconds) {
        if (language === undefined)
            return ""
        const secs = Math.max(0, Math.round(seconds))
        if (secs === 0)
            return qsTr("0 min")
        const total = Math.round(secs / 60)
        if (total === 0)
            return qsTr("Under 1 min")
        const h = Math.floor(total / 60)
        const m = total % 60
        if (h === 0)
            return qsTr("%1 min").arg(m)
        if (m === 0)
            return qsTr("%1 h").arg(h)
        return qsTr("%1 h %2 min").arg(h).arg(m)
    }

    // "Today", "Yesterday", else a short weekday and date ("Mon 3 Nov") for the day "YYYY-MM-DD".
    function dayWord(daysAgo, day) {
        if (language === undefined)
            return ""
        if (daysAgo === 0)
            return qsTr("Today")
        if (daysAgo === 1)
            return qsTr("Yesterday")
        return Qt.locale().toString(new Date(day + "T12:00:00"), "ddd d MMM")
    }

    // "Yesterday 19:40": the day word and the clock time of an instant (unix seconds) in the
    // console's time zone.
    function when(daysAgo, day, startUnix) {
        return qsTr("%1 %2").arg(dayWord(daysAgo, day)).arg(TimeZone.formatClock(startUnix * 1000))
    }

    // The three-letter weekday of a bar (dow 1 = Monday .. 7 = Sunday) in the UI language.
    function weekdayShort(dow) {
        if (language === undefined)
            return ""
        return Qt.locale().dayName(dow % 7, Locale.ShortFormat)
    }
}
