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
            for (const role of ["logo", "card", "cover", "preview", "trailer"])
                verify(p.art[role], role)
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
