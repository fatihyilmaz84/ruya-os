import QtQuick
import QtTest
import RuyaShell

// Library1's .play keys (RUY-852) through the mock backend: a .play item carries its art roles,
// genres, players, controller, age rating, tier and signer; every other item is unchanged.
Item {
    width: 320
    height: 240

    TestCase {
        id: tc
        name: "LibraryPlay"
        when: windowShown

        function test_a_play_item_has_every_field() {
            Library.resetMockForTests("play")
            tryVerify(() => Library.item("flatpak:play.com.example.starhopper").play === true)
            const p = Library.item("flatpak:play.com.example.starhopper")
            compare(p.title, "Star Hopper")
            compare(p.genres, ["platformer", "adventure"])
            compare(p.playersMin, 1)
            compare(p.playersMax, 2)
            compare(p.controller, "full")
            compare(p.ageRating["violence-cartoon"], "mild")
            compare(p.playTier, "developer")
            compare(p.playSigner, "Example Games")
            compare(p.playSignerKeyId, "0123456789abcdef0123456789abcdef")
            compare(p.playScreenshots.length, 0, "no screenshot path to a file the mock does not have (RUY-886)")
            compare(p.playRunner, "wine 10.2")
            compare(p.playRunnerSource, "system")
            compare(p.playRunnerTested, "9.20")
            compare(p.playResolveError, "")
            for (const role of ["icon", "logo", "card", "cover", "hero"])
                verify(p.art[role], role)
        }

        // RUY-886: a path the mock serves must name a file that is there (the pictures the shell ships), or
        // every surface that shows the plain .play scenario draws "cannot load". Every art role and screenshot of
        // every item is read like a resource would be.
        function test_every_path_the_plain_mock_serves_exists() {
            Library.resetMockForTests("play")
            tryVerify(() => Library.item("flatpak:play.com.example.starhopper").play === true)
            let paths = []
            for (const it of Library.items) {
                for (const role in (it.art ?? {}))
                    paths.push(it.art[role])
                paths = paths.concat(it.playScreenshots ?? [])
            }
            verify(paths.length >= 5, "the .play item brings its pictures: " + paths.length)
            for (const path of paths) {
                const xhr = new XMLHttpRequest()
                xhr.open("GET", path, false)
                let ok = true
                try {
                    xhr.send()
                } catch (e) {
                    ok = false
                }
                verify(ok && xhr.responseText.length > 100, "the mock serves a path that is not a file: " + path)
            }
        }

        // RUY-903: a refusal is one sentence and no runner; Star Hopper keeps its runner.
        function test_a_refused_item_has_its_sentence_and_no_runner() {
            Library.resetMockForTests("playart:" + artFixtures)
            tryVerify(() => Library.item("flatpak:play.com.example.quiet").play === true)
            const q = Library.item("flatpak:play.com.example.quiet")
            compare(q.playResolveError, "The OS runner is 8.0, older than the required 9.0.")
            compare(q.playRunner, "")
            compare(q.playRunnerSource, "")
            compare(Library.item("flatpak:play.com.example.starhopper").playRunner, "wine 10.2")
            Library.resetMockForTests("")
        }

        // RUY-854: an item is found by the Flatpak id it starts (the id Session1 and Store1 use).
        function test_an_item_is_found_by_the_flatpak_it_starts() {
            Library.resetMockForTests("play")
            tryVerify(() => Library.item("flatpak:play.com.example.starhopper").play === true)
            compare(Library.itemForApp("play.com.example.starhopper").title, "Star Hopper")
            compare(Library.itemForApp("play.com.example.starhopper").id, "flatpak:play.com.example.starhopper")
            compare(Library.itemForApp("org.example.Player").title, "Open Player")
            compare(Object.keys(Library.itemForApp("org.example.Nothing")).length, 0, "no such app")
            compare(Object.keys(Library.itemForApp("")).length, 0, "an empty id matches no item")
            compare(Object.keys(Library.itemForApp("730")).length, 0, "a Steam item has no Flatpak id")
            Library.resetMockForTests("")
        }

        function test_other_items_have_no_play_keys() {
            Library.resetMockForTests("play")
            tryVerify(() => Library.items.length === 11)
            const r = Library.item("steam:730")
            compare(r.play, undefined)
            compare(r.playTier, undefined)
            Library.resetMockForTests("")
            tryVerify(() => Library.items.length === 10)
        }

        SignalSpy { id: answered; target: Library; signalName: "runnerChoiceAnswered" }
        SignalSpy { id: stored; target: Library; signalName: "runnerChoiceSet" }
        SignalSpy { id: changed; target: Library; signalName: "runnerChoiceChanged" }
        SignalSpy { id: resolved; target: Library; signalName: "runnerResolved" }

        function choiceOf(profile, id) {
            answered.clear()
            Library.requestRunnerChoice(profile, id)
            tryCompare(answered, "count", 1)
            return answered.signalArguments[0][2] + " " + answered.signalArguments[0][3]
        }

        function store(profile, id, choice) {
            stored.clear()
            Library.setRunnerChoice(profile, id, choice)
            tryCompare(stored, "count", 1)
            return stored.signalArguments[0][3]
        }

        // RUY-959: the runner choice is per profile, "package" by default and clears; a plain item,
        // an id that is not installed and an unknown choice are refused with Library1's status strings.
        function test_the_runner_choice_is_per_profile_and_refuses_what_library1_refuses() {
            Library.resetMockForTests("play")
            tryVerify(() => Library.item("flatpak:play.com.example.starhopper").play === true)
            const hop = "flatpak:play.com.example.starhopper"
            compare(choiceOf("p1", hop), "ok package")
            changed.clear()
            compare(store("p1", hop, "bundled"), "ok")
            compare(changed.count, 1)
            compare(changed.signalArguments[0][0], "p1")
            compare(changed.signalArguments[0][2], "bundled")
            compare(store("p2", hop, "system"), "ok")
            compare(choiceOf("p1", hop), "ok bundled")
            compare(choiceOf("p2", hop), "ok system")
            compare(store("p1", hop, "bundled"), "ok")
            compare(changed.count, 2, "no change, no signal")
            compare(store("p1", hop, "package"), "ok")
            compare(choiceOf("p1", hop), "ok package")
            compare(store("p1", "steam:730", "system"), "not_play")
            compare(store("p1", "flatpak:play.not.installed", "system"), "unknown")
            compare(store("p1", hop, "proton"), "invalid")
            compare(store("../x", hop, "system"), "invalid")
            compare(choiceOf("p1", "steam:730"), "not_play ")
            Library.resetMockForTests("")
            compare(choiceOf("p2", "flatpak:play.not.installed"), "unknown ")
        }

        // RUY-959: ResolveRunner answers with the item's runner keys (the mock resolves every choice as
        // the package's default) and refuses as the choice calls do.
        function test_resolve_runner_answers_with_the_runner_keys() {
            Library.resetMockForTests("play")
            tryVerify(() => Library.item("flatpak:play.com.example.starhopper").play === true)
            resolved.clear()
            Library.resolveRunner("flatpak:play.com.example.starhopper", "system")
            tryCompare(resolved, "count", 1)
            compare(resolved.signalArguments[0][2], "ok")
            const r = resolved.signalArguments[0][3]
            compare(r.playRunner, "wine 10.2")
            compare(r.playRunnerSource, "system")
            compare(r.playRunnerTested, "9.20")
            compare(r.playResolveError, "")
            resolved.clear()
            Library.resolveRunner("steam:730", "system")
            tryCompare(resolved, "count", 1)
            compare(resolved.signalArguments[0][2], "not_play")
            compare(resolved.signalArguments[0][3].playRunner, "")
            Library.resetMockForTests("")
        }

        // RUY-959: an older ListRunners reply that arrives after a newer one does not replace it.
        function test_a_late_runners_reply_does_not_replace_a_newer_one() {
            const wine = { family: "wine", kind: "wine", version: "10.0", licence: "", sourceUrl: "" }
            Library.mockSetRunners([wine], 300)
            Library.mockSetRunners([], 0)
            tryVerify(() => Library.runners.length === 0)
            tryVerify(() => Library.mockPendingReplies() === 0, 2000)
            compare(Library.runners.length, 0, "the late reply of the first list was dropped")
            Library.resetMockForTests("")
            tryVerify(() => Library.runners.length === 2)
            compare(Library.runners[0].version, "GE-Proton11-12")
            compare(Library.runners[1].version, "wine-11.0")
        }
    }
}
