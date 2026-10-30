import QtQuick
import QtTest
import RuyaShell

// An admin installs a high-risk app without a PIN (T-152). Signs in as Player One (p1, PIN 1234).
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
        name: "StoreAdmin"
        when: windowShown

        property Item shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Store.mockReset()
            Profiles.lock()
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            tryCompare(Profiles, "activeProfile", "")
        }

        function test_high_risk_admin_installs_directly() {
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            Profiles.switchTo("p1", "1234")
            tryCompare(Profiles, "activeProfile", "p1")
            tryVerify(() => find("tiles").activeFocus, 2000, "home shelf takes focus after sign-in")
            tryVerify(() => Store.catalogue.length > 0)
            tc.shell.openPage("appDetail", { appId: "org.example.Stream" })
            tryCompare(tc.shell, "currentPage", "appDetail")
            tryVerify(() => find("detailPrimary") && find("detailPrimary").activeFocus, 2000)
            verify(!find("detailAdminNote").visible)
            keyClick(Qt.Key_Return)
            verify(find("page_appDetail").working, "Install starts at once")
            verify(!find("detailPinPad").shown)
            tryVerify(() => Store.app("org.example.Stream").installed === true)
        }
    }
}
