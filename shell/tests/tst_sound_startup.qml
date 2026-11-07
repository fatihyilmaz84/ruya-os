import QtQuick
import QtTest
import RuyaShell

// The start-up cue (T-227): once, at the first frame the shell draws, and not again for a later frame or
// a later window. Alone in its file so that nothing else has played it yet (each file gets a fresh engine).
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
        name: "SoundStartup"
        when: windowShown

        function test_the_start_up_cue_sounds_once() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            compare(Sfx.startupCount, 0, "nothing before the shell draws")
            const shell = createTemporaryObject(shellComponent, host)
            verify(shell)
            tryCompare(Sfx, "startupCount", 1, 5000, "the first frame")
            const played = Sfx.playedCount
            verify(played >= 1, "and it sounded")
            wait(300)                                       // more frames
            compare(Sfx.startupCount, 1, "not again for the next frame")
            const second = createTemporaryObject(shellComponent, host)
            verify(second)
            wait(300)
            compare(Sfx.startupCount, 1, "nor for the next window")
        }
    }
}
