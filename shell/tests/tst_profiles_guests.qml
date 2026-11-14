import QtQuick
import QtTest
import RuyaShell

// RUY-125: VerifyPin (a profile's PIN without signing in) and temporary guests, against the
// mock, which keeps the rules of services/ruya-profiles: a guest needs a signed-in profile, at
// most 3, numbered lowest free, never in `profiles`, wiped on lock() and on a switch to another
// profile, and it only joins. Own file: it signs in and fails PINs; the mock is reset before
// every test.
Item {
    id: host
    width: 320
    height: 240

    SignalSpy { id: verifySpy; target: Profiles; signalName: "pinVerified" }
    SignalSpy { id: createSpy; target: Profiles; signalName: "guestCreated" }
    SignalSpy { id: removeSpy; target: Profiles; signalName: "guestRemoved" }
    SignalSpy { id: switchSpy; target: Profiles; signalName: "switchFinished" }
    SignalSpy { id: pinSpy; target: Profiles; signalName: "setPinFinished" }
    SignalSpy { id: renameSpy; target: Profiles; signalName: "renameFinished" }
    SignalSpy { id: deleteSpy; target: Profiles; signalName: "deleteFinished" }

    TestCase {
        id: tc
        name: "ProfilesGuests"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => Profiles.guests.length === 0)
            for (const spy of [verifySpy, createSpy, removeSpy, switchSpy, pinSpy, renameSpy, deleteSpy])
                spy.clear()
        }

        // Calls fn and returns the arguments of the next signal of spy.
        function reply(spy, fn) {
            const before = spy.count
            fn()
            tryCompare(spy, "count", before + 1)
            return Array.prototype.slice.call(spy.signalArguments[before])   // an Arguments object, as an array
        }

        function verifyPin(id, pin) { return reply(verifySpy, () => Profiles.verifyPin(id, pin)) }  // [id, status, attemptsLeft, retryAfterSecs]
        function createGuest() { return reply(createSpy, () => Profiles.createGuest()) }            // [status, id, number]
        function removeGuest(id) { return reply(removeSpy, () => Profiles.removeGuest(id)) }        // [id, status]
        function switchTo(id, pin) { return reply(switchSpy, () => Profiles.switchTo(id, pin)) }    // [id, status, ...]

        function signIn() {
            compare(switchTo("p1", "1234")[1], "ok")
            tryCompare(Profiles, "activeProfile", "p1")
        }

        function guestNumbers() { return Profiles.guests.map(g => g.number) }

        function test_verify_pin_statuses_and_no_sign_in() {
            compare(switchTo("p2", "")[1], "ok")
            tryCompare(Profiles, "activeProfile", "p2")
            compare(verifyPin("p1", "1234"), ["p1", "ok", 0, 0])
            compare(Profiles.activeProfile, "p2", "the right PIN does not switch")
            compare(verifyPin("p1", "0000"), ["p1", "wrong-pin", 4, 0])
            compare(verifyPin("p1", "").slice(0, 3), ["p1", "pin-required", 4])
            compare(verifyPin("p2", "")[1], "ok", "a profile without a PIN")
            compare(verifyPin("nope", "")[1], "unknown-profile")
            compare(Profiles.activeProfile, "p2", "VerifyPin never switches")
        }

        function test_verify_pin_locks_out_like_switch_to() {
            for (let left = 4; left > 0; --left)
                compare(verifyPin("p1", "0000").slice(1, 3), ["wrong-pin", left])
            const locked = verifyPin("p1", "0000")
            compare(locked[1], "locked-out")
            verify(locked[3] > 0, "retry_after_secs on locked-out")
            compare(switchTo("p1", "1234")[1], "locked-out", "the lockout is shared with SwitchTo")
            compare(verifyPin("p1", "1234")[1], "locked-out")
            compare(Profiles.activeProfile, "")
        }

        function test_create_guest_numbers_and_the_cap() {
            compare(createGuest()[0], "not-allowed", "no profile signed in")
            compare(Profiles.guests.length, 0)
            signIn()
            const ids = []
            for (let n = 1; n <= 3; ++n) {
                const r = createGuest()
                compare(r[0], "ok")
                compare(r[2], n)
                ids.push(r[1])
            }
            compare(ids, ["p4", "p5", "p6"], "ids from the never-reused counter")
            compare(createGuest(), ["not-allowed", "", 0], "at most 3 guests")
            compare(guestNumbers(), [1, 2, 3])
            compare(Profiles.profiles.length, 3, "guests are never profiles")
            verify(Profiles.profiles.every(p => ids.indexOf(p.id) < 0))
            verify(Profiles.guests.every(g => /^#[0-9a-f]{6}$/.test(g.avatar)), "a palette colour")

            compare(removeGuest("p4"), ["p4", "ok"])
            compare(guestNumbers(), [2, 3])
            const again = createGuest()
            compare(again, ["ok", "p7", 1], "the lowest free number, a new id")
            compare(guestNumbers(), [1, 2, 3])
            compare(Profiles.guests.map(g => g.id), ["p7", "p5", "p6"], "listed by number")
        }

        function test_remove_guest_never_removes_a_profile() {
            signIn()
            compare(removeGuest("p2"), ["p2", "unknown-profile"])
            compare(removeGuest("nope"), ["nope", "unknown-profile"])
            compare(Profiles.profiles.length, 3)
        }

        function test_a_guest_only_joins() {
            signIn()
            const id = createGuest()[1]
            compare(verifyPin(id, "")[1], "not-allowed")
            compare(switchTo(id, "")[1], "not-allowed")
            compare(reply(pinSpy, () => Profiles.setPin(id, "", "4321"))[1], "not-allowed")
            compare(reply(renameSpy, () => Profiles.renameProfile("p1", "1234", id, "Bob"))[1], "not-allowed")
            compare(reply(deleteSpy, () => Profiles.deleteProfile("p1", "1234", id))[1], "not-allowed")
            compare(Profiles.activeProfile, "p1")
            compare(Profiles.guests.length, 1)
        }

        function test_lock_wipes_every_guest() {
            signIn()
            createGuest()
            createGuest()
            compare(Profiles.guests.length, 2)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => Profiles.guests.length === 0)
            signIn()
            compare(createGuest()[2], 1, "numbering starts over in the next session")
        }

        function test_a_switch_to_another_profile_wipes_every_guest() {
            signIn()
            createGuest()
            compare(switchTo("p1", "1234")[1], "ok")
            compare(Profiles.guests.length, 1, "signing in the same profile again keeps the session")
            compare(switchTo("p2", "")[1], "ok")
            tryCompare(Profiles, "activeProfile", "p2")
            compare(Profiles.guests.length, 0, "a switch ends the session")
        }
    }
}
