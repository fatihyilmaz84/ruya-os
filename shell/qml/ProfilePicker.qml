pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Who's playing?" — first screen after boot and after Lock.
FocusScope {
    id: picker

    property real u: 1

    function choose(profile) {
        Sfx.select()
        if (profile.hasPin)
            pinPad.open(profile)
        else
            Profiles.switchTo(profile.id, "")
    }

    function reset() {
        pinPad.shown = false
        list.forceActiveFocus()
    }

    Text {
        anchors { horizontalCenter: parent.horizontalCenter; bottom: list.top; bottomMargin: 80 * picker.u }
        text: qsTr("Who's playing?")
        opacity: pinPad.shown ? 0 : 1      // the PIN pad replaces the chooser, not overlays it
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs } }
        color: Theme.text
        font.pixelSize: 64 * picker.u
        font.weight: Font.Light
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
        spacing: 48 * picker.u
        interactive: false
        keyNavigationEnabled: true
        focus: true
        model: Profiles.profiles

        delegate: ProfileCard { u: picker.u }

        onCurrentIndexChanged: Sfx.navigate()
        Keys.onReturnPressed: picker.choose(Profiles.profiles[currentIndex])
        Keys.onEnterPressed: picker.choose(Profiles.profiles[currentIndex])
    }

    Text {
        anchors { horizontalCenter: parent.horizontalCenter; top: list.bottom; topMargin: 40 * picker.u }
        visible: !Profiles.available
        opacity: pinPad.shown ? 0 : 1      // the PIN pad replaces the chooser, not overlays it
        Behavior on opacity { NumberAnimation { duration: Theme.pageMs } }
        text: qsTr("Waiting for the profiles service…")
        color: Theme.textDim
        font.pixelSize: 28 * picker.u
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
