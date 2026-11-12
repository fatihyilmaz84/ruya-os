import QtQuick
import QtTest
import RuyaShell

// The top bar's pill shadows after the pills were hidden and shown again (T-430, owner report
// 2026-11-12: the section nav and the status cluster lost their shadow after the display slept).
// GlassShadow turns its layers off while it is not drawn; a MultiEffect whose mask layer went off
// and on under an unchanged `maskSource` keeps the old texture provider (T-387). The pixels need a
// GPU window, so the cases run in `shots` only; offscreen tst_glass checks that the effects are made anew.
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test-1.2.3"; focus: true }
    }
    // A stand-in for a game in front of the shell (as in tst_wallpaper).
    Component {
        id: appComponent
        Item { objectName: "standInApp"; Keys.onPressed: event => { event.accepted = true } }
    }

    TestCase {
        id: tc
        name: "TopBarShadow"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            if (!shotsDir)
                return
            DeviceSettings.reducedMotion = true          // the blobs and fades stand still: the same pixels twice
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            IdleClock.reset()
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
            IdleClock.reset()
            DeviceSettings.effectsQuality = "high"
            DeviceSettings.reducedMotion = false
        }

        // The pill's shadow below its bottom edge, where nothing else of the pill is drawn, as
        // [r, g, b] in 0..255: three columns, a few rows inside the pill's offset and blur.
        function shadowSamples(img, pill) {
            const scale = img.width / tc.shell.width
            const at = pill.mapToItem(tc.shell, 0, 0)
            const out = []
            for (const fx of [0.3, 0.5, 0.7]) {
                for (const dy of [2, 4, 7]) {
                    const x = Math.round((at.x + pill.width * fx) * scale)
                    const y = Math.round((at.y + pill.height + dy * tc.shell.u) * scale)
                    out.push([img.red(x, y), img.green(x, y), img.blue(x, y)])
                }
            }
            return out
        }

        // The largest per-channel difference between two sample sets.
        function sampleDistance(a, b) {
            let d = 0
            for (let i = 0; i < a.length; ++i)
                for (let c = 0; c < 3; ++c)
                    d = Math.max(d, Math.abs(a[i][c] - b[i][c]))
            return d
        }

        function pills() { return [find("sectionNav"), find("statusGlass")] }

        function topBarShown() {
            return pills().every(p => p.visible && p.opacity === 1)
        }

        function grabSamples() {
            waitForRendering(tc.shell)
            wait(300)
            const img = grabImage(tc.shell)
            return { img: img, samples: pills().map(p => shadowSamples(img, p)) }
        }

        // Each row hides the top bar's pills (their shadows' layers go off) and shows them again:
        // an app in front and gone; the screen saver and the dark screen and a wake; the
        // Performance tier (no shadows) and back to High.
        function test_zz_pill_shadow_comes_back_data() {
            return [{ tag: "app" }, { tag: "saver" }, { tag: "tier" }]
        }

        function test_zz_pill_shadow_comes_back(data) {
            if (!shotsDir)
                skip("set RUYA_SHOTS_DIR to save screenshots")
            // No effect may be synced against a layer that is off (the Dell's warning, T-430).
            failOnWarning(/is not assigned a valid texture provider/)
            tryVerify(() => topBarShown(), 2000, "the top bar is up")
            const shadows = pills().map(p => findChild(p, "glassShadow"))
            verify(shadows.every(s => s && s.visible), "both pills draw a shadow")
            const fresh = grabSamples()
            fresh.img.save(shotsDir + "/topbar-shadow-fresh-" + data.tag + ".png")

            if (data.tag === "app") {
                const app = createTemporaryObject(appComponent, host)
                tc.shell.addApp(app)
                tryVerify(() => app.activeFocus, 2000, "the app takes focus")
                tryVerify(() => shadows.every(s => !s.visible), 2000, "the pills (and their shadows) are hidden behind the app")
                wait(500)
                tc.shell.removeApp(app)
                tryVerify(() => find("homePlay").activeFocus, 2000, "Home has the focus back")
            } else if (data.tag === "saver") {
                IdleClock.enter("saver")
                tryVerify(() => find("screenSaver").visible, 2000, "the saver is up")
                wait(500)
                IdleClock.enter("off")
                wait(500)
                IdleClock.noteInput()                    // wakes
                compare(IdleClock.stage, "active")
                tryVerify(() => !find("screenSaver").visible, 2000, "the saver is gone")
            } else {
                DeviceSettings.effectsQuality = "performance"
                tryVerify(() => shadows.every(s => !s.visible), 2000, "no shadows on Performance")
                // The samples see the shadow: without it they are lighter.
                const none = grabSamples()
                for (let i = 0; i < 2; ++i) {
                    const d = sampleDistance(fresh.samples[i], none.samples[i])
                    verify(d >= 8, "pill " + i + ": the samples lie in the shadow (difference to no shadow " + d + ")")
                }
                DeviceSettings.effectsQuality = "high"
            }
            tryVerify(() => topBarShown(), 2000, "the top bar is back")
            tryVerify(() => shadows.every(s => s.visible && s.opacity === 1), 2000, "the shadows are back")
            const after = grabSamples()
            after.img.save(shotsDir + "/topbar-shadow-again-" + data.tag + ".png")
            const names = ["section nav", "status cluster"]
            for (let i = 0; i < 2; ++i) {
                const d = sampleDistance(fresh.samples[i], after.samples[i])
                verify(d <= 6, data.tag + ", " + names[i] + ": the shadow matches the first one (max channel difference "
                       + d + "): " + JSON.stringify(fresh.samples[i]) + " vs " + JSON.stringify(after.samples[i]))
            }
        }
    }
}
