import QtQuick
import QtTest
import RuyaShell

// The emergency pad reader (RUY-410, 06 section 8): when org.ruyaos.Input1 has had no owner for 3 s
// the shell reads the physical pads itself and sends the navigation keys of ruya-inputd's Phase 0
// table, until the name has an owner again. Three layers: PadMapper (one pad's evdev events to
// keys), EmergencyReader (the 3 s rule, several pads, a vanished pad; the watcher is faked by
// setting serviceOwned) and the Shell (the keys reach the focused page and never an app).
Item {
    id: host
    width: 1280
    height: 720

    // The kernel's numbers the mapper reads.
    readonly property int evKey: 1
    readonly property int evAbs: 3
    readonly property int absX: 0x00
    readonly property int absY: 0x01
    readonly property int hatX: 0x10
    readonly property int hatY: 0x11
    readonly property int btnSouth: 0x130
    readonly property int btnEast: 0x131
    readonly property int btnStart: 0x13b
    readonly property int btnMode: 0x13c
    readonly property int btnTl: 0x136
    readonly property int dpadUp: 0x220
    readonly property int dpadRight: 0x223

    Component { id: mapperComponent; PadMapper { } }
    Component { id: devicesComponent; PadDevices { } }
    // The type's own defaults.
    Component { id: plainReader; EmergencyReader { } }

    // A reader that logs its keys as "Up+" / "Up-" (a Qt key name is not needed: the code is enough).
    Component {
        id: readerComponent
        EmergencyReader {
            property var log: []
            readDevices: false
            graceMs: 40
            onKey: (key, pressed) => log = log.concat([key + (pressed ? "+" : "-")])
        }
    }

    // The same, logging to the host, which outlives it.
    property var observed: []
    Component {
        id: observedReaderComponent
        EmergencyReader {
            readDevices: false
            graceMs: 40
            onKey: (key, pressed) => host.observed = host.observed.concat([key + (pressed ? "+" : "-")])
        }
    }

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // A window of an app that takes every key, like a game, and remembers them.
    Component {
        id: appComponent
        Item {
            objectName: "standInApp"
            property string appId: "org.example.Racer"
            property var seen: []
            Keys.onPressed: event => { seen = seen.concat([event.key]); event.accepted = true }
        }
    }

    SignalSpy { id: launchedSpy; target: Session; signalName: "launchFinished" }

    TestCase {
        id: tc
        name: "InputEmergency"
        when: windowShown

        property Shell shell: null
        // A QtObject property reads null once its object is deleted (a var keeps the wrapper).
        property QtObject subject: null
        property PadDevices devices: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Input.mockNameOwned(true)
            launchedSpy.clear()
        }

        function cleanup() {
            Input.mockNameOwned(true)
        }

        function pressed(events) { return events.map(e => e.key + (e.pressed ? "+" : "-")) }

        function mapper() {
            const m = createTemporaryObject(mapperComponent, host)
            verify(m)
            return m
        }

        // ---- PadMapper ------------------------------------------------------------------------

        function test_buttons_map_to_the_navigation_keys_and_release() {
            const m = mapper()
            const table = [[btnSouth, Qt.Key_Return], [btnEast, Qt.Key_Escape], [btnStart, Qt.Key_Menu],
                           [btnMode, Qt.Key_HomePage], [dpadUp, Qt.Key_Up], [dpadRight, Qt.Key_Right]]
            for (const row of table) {
                compare(pressed(m.feed(evKey, row[0], 1)), [row[1] + "+"], "button " + row[0] + " presses")
                compare(m.heldKeys(), [row[1]])
                compare(pressed(m.feed(evKey, row[0], 0)), [row[1] + "-"], "button " + row[0] + " releases")
                compare(m.heldKeys(), [])
            }
        }

        function test_what_is_not_in_the_table_gives_nothing() {
            const m = mapper()
            compare(m.feed(evKey, btnTl, 1), [], "a shoulder button is not in the emergency table")
            compare(m.feed(evAbs, 0x02, 32767), [], "ABS_Z is not a stick")
            compare(m.feed(0, 0, 0), [], "a sync event")
            compare(m.heldKeys(), [])
        }

        function test_a_repeat_and_a_release_never_seen_pressed_hold_nothing() {
            const m = mapper()
            compare(pressed(m.feed(evKey, btnSouth, 1)), [Qt.Key_Return + "+"])
            compare(m.feed(evKey, btnSouth, 2), [], "a kernel repeat is no second press")
            compare(m.feed(evKey, btnSouth, 1), [], "a second press while down is no second hold")
            compare(pressed(m.feed(evKey, btnSouth, 0)), [Qt.Key_Return + "-"], "one release lets go")
            // Opened with the button held: the release comes without a press.
            compare(m.feed(evKey, btnEast, 0), [], "a release without a press does nothing")
        }

        function test_hat_axes_press_and_release_in_both_directions() {
            const m = mapper()
            compare(pressed(m.feed(evAbs, hatX, -1)), [Qt.Key_Left + "+"])
            compare(pressed(m.feed(evAbs, hatX, 1)), [Qt.Key_Left + "-", Qt.Key_Right + "+"], "straight across")
            compare(pressed(m.feed(evAbs, hatY, -1)), [Qt.Key_Up + "+"], "a second axis at once")
            compare(m.heldKeys().sort(), [Qt.Key_Up, Qt.Key_Right].sort())
            compare(pressed(m.feed(evAbs, hatX, 0)), [Qt.Key_Right + "-"])
            compare(pressed(m.feed(evAbs, hatY, 1)), [Qt.Key_Up + "-", Qt.Key_Down + "+"])
            compare(pressed(m.feed(evAbs, hatY, 0)), [Qt.Key_Down + "-"])
            compare(m.heldKeys(), [])
        }

        function test_stick_presses_at_60_percent_and_lets_go_below_35() {
            const m = mapper()
            // Default range -32768..32767 (half range 32767.5, centre -0.5).
            compare(m.feed(evAbs, absX, 14000), [], "43 % from rest: not pressed")
            compare(m.feed(evAbs, absX, 19000), [], "58 % from rest: not pressed")
            compare(pressed(m.feed(evAbs, absX, 20000)), [Qt.Key_Right + "+"], "61 %: pressed")
            compare(m.feed(evAbs, absX, 15000), [], "46 %: held (hysteresis)")
            compare(m.feed(evAbs, absX, 12000), [], "37 %: held (hysteresis)")
            compare(pressed(m.feed(evAbs, absX, 10000)), [Qt.Key_Right + "-"], "30 %: released")
            compare(m.feed(evAbs, absX, 15000), [], "46 % again from rest: not pressed, no chatter")

            compare(pressed(m.feed(evAbs, absY, -32000)), [Qt.Key_Up + "+"], "stick up is negative")
            compare(pressed(m.feed(evAbs, absY, 32000)), [Qt.Key_Up + "-", Qt.Key_Down + "+"], "flip straight across")
            compare(pressed(m.feed(evAbs, absY, 0)), [Qt.Key_Down + "-"])
            compare(pressed(m.feed(evAbs, absX, -25000)), [Qt.Key_Left + "+"])
            compare(pressed(m.feed(evAbs, absX, 0)), [Qt.Key_Left + "-"])
        }

        function test_stick_uses_the_range_the_pad_reports() {
            const m = mapper()
            m.setAxisRange(absX, 0, 255)                  // an 8-bit stick: centre 127.5
            compare(m.feed(evAbs, absX, 128), [], "centre")
            compare(m.feed(evAbs, absX, 200), [], "57 %")
            compare(pressed(m.feed(evAbs, absX, 210)), [Qt.Key_Right + "+"], "65 %")
            compare(pressed(m.feed(evAbs, absX, 120)), [Qt.Key_Right + "-"], "back at the centre")
        }

        function test_a_key_two_sources_hold_goes_up_with_the_last() {
            const m = mapper()
            compare(pressed(m.feed(evAbs, hatY, 1)), [Qt.Key_Down + "+"])
            compare(m.feed(evAbs, absY, 30000), [], "the stick says Down too: still one hold")
            compare(m.feed(evAbs, hatY, 0), [], "the hat lets go, the stick still holds")
            compare(m.heldKeys(), [Qt.Key_Down])
            compare(pressed(m.feed(evAbs, absY, 0)), [Qt.Key_Down + "-"], "the last source lets go")
        }

        function test_a_vanished_pad_releases_what_it_held() {
            const m = mapper()
            m.feed(evKey, btnSouth, 1)
            m.feed(evAbs, hatX, -1)
            m.feed(evAbs, absY, 30000)
            compare(m.heldKeys().length, 3)
            compare(m.releaseAll().map(e => e.pressed), [false, false, false], "a release for each")
            compare(m.heldKeys(), [])
            compare(m.releaseAll(), [], "nothing left to release")
            compare(pressed(m.feed(evKey, btnSouth, 1)), [Qt.Key_Return + "+"], "a fresh pad starts clean")
        }

        function test_a_full_state_read_after_dropped_events_releases_what_is_no_longer_down() {
            // SYN_DROPPED: the pad's state is read again and fed as events (PadDevices.resync).
            const m = mapper()
            m.feed(evKey, btnSouth, 1)
            m.feed(evAbs, hatX, -1)
            m.feed(evAbs, absY, 30000)
            // The releases were lost; the state read says South is up, the hat centred, the stick centred,
            // and Start newly down.
            const state = [[evKey, btnSouth, 0], [evKey, btnEast, 0], [evKey, btnStart, 1], [evKey, btnMode, 0],
                           [evAbs, hatX, 0], [evAbs, hatY, 0], [evAbs, absX, 0], [evAbs, absY, 0]]
            const out = []
            for (const e of state)
                for (const k of m.feed(e[0], e[1], e[2]))
                    out.push(k.key + (k.pressed ? "+" : "-"))
            compare(out.sort(), [Qt.Key_Return + "-", Qt.Key_Left + "-", Qt.Key_Down + "-", Qt.Key_Menu + "+"].sort())
            compare(m.heldKeys(), [Qt.Key_Menu])
        }

        // ---- PadDevices and EmergencyReader teardown (a use-after-free once, review of round 1) ----

        function test_stop_reports_every_pad_gone() {
            const gones = []
            tc.devices = devicesComponent.createObject(host)
            verify(tc.devices)
            tc.devices.gone.connect(id => gones.push(id))
            tc.devices.mockPad(5)
            tc.devices.mockPad(6)
            compare(tc.devices.padCount(), 2)
            tc.devices.stop()
            compare(gones.sort(), [5, 6], "stop() tells who listens")
            compare(tc.devices.padCount(), 0)
            tc.devices.destroy()
        }

        // The destructor closes the pads and emits nothing (a listener may be half destroyed: the
        // use-after-free of round 1). QML drops its own connections when an object is destroyed, so a
        // test cannot observe a signal from the destructor, so these two are smoke tests of the teardown
        // with a pad open and with a key held (they do not fail if the fix is undone).
        function test_destroying_a_device_source_with_a_pad_open_is_safe() {
            tc.devices = devicesComponent.createObject(host)
            tc.devices.mockPad(7)
            tc.subject = tc.devices
            tc.devices.destroy()
            tryVerify(() => tc.subject === null, 2000, "the object is deleted")
        }

        function test_destroying_an_active_reader_with_a_key_held_is_clean() {
            host.observed = []
            let r = createTemporaryObject(observedReaderComponent, host)
            verify(r)
            r.serviceOwned = false
            tryCompare(r, "active", true)
            r.mockPadEvent(1, evAbs, hatY, 1)
            compare(host.observed, [Qt.Key_Down + "+"])
            tc.subject = r
            r.destroy()
            tryVerify(() => tc.subject === null, 2000, "the object is deleted")
            compare(host.observed, [Qt.Key_Down + "+"], "no release was sent by the time it is gone")
        }

        // ---- EmergencyReader: the 3 s rule, several pads ----------------------------------------

        function reader() {
            const r = createTemporaryObject(readerComponent, host)
            verify(r)
            return r
        }

        function test_the_grace_is_three_seconds_and_the_service_starts_present() {
            const plain = createTemporaryObject(plainReader, host)
            verify(plain)
            compare(plain.graceMs, 3000, "3 s without an owner (06 section 8)")
            compare(plain.serviceOwned, true, "the service is assumed present until the bus says otherwise")
            compare(plain.active, false)
            compare(plain.readDevices, true, "the real pads are read unless the mock services run")
        }

        function test_a_name_that_returns_within_the_grace_never_starts_it() {
            const r = reader()
            r.graceMs = 300
            r.serviceOwned = false
            wait(100)
            compare(r.active, false, "still inside the grace")
            r.serviceOwned = true                          // ruya-inputd restarted within the grace
            wait(400)
            compare(r.active, false, "the timer was stopped by the name coming back")
            compare(r.log, [])
        }

        function test_without_an_owner_the_reader_turns_on_after_the_grace_and_off_when_it_returns() {
            const r = reader()
            r.mockPadEvent(1, evKey, btnSouth, 1)
            compare(r.log, [], "inactive: a pad event is ignored")
            r.serviceOwned = false
            compare(r.active, false, "not at once")
            tryCompare(r, "active", true)
            r.mockPadEvent(1, evKey, btnSouth, 1)
            compare(r.log, [Qt.Key_Return + "+"])
            r.mockPadEvent(1, evKey, btnSouth, 0)
            compare(r.log, [Qt.Key_Return + "+", Qt.Key_Return + "-"])
            r.mockPadEvent(1, evAbs, hatY, 1)             // held when the service comes back
            r.log = []
            r.serviceOwned = true
            compare(r.active, false, "off at once")
            compare(r.log, [Qt.Key_Down + "-"], "going off releases what a pad held")
            r.mockPadEvent(1, evKey, btnSouth, 1)
            compare(r.log, [Qt.Key_Down + "-"], "and nothing more is read")
            compare(r.padCount, 0)
        }

        function test_two_pads_share_a_key_and_a_vanished_pad_releases_only_its_own() {
            const r = reader()
            r.serviceOwned = false
            tryCompare(r, "active", true)
            r.mockPadEvent(1, evAbs, hatY, 1)
            r.mockPadEvent(2, evAbs, hatY, 1)
            compare(r.log, [Qt.Key_Down + "+"], "down once, for the first pad")
            r.mockPadGone(1)
            compare(r.log, [Qt.Key_Down + "+"], "the other pad still holds it")
            compare(r.padCount, 1)
            r.mockPadGone(2)
            compare(r.log, [Qt.Key_Down + "+", Qt.Key_Down + "-"], "up with the last pad")
            compare(r.padCount, 0)
            r.mockPadGone(2)
            compare(r.log.length, 2, "a pad that is not there releases nothing")
        }

        function test_each_pad_has_its_own_stick_range() {
            const r = reader()
            r.serviceOwned = false
            tryCompare(r, "active", true)
            r.mockPadRange(7, absX, 0, 255)
            r.mockPadEvent(7, evAbs, absX, 210)
            compare(r.log, [Qt.Key_Right + "+"])
            r.mockPadEvent(8, evAbs, absX, 210)           // another pad, the default range: 0.6 not reached
            compare(r.log, [Qt.Key_Right + "+"])
        }

        function test_the_same_state_again_changes_nothing() {
            const r = reader()
            r.serviceOwned = false
            r.serviceOwned = false
            tryCompare(r, "active", true)
            r.serviceOwned = false
            compare(r.active, true)
            r.serviceOwned = true
            r.serviceOwned = true
            compare(r.active, false)
        }

        // ---- Shell: the keys reach the shell's pages, never an app ------------------------------

        function start() {
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            find("emergencyReader").graceMs = 40
        }

        function goneAndOn() {
            Input.mockNameOwned(false)
            tryCompare(find("emergencyReader"), "active", true)
        }

        function pad(code, value, type) {
            find("emergencyReader").mockPadEvent(1, type === undefined ? evKey : type, code, value)
        }

        function test_the_pad_navigates_the_picker_and_signs_in_when_the_service_is_gone() {
            start()
            const list = find("profileList")
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Left)
            compare(list.currentIndex, 0)

            // With the service present a pad event goes nowhere.
            pad(hatX, 1, evAbs)
            pad(hatX, 0, evAbs)
            compare(list.currentIndex, 0, "the reader is off while the service is there")

            goneAndOn()
            pad(hatX, 1, evAbs)                            // D-pad right
            pad(hatX, 0, evAbs)
            tryCompare(list, "currentIndex", 1)
            verify(list.activeFocus, "the picker keeps the focus")
            pad(btnSouth, 1)                               // A on Ada (no PIN)
            pad(btnSouth, 0)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Home after sign-in with the pad alone")

            Input.mockNameOwned(true)
            tryCompare(find("emergencyReader"), "active", false)
            pad(hatX, -1, evAbs)
            pad(hatX, 0, evAbs)
            verify(find("homePlay").activeFocus, "the service is back: the reader is off again")
        }

        function test_the_pad_never_feeds_an_app_but_the_guide_still_opens_the_hub() {
            start()
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Home")
            tryVerify(() => Library.items.length === 10)
            keyClick(Qt.Key_Return)                        // Play
            tryCompare(launchedSpy, "count", 1)
            tryVerify(() => Session.running.length === 1)
            const app = createTemporaryObject(appComponent, host)
            verify(app)
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the app takes the focus")

            goneAndOn()
            for (const code of [btnSouth, btnEast, btnStart, dpadUp])
                { pad(code, 1); pad(code, 0) }
            pad(hatX, 1, evAbs)
            pad(hatX, 0, evAbs)
            compare(app.seen, [], "no key of the emergency reader reaches the app")
            verify(app.activeFocus, "the app keeps the focus")

            pad(btnMode, 1)                                // Guide
            pad(btnMode, 0)
            tryVerify(() => find("systemActions").activeFocus, 2000, "the Guide key opens the Hub over the app")
            compare(app.seen, [], "and the app did not see it")
            pad(btnEast, 1)                                // B closes the Hub
            pad(btnEast, 0)
            tryVerify(() => app.activeFocus, 2000, "back to the app")
            compare(app.seen, [], "the app saw nothing at all")
        }
    }
}
