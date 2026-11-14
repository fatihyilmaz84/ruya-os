import QtQuick
import QtTest
import RuyaShell

// Settings -> Network against the mock backend: joining WPA, open and enterprise networks, a
// wrong password, the cable going away, forgetting a saved network. Driven with keys only
// (the password is typed on the physical-keyboard path of TextEntry). Signs in as "Ada" (p2,
// no PIN). The mock is reset before every test.
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
        name: "Network"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Network.mockReset()
            tryCompare(Network, "state", "connected")
            tryVerify(() => Network.networks.length === 4 && Network.networks[0].known
                      && !Network.networks[1].known && Network.networks.every(n => !n.active))
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
            clearToasts()
            DeviceSettings.theme = "dreamglass"
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

        function openNetworkPane() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 4; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings
            tryCompare(tc.shell, "currentPage", "settings")
            const list = find("categoryList")
            tryVerify(() => list.activeFocus, 2000, "category list has focus")
            keyClick(Qt.Key_Down)                        // Network
            keyClick(Qt.Key_Right)
            tryVerify(() => find("paneNetwork").visible)
            tryVerify(() => find("wifi_wifi-lounge").activeFocus, 2000, "the first network takes focus")
        }

        function typeText(text) {
            for (const ch of text)
                keyClick(ch)
        }

        function network(id) {
            return Network.networks.find(n => n.id === id)
        }

        // Down to the named row, asserting focus on the way.
        function goTo(name, downs) {
            for (let i = 0; i < downs; ++i)
                keyClick(Qt.Key_Down)
            tryVerify(() => find(name).activeFocus, 2000, name + " has focus")
        }

        function test_status_row() {
            openNetworkPane()
            compare(find("rowNetStatus").label, "Wired connection")
            compare(find("rowNetStatus").value, "Connected")
            compare(find("wifi_wifi-lounge").label, "Lounge 5G")
            verify(find("wifi_wifi-lounge").value.includes("Saved"))
            verify(find("wifi_wifi-home").value.includes("Secured"))
            verify(find("wifi_wifi-cafe").value.includes("Open"))
        }

        // RUY-513: the kinds, the group label, the current network, the silent fact.
        function test_row_kinds_and_group_label() {
            openNetworkPane()
            compare(find("rowNetStatus").kind, "info")
            compare(find("rowScan").kind, "action")
            compare(find("wifi_wifi-lounge").kind, "item")
            compare(find("forget_wifi-lounge").kind, "action")
            const label = find("wifiGroupLabel")
            verify(label.visible, "the label shows with Wi-Fi rows")
            compare(label.text, "Wi-Fi networks")
            verify(label.y < find("wifi_wifi-lounge").y, "above the first Wi-Fi row")
            const pane = find("paneNetwork")
            // No Wi-Fi rows: no label; they come back: the label too.
            Network.mockClearNetworks()
            tryVerify(() => find("wifi_wifi-lounge") === null, 3000, "the Wi-Fi rows are gone")
            verify(!label.visible, "no Wi-Fi rows, no label")
            Network.mockReset()
            tryVerify(() => find("wifi_wifi-lounge") !== null && find("wifi_wifi-lounge").visible, 3000, "the rows are back")
            verify(label.visible, "the label is back with them")
            tryVerify(() => find("wifi_wifi-lounge") !== null)
            // The fact: Up from the first network lands on it, A is silent, the bar offers Back only.
            keyClick(Qt.Key_Up)
            tryVerify(() => find("rowNetStatus").activeFocus, 2000, "Up skips the label and lands on the fact")
            compare(pane.hints.map(h => h.button + " " + h.text).join("|"), "B Back")
            const selects = Sfx.selectCount
            keyClick(Qt.Key_Return)
            compare(Sfx.selectCount, selects, "Accept on the fact makes no sound")
            keyClick(Qt.Key_Down)
            tryVerify(() => find("wifi_wifi-lounge").activeFocus, 2000, "Down skips the label")
            compare(pane.hints.map(h => h.button + " " + h.text).join("|"), "A Connect|B Back")
            // Back leaves from the fact too.
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "Back leaves from the fact row")
        }

        function test_current_network_follows_the_join() {
            openNetworkPane()
            const rows = ["wifi_wifi-lounge", "wifi_wifi-home", "wifi_wifi-cafe"]
            verify(rows.every(r => find(r).current === false), "none is in use at the start")
            goTo("wifi_wifi-cafe", 2)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("wifi_wifi-cafe").current, 2000, "the joined network is current")
            verify(!find("wifi_wifi-lounge").current && !find("wifi_wifi-home").current)
            Network.connectWifi("wifi-lounge", "")
            tryVerify(() => find("wifi_wifi-lounge").current, 2000, "another one joined: the mark moves")
            verify(!find("wifi_wifi-cafe").current)
        }

        function test_connect_wpa() {
            openNetworkPane()
            goTo("wifi_wifi-home", 1)
            keyClick(Qt.Key_Return)
            const entry = find("wifiPasswordEntry")
            tryVerify(() => entry.shown && entry.activeFocus, 2000, "password entry opens")
            verify(entry.mask, "the password is masked")
            typeText(Network.mockPassword())
            keyClick(Qt.Key_Return)                      // Done
            tryVerify(() => network("wifi-home").active, 2000, "the network is active")
            verify(network("wifi-home").known, "a successful join saves the network")
            tryVerify(() => !entry.shown)
            tryVerify(() => find("wifi_wifi-home").activeFocus, 2000, "focus returns to the row")
            verify(find("wifi_wifi-home").value.includes("Connected"))
            compare(toastTexts().length, 0, "no error shown")
        }

        function test_wrong_password() {
            openNetworkPane()
            goTo("wifi_wifi-home", 1)
            keyClick(Qt.Key_Return)
            const entry = find("wifiPasswordEntry")
            tryVerify(() => entry.shown && entry.activeFocus)
            typeText("not-the-password")
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().includes("Wrong password."), 2000, "the error is shown")
            verify(!network("wifi-home").active)
            verify(!network("wifi-home").known)
            tryVerify(() => find("wifi_wifi-home").activeFocus, 2000, "focus stays on the row")
        }

        function test_open_network_joins_at_once() {
            openNetworkPane()
            goTo("wifi_wifi-cafe", 2)
            keyClick(Qt.Key_Return)
            tryVerify(() => network("wifi-cafe").active, 2000)
            compare(find("wifiPasswordEntry"), null, "no password asked for an open network (the keyboard is not even built, T-349)")
            tryVerify(() => find("wifi_wifi-cafe").activeFocus)
        }

        function test_saved_network_needs_no_password() {
            openNetworkPane()
            keyClick(Qt.Key_Return)                      // Lounge 5G is saved
            tryVerify(() => network("wifi-lounge").active, 2000)
            compare(find("wifiPasswordEntry"), null, "no password asked")
        }

        function test_enterprise_unsupported() {
            openNetworkPane()
            goTo("wifi_wifi-campus", 3)
            keyClick(Qt.Key_Return)
            tryVerify(() => toastTexts().includes("Enterprise networks are not supported."), 2000)
            verify(!network("wifi-campus").active)
            tryVerify(() => find("wifi_wifi-campus").activeFocus)
        }

        function test_cable_unplugged() {
            openNetworkPane()
            compare(find("rowNetStatus").value, "Connected")
            Network.mockSetCable(false)
            tryCompare(find("rowNetStatus"), "value", "Not connected")
            compare(find("rowNetStatus").label, "Network")
            goTo("wifi_wifi-cafe", 2)
            keyClick(Qt.Key_Return)                      // join an open network
            tryCompare(find("rowNetStatus"), "label", "Cafe Guest")
            compare(find("rowNetStatus").value, "Connected")
            compare(Network.primary.kind, "wifi")
        }

        function test_forget() {
            openNetworkPane()
            verify(find("forget_wifi-lounge").visible)
            verify(!find("forget_wifi-home").visible, "only saved networks offer Forget")
            goTo("forget_wifi-lounge", 5)
            keyClick(Qt.Key_Return)
            tryVerify(() => !network("wifi-lounge").known, 2000)
            tryVerify(() => !find("forget_wifi-lounge").visible)
            tryVerify(() => find("paneNetwork").activeFocus, 2000, "focus stays in the pane")
        }

        function test_scan_row() {
            openNetworkPane()
            goTo("rowScan", 4)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("rowScan").activeFocus)
            compare(Network.networks.length, 4)
        }

        function test_back_leaves_the_pane() {
            openNetworkPane()
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("categoryList").activeFocus, 2000, "back to the category list")
            tryCompare(tc.shell, "currentPage", "settings")
        }

        function test_an_older_reply_arriving_late_is_dropped() {
            // Wired and connected. Ask again (the replies, a snapshot of that, are held back), then
            // the cable goes and Cafe Guest is joined: the late replies must not put the cable and
            // the idle network list back. The state and the list are two kinds of reply.
            Network.mockRefreshDelayed(150)
            compare(Network.mockPendingReplies(), 2)
            Network.mockSetCable(false)
            Network.connectWifi("wifi-cafe", "")
            tryCompare(Network.primary, "kind", "wifi")
            tryVerify(() => network("wifi-cafe").active)
            tryVerify(() => Network.mockPendingReplies() === 0)
            compare(Network.primary.kind, "wifi", "the late wired state was dropped")
            compare(Network.primary.name, "Cafe Guest")
            verify(network("wifi-cafe").active, "the late list without an active network was dropped")
        }

        function test_zz_screenshots() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            openNetworkPane()
            goTo("wifi_wifi-cafe", 2)
            keyClick(Qt.Key_Return)
            tryVerify(() => network("wifi-cafe").active, 2000)
            clearToasts()
            keyClick(Qt.Key_Up)
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/23-settings-network.png")
        }

        // RUY-512: the same pane in the light theme.
        function test_zz_screenshots_daylight() {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            DeviceSettings.theme = "daylight"
            openNetworkPane()
            clearToasts()
            wait(800)
            grabImage(tc.shell).save(shotsDir + "/23-settings-network-daylight.png")
        }
    }
}
