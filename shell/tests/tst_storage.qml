import QtQuick
import QtTest
import RuyaShell

// Settings -> Storage against the mock backend: the size formatter, every status string of the
// contract, a drive appearing (one toast, the list updates, focus stays valid), eject by keys
// ("Safe to remove"), a busy drive staying listed with a message, and Back on the unsupported
// drive. Signs in as "Ada" (p2, no PIN). The mock is reset before every test (the USB stick
// is not plugged in until a test asks for it).
Item {
    id: host
    width: 1280
    height: 720

    // Every answer of the service, in order: { op, id, status }.
    property var answers: []
    Connections {
        target: Storage
        function onFinished(op, id, status) { host.answers = host.answers.concat([{ op: op, id: id, status: status }]) }
    }

    SignalSpy { id: addedSpy; target: Storage; signalName: "volumeAdded" }
    SignalSpy { id: listedSpy; target: Storage; signalName: "volumesChanged" }

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "Storage"
        when: windowShown

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Storage.mockReset()
            tryVerify(() => Storage.volumes.length === 2)
            host.answers = []
            addedSpy.clear()
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
            clearToasts()
        }

        function cleanup() {
            DeviceSettings.language = "en"
            clearToasts()
        }

        function clearToasts() {
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function toastTexts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i)
                out.push(Notifications.model.get(i).text)
            return out
        }

        function toastCount(text) { return toastTexts().filter(t => t === text).length }

        function openStoragePane() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus, 2000, "category list has focus")
            for (let i = 0; i < 5; ++i)
                keyClick(Qt.Key_Down)                    // ... Storage
            compare(list.currentIndex, 5)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneStorage").visible)
            tryVerify(() => find("storageVol_vol-internal").activeFocus, 2000, "the first volume takes focus")
        }

        // Down (or else up) to the named row (which must exist), asserting that the pane keeps focus.
        function goTo(name) {
            tryVerify(() => find(name) !== null && find(name).visible, 3000, name + " exists")
            for (let i = 0; i < 25 && !find(name).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            for (let i = 0; i < 25 && !find(name).activeFocus; ++i)
                keyClick(Qt.Key_Up)                      // the row is above the focused one
            tryVerify(() => find(name).activeFocus, 2000, name + " has focus")
        }

        function volume(id) { return Storage.volumes.find(v => v.id === id) }

        function answerFor(op, id) {
            return host.answers.find(a => a.op === op && a.id === id)
        }

        function test_format_bytes() {
            DeviceSettings.language = "en"
            compare(Storage.formatBytes(1500000000), "1.5 GB")
            compare(Storage.formatBytes(32000000000), "32 GB", "a trailing .0 is dropped")
            compare(Storage.formatBytes(0), "0 bytes")
            compare(Storage.formatBytes(-5), "0 bytes", "negative sizes are shown as 0")
            compare(Storage.formatBytes(1023), "1 kB", "1023 B is 1.0 kB (SI)")
            DeviceSettings.language = "tr"
            compare(Storage.formatBytes(1500000000), "1,5 GB", "the shell language, not the system's")
            compare(Storage.formatBytes(32000000000), "32 GB")
        }

        function test_eject_in_flight_sends_one_eject() {
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            goTo("storageEject_vol-stick")
            Storage.mockHoldEject(true)                  // an unmount that takes a while
            keyClick(Qt.Key_Return)
            tryVerify(() => Storage.mockEjectCalls() === 1, 2000, "one eject sent")
            keyClick(Qt.Key_Return)                      // a second Accept, a key repeat
            keyClick(Qt.Key_Return)
            wait(100)                                    // a second call would have arrived by now
            compare(Storage.mockEjectCalls(), 1, "still one eject")
            Storage.mockHoldEject(false)                 // the answer comes
            tryVerify(() => volume("vol-stick") === undefined, 2000, "ejected")
            tryVerify(() => toastTexts().includes("Safe to remove"), 2000)
            compare(Storage.mockEjectCalls(), 1)
        }

        function test_republished_list_keeps_one_inserted_toast() {
            Storage.mockPlugStick()
            tryVerify(() => toastCount("Drive inserted: Ruya Stick") === 1, 2000, "one toast")
            compare(addedSpy.count, 1)
            listedSpy.clear()
            Storage.mockRepublish()
            tryCompare(listedSpy, "count", 1, 2000, "the list was published again")
            compare(addedSpy.count, 1, "no second volumeAdded")
            compare(toastCount("Drive inserted: Ruya Stick"), 1, "still one toast")
        }

        function test_contract_statuses() {
            const seen = new Set()
            function run(id) {
                host.answers = []
                Storage.eject(id)
                tryVerify(() => answerFor("eject", id) !== undefined, 2000, "eject " + id + " answered")
                const status = answerFor("eject", id).status
                seen.add(status)
                return status
            }
            compare(run(""), "invalid")
            compare(run("nope"), "unknown-volume")
            compare(run("vol-stick"), "unknown-volume", "not plugged in yet")
            compare(run("vol-internal"), "failed", "an internal disk cannot be ejected")
            compare(run("vol-old"), "unsupported")
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            Storage.mockSetBusy("vol-stick", true)
            compare(run("vol-stick"), "busy")
            verify(volume("vol-stick") !== undefined, "a busy volume stays listed")
            Storage.mockSetBusy("vol-stick", false)
            compare(run("vol-stick"), "ok")
            tryVerify(() => volume("vol-stick") === undefined)
            for (const s of ["ok", "unknown-volume", "busy", "unsupported", "invalid", "failed"])
                verify(seen.has(s), "status " + s + " exercised")
            compare(seen.size, 6, "no status outside the contract")
        }

        function test_volume_appears_toast_once_and_focus_stays() {
            openStoragePane()
            goTo("storageVol_vol-old")
            compare(find("storageVol_vol-internal").value, "ext4 · " + Storage.formatBytes(318000000000)
                    + " free of " + Storage.formatBytes(512000000000))
            verify(find("storageVol_vol-stick") === null || !find("storageVol_vol-stick").visible)
            Storage.mockPlugStick()
            tryVerify(() => find("storageVol_vol-stick") !== null, 2000, "the list gains the stick")
            tryCompare(addedSpy, "count", 1)
            tryVerify(() => toastCount("Drive inserted: Ruya Stick") === 1, 2000, "one toast")
            compare(find("storageVol_vol-stick").value, "exFAT · " + Storage.formatBytes(21500000000)
                    + " free of " + Storage.formatBytes(32000000000))
            tryVerify(() => find("storageVol_vol-old").activeFocus, 2000, "focus stays on its row")
            verify(find("paneStorage").activeFocus)
            tryVerify(() => find("storageEject_vol-stick").visible, 2000, "the stick can be ejected")
            wait(150)                                    // a duplicate toast would have come by now
            compare(toastCount("Drive inserted: Ruya Stick"), 1, "once")
            compare(addedSpy.count, 1)
        }

        function test_delayed_insert_like_a_fresh_start() {
            Storage.mockReset(true)                      // the stick comes by itself after a delay
            tryCompare(addedSpy, "count", 1, 3000)
            tryVerify(() => toastCount("Drive inserted: Ruya Stick") === 1, 2000)
            compare(Storage.volumes.map(v => v.id).join(), "vol-internal,vol-old,vol-stick")
        }

        function test_eject_by_keys() {
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            clearToasts()
            goTo("storageVol_vol-stick")
            keyClick(Qt.Key_Return)                      // Accept offers Eject
            tryVerify(() => find("storageEject_vol-stick").activeFocus, 2000, "focus moves to the Eject row")
            compare(find("storageEject_vol-stick").label, "Eject Ruya Stick")
            keyClick(Qt.Key_Return)
            tryVerify(() => volume("vol-stick") === undefined, 2000, "the volume is gone")
            tryVerify(() => find("storageVol_vol-stick") === null, 2000, "its row is gone")
            tryVerify(() => find("storageEject_vol-stick") === null)
            tryVerify(() => toastTexts().includes("Safe to remove"), 2000, "safe to remove")
            tryVerify(() => find("storageVol_vol-old").activeFocus, 2000, "focus moves to a valid row")
            verify(find("paneStorage").activeFocus)
        }

        function test_busy_volume_shows_message_and_stays() {
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            Storage.mockSetBusy("vol-stick", true)
            openStoragePane()
            clearToasts()
            goTo("storageEject_vol-stick")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().includes("Ruya Stick is still in use. Close what uses it and try again."),
                      2000, "the message is shown")
            verify(!toastTexts().includes("Safe to remove"))
            verify(volume("vol-stick") !== undefined, "still listed")
            verify(find("storageVol_vol-stick") !== null)
            tryVerify(() => find("storageEject_vol-stick").activeFocus, 2000, "focus stays on the row")
            Storage.mockSetBusy("vol-stick", false)      // closed meanwhile: it works now
            keyClick(Qt.Key_Return)
            tryVerify(() => volume("vol-stick") === undefined, 2000)
            tryVerify(() => toastTexts().includes("Safe to remove"), 2000)
        }

        function test_unsupported_drive_explains_and_back_leaves() {
            openStoragePane()
            goTo("storageVol_vol-old")
            compare(find("storageVol_vol-old").value, "Not supported")
            verify(!find("storageEject_vol-old").visible, "nothing to eject on an unmounted drive")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().includes("This drive's format is not supported. Format it as exFAT on a computer to use it here."),
                      2000, "the reason is shown")
            tryVerify(() => find("storageVol_vol-old").activeFocus, 2000, "focus stays on the row")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Back returns to the category list")
            tryCompare(tc.shell, "currentPage", "settings")
            compare(find("categoryList").currentIndex, 5)
        }

        function test_unplugged_drive_while_focused() {
            // A drive that goes away under the focus (eject from elsewhere) must not strand it.
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            goTo("storageEject_vol-stick")
            Storage.eject("vol-stick")
            tryVerify(() => find("storageEject_vol-stick") === null, 2000)
            tryVerify(() => find("storageVol_vol-old").activeFocus, 2000, "focus moves to a valid row")
        }

        function test_an_older_reply_arriving_late_is_dropped() {
            // Two volumes. Ask again (the reply, a snapshot of that, is held back), then the stick is
            // plugged in: the late reply must not take it off the list again.
            Storage.mockRefreshDelayed(150)
            compare(Storage.mockPendingReplies(), 1)
            Storage.mockPlugStick()
            tryVerify(() => Storage.volumes.length === 3)
            tryVerify(() => Storage.mockPendingReplies() === 0)
            compare(Storage.volumes.length, 3, "the late two-volume reply was dropped")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            goTo("storageVol_vol-stick")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/27-settings-storage.png")
        }
    }
}
