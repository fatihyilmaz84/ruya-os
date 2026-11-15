import QtQuick
import QtTest
import RuyaShell

// RUY-468 (06 §7 "Storage", Input1.ForgetConsoleProfile): a console profile that goes takes its
// controller profiles in ruya-inputd with it. Profiles (C++, not QML) calls Input.forgetConsoleProfile
// after DeleteProfile answers "ok", for every guest that leaves the guest list (RemoveGuest, the wipe
// at Lock), and once at the shell's start for every id Input1 still stores that is neither a profile
// nor a live guest. Own file: the start sweep runs once per engine, before any test function, so
// initTestCase sets the mock's stored ids up before Profiles exists (no spy may target Profiles).
// The ListGuests failure at start is tst_input_forget_start.qml.
Item {
    id: host
    width: 320
    height: 240

    SignalSpy { id: storedSpy; target: Input; signalName: "storedConsoleProfilesListed" }
    SignalSpy { id: deleteSpy; signalName: "deleteFinished" }   // target: Profiles, once it exists

    TestCase {
        id: tc
        name: "InputForget"
        when: windowShown

        // What the start sweep did, read before the first test function clears the calls.
        property var startForgets: []
        property var startStored: []
        property int startSweeps: 0

        function forgets() {
            return Input.mockProfileCalls().filter(c => c.method === "ForgetConsoleProfile").map(c => c.args.profile)
        }

        function sweeps() {
            return Input.mockProfileCalls().filter(c => c.method === "StoredConsoleProfiles").length
        }

        function profile(id) {
            return JSON.stringify({ schema_version: 1, id: id, name: "Mine", scope: { type: "global" } })
        }

        // The shell's start: Input1 holds controller profiles of p1, p2 and p77, a profile that went
        // while the shell was down. Profiles is made here, by its first use.
        function initTestCase() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            for (const id of ["p1", "p2", "p77"])
                Input.mockAddStoredConsoleProfile(id)
            compare(Input.mockStoredConsoleProfiles(), ["p1", "p2", "p77"])
            verify(Profiles.mock)
            tryCompare(storedSpy, "count", 1)
            compare(storedSpy.signalArguments[0][0], "ok")
            tryVerify(() => Profiles.profiles.length === 3)
            // The sweep's Forget calls are made as the answer arrives; their own answers follow.
            tc.startForgets = forgets()
            tc.startSweeps = sweeps()
            tryVerify(() => Input.mockStoredConsoleProfiles().length === 2)
            tc.startStored = Input.mockStoredConsoleProfiles()
            deleteSpy.target = Profiles
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => Profiles.guests.length === 0)
            Input.mockClearProfileCalls()
            deleteSpy.clear()
        }

        function signIn() {
            Profiles.switchTo("p2", "")
            tryCompare(Profiles, "activeProfile", "p2")
        }

        // Creates a temporary guest and returns its id.
        function createGuest() {
            const before = Profiles.guests.length
            Profiles.createGuest()
            tryVerify(() => Profiles.guests.length === before + 1)
            return Profiles.guests[Profiles.guests.length - 1].id
        }

        function test_the_start_sweep_forgets_only_the_orphan() {
            compare(tc.startSweeps, 1, "one StoredConsoleProfiles, once both lists answered")
            compare(tc.startForgets, ["p77"], "only the id that is neither a profile nor a guest")
            compare(tc.startStored, ["p1", "p2"])
        }

        function test_a_deleted_profile_forgets_its_controls() {
            Input.saveProfile("p3", profile("mine"))
            tryVerify(() => Input.mockStoredConsoleProfiles().indexOf("p3") >= 0)
            // A refused delete forgets nothing (Profiles reacts as deleteFinished arrives).
            Profiles.deleteProfile("p1", "0000", "p3")
            tryCompare(deleteSpy, "count", 1)
            compare(deleteSpy.signalArguments[0][1], "wrong-pin")
            compare(forgets(), [], "wrong PIN: nothing goes")
            Profiles.deleteProfile("p1", "1234", "p3")
            tryCompare(deleteSpy, "count", 2)
            compare(deleteSpy.signalArguments[1][1], "ok")
            compare(forgets(), ["p3"], "Forget is called as DeleteProfile answers ok")
            tryVerify(() => Input.mockStoredConsoleProfiles().indexOf("p3") < 0)
        }

        function test_a_removed_guest_forgets_its_controls() {
            signIn()
            const id = createGuest()
            Input.saveProfile(id, profile("mine"))
            tryVerify(() => Input.mockStoredConsoleProfiles().indexOf(id) >= 0)
            compare(forgets(), [], "a guest that joins keeps its controls")
            Profiles.removeGuest(id)
            tryVerify(() => Profiles.guests.length === 0)
            tryVerify(() => forgets().length === 1)
            compare(forgets(), [id])
            tryVerify(() => Input.mockStoredConsoleProfiles().indexOf(id) < 0)
        }

        function test_the_guest_wipe_forgets_every_guest() {
            signIn()
            const a = createGuest()
            const b = createGuest()
            verify(a !== b)
            compare(forgets(), [])
            Profiles.lock()   // the session ends: ListGuests answers without both
            tryVerify(() => Profiles.guests.length === 0)
            tryVerify(() => forgets().length === 2)
            compare(forgets().slice().sort(), [a, b].sort())
            compare(sweeps(), 0, "the start sweep ran once, at start")
        }
    }
}
