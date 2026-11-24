pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The one rule for a page about one controller (RUY-701): when that pad leaves Input1, the page asks to
// close (once), and a toast "Controller disconnected" names the pad (once, also when two pages about it
// are stacked: ControllerPads.announceGone). A page that is closing for any reason (Back too) never asks to
// close again: that would close the page below. `silent`: the pad left on purpose (forgotten here), no
// toast. An empty `padId` ("the first connected one") never closes the page. Used by ControllerPage,
// ControlsPage, RemapPage and StickPage: `PadGone { page: page; padId: page.padId }`.
QtObject {
    id: watch

    required property Page page
    property string padId: ""
    property bool silent: false
    // True from the first back request of the page, whatever its cause.
    property bool gone: false
    // The pad as last seen, kept for the toast after it left.
    property var seen: null

    function look() {
        const p = ControllerPads.controllers().find(c => c.id === padId) ?? null
        if (p)
            seen = p
        return p !== null
    }

    function check() {
        if (gone || padId === "" || Input.devicesState !== "ok" || look())
            return
        gone = true
        if (!silent && seen)
            ControllerPads.announceGone(seen)
        page.backRequested()
    }

    property Connections pageBack: Connections {
        target: watch.page
        function onBackRequested() { watch.gone = true }
    }
    property Connections devices: Connections {
        target: Input
        function onDevicesChanged() { watch.check() }
    }
    Component.onCompleted: look()
}
