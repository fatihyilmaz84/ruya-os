pragma Singleton
import QtQuick

// When the liquid pill's specular clock may run (04 §3.8, T-205). The specular moves slowly and
// forever, so on its own it would keep the compositor redrawing at the display's rate while
// nothing else happens (a wallpaper is still, the user has put the pad down). The clock therefore
// runs only while
//   - no app is in front (the status cluster's pill stays visible under an app),
//   - the window is shown (not hidden or minimised), and
//   - there was input in the last `idleMs` (30 s, `Theme.liquidIdleMs`).
// Otherwise it is paused, holding its phase, and the pills stop asking for frames. The Shell
// feeds `appOpen` and `screenShown` and calls `noteInput()` for every key, mouse or touch event
// (`KeyRouter.activity`). Tests set `idleMs` short and call `reset()` when done.
QtObject {
    id: gate

    property bool appOpen: false
    property bool screenShown: true
    property int idleMs: Theme.liquidIdleMs
    property bool idle: false

    readonly property bool running: screenShown && !appOpen && !idle

    function noteInput() {
        idle = false
        idleTimer.restart()
    }

    function reset() {
        appOpen = false
        screenShown = true
        idleMs = Theme.liquidIdleMs
        idle = false
    }

    // The idle period counts only while the clock would otherwise run.
    readonly property Timer idleTimer: Timer {
        interval: gate.idleMs
        running: gate.screenShown && !gate.appOpen && !gate.idle
        repeat: false
        onTriggered: gate.idle = true
    }
}
