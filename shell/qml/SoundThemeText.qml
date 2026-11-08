pragma Singleton
import QtQuick

// The checker's problems (SoundThemeCheck.cpp, English, for a person who writes a theme: they name files and
// fields) said in plain words for the player (T-294): one short line for the first problem, never a path or a
// file name. Settings -> Audio shows it on a drive theme the checker refused and in the toast when a copy fails.
// `problems` is the checker's list (or its first problem as a string). The wording is matched on the checker's
// text; tst_sounds.qml runs every refused fixture through it, so a new problem that falls through to the last
// line shows up there.
QtObject {
    function describe(problems) {
        const first = Array.isArray(problems) ? (problems.length > 0 ? String(problems[0]) : "") : String(problems ?? "")
        if (first.length === 0)
            return ""
        // A file name inside the message can contain any word, so the phrases are matched most specific first.
        if (/theme\.json is missing/.test(first))
            return qsTr("The theme.json file is missing")
        if (/ is missing$/.test(first))
            return qsTr("A sound file is missing")
        if (/ peak above /.test(first))
            return qsTr("A cue is louder than allowed")
        if (/ longer than 1\.5 s/.test(first))
            return qsTr("A cue is longer than allowed")
        if (/folder name is not usable/.test(first))
            return qsTr("The folder name can't be used")
        if (/ leaves the theme folder| is not a plain relative path| is a link|is not a plain path|file name is empty|the value must be a file name/.test(first))
            return qsTr("A file is outside the theme folder")
        if (/^theme\.json |^'(name|author|licence|version|cues)'|SPDX|must look like|more than \d+ cues|'cues' must/.test(first))
            return qsTr("The theme.json file has a mistake")
        // T-330: these three name "the loop" too, so they come before the loop's own line.
        if (/ of its energy is below 150 Hz/.test(first))
            return qsTr("The ambient sound is too deep for TV speakers")
        if (/nearly silent/.test(first))
            return qsTr("The ambient sound is almost silent")
        if (/the FLAC audio is damaged/.test(first))
            return qsTr("A sound file is not in a format that can be played")
        if (/the loop |'loop' needs/.test(first))
            return qsTr("The ambient loop does not fit the file")
        if (/'gain' must|'file' must be|must be an object with a file/.test(first))
            return qsTr("The ambient settings have a mistake")
        if (/ is larger than /.test(first))
            return qsTr("A file is larger than allowed")
        if (/unknown extension|not a (WAV|FLAC|Ogg) file|chunk|the fmt|sample rate|channels|16-bit|no audio data|FLAC|Ogg|Vorbis|cannot be read|[0-9]+ Hz/.test(first))
            return qsTr("A sound file is not in a format that can be played")
        return qsTr("Something in the theme is not right")
    }
}
