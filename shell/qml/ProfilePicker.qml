pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Who's playing?" — first screen after boot and after Lock.
FocusScope {
    id: picker

    property real u: 1
    readonly property Item pinPadItem: pinPad     // the shell reads where focus is (hint bar)

    function choose(profile) {
        Sfx.select()
        if (profile.hasPin)
            pinPad.open(profile)
        else
            Profiles.switchTo(profile.id, "")
    }

    function accept(event) {
        event.accepted = true
        if (controllerHint.exhausted) {
            Sfx.select()
            controllerHint.newSeries()
        } else {
            choose(Profiles.profiles[list.currentIndex])
        }
    }

    function reset() {
        pinPad.shown = false
        list.forceActiveFocus()
    }

    // No keyboard or controller at all: the profiles cannot be chosen, so say how to pair one and
    // keep the pairing window open (T-203). It is opened again when it times out.
    readonly property bool needsController: enabled && Profiles.available && Profiles.profiles.length > 0
                                            && Bluetooth.inputKnown && !Bluetooth.inputPresent

    Text {
        objectName: "pickerTitle"
        anchors { horizontalCenter: parent.horizontalCenter; bottom: list.top; bottomMargin: Theme.spaceXxl * picker.u }
        text: qsTr("Who's playing?")
        opacity: pinPad.shown ? 0 : 1      // the PIN pad replaces the chooser, not overlays it
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs } }
        color: Theme.text
        font.pixelSize: Theme.typeDisplay * picker.u
        font.weight: Theme.weightLight
    }

    ListView {
        id: list
        objectName: "profileList"
        opacity: pinPad.shown ? 0 : 1      // the PIN pad replaces the chooser, not overlays it
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs } }

        anchors.centerIn: parent
        anchors.verticalCenterOffset: 40 * picker.u
        width: Math.min(contentWidth, picker.width * 0.9)
        height: 340 * picker.u
        orientation: ListView.Horizontal
        spacing: Theme.spaceXl * picker.u
        interactive: false
        keyNavigationEnabled: true
        focus: true
        Accessible.role: Accessible.List
        Accessible.name: currentItem ? currentItem.Accessible.name : qsTr("Profiles")
        model: Profiles.profiles

        delegate: ProfileCard { u: picker.u }

        onCurrentIndexChanged: Sfx.navigate()
        // When the automatic pairing windows have run out, A starts a new series first.
        Keys.onReturnPressed: event => picker.accept(event)
        Keys.onEnterPressed: event => picker.accept(event)
    }

    Text {
        anchors { horizontalCenter: parent.horizontalCenter; top: list.bottom; topMargin: Theme.spaceL * picker.u }
        visible: !Profiles.available
        opacity: pinPad.shown ? 0 : 1      // the PIN pad replaces the chooser, not overlays it
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs } }
        text: qsTr("Waiting for the profiles service…")
        color: Theme.text
        font.pixelSize: Theme.typeBody * picker.u
    }

    ControllerPairHint {
        id: controllerHint
        objectName: "pickerControllerHint"
        anchors { horizontalCenter: parent.horizontalCenter; top: list.bottom; topMargin: Theme.spaceXxl * picker.u }
        width: Math.min(picker.width * 0.7, 1200 * picker.u)
        u: picker.u
        visible: picker.needsController && !pinPad.shown
        active: picker.needsController
        autoRetry: true
    }

    PinPad {
        id: pinPad
        objectName: "pinPad"
        anchors.fill: parent
        u: picker.u
        // After a successful sign-in the picker is disabled and the shell has already moved
        // focus to home; only reclaim it when the pad was cancelled.
        onClosed: if (picker.enabled) list.forceActiveFocus()
    }
}
