import QtQuick
import QtTest
import RuyaShell

// RUY-468 (06 §7 "Storage"): the shell's start sweep never runs on a partial view. Here the first
// ListGuests fails: Profiles does not ask Input1 for its stored console profiles (a live guest's
// controls could be among them) until a later refresh lists both. Own file: the sweep runs once
// per engine, and the failure must reach Profiles' first refresh (no spy may target Profiles).
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

        function test_the_sweep_waits_for_both_lists() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Input.mockAddStoredConsoleProfile("p77")
            // Profiles is made by this call; its first refresh answers after it, ListGuests failing.
            Profiles.mockFailGuests("listGuests", "failed", 1)
            tryVerify(() => Profiles.profiles.length === 3)
            compare(Profiles.guests, [])
            // One more answer through the mock's queue: anything a wrong sweep set off is in by now.
            Input.listProfiles("p1")
            tryCompare(listedSpy, "count", 1)
            compare(calls("StoredConsoleProfiles").length, 0, "ListGuests failed: no sweep")
            compare(calls("ForgetConsoleProfile").length, 0)
            compare(Input.mockStoredConsoleProfiles(), ["p77"])
            // Both lists answer: the sweep runs, once, and forgets the orphan.
            Profiles.refresh()
            tryCompare(storedSpy, "count", 1)
            tryVerify(() => calls("ForgetConsoleProfile").length === 1)
            compare(calls("ForgetConsoleProfile")[0].args, { profile: "p77" })
            tryVerify(() => Input.mockStoredConsoleProfiles().length === 0)
            Profiles.refresh()
            tryVerify(() => Profiles.mockPendingReplies() === 0)
            Input.listProfiles("p1")
            tryCompare(listedSpy, "count", 2)
            compare(calls("StoredConsoleProfiles").length, 1, "once per start")
        }
    }
}
