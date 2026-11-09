import QtQuick
import QtTest
import RuyaShell

// Whose app a window is (T-164, ADR-023): the compositor maps a Wayland client to a profile by
// its peer uid (AppGate.verdict) and hands the window to Shell.addApp(item, profile). An app is
// shown only while someone is signed in and only to its own profile ("" = the shell's own test
// client, shown to anyone signed in); the others wait hidden and never get the focus or a key.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    // Records the keys it receives and accepts all of them, like a real app would.
    Component {
        id: appComponent
        Item {
            property var keys: []
            Keys.onPressed: event => {
                keys = keys.concat([event.key])
                event.accepted = true
            }
        }
    }

    TestCase {
        id: tc
        name: "AppOwner"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function newApp() {
            const app = createTemporaryObject(appComponent, host)
            verify(app)
            return app
        }

        function signIn(id, pin) {
            Profiles.switchTo(id, pin)
            tryCompare(Profiles, "activeProfile", id)
        }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Power.mockReset()
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker has focus on start")
        }

        function cleanup() {
            Profiles.lock()
        }

        function test_gate_verdicts() {
            const shellUid = 990, p1 = 1001, p2 = 1002
            const v = (uid, profile, activeUid) => AppGate.verdict(uid, shellUid, profile, activeUid)
            compare(v(p1, "p1", p1), { accepted: true, profile: "p1", reason: "profile" })
            compare(v(shellUid, "p1", p1), { accepted: true, profile: "", reason: "shell" })
            compare(v(shellUid, "", -1), { accepted: true, profile: "", reason: "shell" },
                    "the shell's own client waits hidden while nobody is signed in")
            compare(v(p2, "p1", p1), { accepted: false, profile: "", reason: "other-user" })
            compare(v(p1, "", -1), { accepted: false, profile: "", reason: "nobody-signed-in" })
            compare(v(0, "p1", p1), { accepted: false, profile: "", reason: "other-user" }, "never root")
            compare(v(0, "p1", 0).accepted, false, "not even when the table says root")
            compare(v(-1, "p1", p1).accepted, false, "an unknown uid")
            compare(v(p1, "p1", -1).reason, "nobody-signed-in", "a profile whose user is unknown")
            compare(AppGate.unixUser("p1"), "ruya-p1")
            compare(AppGate.unixUser("guest_2-x"), "ruya-guest_2-x")
            for (const bad of ["", "../p1", "p 1", "p1/x", "p1;x", "a".repeat(33)])
                compare(AppGate.unixUser(bad), "", "no user for " + JSON.stringify(bad))
            compare(AppGate.socketDir, "/run/ruya-wayland")
        }

        function test_nobody_signed_in_hides_every_app() {
            const app = newApp()
            tc.shell.addApp(app, "")
            compare(tc.shell.appOpen, false, "no app is open while nobody is signed in")
            compare(find("appLayer").visible, false)
            compare(app.visible, false)
            verify(find("profileList").activeFocus, "the picker keeps the focus")
            keyClick(Qt.Key_A)
            compare(app.keys.length, 0, "no key reaches the hidden app")

            signIn("p2", "")
            tryVerify(() => app.activeFocus, 2000, "after the sign-in the waiting app is shown and focused")
            compare(tc.shell.appOpen, true)
            compare(find("appLayer").visible, true)
            compare(app.visible, true)
        }

        function test_lock_hides_the_app_and_its_profile_gets_it_back() {
            signIn("p2", "")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            const app = newApp()
            tc.shell.addApp(app, "p2")
            tryVerify(() => app.activeFocus, 2000, "the profile's app is shown and focused")
            compare(find("appLayer").visible, true)

            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            compare(tc.shell.appOpen, false)
            compare(find("appLayer").visible, false, "nothing of the app is drawn over the picker")
            compare(app.visible, false)
            tryVerify(() => find("profileList").activeFocus, 2000, "the picker takes the focus")
            keyClick(Qt.Key_B)
            compare(app.keys.length, 0)

            signIn("p2", "")
            tryVerify(() => app.activeFocus, 2000, "signing in again brings the app back with the focus")
            compare(app.visible, true)
            keyClick(Qt.Key_C)
            compare(app.keys, [Qt.Key_C])
        }

        function test_another_profiles_app_stays_hidden() {
            signIn("p2", "")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            const theirs = newApp()
            tc.shell.addApp(theirs, "p1")
            compare(tc.shell.appOpen, false, "Player One's app is not open for Ada")
            compare(theirs.visible, false)
            verify(find("homePlay").activeFocus, "Home keeps the focus")
            tc.shell.focusApp(theirs)
            verify(!theirs.activeFocus, "focusApp cannot reach another profile's app")
            keyClick(Qt.Key_Left)
            compare(theirs.keys.length, 0)

            const mine = newApp()
            tc.shell.addApp(mine, "p2")
            tryVerify(() => mine.activeFocus, 2000, "Ada's own app is shown and focused")
            compare(tc.shell.shownApps.length, 1)
            tc.shell.removeApp(mine)
            tryVerify(() => find("homePlay").activeFocus, 2000, "removing it goes back to Home, not to the hidden app")
            compare(tc.shell.appOpen, false)
            verify(!theirs.activeFocus)

            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            signIn("p1", "1234")
            tryVerify(() => theirs.activeFocus, 2000, "Player One gets their own app back")
            compare(theirs.visible, true)
            compare(tc.shell.shownApps.length, 1)
        }

        function test_switch_hides_the_previous_profiles_app() {
            signIn("p1", "1234")
            tryVerify(() => find("homePlay").activeFocus, 2000)
            const app = newApp()
            tc.shell.addApp(app, "p1")
            tryVerify(() => app.activeFocus, 2000)
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            signIn("p2", "")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Ada starts at Home, not in Player One's app")
            compare(tc.shell.appOpen, false)
            compare(app.visible, false)
            compare(find("appLayer").visible, false)
        }
    }
}
