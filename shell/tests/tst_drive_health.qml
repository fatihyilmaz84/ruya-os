import QtQuick
import QtTest
import RuyaShell
import "LiveRows.js" as LiveRows
import "SettingsNav.js" as SettingsNav

// The internal drives' SMART state (RUY-737; DriveHealth, System information's storage.drives) against
// the mock: the "Drive" rows of Settings -> System > Device health ("Good", "Check soon", "Failing"
// with a mark and the word, the model as the second line), the mark on the System category, focus
// staying on a row whose value changes, the failing notice (once per drive and boot, never for
// "Check soon") and nothing at all for a machine whose drives have no SMART. Signs in as "Ada".
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "DriveHealth"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function drive(model, smart, extra) {
            const d = { model: model, type: "ssd", size_bytes: 500107862016 }
            if (smart)
                d.smart = smart
            return Object.assign(d, extra ?? {})
        }

        function setDrives(list) { SystemDetails.mockSet("storage.drives", list) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.language = "en"
            SystemDetails.mockReset()
            Thermal.mockReset()
            DriveHealth.notified = ({})
            Power.mockReset()
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
            SystemDetails.mockReset()
            clearToasts()
            DeviceSettings.language = "en"
        }

        function clearToasts() {
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
        }

        function driveToasts() {
            const out = []
            for (let i = 0; i < Notifications.model.count; ++i) {
                const t = Notifications.model.get(i)
                if (t.text === "A drive is failing")
                    out.push(t)
            }
            return out
        }

        function openSystemPane() {
            keyClick(Qt.Key_Up)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000, "category list has focus")
            SettingsNav.select(tc, "system")
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneSystem").activeFocus, 2000, "System pane has focus")
        }

        function goTo(name) {
            tryVerify(() => find(name) !== null && find(name).visible, 3000, name + " exists")
            for (let i = 0; i < 40 && !find(name).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => find(name).activeFocus, 2000, name + " has focus")
        }

        // ---- the rows

        function test_a_good_drive_has_a_row_with_the_model_and_no_mark() {
            openSystemPane()
            tryVerify(() => find("healthDrive_0") !== null, 2000)
            const row = find("healthDrive_0")
            compare(row.label, "Drive")
            compare(row.value, "Good")
            compare(row.marked, false, "good has no mark")
            compare(row.detail, "Samsung SSD 870", "the model; the temperature is Thermal's own row")
            verify(find("health_mock:fan").y < row.y, "after the temperatures")
        }

        function test_check_soon_and_failing_have_a_mark_and_the_word() {
            setDrives([drive("Old Disk", "warning"), drive("Dying Disk", "failing")])
            openSystemPane()
            tryVerify(() => find("healthDrive_1") !== null, 2000)
            const warn = find("healthDrive_0")
            const fail = find("healthDrive_1")
            compare(warn.label, "Drive 1")
            compare(fail.label, "Drive 2", "numbered when there are several")
            compare(warn.markText, "Check soon")
            compare(warn.value, "", "the word is the mark's, not said twice")
            compare(warn.marked, true)
            compare(warn.markColor.toString(), Theme.warningText.toString())
            compare(fail.markText, "Failing")
            compare(fail.markColor.toString(), Theme.errorText.toString())
            compare(fail.detail, "Dying Disk")
            verify(warn.accessibleValue.indexOf("Check soon") >= 0)
        }

        function test_a_drive_without_smart_has_no_row() {
            setDrives([drive("Virtio", "unsupported"), drive("Unknown", "")])
            openSystemPane()
            tryVerify(() => find("health_mock:fan") !== null, 2000)
            compare(find("healthDrive_0"), null)
            compare(DriveHealth.worst, "")
        }

        function test_the_smart_temperature_shows_only_where_thermal_has_no_drive() {
            setDrives([drive("Sata Disk", "ok", { temperature_c: 41 })])
            openSystemPane()
            tryVerify(() => find("healthDrive_0") !== null, 2000)
            compare(find("healthDrive_0").detail, "Sata Disk", "Thermal measures the drive itself")
            Thermal.mockRemove("mock:ssd")
            tryVerify(() => find("healthDrive_0").detail === "Sata Disk · 41 °C", 2000)
        }

        function test_focus_stays_on_a_row_whose_value_changes() {
            setDrives([drive("Disk A", "ok")])
            openSystemPane()
            goTo("healthDrive_0")
            const row = find("healthDrive_0")
            const tracked = LiveRows.track(row)
            setDrives([drive("Disk A", "warning")])
            tryCompare(row, "markText", "Check soon")
            compare(row.value, "")
            LiveRows.verifySame(tc, tracked, "a new state")
            verify(row.activeFocus, "focus stays")
        }

        function test_the_focused_row_going_away_moves_focus_on() {
            setDrives([drive("Disk A", "ok")])
            openSystemPane()
            goTo("healthDrive_0")
            setDrives([drive("Disk A", "unsupported")])
            tryVerify(() => find("healthDrive_0") === null, 2000, "its row is gone")
            tryVerify(() => find("paneSystem").activeFocus, 2000, "focus is still in the pane")
        }

        // ---- the category mark

        function test_the_system_category_carries_the_drive_mark() {
            keyClick(Qt.Key_Up)
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("categoryList").activeFocus, 2000)
            SettingsNav.select(tc, "system")
            compare(find("categoryHeatMark_system").visible, false, "a good drive shows nothing")
            setDrives([drive("Disk A", "warning")])
            tryVerify(() => find("categoryHeatMark_system").visible, 2000, "Check soon is marked")
            compare(find("categoryHeatMark_system").color.toString(), Theme.warningText.toString())
            verify(find("category_system").Accessible.name.indexOf("Check soon") >= 0, find("category_system").Accessible.name)
            setDrives([drive("Disk A", "failing")])
            tryVerify(() => find("categoryHeatMark_system").color.toString() === Theme.errorText.toString(), 2000)
            setDrives([drive("Disk A", "ok")])
            tryVerify(() => !find("categoryHeatMark_system").visible, 2000)
            verify(find("categoryList").activeFocus, "focus untouched")
        }

        // ---- the failing notice

        function test_a_failing_drive_is_told_once_and_check_soon_never() {
            setDrives([drive("Warn Disk", "warning")])
            wait(200)
            compare(driveToasts().length, 0, "Check soon posts nothing")
            setDrives([drive("Fail Disk", "failing")])
            tryVerify(() => driveToasts().length === 1, 2000)
            const toast = driveToasts()[0]
            compare(toast.kind, "warning")
            compare(toast.detail, "Back up your saves · Fail Disk")
            // The same drive again, after other changes: not a second time.
            setDrives([drive("Fail Disk", "failing", { power_on_hours: 5 })])
            setDrives([drive("Fail Disk", "ok")])
            setDrives([drive("Fail Disk", "failing")])
            wait(200)
            compare(driveToasts().length, 1, "once per boot")
            // Another drive failing is its own news.
            setDrives([drive("Fail Disk", "failing"), drive("Other Disk", "failing", { size_bytes: 1000 })])
            tryVerify(() => driveToasts().length === 2, 2000)
        }

        function test_the_failing_notice_is_in_the_language_the_shell_runs_in() {
            DeviceSettings.language = "tr"
            setDrives([drive("Fail Disk", "failing")])
            tryVerify(() => Notifications.model.count === 1, 2000)
            compare(Notifications.model.get(0).text, "Bir sürücü arızalanıyor")
            compare(Notifications.model.get(0).detail, "Kayıtlarınızı yedekleyin · Fail Disk")
        }

        function test_the_failing_notice_offers_settings_system() {
            setDrives([drive("Fail Disk", "failing")])
            tryVerify(() => driveToasts().length === 1, 2000)
            let found = null
            for (const item of NotificationCentre.items) {
                if (item.title === "A drive is failing")
                    found = item
            }
            verify(found, "the item is in the centre")
            compare(found.source, "devices")
            compare(found.actions[0].id, "settings:system")
            compare(found.actions[0].label, "Open Settings")
        }

        function test_a_machine_without_smart_says_nothing() {
            setDrives([drive("Virtio", "unsupported")])
            wait(200)
            compare(driveToasts().length, 0)
            compare(DriveHealth.drives.length, 0)
            setDrives([])
            wait(100)
            compare(driveToasts().length, 0)
        }

        // ---- System information

        function test_the_system_information_shows_hours_and_wear_where_known() {
            setDrives([drive("Nvme Disk", "ok", { power_on_hours: 812, wear_percent: 4, type: "nvme" }),
                       drive("Sata Disk", "ok", { power_on_hours: 1 })])
            const rows = Qt.createQmlObject('import QtQuick; import RuyaShell; SystemInfoRows {}', host)
            tryVerify(() => rows.byUid["storage/drive0hours"] !== undefined, 2000)
            compare(rows.byUid["storage/drive0hours"].label, "Drive 1 powered on")
            compare(rows.byUid["storage/drive0hours"].value, "812 hours")
            compare(rows.byUid["storage/drive0wear"].value, "4 %")
            compare(rows.byUid["storage/drive1hours"].value, "1 hour")
            compare(rows.byUid["storage/drive1wear"], undefined, "no wear for a drive that does not say")
            compare(rows.byUid["storage/drive0health"].value, "Good")
            compare(rows.byUid["storage/drive0health"].value, DriveHealth.stateText("ok"), "one word for a good drive on both surfaces")
            setDrives([drive("Nvme Disk", "warning")])
            tryVerify(() => rows.byUid["storage/drive0health"].value === "Check soon", 2000)
            compare(rows.byUid["storage/drive0hours"], undefined, "unknown stays absent")
            rows.destroy()
        }

        // ---- screenshots (dev.ps1 shots)

        function showDrives() {
            openSystemPane()
            goTo("healthDrive_1")
            wait(800)
        }

        function test_zz_screenshots_warning_and_failing() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            setDrives([drive("Samsung SSD 860 EVO 500GB", "warning"), drive("WD_BLACK SN770 1TB", "failing", { type: "nvme" })])
            showDrives()
            grabImage(tc.shell).save(shotsDir + "/31-settings-drive-health.png")
        }

        function test_zz_screenshots_turkish() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            // The language first, as at boot: the notice is raised in the language the shell runs in.
            DeviceSettings.language = "tr"
            setDrives([drive("Samsung SSD 860 EVO 500GB", "warning"), drive("WD_BLACK SN770 1TB", "failing", { type: "nvme" })])
            showDrives()
            grabImage(tc.shell).save(shotsDir + "/31-settings-drive-health-tr.png")
        }
    }
}
