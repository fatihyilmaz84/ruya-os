import QtQuick
import QtTest
import RuyaShell

// ADR-045, RUY-1056: Steam items are per profile. Library mirrors Library1's ActiveProfile (which
// ruya-session sets; the mock plays it and follows Library.profile one turn later) and hides every
// Steam item while it is not the signed-in profile, so no profile sees another's games during a
// switch. The mock: its three profiles (p1, p2, p3) have the Steam games, a later profile (p4) none.
// The mock lists them for nobody ("") too, for pages built without a Shell; the service's own view of
// nobody (Flatpak items only) is tested in Rust (view.rs).
Item {
    width: 320
    height: 240

    TestCase {
        id: tc
        name: "LibraryProfile"
        when: windowShown

        SignalSpy { id: listed; target: Library; signalName: "itemsChanged" }

        function steamIn(list) {
            return list.filter(i => i.source === "steam").map(i => i.id)
        }

        function signIn(profile) {
            Library.profile = profile
            tryCompare(Library, "activeProfile", profile)
        }

        function init() {
            Library.resetMockForTests("")
            signIn("p1")
            tryVerify(() => Library.items.length === 10, 2000, "the list has 10 items")
        }

        function cleanup() {
            Library.profile = ""
            Library.resetMockForTests("")
        }

        function test_a_switch_hides_the_steam_items_at_once_and_reloads_the_list() {
            compare(steamIn(Library.items).length, 5, "Player One's Steam games")
            verify(steamIn(Library.games).length > 0)
            verify(steamIn(Library.recent).length > 0)
            listed.clear()
            Library.profile = "p4"
            // Before the service has switched: p1's games are already gone from every list.
            compare(Library.activeProfile, "p1", "the service has not switched yet")
            compare(steamIn(Library.items), [], "no Steam item of p1 while p4 is in front")
            compare(steamIn(Library.games), [])
            compare(steamIn(Library.recent), [])
            compare(Library.item("steam:730"), {}, "not by id either")
            compare(listed.count, 1, "the hiding is announced")
            compare(Library.items.length, 5, "the Flatpak items stay")
            tryCompare(Library, "activeProfile", "p4")
            tryVerify(() => listed.count > 1, 2000, "the list is read again for p4")
            compare(steamIn(Library.items), [], "p4 has no Steam games")
            compare(Library.items.length, 5)
            verify(Library.item("flatpak:org.example.Racer").id, "the Flatpak games are there")
        }

        function test_between_two_profiles_with_steam_games_the_list_comes_back_after_the_switch() {
            Library.profile = "p2"
            compare(steamIn(Library.items), [], "Player One's games are hidden from Ada at once")
            tryCompare(Library, "activeProfile", "p2")
            tryVerify(() => Library.items.length === 10, 2000, "the list has 10 items")
            compare(Library.item("steam:730").title, "Counter Strike", "Ada's own Steam games")
        }

        function test_switching_back_brings_the_profiles_steam_items_back() {
            signIn("p4")
            tryVerify(() => Library.items.length === 5, 2000, "the list has 5 items")
            Library.profile = "p1"
            compare(steamIn(Library.items), [], "still p4's view until the service switches")
            tryCompare(Library, "activeProfile", "p1")
            tryVerify(() => Library.items.length === 10, 2000, "the list has 10 items")
            compare(Library.item("steam:730").title, "Counter Strike")
        }

        // A list that arrives after the switch but was read before it (the service answered before its
        // ActiveProfile change) never brings the previous profile's games back.
        function test_a_late_list_of_the_previous_profile_is_not_shown() {
            Library.mockListDelayed(100)            // read while p1 is active
            Library.profile = "p4"
            tryCompare(Library, "activeProfile", "p4")
            tryVerify(() => Library.mockPendingReplies() === 0, 2000, "the late reply has landed")
            compare(steamIn(Library.items), [], "p4 never sees Player One's games")
        }
    }
}
