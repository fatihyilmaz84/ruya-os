import QtQuick
import QtTest
import RuyaShell

// Settings -> About -> System information (T-226) against the mock backends: the sections and rows
// (three machines), a value that cannot be read is absent and never 0, the live values update in
// place with focus kept and are asked for only while the page is visible, the report export to a
// USB drive and its privacy default (MAC, IP, Wi-Fi name and Bluetooth address are left out unless
// the user opts in, in both files), controller-only operation, a late reply, Turkish.
// Signs in as "Ada" (p2, no PIN). The mocks are reset before every test.
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
        name: "SystemInfo"
        when: windowShown

        property Shell shell: null
        readonly property int aboutIndex: 10
        readonly property string txtName: "RuyaOS-system-report.txt"
        readonly property string jsonName: "RuyaOS-system-report.json"

        function find(name) { return findChild(tc.shell, name) }
        function row(uid) { return findChild(tc.shell, "sysRow_" + uid) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            DeviceSettings.language = "en"
            SystemDetails.mockReset()
            tryVerify(() => SystemDetails.valid)
            Storage.mockReset(false)
            Storage.mockSetSaveStatus("")
            Network.mockReset()
            Batteries.mockReset()
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
        }

        function cleanup() {
            DeviceSettings.language = "en"
            SystemDetails.mockReset()
            Storage.mockSetSaveStatus("")
            Network.mockReset()
            Batteries.mockReset()
        }

        // Down to the named item, asserting that it takes focus.
        function goTo(name) {
            tryVerify(() => find(name) !== null && find(name).visible, 3000, name + " exists")
            for (let i = 0; i < 120 && !find(name).activeFocus; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => find(name).activeFocus, 2000, name + " has focus")
        }

        function goToRow(uid) { goTo("sysRow_" + uid) }

        // Home -> Settings -> About -> System information, with the controller's keys only.
        function openSystemInfo() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus, 2000, "category list has focus")
            for (let i = 0; i < 20 && list.currentIndex < aboutIndex; ++i)
                keyClick(Qt.Key_Down)
            compare(list.currentIndex, aboutIndex)
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneAbout").activeFocus, 2000, "About pane has focus")
            goTo("aboutSystemInfo")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "systemInfo")
            tryVerify(() => find("sysSave").activeFocus, 2000, "the page opens on its first row")
        }

        function plugStick() {
            Storage.mockPlugStick()
            tryVerify(() => Storage.volumes.some(v => v.id === "vol-stick"), 2000, "the stick is listed")
        }

        // The information rows of the open page, top to bottom.
        function collectRows(item, out) {
            for (let i = 0; i < item.children.length; ++i) {
                const child = item.children[i]
                if (child.objectName.startsWith("sysRow_"))
                    out.push(child)
                collectRows(child, out)
            }
        }
        function infoRows() {
            const out = []
            collectRows(find("page_systemInfo"), out)
            return out
        }

        function savedFiles() { return Storage.mockSavedFiles() }

        function savedJson() { return JSON.parse(savedFiles()[jsonName]) }

        function saveWith(addresses) {
            if (addresses) {
                keyClick(Qt.Key_Down)
                tryVerify(() => find("sysAddresses").activeFocus)
                keyClick(Qt.Key_Return)
                tryCompare(find("sysAddresses"), "checked", true)
                keyClick(Qt.Key_Up)
                tryVerify(() => find("sysSave").activeFocus)
            }
            const calls = Storage.mockSaveCalls()
            keyClick(Qt.Key_Return)
            tryVerify(() => Storage.mockSaveCalls() === calls + 1, 2000, "a save was asked for")
            tryVerify(() => find("page_systemInfo").saveState === "ok", 2000, "the page says it saved")
        }

        // ---- opening and leaving

        function test_about_opens_the_page_and_back_returns_to_the_row() {
            openSystemInfo()
            verify(find("page_systemInfo").visible)
            compare(find("page_systemInfo").title, "System information")
            keyClick(Qt.Key_Escape)                      // B
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("aboutSystemInfo").activeFocus, 2000, "focus returns to the About row")
        }

        // ---- sections and rows

        // The viewport shows every whole row that fits, from the first (the pane sizes it from the
        // rows it has, and rows arrive after the page opens).
        function test_the_page_opens_showing_all_the_rows_that_fit() {
            openSystemInfo()
            const body = find("sysBody")
            tryVerify(() => body.viewport.height > 3 * find("sysSave").height, 2000, "more than the first rows are shown")
            const rows = infoRows()
            verify(rows.length > 10)
            const first = rows[0]
            verify(body.viewport.height >= body.height - 2 * first.height, "the viewport fills the pane to its last whole row")
        }

        // What the hint bar offers: A only where A does something (the two export rows).
        function hintsOf(item) { return item.hints.map(h => h.button + " " + h.text).join("|") }

        function test_the_hint_bar_offers_select_only_on_the_export_rows() {
            openSystemInfo()
            const page = find("page_systemInfo")
            compare(hintsOf(page), "A Select|B Back", "Save report")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("sysAddresses").activeFocus)
            compare(hintsOf(page), "A Select|B Back", "Include network addresses")
            keyClick(Qt.Key_Down)
            tryVerify(() => row("console/version").activeFocus)
            compare(hintsOf(page), "B Back", "an information row does nothing on A")
            keyClick(Qt.Key_Up)
            tryVerify(() => find("sysAddresses").activeFocus)
            compare(hintsOf(page), "A Select|B Back")
        }

        // A row's label can be a device's own name: it is never read as markup.
        function test_labels_are_plain_text() {
            Batteries.mockSet("pad-markup", 70, "discharging", "controller", "<b>Bold</b> Pad")
            openSystemInfo()
            tryVerify(() => infoRows().some(r => r.label === "<b>Bold</b> Pad"), 2000, "the name is the label, literally")
            const item = infoRows().find(r => r.label === "<b>Bold</b> Pad")
            compare(findChild(item, "label").textFormat, Text.PlainText)
            compare(findChild(find("sysSave"), "label").textFormat, Text.PlainText, "every settings row")
        }

        function test_the_dell_has_its_sections_and_rows() {
            openSystemInfo()
            for (const id of ["console", "cpu", "memory", "graphics", "storage", "network", "bluetooth", "audio", "controllers"])
                verify(find("sysHeading_" + id), "a heading for " + id)
            compare(find("sysHeading_cpu").text, "Processor")
            compare(row("console/version").value, "RuyaOS 0.0.50")
            compare(row("console/machine").value, "Dell Inc. OptiPlex 3080")
            compare(row("console/firmware").value, "UEFI")
            compare(row("console/secure_boot").value, "Off")
            compare(row("cpu/model").value, "Intel(R) Core(TM) i5-10500T CPU @ 2.30GHz")
            compare(row("cpu/cores").value, "6")
            compare(row("cpu/threads").value, "12")
            compare(row("cpu/clock").value, "2300 MHz (up to 3800 MHz)")
            compare(row("cpu/temperature").value, "41 °C", "the processor temperature is Thermal's, not repeated by the service")
            compare(row("graphics/gpu").value, "Intel UHD Graphics 630")
            compare(row("graphics/driver").value, "i915 6.18.3-200.fc44.x86_64")
            compare(row("graphics/mesa").value, "25.2.6")
            compare(row("graphics/connector").value, "HDMI-A-1")
            compare(row("graphics/effects").value, "High", "the effects tier is the shell's own setting")
            compare(row("storage/drive0").value, "Samsung SSD 870 · SSD · " + Storage.formatBytes(500107862016))
            compare(row("storage/free").value, Storage.formatBytes(450000000000) + " free of " + Storage.formatBytes(464000000000),
                    "the free space is Storage's (T-196) number")
            compare(row("network/connection").value, "Wired")
            compare(row("network/link").value, "1000 Mb/s")
            compare(row("bluetooth/chipset").value, "Intel Corp. Bluetooth wireless interface")
            verify(row("audio/output1"), "an output device (keyed by position, not by the service id)")
            const pad = Batteries.devices.find(b => b.kind === "controller")
            compare(row("controllers/controller1").value, pad.percent + " %", "a controller with its battery (T-223)")
            compare(row("controllers/controller1").label, pad.name)
            verify(row("controllers/controller2") === null, "a controller that is not connected (Retro Pad) is not listed")
            // A connected controller that has no entry in Batteries is listed from Bluetooth (with its own battery).
            Batteries.mockClear()
            tryVerify(() => row("controllers/controller1") !== null && row("controllers/controller1").label === "Ruya Pad Pro", 2000)
            compare(row("controllers/controller1").value, "80 %")
        }

        function test_memory_has_a_usage_bar() {
            openSystemInfo()
            const used = row("memory/used")
            verify(used, "the in-use row")
            const track = findChild(used, "usageTrack")
            verify(track.visible, "a bar for the memory in use")
            const fill = findChild(used, "usageFill")
            const expected = SystemDetails.info["memory.used_bytes"] / SystemDetails.info["memory.total_bytes"]
            tryVerify(() => Math.abs(fill.width / track.width - expected) < 0.02, 2000, "the bar shows " + expected)
            verify(!findChild(row("memory/total"), "usageTrack").visible, "other rows have no bar")
        }

        function test_the_other_machines() {
            SystemDetails.mockProfile("nvidia")
            openSystemInfo()
            compare(row("graphics/gpu").value, "NVIDIA GeForce RTX 3070")
            compare(row("graphics/nvidia").value, "550.54.14")
            verify(row("graphics/mesa") === null, "Mesa is not shown with the NVIDIA driver")
            compare(row("storage/drive0").value, "WD_BLACK SN770 1TB · NVMe · " + Storage.formatBytes(1000204886016))
            compare(row("storage/drive0health").value, "Healthy", "health only for NVMe")
            compare(row("storage/drive1").value, "ST2000DM008-2FR102 · Hard disk · " + Storage.formatBytes(2000398934016))
            verify(row("storage/drive1health") === null, "no health for a hard disk")
            compare(find("sysRow_storage/drive0").label, "Drive 1")
            verify(row("memory/swap") === null, "no swap: absent, not 0")
            SystemDetails.mockProfile("amd")
            tryCompare(row("graphics/gpu"), "value", "AMD Radeon Graphics (Barcelo)")
            compare(row("cpu/model").value, "AMD Ryzen 5 5625U with Radeon Graphics")
            compare(row("console/secure_boot").value, "On")
            compare(row("graphics/mesa").value, "25.2.6")
            compare(row("storage/drive0").label, "Drive")
        }

        function test_a_value_that_cannot_be_read_is_absent_not_zero() {
            openSystemInfo()
            verify(row("memory/swap"), "swap is listed on the Dell")
            SystemDetails.mockRemove("memory.swap_total_bytes")
            SystemDetails.mockRemove("memory.swap_used_bytes")
            tryVerify(() => row("memory/swap") === null, 2000, "the swap row goes away")
            SystemDetails.mockRemove("graphics.vendor")
            SystemDetails.mockRemove("graphics.model")
            SystemDetails.mockRemove("graphics.driver")
            SystemDetails.mockRemove("cpu.cores")
            tryVerify(() => row("graphics/gpu") === null, 2000)
            verify(row("graphics/driver") === null)
            verify(row("cpu/cores") === null)
            verify(row("cpu/threads") !== null, "what is known stays")
            // No row shows a zero or an empty value for something that could not be read.
            for (const item of infoRows()) {
                verify(item.value !== "", item.objectName + " is empty")
                verify(item.value !== "0" && item.value !== Storage.formatBytes(0), item.objectName + " shows a zero")
            }
        }

        // ---- live values

        function test_live_values_update_in_place_and_focus_is_kept() {
            openSystemInfo()
            goToRow("memory/used")
            const used = row("memory/used")
            const before = used.value
            const fillBefore = findChild(used, "usageFill").width
            SystemDetails.mockSet("memory.used_bytes", 6500000000)
            tryVerify(() => used.value !== before, 2000, "the value changed")
            compare(used.value, Storage.formatBytes(6500000000))
            verify(row("memory/used") === used, "the same row, not a new one")
            tryVerify(() => findChild(used, "usageFill").width !== fillBefore, 2000, "the bar follows")
            verify(used.activeFocus, "focus stays on the row")
            SystemDetails.mockSet("cpu.freq_mhz", 3777)
            tryVerify(() => row("cpu/clock").value === "3777 MHz (up to 3800 MHz)", 2000)
            verify(used.activeFocus, "focus stays after another live value")
        }

        function test_the_page_asks_for_live_values_only_while_it_is_visible() {
            SystemDetails.liveIntervalMs = 40
            openSystemInfo()
            const page = find("page_systemInfo")
            const start = SystemDetails.refreshCount
            tryVerify(() => SystemDetails.refreshCount >= start + 3, 3000, "polled while visible")
            // Hidden (a page over it hides it and keeps it alive): the timer stops and nothing is asked for.
            page.visible = false
            tryVerify(() => !find("sysLiveTimer").running, 2000, "the timer stops with the page")
            const stopped = SystemDetails.refreshCount
            wait(10 * SystemDetails.liveIntervalMs)
            compare(SystemDetails.refreshCount, stopped, "nothing is asked for while the page is hidden")
            page.visible = true
            tryVerify(() => SystemDetails.refreshCount > stopped, 2000, "and it asks again when shown")
            // Not while an app is in front, nor while the window is not shown.
            for (const gate of ["appOpen", "screenShown"]) {
                LiquidGate[gate] = gate === "appOpen"
                tryVerify(() => !find("sysLiveTimer").running, 2000, gate + " stops the timer")
                const held = SystemDetails.refreshCount
                wait(10 * SystemDetails.liveIntervalMs)
                compare(SystemDetails.refreshCount, held, "nothing is asked for with " + gate)
                LiquidGate.reset()
                tryVerify(() => find("sysLiveTimer").running, 2000, "it runs again")
            }
        }

        function test_a_late_reply_is_dropped() {
            openSystemInfo()
            SystemDetails.mockRefreshDelayed(250)         // answers with the data as it is now, in 250 ms
            compare(SystemDetails.mockPendingReplies(), 1)
            SystemDetails.mockSet("cpu.model", "Newer CPU")
            tryVerify(() => row("cpu/model").value === "Newer CPU", 2000)
            tryVerify(() => SystemDetails.mockPendingReplies() === 0, 3000, "the old reply has landed")
            compare(SystemDetails.info["cpu.model"], "Newer CPU", "and was dropped")
            compare(row("cpu/model").value, "Newer CPU")
        }

        // ---- the controller's keys

        function test_rows_only_scroll_accept_does_nothing_and_b_goes_back() {
            openSystemInfo()
            keyClick(Qt.Key_Down)
            tryVerify(() => find("sysAddresses").activeFocus)
            keyClick(Qt.Key_Down)
            // Past the export controls the next focusable item is the first information row.
            tryVerify(() => row("console/version").activeFocus, 2000, "Down reaches the first row")
            const calls = Storage.mockSaveCalls()
            keyClick(Qt.Key_Return)
            compare(Storage.mockSaveCalls(), calls, "Accept on an information row does nothing")
            compare(tc.shell.currentPage, "systemInfo")
            keyClick(Qt.Key_Down)
            tryVerify(() => row("console/channel").activeFocus, 2000)
            keyClick(Qt.Key_Up)
            tryVerify(() => row("console/version").activeFocus, 2000)
            const last = infoRows()[infoRows().length - 1]
            goTo(last.objectName)
            keyClick(Qt.Key_Down)
            verify(last.activeFocus, "clamps at the last row")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("aboutSystemInfo").activeFocus, 2000)
        }

        // ---- the report

        function test_no_drive_says_so_and_writes_nothing() {
            openSystemInfo()
            keyClick(Qt.Key_Return)
            tryVerify(() => find("sysSaveMessage").visible, 2000)
            compare(find("sysSaveMessage").text, "No USB drive found. Plug one in and try again.")
            compare(Storage.mockSaveCalls(), 0)
            verify(find("sysSave").activeFocus)
        }

        function test_the_report_is_saved_without_addresses_by_default() {
            Network.mockSetCable(false)
            Network.connectWifi("wifi-home", Network.mockPassword())
            tryCompare(Network.primary, "kind", "wifi")
            plugStick()
            // Devices whose ids and names look like addresses: a UPower path with the pad's address in
            // it, and a name that is an address. Neither may be in either file.
            const upower = "/org/freedesktop/UPower/devices/gaming_input_ps_controller_battery_a0o5bo51o12o34o56"
            Batteries.mockSet(upower, 55, "discharging", "controller", "Pad A0:5B:51:12:34:56")
            openSystemInfo()
            verify(!find("sysAddresses").checked, "network addresses start off")
            saveWith(false)
            compare(find("sysSaveMessage").text, "Saved RuyaOS-system-report.txt and RuyaOS-system-report.json to Ruya Stick.")
            compare(find("sysSaveMessage").textFormat, Text.PlainText, "the drive's label is the stick's: never markup")
            const files = savedFiles()
            compare(Object.keys(files).sort(), [jsonName, txtName])
            // Nothing of what names this console on a network, in either file.
            const text = files[txtName]
            const json = files[jsonName]
            const secrets = ["c8:4b:d6:aa:bb:cc", "192.168.1.21", "HomeNet", "9C:B6:D0:12:34:56", "a0o5bo51o12o34o56", "A0:5B:51:12:34:56", upower]
            // The services' own ids (a Bluetooth id is the device's address): none of them either.
            for (const sink of Audio.sinks)
                secrets.push(sink.id)
            for (const device of Bluetooth.devices)
                secrets.push(device.id)
            for (const device of Batteries.devices)
                secrets.push(device.id)
            for (const secret of secrets) {
                verify(text.indexOf(secret) < 0, "the text has no " + secret)
                verify(json.indexOf(secret) < 0, "the JSON has no " + secret)
            }
            verify(json.indexOf("controller1") >= 0 && json.indexOf("output1") >= 0, "devices are keyed by position")
            verify(text.indexOf("Intel(R) Core(TM) i5-10500T") >= 0, "but the rest is there")
            verify(text.indexOf("MAC address") < 0 && text.indexOf("IP address") < 0 && text.indexOf("Wi-Fi network") < 0)
            const report = savedJson()
            compare(report.includesNetworkAddresses, false)
            compare(report.sections.cpu.model, "Intel(R) Core(TM) i5-10500T CPU @ 2.30GHz")
            compare(report.sections.memory.total, 7970348 * 1024, "numbers stay numbers, sizes are bytes")
            for (const key of ["mac", "ip", "ssid"])
                verify(!(key in report.sections.network), "no network." + key)
            verify("connection" in report.sections.network)
            compare(Object.keys(report.sections.bluetooth).indexOf("address"), -1)
            verify(text.indexOf("not included") >= 0, "the text says that addresses were left out")
        }

        function test_the_report_includes_addresses_only_on_request() {
            Network.mockSetCable(false)
            Network.connectWifi("wifi-home", Network.mockPassword())
            tryCompare(Network.primary, "kind", "wifi")
            plugStick()
            openSystemInfo()
            saveWith(true)
            const text = savedFiles()[txtName]
            const json = savedFiles()[jsonName]
            for (const wanted of ["c8:4b:d6:aa:bb:cc", "192.168.1.21", "HomeNet", "9C:B6:D0:12:34:56"]) {
                verify(text.indexOf(wanted) >= 0, "the text has " + wanted)
                verify(json.indexOf(wanted) >= 0, "the JSON has " + wanted)
            }
            const report = savedJson()
            compare(report.includesNetworkAddresses, true)
            compare(report.sections.network.ssid, "HomeNet")
            // The switch starts off again the next time the page opens.
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("aboutSystemInfo").activeFocus, 2000)
            tryVerify(() => find("page_systemInfo") === null, 3000, "the closed page is gone")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "systemInfo")
            tryVerify(() => find("sysAddresses") !== null)
            verify(!find("sysAddresses").checked, "off again")
        }

        function test_the_report_is_english_whatever_the_ui_language() {
            plugStick()
            DeviceSettings.language = "tr"
            openSystemInfo()
            saveWith(false)
            const text = savedFiles()[txtName]
            verify(text.indexOf("Processor") >= 0 && text.indexOf("İşlemci") < 0, "the file stays in English")
            compare(savedJson().sections.cpu.model, "Intel(R) Core(TM) i5-10500T CPU @ 2.30GHz")
        }

        function test_save_failures_are_told() {
            plugStick()
            openSystemInfo()
            const answers = { "full": "This drive is full. Free some space or try another one.",
                              "read-only": "This drive is read-only. Try another one.",
                              "failed": "The report could not be saved." }
            for (const status of Object.keys(answers)) {
                Storage.mockSetSaveStatus(status)
                const calls = Storage.mockSaveCalls()
                keyClick(Qt.Key_Return)
                tryVerify(() => Storage.mockSaveCalls() === calls + 1, 2000)
                tryVerify(() => find("sysSaveMessage").text === answers[status], 2000, status)
            }
            Storage.mockSetSaveStatus("")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("page_systemInfo").saveState === "ok", 2000)
            verify(find("sysSave").activeFocus, "focus never left the row")
        }

        // ---- Turkish

        function test_turkish_rows_update_in_place() {
            openSystemInfo()
            goToRow("cpu/model")
            const model = row("cpu/model")
            DeviceSettings.language = "tr"
            tryCompare(find("sysHeading_cpu"), "text", "İşlemci")
            compare(model.label, "Model")
            verify(row("cpu/model") === model, "the row is the same object: the model is keys only")
            verify(model.activeFocus, "focus survives the language switch")
            compare(row("cpu/cores").label, "Çekirdek sayısı")
            compare(find("sysSave").label, "Raporu USB sürücüye kaydet")
            compare(row("console/secure_boot").value, "Kapalı")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            plugStick()
            openSystemInfo()
            wait(800)
            // In a real window the rows must be laid out and shown (a Column left unlaid showed one row).
            verify(find("sysBody").viewport.height > 3 * find("sysSave").height, "the page shows more than its first row")
            grabImage(tc.shell).save(shotsDir + "/30-system-info-top.png")
            goToRow("memory/used")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/30-system-info-memory.png")
            goToRow("storage/free")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/30-system-info-storage.png")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("page_systemInfo") === null, 3000, "the closed page is gone")
            SystemDetails.mockProfile("nvidia")
            tryVerify(() => find("aboutSystemInfo").activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "systemInfo")
            goToRow("graphics/nvidia")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/30-system-info-nvidia.png")
            keyClick(Qt.Key_Escape)
            tryCompare(tc.shell, "currentPage", "settings")
            tryVerify(() => find("page_systemInfo") === null, 3000, "the closed page is gone")
            tryVerify(() => find("aboutSystemInfo").activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "systemInfo")
            tryVerify(() => find("sysSave").activeFocus, 2000)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("sysSaveMessage").text.startsWith("Saved "), 2000)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/30-system-info-saved.png")
        }

        function test_zz_screenshots_turkish() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.language = "tr"
            SystemDetails.mockProfile("amd")
            openSystemInfo()
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/30-system-info-tr.png")
            goToRow("graphics/gpu")
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/30-system-info-graphics-tr.png")
        }
    }
}
