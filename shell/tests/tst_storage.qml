import QtQuick
import QtTest
import RuyaShell

// Settings -> Storage against the mock backend: the console's own storage ("This console", T-196:
// numbers, rows updated in place, the low-space bar, a late reply), the size formatter, every status string of the
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

    SignalSpy { id: addedSpy; target: Storage; signalName: "driveAdded" }
    SignalSpy { id: listedSpy; target: Storage; signalName: "volumesChanged" }

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "Storage"
        when: windowShown

        property Shell shell: null

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
                out.push(Notifications.model.get(i).text + (Notifications.model.get(i).detail !== "" ? ": " + Notifications.model.get(i).detail : ""))
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
            for (let i = 0; i < 6; ++i)
                keyClick(Qt.Key_Down)                    // ... Storage
            compare(list.currentIndex, 6)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneStorage").visible)
            tryVerify(() => find("storageInternal").activeFocus, 2000, "the first row (This console) takes focus")
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
            compare(addedSpy.count, 1, "no second driveAdded")
            compare(toastCount("Drive inserted: Ruya Stick"), 1, "still one toast")
        }

        // A stick with two partitions: one toast naming the first and counting the second.
        function test_two_partitions_of_one_drive_give_one_toast() {
            verify(Storage.groupWindowMs > 0, "the window is visible to QML (the waits below depend on it)")
            Storage.mockPlug(["vol-stick", "vol-stick-2"])
            tryVerify(() => toastCount("Drive inserted: Ruya Stick (and 1 more)") === 1, 2000, "one toast")
            wait(Storage.groupWindowMs + 200)            // a second toast would have come by now
            compare(addedSpy.count, 1, "one driveAdded")
            compare(addedSpy.signalArguments[0][0], "drive-stick")
            compare(addedSpy.signalArguments[0][2], 2)
            compare(toastTexts().filter(t => t.startsWith("Drive inserted")).length, 1, "no other drive toast")
            verify(volume("vol-stick") !== undefined && volume("vol-stick-2") !== undefined, "both listed")
            compare(volume("vol-stick-2").drive, volume("vol-stick").drive)
        }

        // Partitions that arrive in separate lists, inside the window, still join the first.
        function test_a_partition_that_follows_inside_the_window_joins_the_toast() {
            Storage.mockPlug(["vol-stick"])
            Storage.mockPlug(["vol-stick-2"])
            tryVerify(() => toastCount("Drive inserted: Ruya Stick (and 1 more)") === 1, 2000, "one toast")
            wait(Storage.groupWindowMs + 200)
            compare(addedSpy.count, 1)
        }

        function test_two_different_drives_give_two_toasts() {
            Storage.mockPlug(["vol-stick", "vol-card"])
            tryVerify(() => toastCount("Drive inserted: Ruya Stick") === 1, 2000, "the stick")
            tryVerify(() => toastCount("Drive inserted: Camera Card") === 1, 2000, "the card")
            wait(Storage.groupWindowMs + 200)
            compare(addedSpy.count, 2)
            compare(toastTexts().filter(t => t.startsWith("Drive inserted")).length, 2)
        }

        // A partition we do not mount stays listed but is not counted; a drive that has nothing
        // else gives no toast.
        function test_unsupported_partitions_are_listed_but_not_counted() {
            Storage.mockPlug(["vol-stick", "vol-stick-raw"])
            tryVerify(() => toastCount("Drive inserted: Ruya Stick") === 1, 2000, "no count for the raw partition")
            tryVerify(() => volume("vol-stick-raw") !== undefined, 2000, "still listed")
            compare(volume("vol-stick-raw").filesystem, "unknown")
            compare(addedSpy.signalArguments[0][2], 1)
            addedSpy.clear()
            Storage.mockPlug(["vol-odd"])
            tryVerify(() => volume("vol-odd") !== undefined, 2000, "listed")
            wait(Storage.groupWindowMs + 200)
            compare(addedSpy.count, 0, "no driveAdded")
            compare(toastTexts().filter(t => t.startsWith("Drive inserted")).length, 1, "no toast for the unsupported drive")
        }

        // A stick pulled again inside the grouping window is never announced.
        function test_a_drive_ejected_inside_the_window_gives_no_toast() {
            Storage.mockPlugStick()
            Storage.eject("vol-stick")
            tryVerify(() => answerFor("eject", "vol-stick") !== undefined, 2000, "ejected")
            wait(Storage.groupWindowMs + 200)
            compare(addedSpy.count, 0, "no driveAdded")
            compare(toastTexts().filter(t => t.startsWith("Drive inserted")).length, 0, "no toast")
            verify(volume("vol-stick") === undefined)
        }

        // Plugged in, pulled and plugged in again inside the window: one volume, not "and 1 more".
        function test_a_volume_plugged_in_twice_inside_the_window_counts_once() {
            Storage.mockPlugStick()
            Storage.eject("vol-stick")
            Storage.mockPlugStick()
            tryVerify(() => toastCount("Drive inserted: Ruya Stick") === 1, 2000, "one toast")
            wait(Storage.groupWindowMs + 200)
            compare(addedSpy.count, 1)
            compare(addedSpy.signalArguments[0][2], 1, "one volume")
            compare(toastTexts().filter(t => t.startsWith("Drive inserted")).length, 1)
            verify(volume("vol-stick") !== undefined)
        }

        // Ejects `id` and returns the status of the answer. A top-level function: qmllint goes
        // blind on a local declared inside a nested one (T-189, scripts/lint-test-members.ps1).
        function ejectStatus(seen, id) {
            host.answers = []
            Storage.eject(id)
            tryVerify(() => answerFor("eject", id) !== undefined, 2000, "eject " + id + " answered")
            const status = answerFor("eject", id).status
            seen.add(status)
            return status
        }

        function test_contract_statuses() {
            const seen = new Set()
            const run = (id) => ejectStatus(seen, id)
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

        // RUY-544: the entry kind ("volume" | "scan" | "eject") must not land in SettingRow.kind (the row kind).
        function test_storage_rows_have_a_valid_row_kind() {
            openStoragePane()
            const row = find("storageVol_vol-internal")
            verify(row !== null)
            verify(["item", "action", "page", "info"].indexOf(row.kind) >= 0, "row kind is " + row.kind)
            compare(row.entryKind, "volume")
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
            compare(find("storageVol_vol-stick").value, "exFAT · " + Storage.formatBytes(44500000000)
                    + " free of " + Storage.formatBytes(64000000000))
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
            compare(find("categoryList").currentIndex, 6)
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

        // The share of the bar that is filled, 0..1 (the fill eases its width, so callers wait).
        function barFill() {
            return find("usageFill").width / find("usageTrack").width
        }

        function test_internal_storage_numbers_from_the_mock() {
            tryCompare(Storage.internal, "valid", true)
            compare(Storage.internal.totalBytes, 464000000000)
            compare(Storage.internal.freeBytes, 450000000000)
            compare(Storage.internal.appsBytes, 6500000000)
            compare(Storage.internal.dataBytes, -1, "the profile homes cannot be read by the service: unknown")
            compare(Storage.internal.systemBytes, 7500000000, "without the data: everything used that is not apps")
        }

        // The service's answer today: profile data unknown. No "Profile data" row, the rest is "Other".
        function test_pane_shows_this_console_first() {
            tryCompare(Storage.internal, "valid", true)
            openStoragePane()
            compare(find("storageHeadingInternal").text, "This console")
            compare(find("storageInternal").label, "Free space")
            compare(find("storageInternal").value, "450 GB free of 464 GB")
            compare(find("storageApps").label, "Apps and games")
            compare(find("storageApps").value, "6.5 GB")
            verify(!find("storageData").visible, "no Profile data row while it is unknown")
            compare(find("storageSystem").label, "Other")
            compare(find("storageSystem").value, "7.5 GB")
            tryVerify(() => Math.abs(barFill() - 14 / 464) < 0.003, 2000, "the bar shows 14 of 464 GB used")
            compare(find("storageInternal").fillColor, Theme.text, "plenty free: the plain colour")
            verify(find("storageInternal").y < find("storageApps").y && find("storageApps").y < find("storageSystem").y,
                   "in this order")
            verify(find("storageSystem").y < find("storageVol_vol-internal").y, "above the drives")
            compare(find("storageHeadingDrives").text, "Drives")
        }

        // With the profile data known (a later root source): its own row, and the rest is "System".
        function test_known_profile_data_has_its_row_and_system_is_the_remainder() {
            tryCompare(Storage.internal, "valid", true)
            Storage.mockSetInternal(464000000000, 450000000000, 6500000000, 3200000000)
            tryCompare(Storage.internal, "dataBytes", 3200000000)
            openStoragePane()
            tryVerify(() => find("storageData").visible, 2000, "the row appears")
            compare(find("storageData").label, "Profile data")
            compare(find("storageData").value, "3.2 GB")
            compare(find("storageSystem").label, "System")
            compare(find("storageSystem").value, "4.3 GB")
            verify(find("storageApps").y < find("storageData").y && find("storageData").y < find("storageSystem").y,
                   "in this order")
            goTo("storageApps")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("storageData").activeFocus, 2000, "Down reaches Profile data")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("storageSystem").activeFocus, 2000, "and then System")
            Storage.mockSetInternal(464000000000, 450000000000, 6500000000, -1)   // unknown again
            tryVerify(() => !find("storageData").visible, 2000, "the row goes")
            compare(find("storageSystem").label, "Other")
            compare(find("storageSystem").value, "7.5 GB")
        }

        // Opening the pane asks for the numbers again (free space has no signal); Settings opening
        // alone does not.
        function test_the_numbers_are_read_again_when_the_pane_is_shown() {
            tryCompare(Storage.internal, "valid", true)
            openStoragePane()
            const shown = Storage.mockUsageCalls()
            keyClick(Qt.Key_Left)                        // back to the category list
            tryVerify(() => find("categoryList").activeFocus, 2000)
            keyClick(Qt.Key_Down)                        // another category: the pane is hidden
            tryVerify(() => !find("paneStorage").visible, 2000)
            compare(Storage.mockUsageCalls(), shown, "hiding it asks for nothing")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("paneStorage").visible, 2000)
            tryVerify(() => Storage.mockUsageCalls() === shown + 1, 2000, "showing it asks once")
        }

        // New numbers change the rows' text and bar in place: the same row objects, focus kept.
        function test_updating_internal_changes_the_rows_in_place_and_focus_stays() {
            tryCompare(Storage.internal, "valid", true)
            Storage.mockSetInternal(464000000000, 450000000000, 6500000000, 3200000000)
            tryCompare(Storage.internal, "dataBytes", 3200000000)
            openStoragePane()
            tryVerify(() => find("storageData").visible, 2000)
            goTo("storageApps")
            const apps = find("storageApps")
            const free = find("storageInternal")
            const data = find("storageData")
            Storage.mockSetInternal(464000000000, 300000000000, 100000000000, 50000000000)
            tryCompare(apps, "value", "100 GB")
            compare(free.value, "300 GB free of 464 GB")
            compare(data.value, "50 GB")
            compare(find("storageSystem").value, "14 GB")
            tryVerify(() => Math.abs(barFill() - 164 / 464) < 0.003, 2000, "the bar follows")
            verify(find("storageApps") === apps && find("storageInternal") === free && find("storageData") === data,
                   "the rows were not recreated")
            verify(apps.activeFocus, "focus stays on the row")
            verify(find("paneStorage").activeFocus)
            keyClick(Qt.Key_Down)                        // and the keys still move on from it
            tryVerify(() => find("storageData").activeFocus, 2000, "Down moves on")
        }

        function test_low_space_turns_the_bar_to_the_warning_colour() {
            tryCompare(Storage.internal, "valid", true)
            openStoragePane()
            compare(find("storageInternal").fillColor, Theme.text)
            Storage.mockLowSpace(true)
            tryCompare(find("storageInternal"), "fillColor", Theme.warningText)
            compare(find("storageInternal").value, "28 GB free of 464 GB")
            tryVerify(() => Math.abs(barFill() - 436 / 464) < 0.003, 2000, "nearly full")
            verify(find("storageInternal").activeFocus, "focus stays")
            // Exactly 10 % free is not low yet; just under is.
            Storage.mockSetInternal(464000000000, 46500000000, 1000000000, 1000000000)
            tryCompare(find("storageInternal"), "fillColor", Theme.text)
            Storage.mockSetInternal(464000000000, 46300000000, 1000000000, 1000000000)
            tryCompare(find("storageInternal"), "fillColor", Theme.warningText)
            Storage.mockLowSpace(false)
            tryCompare(find("storageInternal"), "fillColor", Theme.text)
        }

        function test_unknown_parts_show_a_dash() {
            tryCompare(Storage.internal, "valid", true)
            Storage.mockSetInternal(464000000000, 450000000000, -1, -1)  // not measured yet
            tryCompare(Storage.internal, "appsBytes", -1)
            openStoragePane()
            compare(find("storageInternal").value, "450 GB free of 464 GB")
            compare(find("storageApps").value, "—")
            compare(find("storageSystem").value, "—")
            verify(!find("storageData").visible)
            Storage.mockSetInternal(464000000000, 450000000000, 6500000000, -1)
            tryCompare(find("storageApps"), "value", "6.5 GB")
            compare(find("storageSystem").value, "7.5 GB", "without the data: used and not apps")
            // The data known but not the apps: the rest cannot be told.
            Storage.mockSetInternal(464000000000, 450000000000, -1, 3200000000)
            tryVerify(() => find("storageData").visible, 2000)
            compare(find("storageData").value, "3.2 GB")
            tryCompare(find("storageApps"), "value", "—")
            compare(find("storageSystem").value, "—", "the rest is not known while the apps are missing")
        }

        // The answer to an older question must not put old numbers back (T-191).
        function test_a_late_usage_reply_is_dropped() {
            tryCompare(Storage.internal, "valid", true)
            compare(Storage.internal.freeBytes, 450000000000)
            Storage.mockRefreshInternalDelayed(300)       // a snapshot with 450 GB free is on its way
            compare(Storage.mockPendingReplies(), 1)
            Storage.mockLowSpace(true)                    // the service says SystemUsageChanged: 28 GB
            tryCompare(Storage.internal, "freeBytes", 28000000000)
            tryVerify(() => Storage.mockPendingReplies() === 0, 2000)
            compare(Storage.internal.freeBytes, 28000000000, "the late snapshot was dropped")
            Storage.mockLowSpace(false)
        }

        // ---- what RuyaOS finds on a removable drive (T-331) ----

        // The scan state of a volume, "" while it has no entry (an entry goes when its volume changes).
        function scanState(id) { return Storage.scans[id] ? Storage.scans[id].state : "" }

        function scanRowNames(volId) {
            const out = []
            const prefix = "storageScan_" + volId + "_"
            for (const r of find("paneStorage").focusableRows()) {
                if (r.objectName.indexOf(prefix) === 0)
                    out.push(r.objectName.substring(prefix.length))
            }
            return out
        }

        function test_removable_breakdown() {
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            tryVerify(() => find("storageScan_vol-stick_cat:games") !== null, 3000, "the scan ends in rows")
            compare(find("storageScan_vol-stick_cat:games").label, "Games")
            compare(find("storageScan_vol-stick_cat:games").value, "12 GB")
            compare(find("storageScan_vol-stick_cat:backups").label, "Backups")
            compare(find("storageScan_vol-stick_cat:backups").value, "2 GB")
            compare(find("storageScan_vol-stick_cat:captures").label, "Captures")
            compare(find("storageScan_vol-stick_cat:captures").value, "1.5 GB")
            compare(find("storageScan_vol-stick_cat:pictures").label, "Pictures")
            compare(find("storageScan_vol-stick_cat:pictures").value, "300 MB")
            compare(find("storageScan_vol-stick_other").label, "Other")
            compare(find("storageScan_vol-stick_other").value, "3.7 GB")
            compare(find("storageScan_vol-stick_wait"), null, "no Scanning row once it is done")
            compare(scanRowNames("vol-stick").join(), "cat:games,cat:backups,cat:captures,cat:pictures,other")
            // Under the drive's own row and above its Eject row, in the order of the service.
            verify(find("storageVol_vol-stick").y < find("storageScan_vol-stick_cat:games").y)
            // A step in from the drive's row, and still inside the pane.
            const vol = find("storageVol_vol-stick")
            const games = find("storageScan_vol-stick_cat:games")
            verify(games.x > vol.x, "indented")
            compare(games.x + games.width, vol.x + vol.width, "ends where the drive's row ends")
            verify(find("storageScan_vol-stick_cat:games").y < find("storageScan_vol-stick_cat:backups").y)
            verify(find("storageScan_vol-stick_other").y < find("storageEject_vol-stick").y)
            // The internal disk is not scanned (the "This console" rows tell its story).
            compare(find("storageScan_vol-internal_wait"), null)
            compare(Storage.mockScanCalls().join(), "vol-stick")
            // The parts add up to what the service counted.
            const s = Storage.scans["vol-stick"]
            compare(s.state, "done")
            compare(s.partial, false)
            compare(s.usedBytes, 19500000000)
        }

        function test_nothing_recognised_has_one_line() {
            Storage.mockPlug(["vol-card"])
            tryVerify(() => volume("vol-card") !== undefined)
            openStoragePane()
            tryVerify(() => find("storageScan_vol-card_none") !== null, 3000)
            compare(find("storageScan_vol-card_none").label, "Nothing found here")
            compare(find("storageScan_vol-card_none").value, "")
            compare(scanRowNames("vol-card").join(), "none", "one line, no Other row")
        }

        function test_partial_result_reads_at_least() {
            Storage.mockSetScanPartial(true)
            Storage.mockPlug(["vol-stick", "vol-card"])
            tryVerify(() => volume("vol-card") !== undefined)
            openStoragePane()
            tryVerify(() => find("storageScan_vol-stick_cat:games") !== null, 3000)
            compare(find("storageScan_vol-stick_cat:games").value, "at least 12 GB")
            compare(find("storageScan_vol-stick_other").value, "at least 3.7 GB")
            tryVerify(() => find("storageScan_vol-card_none") !== null, 3000)
            compare(find("storageScan_vol-card_none").label, "Nothing found so far", "a partial walk may not have got to it")
            compare(find("storageScan_vol-card_none").value, "")
            compare(Storage.scans["vol-stick"].partial, true)
        }

        // The Scanning row while the walk runs, then rows in its place; the focus stays where it was.
        function test_scanning_row_then_results_and_focus_stays() {
            Storage.mockHoldScan(true)
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            tryVerify(() => find("storageScan_vol-stick_wait") !== null, 3000, "a Scanning row")
            compare(find("storageScan_vol-stick_wait").label, "Scanning…")
            compare(Storage.scans["vol-stick"].state, "running")
            goTo("storageVol_vol-stick")
            Storage.mockHoldScan(false)
            tryVerify(() => find("storageScan_vol-stick_cat:games") !== null, 3000)
            compare(find("storageScan_vol-stick_wait"), null)
            verify(find("storageVol_vol-stick").activeFocus, "focus stays on the drive's row")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("storageScan_vol-stick_cat:games").activeFocus, 2000, "Down reaches the first result")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Back leaves")
        }

        // A second drive's numbers arriving change the rows around the focused one, not the row itself.
        function test_focus_stays_on_its_row_while_another_drive_reports() {
            Storage.mockHoldScan(true)
            Storage.mockPlug(["vol-stick", "vol-card"])
            tryVerify(() => volume("vol-card") !== undefined)
            openStoragePane()
            tryVerify(() => find("storageScan_vol-stick_wait") !== null, 3000)
            Storage.mockHoldScan(false)                  // the stick finishes, then the card is asked
            tryVerify(() => find("storageScan_vol-stick_cat:games") !== null, 3000)
            goTo("storageScan_vol-stick_cat:games")
            const games = find("storageScan_vol-stick_cat:games")
            tryVerify(() => find("storageScan_vol-card_none") !== null, 3000, "the card's result appears below")
            verify(find("storageScan_vol-stick_cat:games") === games, "the row was not recreated")
            verify(games.activeFocus, "focus stays")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("storageScan_vol-stick_cat:backups").activeFocus, 2000, "and the keys move on")
        }

        function test_one_scan_at_a_time_the_second_follows() {
            Storage.mockHoldScan(true)
            Storage.mockPlug(["vol-stick", "vol-card"])
            tryVerify(() => volume("vol-card") !== undefined)
            openStoragePane()
            tryVerify(() => Storage.mockScanCalls().length === 1, 3000)
            wait(100)
            compare(Storage.mockScanCalls().join(), "vol-stick", "the card waits for the stick")
            Storage.mockHoldScan(false)
            tryVerify(() => Storage.mockScanCalls().join() === "vol-stick,vol-card", 3000)
            tryVerify(() => find("storageScan_vol-card_none") !== null, 3000)
        }

        function test_scan_cancelled_when_pane_hides() {
            Storage.mockHoldScan(true)
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            tryVerify(() => Storage.mockScanCalls().length === 1, 3000)
            tryVerify(() => scanState("vol-stick") === "running", 3000)
            keyClick(Qt.Key_Left)                        // back to the category list
            tryVerify(() => find("categoryList").activeFocus, 2000)
            keyClick(Qt.Key_Down)                        // another category: the pane is hidden
            tryVerify(() => !find("paneStorage").visible, 2000)
            tryVerify(() => Storage.mockCancelCalls().join() === "vol-stick", 2000, "the walk was stopped")
            tryVerify(() => scanState("vol-stick") === "cancelled", 2000)
            // Shown again: a new scan, and its result.
            Storage.mockHoldScan(false)
            keyClick(Qt.Key_Up)
            tryVerify(() => find("paneStorage").visible, 2000)
            tryVerify(() => Storage.mockScanCalls().length === 2, 3000, "asked again")
            tryVerify(() => scanState("vol-stick") === "done", 3000)
        }

        function test_eject_cancels_the_scan_first() {
            Storage.mockHoldScan(true)
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            tryVerify(() => find("storageScan_vol-stick_wait") !== null, 3000)
            goTo("storageEject_vol-stick")
            keyClick(Qt.Key_Return)
            tryVerify(() => volume("vol-stick") === undefined, 2000, "the drive is gone")
            compare(Storage.mockCancelCalls().join(), "vol-stick", "its scan was cancelled")
            compare(Storage.mockScanCalls().length, 1, "and not started again")
            tryVerify(() => toastTexts().includes("Safe to remove"), 2000)
            tryVerify(() => find("storageScan_vol-stick_wait") === null, 2000, "its rows are gone")
            tryVerify(() => find("storageVol_vol-old").activeFocus, 2000, "focus lands on a valid row")
            compare(Object.keys(Storage.scans).length, 0, "nothing is kept for a drive that left")
        }

        // The answer to an older question must not put an old state back (RequestSequence).
        function test_late_scan_reply_is_dropped() {
            Storage.mockHoldScan(true)
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            tryVerify(() => Storage.scans["vol-stick"] !== undefined, 3000)
            compare(Storage.scans["vol-stick"].state, "running")
            Storage.mockRefreshScanDelayed("vol-stick", 300)   // a snapshot "running" is on its way
            compare(Storage.mockPendingReplies(), 1)
            Storage.mockHoldScan(false)                        // the scan ends: "done"
            tryVerify(() => scanState("vol-stick") === "done", 3000)
            tryVerify(() => Storage.mockPendingReplies() === 0, 2000)
            compare(Storage.scans["vol-stick"].state, "done", "the late snapshot was dropped")
            tryVerify(() => find("storageScan_vol-stick_cat:games") !== null, 2000)
            compare(find("storageScan_vol-stick_wait"), null)
        }

        // The cache is the facade's too: a volume whose free space changed is asked again.
        function test_a_changed_volume_is_scanned_again() {
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            tryVerify(() => scanState("vol-stick") === "done", 3000)
            Storage.mockRepublish()                      // unchanged: no new walk
            wait(150)
            compare(Storage.mockScanCalls().length, 1)
            Storage.mockSetLabel("vol-stick", "Renamed")  // a label alone does not change what was scanned
            wait(150)
            compare(Storage.mockScanCalls().length, 1)
            Storage.mockSetFree("vol-stick", 40000000000)
            tryVerify(() => Storage.mockScanCalls().length === 2, 3000, "new free space: scanned again")
            tryVerify(() => scanState("vol-stick") === "done", 3000)
        }

        function test_zz_screenshots_scan() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Storage.mockPlug(["vol-stick", "vol-card"])
            tryVerify(() => volume("vol-card") !== undefined)
            openStoragePane()
            tryVerify(() => find("storageScan_vol-card_none") !== null, 3000)
            goTo("storageScan_vol-stick_cat:games")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/27-settings-storage-scan.png")
        }

        function test_zz_screenshots_scan_partial() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Storage.mockSetScanPartial(true)
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            tryVerify(() => find("storageScan_vol-stick_other") !== null, 3000)
            goTo("storageScan_vol-stick_cat:backups")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/27-settings-storage-scan-partial.png")
        }

        function shownHints() { return find("paneStorage").hints.map(h => h.button + " " + h.text).join("|") }

        // A row that does nothing on Accept says so: the hint bar offers Back only, and Accept is silent.
        function test_scan_rows_offer_back_only_and_accept_does_nothing() {
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            tryVerify(() => find("storageScan_vol-stick_cat:games") !== null, 3000)
            compare(shownHints(), "B Back", "the first row (This console) is a fact")
            goTo("storageVol_vol-stick")
            compare(shownHints(), "A Select|B Back", "a drive's own row does something")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("storageScan_vol-stick_cat:games").activeFocus, 2000)
            compare(shownHints(), "B Back", "a result row does nothing on Accept")
            const row = find("storageScan_vol-stick_cat:games")
            verify(row.inert)
            let hit = 0
            row.activated.connect(() => { hit++ })
            keyClick(Qt.Key_Return)
            wait(100)
            compare(hit, 0, "Accept on a result row emits nothing")
            verify(row.activeFocus, "and focus stays")
            goTo("storageEject_vol-stick")
            compare(shownHints(), "A Select|B Back", "Eject does something")
            goTo("storageApps")
            compare(shownHints(), "B Back")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Back leaves")
        }

        // The focused row is inside what the pane shows (rows rebuilt under it must not leave it off screen).
        function focusedRowIsShown() {
            const pane = find("paneStorage")
            const row = pane.focusableRows().find(r => r.activeFocus)
            if (!row)
                return false
            return row.y >= pane.scrollY - 0.5 && row.y + row.height <= pane.scrollY + pane.viewport.height + 0.5
        }

        function test_focus_stays_in_view_when_the_rows_under_it_are_rebuilt() {
            Storage.mockPlug(["vol-card"])
            tryVerify(() => volume("vol-card") !== undefined)
            openStoragePane()
            tryVerify(() => find("storageScan_vol-card_none") !== null, 3000)
            goTo("storageScan_vol-card_none")
            tryVerify(() => focusedRowIsShown(), 2000, "the focused result row is in view")
            Storage.mockSetScanFailed(true)
            Storage.mockSetFree("vol-card", 39000000000)   // the volume changed: scanned again, now unreadable
            tryVerify(() => find("storageScan_vol-card_failed") !== null, 3000)
            tryVerify(() => find("paneStorage").activeFocus, 2000)
            tryVerify(() => focusedRowIsShown(), 2000, "the focused row is still in view")
            keyClick(Qt.Key_Down)
            tryVerify(() => focusedRowIsShown(), 2000, "and Down keeps it in view")
        }

        function test_unreadable_drive_says_so_and_how_to_retry() {
            Storage.mockSetScanFailed(true)
            Storage.mockPlug(["vol-card"])
            tryVerify(() => volume("vol-card") !== undefined)
            openStoragePane()
            tryVerify(() => find("storageScan_vol-card_failed") !== null, 3000)
            compare(find("storageScan_vol-card_failed").label, "Could not read this drive")
            compare(find("storageScan_vol-card_failed").value, "Plug it in again")
            compare(scanRowNames("vol-card").join(), "failed")
            compare(Storage.mockScanCalls().length, 1, "not asked again in a loop")
            wait(200)
            compare(Storage.mockScanCalls().length, 1)
            compare(Storage.scans["vol-card"].state, "failed")
        }

        function test_zz_screenshots_scan_states() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            // Scanning, then nothing recognised, then an unreadable drive; English and Turkish.
            for (const lang of ["en", "tr"]) {
                DeviceSettings.language = lang
                Storage.mockReset()
                tryVerify(() => Storage.volumes.length === 2)
                Storage.mockSetScanFailed(false)
                Storage.mockHoldScan(true)
                Storage.mockPlug(["vol-card"])
                tryVerify(() => volume("vol-card") !== undefined)
                if (lang === "en")
                    openStoragePane()
                tryVerify(() => find("storageScan_vol-card_wait") !== null, 3000)
                goTo("storageScan_vol-card_wait")
                wait(800)
                grabImage(tc.shell).save(shotsDir + "/27-settings-storage-scan-scanning" + (lang === "tr" ? "-tr" : "") + ".png")
                Storage.mockHoldScan(false)
                tryVerify(() => find("storageScan_vol-card_none") !== null, 3000)
                goTo("storageScan_vol-card_none")
                wait(800)
                grabImage(tc.shell).save(shotsDir + "/27-settings-storage-scan-empty" + (lang === "tr" ? "-tr" : "") + ".png")
                // An unreadable drive: scanned again after the volume changes.
                Storage.mockSetScanFailed(true)
                Storage.mockSetFree("vol-card", 39000000000)
                tryVerify(() => find("storageScan_vol-card_failed") !== null, 3000)
                goTo("storageScan_vol-card_failed")
                wait(800)
                grabImage(tc.shell).save(shotsDir + "/27-settings-storage-scan-failed" + (lang === "tr" ? "-tr" : "") + ".png")
            }
        }

        function test_zz_screenshots_scan_turkish() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Storage.mockPlug(["vol-stick", "vol-card"])
            tryVerify(() => volume("vol-card") !== undefined)
            DeviceSettings.language = "tr"
            openStoragePane()
            tryVerify(() => find("storageScan_vol-card_none") !== null, 3000)
            goTo("storageScan_vol-stick_cat:games")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/27-settings-storage-scan-tr.png")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            openStoragePane()
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/27-settings-storage.png")
            goTo("storageVol_vol-stick")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/27-settings-storage-stick.png")
        }

        function test_zz_screenshots_low_space() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            Storage.mockLowSpace(true)
            tryCompare(Storage.internal, "freeBytes", 28000000000)
            openStoragePane()
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/27-settings-storage-low.png")
            Storage.mockLowSpace(false)
        }

        function test_zz_screenshots_profile_data_known() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            Storage.mockSetInternal(464000000000, 450000000000, 6500000000, 3200000000)
            tryCompare(Storage.internal, "dataBytes", 3200000000)
            openStoragePane()
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/27-settings-storage-data.png")
        }

        function test_zz_screenshots_turkish() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            Storage.mockPlugStick()
            tryVerify(() => volume("vol-stick") !== undefined)
            DeviceSettings.language = "tr"
            openStoragePane()
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/27-settings-storage-tr.png")
        }
    }
}
