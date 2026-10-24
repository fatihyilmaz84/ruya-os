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

        property Item shell: null

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
            tryVerify(() => find("tiles").activeFocus, 2000, "home shelf takes focus after sign-in")
            clearToasts()
        }

        function cleanup() {
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

        function openNetworkPane() {
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)                      // Settings tile
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
            verify(!find("wifiPasswordEntry").shown, "no password asked for an open network")
            tryVerify(() => find("wifi_wifi-cafe").activeFocus)
        }

        function test_saved_network_needs_no_password() {
            openNetworkPane()
            keyClick(Qt.Key_Return)                      // Lounge 5G is saved
            tryVerify(() => network("wifi-lounge").active, 2000)
            verify(!find("wifiPasswordEntry").shown)
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
    }
}
