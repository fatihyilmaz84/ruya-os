import QtQuick
import RuyaShell

// Accept on release, and a long press (02 §1.7, 04 §3.4), for an item that has an Options menu (Home's
// Recent row and hero buttons, the Games grid). The owner forwards the key events of the item to
// `press()` / `release()` from its own Keys handlers and listens to two signals:
//
//   tapped()       Accept was released before `Theme.longPressMs`: do what a press did before.
//   longPressed()  Accept was held for `Theme.longPressMs`: open the Options menu. Its release does nothing.
//
// The press must have been seen on this item: `press()` runs only for a key event the item received
// while it had the focus, so a release whose press began elsewhere (the press that opened the page, or
// that moved the focus here) finds `pressing` false and does nothing. The owner calls `cancel()` when the
// item it watches changes (the current card, the focused button) or loses the focus: a hold belongs to
// one item. Auto-repeat is the same physical press and is swallowed. `ringShown` and `ringProgress` feed
// the HoldRing: it shows after `Theme.holdRingDelayMs`, the arc linear from there to `longPressMs`. The
// times are input times, not multiplied by `Theme.motionScale` (04 §3.4).
QtObject {
    id: hold

    // False: Accept is not handled here at all (the owner's item has nothing to act on).
    property bool active: true
    property bool pressing: false
    // Milliseconds since the press, driven by a clock that runs only while `pressing`.
    property real heldMs: 0

    readonly property bool ringShown: pressing && heldMs >= Theme.holdRingDelayMs
    readonly property real ringProgress: ringShown
        ? Math.max(0, Math.min(1, (heldMs - Theme.holdRingDelayMs) / (Theme.longPressMs - Theme.holdRingDelayMs)))
        : 0

    signal tapped()
    signal longPressed()

    function isAcceptKey(key) {
        return key === Qt.Key_Return || key === Qt.Key_Enter
    }

    // A key press of the owner's item. True when it was an Accept key (the owner marks the event accepted).
    function press(event) {
        if (!active || !isAcceptKey(event.key))
            return false
        if (event.isAutoRepeat || pressing)
            return true
        pressing = true
        heldMs = 0
        clock.restart()
        longTimer.restart()
        return true
    }

    // A key release of the owner's item. True when it was an Accept key.
    function release(event) {
        if (!isAcceptKey(event.key))
            return false
        if (event.isAutoRepeat)
            return true
        if (pressing) {
            stop()
            tapped()
        }
        return true
    }

    function cancel() {
        if (pressing)
            stop()
    }

    function stop() {
        pressing = false
        longTimer.stop()
        clock.stop()
        heldMs = 0
    }

    property Timer longTimer: Timer {
        interval: Theme.longPressMs
        onTriggered: {
            hold.stop()
            hold.longPressed()
        }
    }

    property NumberAnimation clock: NumberAnimation {
        target: hold
        property: "heldMs"
        from: 0
        to: Theme.longPressMs
        duration: Theme.longPressMs
    }
}
