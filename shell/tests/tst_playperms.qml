import QtQuick
import QtTest
import RuyaShell

// .play permissions in the shell (RUY-853, RUY-864; 05 §8, Play1 Inspect's `gate`): the mock derives the gate as
// ruya-play-trust does (the network + removable-media pair is high risk), the confirm sheet says what the gate
// says (a warning for admin-pin-warning), a Standard profile and a Guest ask an admin's PIN and an admin installs
// at once, a wrong PIN or Back from the pad installs nothing and puts focus back on Install, and an update lists
// what it adds. Signs in as Player One (p1, admin, PIN 1234), Ada (p2, standard) or Sam (p3, guest).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    property var infos: []      // { path, info } as Play said them

    Connections {
        target: Play
        function onInspected(path, info) { host.infos = host.infos.concat([{ path: path, info: info }]) }
    }

    TestCase {
        id: tc
        name: "PlayPerms"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }
        function page() { return find("page_installPackage") }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            while (Notifications.model.count > 0)
                Notifications.dismiss(Notifications.model.get(0).toastId)
            Notifications.pending = []
            Play.mockReset()
            Store.mockReset()
            Profiles.lock()
            Profiles.resetMockForTests("seeded")
            tryVerify(() => Profiles.profiles.length === 3)
            tryCompare(Profiles, "activeProfile", "")
            tryVerify(() => Play.sources.length === 11)
            host.infos = []
        }

        function cleanup() {
            Play.mockPauseJobs(false)
        }

        function start(who) {
            const ids = { admin: ["p1", "1234"], ada: ["p2", ""], sam: ["p3", ""] }
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            Profiles.switchTo(ids[who][0], ids[who][1])
            tryCompare(Profiles, "activeProfile", ids[who][0])
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function openPackage(fixture) {
            tc.shell.openPage("installPackage", { path: Play.mockPath(fixture) })
            tryCompare(tc.shell, "currentPage", "installPackage")
            tryVerify(() => page().info !== null, 3000, "Inspect answered")
            tryVerify(() => page().mainButton() !== null && page().mainButton().activeFocus, 3000, "the main button has the focus")
        }

        function openSheet(fixture) {
            openPackage(fixture)
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown, 2000)
            tryVerify(() => find("installConfirmInstall").activeFocus, 2000, "Install has the focus")
            tryVerify(() => find("installConfirm").opacity === 1, 2000, "the sheet has faded in (visible follows opacity)")
        }

        function enterPin(pin) {
            for (const ch of pin)
                keyClick(Qt.Key_0 + Number(ch))
            keyClick(Qt.Key_Enter)
        }

        function gateOf(fixture) {
            const path = Play.mockPath(fixture)
            host.infos = []
            Play.inspect(path)
            tryVerify(() => host.infos.length === 1, 2000, fixture + " inspected")
            return host.infos[0].info.gate
        }

        // ---- RUY-864: the mock's gate, per fixture ----

        function test_the_mock_derives_the_gate_as_the_service_does() {
            compare(gateOf("starhopper"), "admin-pin-warning", "developer tier + network and removable media: the pair is high")
            compare(gateOf("rawaccess.play.zip"), "admin-pin-warning", "developer tier, high-risk requests")
            compare(gateOf("pixelforest.play.zip"), "allowed", "official tier, low risk")
            compare(gateOf("homebrew"), "allowed", "unverified, nothing high")
            compare(gateOf("flaky"), "allowed", "developer tier, low risk")
            compare(gateOf("broken"), "allowed")
            // The network alone, or removable media alone, is not the pair.
            compare(gateOf("oldbad"), "allowed", "the network without removable media")
        }

        function test_the_pair_is_listed_once_as_a_high_risk_request() {
            gateOf("starhopper")
            const keys = host.infos[0].info.permissions.map(p => p.key)
            compare(keys.filter(k => k === "network+removable_media").length, 1)
            compare(keys[keys.length - 1], "network+removable_media", "last, as the service lists it")
        }

        // ---- The sheet's words per gate ----

        function test_the_warning_gate_says_the_warning_and_the_pin_line_to_a_standard_profile() {
            start("ada")
            openSheet("starhopper")
            verify(find("installConfirmWarning").visible, "admin-pin-warning shows its warning")
            compare(find("installConfirmPin").text, "A high-risk permission needs an admin's PIN.")
            verify(find("installConfirmPin").visible)
            verify(!find("installConfirmUpdateAdds").visible, "not an update")
            // High risk first: the pair (listed last by the service) is among the four rows shown, not behind "And n more".
            const row = findChild(find("installConfirmPermissions"), "permission_network+removable_media")
            verify(row !== null && row.visible, "the pair row is shown on the sheet")
            verify(find("installConfirmPermissions").shownCount === 4 && findChild(find("installConfirmPermissions"), "permissionMore").visible,
                   "the list is cut at four rows")
        }

        function test_the_admin_pin_gate_has_no_warning_line() {
            start("ada")
            openPackage("starhopper")
            const record = JSON.parse(JSON.stringify(page().info))
            record.gate = "admin-pin"
            find("installConfirm").open(record, find("installButton"))
            tryVerify(() => find("installConfirm").opacity === 1, 2000, "the sheet has faded in")
            verify(!find("installConfirmWarning").visible, "admin-pin has no warning")
            compare(find("installConfirmPin").text, "A high-risk permission needs an admin's PIN.")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("installConfirm").shown, 2000)
        }

        function test_an_allowed_gate_names_the_admin_pin_all_the_same_for_a_standard_profile() {
            start("ada")
            openSheet("pixelforest.play.zip")
            verify(!find("installConfirmWarning").visible)
            compare(find("installConfirmPin").text, "An admin's PIN is needed to install this app.",
                    "Install needs an admin's approval whatever the gate (Play1.xml)")
        }

        // ---- Who is asked ----

        function test_an_admin_installs_at_once_but_still_reads_the_warning() {
            start("admin")
            openSheet("starhopper")
            verify(find("installConfirmWarning").visible, "the warning is said to an admin too")
            verify(!find("installConfirmPin").visible, "no PIN line for an admin")
            keyClick(Qt.Key_Return)
            tryVerify(() => page().working, 3000, "the install starts at once")
            verify(!find("installPinPad").shown, "no PIN pad for an admin")
        }

        function test_a_standard_profile_enters_an_admins_pin_a_wrong_pin_installs_nothing() {
            start("ada")
            openSheet("starhopper")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installPinPad").shown, 2000, "the admin's PIN pad")
            tryVerify(() => find("installPinPad").activeFocus, 2000)
            enterPin("0000")
            tryVerify(() => findChild(find("installPinPad"), "pinMessage").text.indexOf("Wrong PIN") === 0, 2000)
            compare(Object.keys(Play.jobs).length, 0, "nothing was installed")
            verify(!page().working)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("installPinPad").shown, 2000)
            tryVerify(() => find("installButton").activeFocus, 2000, "Back from the pad: focus on Install")
            compare(Object.keys(Play.jobs).length, 0)
            verify(!page().working)
        }

        function test_the_right_pin_installs() {
            start("ada")
            openSheet("starhopper")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installPinPad").shown, 2000)
            enterPin("1234")
            tryVerify(() => page().working, 3000, "the right PIN starts the job")
        }

        function test_a_guest_never_installs_without_an_admins_pin() {
            start("sam")
            openSheet("starhopper")
            compare(find("installConfirmPin").text, "A high-risk permission needs an admin's PIN.")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installPinPad").shown, 2000, "a guest is asked for an admin's PIN too")
            compare(Object.keys(Play.jobs).length, 0)
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("installPinPad").shown, 2000)
            tryVerify(() => find("installButton").activeFocus, 2000)
            verify(!page().working, "nothing installed")
        }

        // ---- The update's diff ----

        function test_an_update_lists_what_it_adds_on_the_sheet_and_the_page() {
            Play.mockSetInstalled("com.example.rawaccess", 4)
            start("admin")
            openPackage("rawaccess.play.zip")
            verify(page().info.updateKnown, "an update of an installed build")
            verify(find("installUpdateAdds").visible)
            compare(find("installUpdateAdds").text, "The update adds: Accesses all devices, Can inspect other programs")
            keyClick(Qt.Key_Return)
            tryVerify(() => find("installConfirm").shown && find("installConfirm").opacity === 1, 2000)
            verify(find("installConfirmUpdateAdds").visible)
            compare(find("installConfirmUpdateAdds").text, "The update adds: Accesses all devices, Can inspect other programs")
            keyClick(Qt.Key_Escape)
            tryVerify(() => !find("installConfirm").shown, 2000)
            tryVerify(() => find("installButton").activeFocus, 2000, "Back from the sheet: focus on Install")
        }

        function test_a_package_that_is_not_an_update_lists_no_adds() {
            start("admin")
            openPackage("rawaccess.play.zip")
            verify(!page().info.updateKnown)
            verify(!find("installUpdateAdds").visible, "not installed: the fixture's diff is not shown")
        }

        function test_an_update_that_drops_only_adds_nothing() {
            Play.mockSetInstalled("com.example.pixelforest", 2)
            start("admin")
            openPackage("pixelforest.play.zip")
            verify(page().info.updateKnown)
            verify(!find("installUpdateAdds").visible, "it only removes the network")
        }
    }
}
