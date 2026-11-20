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

        function test_other_items_have_no_play_keys() {
            Library.resetMockForTests("play")
            tryVerify(() => Library.items.length === 11)
            const r = Library.item("steam:730")
            compare(r.play, undefined)
            compare(r.playTier, undefined)
            Library.resetMockForTests("")
            tryVerify(() => Library.items.length === 10)
        }
    }
}
