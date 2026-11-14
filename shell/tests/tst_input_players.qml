import QtQuick
import QtTest
import RuyaShell

// The players' seats (RUY-121, ADR-017, 06 section 11.3) through the Input singleton and the mock
// service, which keeps ruya-inputd's rules (routing.rs, seats.rs): a sign-in seats player 1 on the
// pad that signed in (the pad of the last mockActiveInput since the lock, or none for a keyboard
// sign-in); JoinPlayer and LeavePlayer answer the XML's statuses; PlayersChanged reaches
// Input.players; a new owner of the name has the list asked again, after the players the shell knew
// joined again (a restarted service knows no seats). No Shell: nothing else calls SetRoute here.
Item {
    id: host
    width: 1280
    height: 720

    readonly property string dualSense: "bluetooth-054c-0ce6-3f2a9c41d0b7"
    readonly property string xbox: "usb-045e-0b12-8e01c2d4a9f3"
    readonly property string pro: "bluetooth-057e-2009-b7c0e1f2a3d4"

    SignalSpy { id: joinSpy; target: Input; signalName: "joinFinished" }
    SignalSpy { id: leaveSpy; target: Input; signalName: "leaveFinished" }

    TestCase {
        id: tc
        name: "InputPlayers"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Input.mockFail(false)
            Input.mockFailJoin("")
            Input.mockNameOwned(true)
            Input.mockResetDevices()
            route("locked", "")
            tryVerify(() => Input.players.length === 0, 2000, "no seats while locked")
            joinSpy.clear()
            leaveSpy.clear()
        }

        function cleanup() {
            Input.mockFailJoin("")
            Input.mockNameOwned(true)
        }

        // Sends a route with no app and waits for the mock service's "ok".
        function route(name, profile) {
            Input.setRoute(name, "", "", profile)
            tryVerify(() => Input.status === "ok" && Input.mockServiceProfile() === profile, 2000,
                      name + " " + profile + ": " + Input.status)
        }

        // The seats as "slot:profile:device" lines, for one compare.
        function seats(list) {
            return list.map(p => p.slot + ":" + p.profile + ":" + p.device_id).join(" ")
        }

        // JoinPlayer, then its answer: [status, slot].
        function join(deviceId, profile) {
            const before = joinSpy.count
            Input.joinPlayer(deviceId, profile)
            tryVerify(() => joinSpy.count === before + 1, 2000, "JoinPlayer " + deviceId + " answered")
            const args = joinSpy.signalArguments[before]
            compare(args[0], deviceId)
            compare(args[1], profile)
            return [args[2], args[3]]
        }

        function leave(slot) {
            const before = leaveSpy.count
            Input.leavePlayer(slot)
            tryVerify(() => leaveSpy.count === before + 1, 2000, "LeavePlayer " + slot + " answered")
            compare(leaveSpy.signalArguments[before][0], slot)
            return leaveSpy.signalArguments[before][1]
        }

        function deviceRecord(id) {
            return Input.devices.find(d => d.id === id)
        }

        function signInWith(deviceId, profile) {
            Input.mockActiveInput(deviceId, "playstation")
            route("shell", profile)
            tryVerify(() => seats(Input.players) === "1:" + profile + ":" + deviceId, 2000,
                      "player 1 on the pad that signed in: " + seats(Input.players))
        }

        function test_a_pad_sign_in_seats_player_1_on_that_pad() {
            signInWith(host.dualSense, "p1")
            const p = Input.players[0]
            compare(p.held, false)
            compare(p.held_secs, 0)
            tryVerify(() => deviceRecord(host.dualSense).slot === 1 && deviceRecord(host.dualSense).profile === "p1",
                      2000, "the device record names the seat")
            compare(deviceRecord(host.xbox).slot, 0)
            compare(deviceRecord(host.xbox).profile, "")
            compare(seats(Input.mockPlayers()), seats(Input.players))
        }

        function test_a_keyboard_sign_in_seats_player_1_without_a_pad() {
            // The last press was before the lock: it does not count for the next profile.
            route("shell", "p2")
            tryVerify(() => seats(Input.players) === "1:p2:", 2000, seats(Input.players))
        }

        function test_join_and_leave_answer_their_statuses() {
            signInWith(host.dualSense, "p1")
            compare(join(host.xbox, "p2"), ["ok", 2])
            compare(join(host.pro, "p3"), ["ok", 3])
            Input.mockAddDevice({ id: "usb-1234-5678-000000000001", family: "generic" })
            Input.mockAddDevice({ id: "usb-1234-5678-000000000002", family: "generic" })
            tryVerify(() => Input.devices.length === 5, 2000, "five pads")
            compare(join("usb-1234-5678-000000000001", "p4"), ["ok", 4])
            tryVerify(() => Input.players.length === 4, 2000, "four players")
            compare(join("usb-1234-5678-000000000002", "p5"), ["full", 0])
            compare(Input.mockPlayers().length, 4, "full changes nothing")
            compare(join("usb-0000-0000-ffffffffffff", "p5"), ["unknown-device", 0])
            compare(join("Not An Id", "p5"), ["invalid", 0])
            compare(join(host.dualSense, "../p1"), ["unknown-profile", 0])
            // The same pad and profile again: ok, nothing changes.
            compare(join(host.xbox, "p2"), ["ok", 2])
            compare(leave(1), "not-allowed")
            compare(leave(0), "invalid")
            compare(leave(5), "invalid")
            compare(leave(2), "ok")
            tryVerify(() => Input.players.length === 3, 2000, "seat 2 is free: " + seats(Input.players))
            compare(leave(2), "ok", "an empty seat")
            Input.mockFailJoin("failed")
            compare(join(host.xbox, "p2"), ["failed", 0])
            Input.mockFailJoin("")
            // Locked: nobody is signed in.
            route("locked", "")
            compare(join(host.xbox, "p2"), ["not-allowed", 0])
            compare(leave(2), "not-allowed")
        }

        function test_players_changed_reaches_players() {
            signInWith(host.dualSense, "p1")
            Input.joinPlayer(host.xbox, "p2")
            tryVerify(() => seats(Input.players) === "1:p1:" + host.dualSense + " 2:p2:" + host.xbox, 2000,
                      seats(Input.players))
            // p2 moves to the Pro Controller and keeps seat 2; the Xbox pad is unseated.
            compare(join(host.pro, "p2"), ["ok", 2])
            tryVerify(() => seats(Input.players) === "1:p1:" + host.dualSense + " 2:p2:" + host.pro, 2000,
                      seats(Input.players))
            tryVerify(() => deviceRecord(host.xbox).slot === 0 && deviceRecord(host.pro).slot === 2, 2000,
                      "the records follow")
            // A seated pad that goes frees its seat; player 1's leaves seat 1 without a pad.
            Input.mockRemoveDevice(host.pro)
            tryVerify(() => seats(Input.players) === "1:p1:" + host.dualSense, 2000, seats(Input.players))
            Input.mockRemoveDevice(host.dualSense)
            tryVerify(() => seats(Input.players) === "1:p1:", 2000, seats(Input.players))
        }

        function test_the_players_join_again_when_the_service_restarts() {
            signInWith(host.dualSense, "p1")
            compare(join(host.xbox, "p2"), ["ok", 2])
            const both = "1:p1:" + host.dualSense + " 2:p2:" + host.xbox
            tryVerify(() => seats(Input.players) === both, 2000, seats(Input.players))
            const joins = joinSpy.count
            // A new process knows no seats; the shell's route alone would seat player 1 on no pad.
            Input.mockRestart()
            tryVerify(() => seats(Input.mockPlayers()) === both, 2000,
                      "the restarted service has the players again: " + seats(Input.mockPlayers()))
            tryVerify(() => seats(Input.players) === both, 2000, seats(Input.players))
            compare(joinSpy.count, joins, "the shell's replay is not announced as a join")
        }

        function test_the_list_is_asked_again_when_the_name_gets_a_new_owner() {
            signInWith(host.dualSense, "p1")
            // While the name has no owner its PlayersChanged is not heard.
            Input.mockNameOwned(false)
            compare(join(host.xbox, "p2"), ["ok", 2])
            compare(seats(Input.players), "1:p1:" + host.dualSense, "no signal reached the shell")
            Input.mockNameOwned(true)
            tryVerify(() => seats(Input.players) === "1:p1:" + host.dualSense + " 2:p2:" + host.xbox, 2000,
                      "ListPlayers again: " + seats(Input.players))
        }
    }
}
