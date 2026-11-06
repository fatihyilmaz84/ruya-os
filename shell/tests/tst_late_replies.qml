import QtQuick
import QtTest
import RuyaShell

// T-191: a reply to an older list request that arrives after a newer one must not put the old
// list back (Profiles, Library, Update). The mock holds one reply back (mock...Delayed: a snapshot
// of now), the data changes, and the late reply lands on top of the newer one. The same guard
// (RequestSequence) sits in the D-Bus clients. Own file: it resets the singletons it uses.
Item {
    id: host
    width: 320
    height: 240

    TestCase {
        id: tc
        name: "LateReplies"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            Library.resetMockForTests("")
            tryVerify(() => Library.items.length === 10)
            Update.mockReset()
            tryCompare(Update, "state", "idle")
            tryVerify(() => Profiles.mockPendingReplies() === 0 && Library.mockPendingReplies() === 0
                            && Update.mockPendingReplies() === 0)
        }

        function profileNamed(name) { return Profiles.profiles.some(p => p.name === name) }

        // The list is asked for (the reply, a snapshot with "Ada", is held back), then Ada is
        // renamed and the list published again: the late snapshot must not bring "Ada" back.
        function test_profiles_a_late_list_is_dropped() {
            verify(profileNamed("Ada"))
            Profiles.mockRefreshDelayed(300)
            compare(Profiles.mockPendingReplies(), 1)
            Profiles.renameProfile("p1", "1234", "p2", "Ada Lovelace")
            tryVerify(() => profileNamed("Ada Lovelace"))
            tryVerify(() => Profiles.mockPendingReplies() === 0, 2000)
            verify(profileNamed("Ada Lovelace"), "the late snapshot was dropped")
            verify(!profileNamed("Ada"))
        }

        function test_library_a_late_list_is_dropped() {
            Library.mockListDelayed(300)                 // a snapshot with ten items
            compare(Library.mockPendingReplies(), 1)
            Library.resetMockForTests("empty")           // the service says ItemsChanged: nothing left
            tryVerify(() => Library.items.length === 0)
            tryVerify(() => Library.mockPendingReplies() === 0, 2000)
            compare(Library.items.length, 0, "the late snapshot did not bring ten items back")
        }

        function test_update_a_late_status_is_dropped() {
            verify(Update.rollbackAvailable)
            Update.mockRefreshDelayed(300)               // a snapshot with a rollback available
            compare(Update.mockPendingReplies(), 1)
            Update.mockSetRollbackAvailable(false)
            tryCompare(Update, "rollbackAvailable", false)
            tryVerify(() => Update.mockPendingReplies() === 0, 2000)
            compare(Update.rollbackAvailable, false, "the late snapshot was dropped")
        }
    }
}
