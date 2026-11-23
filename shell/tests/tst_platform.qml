import QtQuick
import QtTest
import RuyaShell

// RUY-1104: the Platform facade (org.ruyaos.Platform1.Manage) against the mock backend: the
// capabilities and their defaults, the permissions a profile set, setting one, a reply that arrives
// after a newer one, and the one rule of who may change whose permissions (mayChange, lead-45).
// Mock profiles: p1 Player One (admin, PIN 1234), p2 Ada (standard), p3 Sam (guest role).
Item {
    id: host
    width: 320
    height: 240

    SignalSpy { id: setSpy; target: Platform; signalName: "setPermissionFinished" }
    SignalSpy { id: listSpy; target: Platform; signalName: "permissionsChanged" }
    SignalSpy { id: failSpy; target: Platform; signalName: "permissionsFailed" }

    TestCase {
        id: tc
        name: "Platform"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            Platform.mockReset()
            setSpy.clear()
            failSpy.clear()
            listSpy.clear()
        }

        function signIn(id, pin) {
            Profiles.switchTo(id, pin)
            tryCompare(Profiles, "activeProfile", id)
        }

        // The arguments of the spy's first emission, one by one (QtTest's compare of two arrays
        // does not look inside).
        function compareArgs(spy, expected) {
            compare(spy.signalArguments[0].length, expected.length)
            for (let i = 0; i < expected.length; ++i)
                compare(spy.signalArguments[0][i], expected[i])
        }

        // Asks for a profile's list and waits for the reply (the singleton keeps the last list
        // of an earlier test, so the profile alone would not tell).
        function load(profileId) {
            const before = listSpy.count
            Platform.refreshPermissions(profileId)
            tryVerify(() => listSpy.count === before + 1)
            compare(Platform.permissionsProfile, profileId)
        }

        function test_capabilities_list_every_key_with_its_default() {
            compare(Platform.capabilities.length, 0)
            Platform.refreshCapabilities()
            tryVerify(() => Platform.capabilities.length === 1)
            compare(Platform.capabilities[0].key, "lifecycle")
            compare(Platform.capabilities[0].defaultAllowed, true)
        }

        function test_a_set_permission_is_listed() {
            signIn("p2", "")
            load("p2")
            compare(Platform.permissions.length, 0, "nothing set: the defaults")
            Platform.setPermission("p2", "org.example.Racer", "lifecycle", false)
            tryCompare(setSpy, "count", 1)
            compareArgs(setSpy, ["p2", "org.example.Racer", "lifecycle", "ok"])
            load("p2")
            compare(Platform.permissions.length, 1)
            compare(Platform.permissions[0].appId, "org.example.Racer")
            compare(Platform.permissions[0].capability, "lifecycle")
            compare(Platform.permissions[0].allowed, false)
            Platform.setPermission("p2", "org.example.Racer", "lifecycle", true)
            tryCompare(setSpy, "count", 2)
            load("p2")
            compare(Platform.permissions.length, 1)
            compare(Platform.permissions[0].allowed, true)
        }

        function test_a_bad_request_is_refused_by_the_backend() {
            signIn("p2", "")
            Platform.setPermission("p2", "org.example.Racer", "nonsense", true)
            tryCompare(setSpy, "count", 1)
            compare(setSpy.signalArguments[0][3], "invalid-argument")
            Platform.refreshPermissions("")
            tryCompare(failSpy, "count", 1)
            compareArgs(failSpy, ["", "invalid-argument"])
        }

        // The reply to the first list (held back, a snapshot of p2) arrives after the list of p1:
        // it must not put p2's choices back.
        function test_a_late_permission_list_is_dropped() {
            signIn("p1", "1234")
            Platform.setPermission("p2", "org.example.Racer", "lifecycle", false)
            tryCompare(setSpy, "count", 1)
            Platform.mockRefreshDelayed(300, "p2")
            compare(Platform.mockPendingReplies(), 1)
            load("p1")
            compare(Platform.permissions.length, 0)
            tryVerify(() => Platform.mockPendingReplies() === 0)
            wait(0)
            compare(listSpy.count, 1, "the late reply of p2 was dropped")
            compare(Platform.permissionsProfile, "p1")
            compare(Platform.permissions.length, 0)
        }

        function test_mayChange_a_profile_changes_its_own() {
            signIn("p2", "")
            verify(Platform.mayChange("p2"))
            verify(!Platform.mayChange("p1"), "a standard profile never changes another's")
            verify(!Platform.mayChange("p3"))
            verify(!Platform.mayChange(""))
        }

        function test_mayChange_an_admin_changes_any() {
            signIn("p1", "1234")
            verify(Platform.mayChange("p1"))
            verify(Platform.mayChange("p2"))
            verify(Platform.mayChange("p3"))
        }

        function test_mayChange_nobody_changes_a_temporary_guests() {
            signIn("p1", "1234")
            Profiles.createGuest()
            tryVerify(() => Profiles.guests.length === 1)
            const guest = Profiles.guests[0].id
            verify(!Platform.mayChange(guest), "a guest has the defaults only")
            verify(Platform.mayChange("p2"))
        }

        function test_mayChange_a_guest_changes_nothing() {
            signIn("p3", "")
            verify(!Platform.mayChange("p3"))
            verify(!Platform.mayChange("p1"))
            verify(!Platform.mayChange("p2"))
        }

        function test_mayChange_nobody_signed_in_changes_nothing() {
            verify(!Platform.mayChange("p1"))
        }

        function test_set_permission_follows_mayChange() {
            signIn("p3", "")
            Platform.setPermission("p2", "org.example.Racer", "lifecycle", false)
            tryCompare(setSpy, "count", 1)
            compareArgs(setSpy, ["p2", "org.example.Racer", "lifecycle", "not-allowed"])
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            signIn("p1", "1234")
            load("p2")
            compare(Platform.permissions.length, 0, "the refused set changed nothing")
        }
    }
}
