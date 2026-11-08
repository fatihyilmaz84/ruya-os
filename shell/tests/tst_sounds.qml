import QtQuick
import QtTest
import RuyaShell

// Sound themes, the cue set and the ambient bed (T-227, 02 §5). The checker is tested on the fixture
// folders SoundThemes writes (the same ones scripts/lint-sound-themes.ps1 runs); Sfx is tested through its
// properties and counters: there is nothing to listen to offscreen. The ambient bed and the Settings rows
// are in tst_sound_ui.qml.
Item {
    id: host
    width: 1280
    height: 720

    // ---------------------------------------------------------------- the checker
    TestCase {
        id: checker
        name: "SoundChecker"
        when: windowShown

        property string root: ""

        function initTestCase() {
            root = SoundThemes.fixturesDir()
            verify(root.length > 0, "fixtures written")
        }

        function problemsOf(theme) {
            const r = SoundThemes.check(checker.root + "/" + theme)
            return r.problems.join("\n")
        }

        // One rejected theme: it fails, and for the reason the fixture was made for.
        function rejected(theme, text) {
            const r = SoundThemes.check(checker.root + "/" + theme)
            verify(!r.ok, theme + " must be rejected")
            verify(r.problems.join("\n").includes(text), theme + ": " + r.problems.join("; ") + " (wanted: " + text + ")")
        }

        function test_a_valid_theme_passes() {
            const r = SoundThemes.check(checker.root + "/ok-full")
            verify(r.ok, r.problems.join("; "))
            compare(r.cues, 13)
            verify(r.hasAmbient)
            compare(r.loopStart, 0)
            compare(r.loopEnd, 10000)
            compare(r.name, "Fixture")
            const ogg = SoundThemes.check(checker.root + "/ok-ogg")
            verify(ogg.ok, ogg.problems.join("; "))
            compare(ogg.loopStart, 1000, "an Ogg ambient file is read for its length")
        }

        function test_every_fixture_ends_as_expected() {
            const cases = SoundThemes.fixtureCases()
            verify(cases.length >= 20)
            let passes = 0
            let refusals = 0
            for (const c of cases) {
                const r = SoundThemes.check(checker.root + "/" + c.name)
                compare(r.ok, c.shouldPass, c.name + ": " + r.problems.join("; "))
                if (c.shouldPass) {
                    passes++
                } else {
                    refusals++
                    verify(r.problems.join("\n").includes(c.expect), c.name + ": " + r.problems.join("; "))
                }
            }
            verify(passes >= 4)
            verify(refusals >= 16)
        }

        function test_oversize_cue() { rejected("bad-oversize-cue", "larger than 200 KB") }
        function test_cue_too_long() { rejected("bad-long-cue", "longer than 1.5 s") }
        function test_cue_too_loud() { rejected("bad-loud-cue", "peak above -3 dBFS") }
        function test_cue_sample_rate() { rejected("bad-cue-rate", "sample rate 44100") }
        function test_loop_outside_the_file() { rejected("bad-loop-outside", "not inside the file") }
        function test_loop_too_short() { rejected("bad-loop-short", "shorter than 5 s") }
        function test_unknown_extension() {
            rejected("bad-cue-extension", "unknown extension")
            rejected("bad-ambient-extension", "unknown extension")
        }
        function test_missing_manifest() { rejected("bad-no-manifest", "theme.json is missing") }
        function test_manifest_is_not_json() { rejected("bad-json", "not a JSON object") }
        function test_oversize_ambient() { rejected("bad-ambient-oversize", "larger than 3 MB") }
        function test_not_audio() {
            rejected("bad-cue-not-wav", "not a WAV file")
            rejected("bad-ambient-not-audio", "not a FLAC file")
        }
        function test_flac_frames_must_name_their_sample_rate() {
            // T-321: frames with rate code 0 ("as in STREAMINFO", valid FLAC) play at 0 Hz under Qt 6.11's
            // FFmpeg player: no sound, and "QAudioSink::start: QAudioFormat not valid" several times a second.
            rejected("bad-flac-frame-rate", "do not name their sample rate")
            rejected("bad-flac-no-frames", "has no audio frames")
            const r = SoundThemes.check(checker.root + "/ok-flac-padding")
            verify(r.ok, "a PADDING block before the first frame (past the 4 KB head) is walked: " + r.problems.join("; "))
        }
        function test_path_escaping_the_folder() {
            rejected("bad-escape", "leaves the theme folder")
            rejected("bad-absolute", "not a plain relative path")
        }
        function test_schema_errors() {
            rejected("bad-no-name", "'name'")
            rejected("bad-licence", "SPDX")
            rejected("bad-ambient-gain", "'gain'")
            rejected("bad-cue-missing", "is missing")
        }

        function test_an_unknown_cue_is_a_warning_not_an_error() {
            const r = SoundThemes.check(checker.root + "/ok-unknown-cue")
            verify(r.ok, r.problems.join("; "))
            compare(r.cues, 1, "only the known cue is kept")
            verify(r.warnings.join("\n").includes("fanfare"))
        }

        function test_hostile_wav_chunk_sizes() {
            // A chunk size of 0xFFFFFFF8 once looped forever and 0x80000000 once read out of range.
            rejected("bad-wav-chunk-loop", "a chunk is cut short")
            rejected("bad-wav-chunk-negative", "a chunk is cut short")
            const r = SoundThemes.check(checker.root + "/ok-wav-extra-chunk")
            verify(r.ok, "an honest extra chunk is skipped: " + r.problems.join("; "))
        }

        function test_a_hostile_file_always_gets_a_verdict() {
            // WAV, Ogg and FLAC with every length field of the first 128 bytes set to 0, 1, 0x7fffffff,
            // 0x80000000 and 0xfffffff8, cut and corrupted at every offset: each must come back (bounded: 60 s).
            const r = SoundThemes.fuzz(60000)
            verify(r.ok, r.problem)
            verify(r.cases > 1500, "cases tried: " + r.cases)
        }

        function test_granule_and_loop_numbers_that_do_not_fit() {
            // An Ogg granule position of 2^63 - 1, and a loop end of 1e300 ms (clamped before it becomes a
            // 64-bit number: the message shows the clamped value, not whatever the cast happened to give).
            rejected("bad-granule-overflow", "no usable length")
            rejected("bad-loop-overflow", "the loop (0 to 1000000000000000 ms) is not inside the file")
        }

        function test_refusal_message_names_the_problem() {
            // Three refusals, said in plain words (no file name, no path), in English and in Turkish.
            const wanted = {
                "bad-loud-cue": ["A cue is louder than allowed", "Bir arayüz sesi izin verilenden daha yüksek"],
                "bad-long-cue": ["A cue is longer than allowed", "Bir arayüz sesi izin verilenden daha uzun"],
                "bad-loop-short": ["The ambient loop does not fit the file", "Ortam sesi döngüsü dosyaya uymuyor"],
            }
            for (const language of ["en", "tr"]) {
                DeviceSettings.language = language
                for (const theme in wanted) {
                    const r = SoundThemes.check(checker.root + "/" + theme)
                    verify(!r.ok, theme)
                    const text = SoundThemeText.describe(r.problems)
                    compare(text, wanted[theme][language === "en" ? 0 : 1], theme + " in " + language)
                    verify(!text.includes("/") && !text.includes(".wav") && !text.includes(".flac"), "no file name: " + text)
                }
            }
            DeviceSettings.language = "en"
            compare(SoundThemeText.describe([]), "", "nothing wrong, nothing said")
        }

        function test_every_refused_fixture_gets_a_specific_message() {
            const fallback = "Something in the theme is not right"
            for (const c of SoundThemes.fixtureCases()) {
                if (c.shouldPass)
                    continue
                const r = SoundThemes.check(checker.root + "/" + c.name)
                const text = SoundThemeText.describe(r.problems)
                verify(text.length > 0 && text !== fallback, c.name + ": " + r.problems[0] + " -> " + text)
            }
        }

        function test_a_folder_that_does_not_exist() {
            verify(!SoundThemes.check(checker.root + "/no-such-theme").ok)
        }

        function test_the_bundled_theme_passes() {
            const r = SoundThemes.check(":/qt/qml/RuyaShell/sounds/dreamglass")
            verify(r.ok, r.problems.join("; "))
            compare(r.cues, 13, "every cue of the contract has a file")
            verify(r.hasAmbient)
            verify(r.loopEnd - r.loopStart >= 60000, "a loop of about a minute or more")
            compare(r.warnings.length, 0)
        }

        function test_the_example_theme_passes() {
            const url = Qt.resolvedUrl("../../samples/sound-theme-example").toString()
            const path = url.replace(/^file:\/\/\/([A-Za-z]:)/, "$1").replace(/^file:\/\//, "")
            const r = SoundThemes.check(path)
            verify(r.ok, path + ": " + r.problems.join("; "))
            compare(r.cues, 13)
            verify(r.hasAmbient)
        }
    }

    // ---------------------------------------------------------------- the cues
    TestCase {
        id: cues
        name: "SoundCues"
        when: windowShown

        SignalSpy { id: importSpy; target: SoundThemes; signalName: "importFinished" }

        readonly property var names: [
            ["navigate", "navigate", "navigateCount", "navigateEffect"],
            ["select", "select", "selectCount", "selectEffect"],
            ["back", "back", "backCount", "backEffect"],
            ["error", "error", "errorCount", "errorEffect"],
            ["notification", "notification", "notificationCount", "notificationEffect"],
            ["warning", "warning", "warningCount", "warningEffect"],
            ["open", "open", "openCount", "openEffect"],
            ["close", "close", "closeCount", "closeEffect"],
            ["page", "page", "pageCount", "pageEffect"],
            ["volume", "volume", "volumeCount", "volumeEffect"],
            ["startup", "startup", "startupCount", "startupEffect"],
            ["toggle-on", "toggleOn", "toggleOnCount", "toggleOnEffect"],
            ["toggle-off", "toggleOff", "toggleOffCount", "toggleOffEffect"],
        ]

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Audio.mockReset()
            SoundThemes.mockReset()
            DeviceSettings.soundTheme = "dreamglass"
            IdleClock.reset()
            tryVerify(() => Audio.channelVolumes.ui === 100)
            tryCompare(Sfx, "ducking", false, 3000)
        }

        function cleanup() {
            IdleClock.reset()
            DeviceSettings.soundTheme = "dreamglass"
        }

        function test_every_cue_plays_through_the_theme() {
            tryCompare(SoundThemes, "activeId", "dreamglass")
            for (const n of cues.names) {
                const url = Sfx.themeCues[n[0]]
                verify(url !== undefined && url.endsWith("/dreamglass/" + n[0] + ".wav"), n[0] + " comes from the theme: " + url)
                const effect = Sfx[n[3]]
                tryVerify(() => effect.source.toString() === url, 2000, n[0] + " effect follows the theme")
                const count = Sfx[n[2]]
                const played = Sfx.playedCount
                Sfx[n[1]]()
                compare(Sfx[n[2]], count + 1, n[0] + " counter")
                compare(Sfx.playedCount, played + 1, n[0] + " sounded")
            }
        }

        function test_the_toggle_cue_follows_the_direction() {
            const on = Sfx.toggleOnCount
            const off = Sfx.toggleOffCount
            Sfx.toggled(true)
            Sfx.toggled(false)
            Sfx.toggled(false)
            compare(Sfx.toggleOnCount, on + 1)
            compare(Sfx.toggleOffCount, off + 2)
        }

        function test_the_ui_channel_scales_every_cue() {
            Audio.setChannelVolume("ui", 50)
            tryCompare(Sfx, "gain", 0.5)
            for (const n of cues.names) {
                const base = n[0] === "navigate" ? 0.6 : (n[0] === "volume" ? 0.8 : 1)
                const effect = Sfx[n[3]]
                tryVerify(() => Math.abs(effect.volume - base * 0.5) < 0.001, 2000, n[0] + " volume")
            }
        }

        function test_the_duck_is_held_for_the_length_of_the_cue() {
            verify(SoundThemes.cueMs.startup > 1000, "the checker measured the start-up cue: " + SoundThemes.cueMs.startup)
            verify(SoundThemes.cueMs.navigate < SoundThemes.duckMs)
            Sfx.startup()
            compare(Sfx.duckTimer.interval, SoundThemes.cueMs.startup, "held as long as the cue")
            Sfx.navigate()
            compare(Sfx.duckTimer.interval, SoundThemes.duckMs, "a short cue holds for the minimum")
            tryCompare(Sfx, "ducking", false, 4000)
        }

        function test_gain_zero_is_silent() {
            Audio.setChannelVolume("ui", 0)
            tryCompare(Sfx, "gain", 0)
            tryCompare(Sfx.selectEffect, "volume", 0)
            const played = Sfx.playedCount
            const ducks = Sfx.duckCount
            const selects = Sfx.selectCount
            Sfx.select()
            compare(Sfx.selectCount, selects + 1, "the request is counted")
            compare(Sfx.playedCount, played, "but nothing sounds")
            compare(Sfx.duckCount, ducks, "and the ambient bed is not lowered for a cue nobody hears")
        }

        function test_reduced_motion_does_not_silence_sound() {
            DeviceSettings.reducedMotion = true
            tryCompare(Theme, "reducedMotion", true)
            const played = Sfx.playedCount
            Sfx.select()
            compare(Sfx.playedCount, played + 1)
            DeviceSettings.reducedMotion = false
        }

        function test_silent_while_the_screen_is_covered() {
            for (const stage of ["saver", "off", "sleep"]) {
                IdleClock.stage = stage
                verify(Sfx.quiet, stage)
                const played = Sfx.playedCount
                const selects = Sfx.selectCount
                Sfx.select()
                compare(Sfx.selectCount, selects + 1)
                compare(Sfx.playedCount, played, "no cue under the " + stage + " stage")
            }
            IdleClock.stage = "active"
            const played = Sfx.playedCount
            Sfx.select()
            compare(Sfx.playedCount, played + 1)
        }

        function test_a_cue_asks_the_bed_to_duck() {
            const ducks = Sfx.duckCount
            Sfx.back()
            compare(Sfx.duckCount, ducks + 1)
            verify(Sfx.ducking)
            tryCompare(Sfx, "ducking", false, 3000)
        }

        function test_a_missing_cue_falls_back_to_the_bundled_theme() {
            importSpy.clear()
            SoundThemes.mockPrepareDrive()
            SoundThemes.refresh(["/run/media/mock/Ruya Stick"])
            tryVerify(() => SoundThemes.themes.filter(t => t.kind === "drive").length === 2, 5000)
            const plain = SoundThemes.themes.find(t => t.kind === "drive" && t.name === "Plain" && t.id.endsWith("/Plain"))
            verify(plain, "the partial theme is listed")
            SoundThemes.importTheme(plain.path)
            tryCompare(importSpy, "count", 1, 5000)
            compare(importSpy.signalArguments[0][0], "ok")
            compare(importSpy.signalArguments[0][1], "user:Plain")
            DeviceSettings.soundTheme = "user:Plain"
            tryCompare(SoundThemes, "activeId", "user:Plain")
            verify(!SoundThemes.selectedBroken)
            verify(SoundThemes.cues.select.includes("/Plain/select.wav"), "the theme's own cue plays")
            verify(SoundThemes.cues.back.includes("/Plain/sub/back.wav"), "also from a sub-folder")
            verify(SoundThemes.cues.navigate.includes("/dreamglass/navigate.wav"), "a cue the theme lacks comes from the bundled one")
            compare(SoundThemes.ambientUrl, "", "a theme without ambient has none")
            const url = SoundThemes.cues.select
            tryVerify(() => Sfx.selectEffect.source.toString() === url, 2000, "Sfx follows")
        }

        function test_a_broken_theme_leaves_the_bundled_one_active() {
            DeviceSettings.soundTheme = "user:Nothing"
            tryCompare(SoundThemes, "selectedBroken", true)
            compare(SoundThemes.activeId, "dreamglass")
            verify(SoundThemes.cues.select.includes("/dreamglass/select.wav"))
            verify(SoundThemes.ambientUrl.includes("/dreamglass/ambient.flac"))
            DeviceSettings.soundTheme = "dreamglass"
            tryCompare(SoundThemes, "selectedBroken", false)
        }

        function test_a_drive_theme_that_fails_the_checker_is_listed_nowhere() {
            SoundThemes.mockPrepareDrive()
            SoundThemes.refresh(["/run/media/mock/Ruya Stick"])
            tryVerify(() => SoundThemes.driveProblems.length === 1, 5000)
            compare(SoundThemes.driveProblems[0].folder, "Broken")
            verify(SoundThemes.driveProblems[0].problem.includes("not a JSON object"))
            compare(SoundThemes.driveProblems[0].problems.length, 1)
            compare(SoundThemes.driveProblems[0].id, "drive:Ruya Stick/Broken")
            verify(!SoundThemes.themes.some(t => t.id.endsWith("/Broken")))
        }

        // A drive theme with this many files and bytes in all (the mock stick), listed and tried; the answer of
        // importTheme. A copy is made of at most 100 files and 12 MB: exactly that much is fine, one more is not.
        function importWith(folder, files, bytes) {
            importSpy.clear()
            SoundThemes.mockPrepareDrive()
            verify(SoundThemes.mockAddDriveTheme(folder, files, bytes), "the test theme is written")
            SoundThemes.refresh(["/run/media/mock/Ruya Stick"])
            tryVerify(() => SoundThemes.themes.some(t => t.kind === "drive" && t.id.endsWith("/" + folder)), 5000, folder + " is listed")
            SoundThemes.importTheme(SoundThemes.themes.find(t => t.kind === "drive" && t.id.endsWith("/" + folder)).path)
            tryCompare(importSpy, "count", 1, 20000)
            return importSpy.signalArguments[0]
        }

        function test_import_at_the_limits() {
            const answer = importWith("AtLimits", SoundThemes.maxCopyFiles, SoundThemes.maxCopyMb * 1024 * 1024)
            compare(answer[0], "ok", "exactly 100 files and exactly 12 MB are accepted")
            compare(answer[1], "user:AtLimits")
            verify(SoundThemes.themes.some(t => t.id === "user:AtLimits"))
        }

        function test_import_over_the_limits() {
            compare(SoundThemes.maxCopyFiles, 100)
            compare(SoundThemes.maxCopyMb, 12)
            let answer = importWith("TooManyFiles", SoundThemes.maxCopyFiles + 1, 100000)
            compare(answer[0], "too-many-files", "101 files")
            verify(!SoundThemes.themes.some(t => t.id === "user:TooManyFiles"), "nothing is left behind")
            answer = importWith("TooLarge", 6, SoundThemes.maxCopyMb * 1024 * 1024 + 1)
            compare(answer[0], "too-large", "12 MB and one byte")
            verify(!SoundThemes.themes.some(t => t.id === "user:TooLarge"))
        }

        function test_only_a_copy_can_be_removed() {
            importSpy.clear()
            SoundThemes.mockPrepareDrive()
            SoundThemes.refresh(["/run/media/mock/Ruya Stick"])
            tryVerify(() => SoundThemes.themes.filter(t => t.kind === "drive").length === 2, 5000)
            const plain = SoundThemes.themes.find(t => t.kind === "drive" && t.id.endsWith("/Plain"))
            SoundThemes.importTheme(plain.path)
            tryCompare(importSpy, "count", 1, 5000)
            // (the path as a string now: an entry found in the list reads from the list, which changes)
            const copyPath = SoundThemes.themes.find(t => t.id === "user:Plain").path
            verify(SoundThemes.check(copyPath).ok)
            verify(!SoundThemes.removeTheme("dreamglass"), "the bundled theme stays")
            verify(!SoundThemes.removeTheme(plain.id), "a theme on a drive is not ours to delete")
            verify(!SoundThemes.removeTheme("user:../x"), "an id with a path")
            verify(!SoundThemes.removeTheme("user:Nothing"), "a copy that does not exist")
            verify(SoundThemes.check(copyPath).ok, "still there")
            DeviceSettings.soundTheme = "user:Plain"
            tryCompare(SoundThemes, "activeId", "user:Plain")
            verify(SoundThemes.removeTheme("user:Plain"))
            compare(SoundThemes.selectedId, "dreamglass", "the chosen copy is gone: the bundled theme is chosen")
            compare(SoundThemes.activeId, "dreamglass")
            verify(!SoundThemes.themes.some(t => t.id === "user:Plain"))
            verify(!SoundThemes.check(copyPath).ok, "the folder is gone")
            DeviceSettings.soundTheme = "dreamglass"
        }

        function test_only_a_listed_drive_theme_is_copied() {
            importSpy.clear()
            SoundThemes.importTheme("C:/Windows")
            tryCompare(importSpy, "count", 1)
            compare(importSpy.signalArguments[0][0], "unknown")
        }

        function test_the_settings_are_validated() {
            DeviceSettings.soundTheme = "../evil"
            compare(DeviceSettings.soundTheme, "dreamglass", "an id with a path is refused")
            DeviceSettings.soundTheme = "user:ok-1"
            compare(DeviceSettings.soundTheme, "user:ok-1")
            DeviceSettings.soundTheme = "dreamglass"
        }
    }
}
