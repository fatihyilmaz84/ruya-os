import QtQuick
import QtTest
import RuyaShell

// RUY-468 (06 §7 "Storage"): the shell's start sweep never runs on a partial view, and never forgets
// an id it saw listed while it waited. Here the first ListGuests fails: Profiles does not ask Input1
// for its stored console profiles (a live guest's controls could be among them) until a later refresh
// lists both. Then the sweep's StoredConsoleProfiles answer is held while a profile p4 is made (listed)
// and leaves the list again without this shell deleting it; the answer lists p4 and the orphan p77,
// and only p77 is forgotten. Own file: the sweep runs once per engine, and the failure must reach
// Profiles' first refresh (no spy may target Profiles).
Item {
    id: host
    width: 320
    height: 240

    SignalSpy { id: listedSpy; target: Input; signalName: "profilesListed" }
    SignalSpy { id: storedSpy; target: Input; signalName: "storedConsoleProfilesListed" }

    TestCase {
        id: tc
        name: "InputForgetStart"
        when: windowShown

        function calls(method) {
            return Input.mockProfileCalls().filter(c => c.method === method)
        }

        function listedIds() {
            return Profiles.profiles.map(p => p.id).join(",")
        }

        function test_the_sweep_waits_for_both_lists_and_keeps_what_it_saw() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Input.mockAddStoredConsoleProfile("p77")
            Input.mockAddStoredConsoleProfile("p4")
            // Profiles is made by this call; its first refresh answers after it, ListGuests failing.
            Profiles.mockFailGuests("listGuests", "failed", 1)
            tryVerify(() => Profiles.profiles.length === 3)
            compare(Profiles.guests, [])
            // One more answer through the mock's queue: anything a wrong sweep set off is in by now.
            Input.listProfiles("p1")
            tryCompare(listedSpy, "count", 1)
            compare(calls("StoredConsoleProfiles").length, 0, "ListGuests failed: no sweep")
            compare(calls("ForgetConsoleProfile").length, 0)
            compare(Input.mockStoredConsoleProfiles(), ["p4", "p77"])

            // Both lists answer: the sweep asks, and its answer waits.
            Input.mockHoldStoredConsoleProfiles(true)
            Profiles.refresh()
            tryVerify(() => calls("StoredConsoleProfiles").length === 1)
            compare(storedSpy.count, 0)
            // While it waits, p4 is made (the mock's next id) and listed...
            Profiles.createProfile("p1", "1234", "Late Player", "standard", "")
            tryVerify(() => listedIds() === "p1,p2,p3,p4", 2000, listedIds())
            // ...and leaves the list again without this shell deleting it (no deleteFinished).
            Profiles.resetMockForTests("seeded")
            tryVerify(() => listedIds() === "p1,p2,p3", 2000, listedIds())
            compare(calls("ForgetConsoleProfile").length, 0)
            // The answer lists p4 and p77: p4 was seen while the sweep waited and is kept.
            Input.mockHoldStoredConsoleProfiles(false)
            tryCompare(storedSpy, "count", 1)
            compare(storedSpy.signalArguments[0][1], ["p4", "p77"])
            tryVerify(() => calls("ForgetConsoleProfile").length === 1)
            compare(calls("ForgetConsoleProfile")[0].args, { profile: "p77" })
            tryVerify(() => Input.mockStoredConsoleProfiles().length === 1)
            compare(Input.mockStoredConsoleProfiles(), ["p4"])

            // Once per start: later refreshes do not sweep again.
            Profiles.refresh()
            tryVerify(() => Profiles.mockPendingReplies() === 0)
            Input.listProfiles("p1")
            tryCompare(listedSpy, "count", 2)
            compare(calls("StoredConsoleProfiles").length, 1, "once per start")
            compare(calls("ForgetConsoleProfile").length, 1)
        }
    }
}
