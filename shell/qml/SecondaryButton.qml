import QtQuick
import RuyaShell

// Secondary button (04 §5): a glass pill next to a primary one (Details). Row focus: fill
// `focusFill`, border 1 -> 4 px `focusRing`, no scale.
FocusScope {
    id: button

    property real u: 1
    property string text
    // As PrimaryButton: Accept is the owner's (on release, with a long press); `anchored` keeps the
    // focused fill while the Options menu is open and drops only the ring; the Hold ring replaces the label.
    property bool acceptOnRelease: false
    property bool anchored: false
    property bool holdShown: false
    property real holdProgress: 0
    readonly property bool lit: activeFocus || anchored

    signal accepted()

    implicitWidth: label.implicitWidth + 2 * Theme.spaceXl * u
    implicitHeight: Theme.rowHeight * u

    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.focusable: true

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: button.lit ? Theme.focusFill : Theme.glass
        border.width: button.activeFocus && !button.anchored ? Theme.focusRingWidth * button.u : Theme.hairlineAt(button.u)
        border.color: button.activeFocus && !button.anchored ? Theme.focusRing : Theme.glassBorder

        Text {
            id: label
            objectName: "buttonLabel"
            anchors.centerIn: parent
            text: button.text
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * button.u
            font.weight: Theme.weightDemiBold
            visible: !holdRing.shown
        }
    }

    HoldRing {
        id: holdRing
        objectName: "buttonHoldRing"
        anchors.centerIn: parent
        u: button.u
        shown: button.holdShown
        progress: button.holdProgress
    }

    Keys.onReturnPressed: event => {
        if (button.acceptOnRelease) {
            event.accepted = false
            return
        }
        Sfx.select()
        button.accepted()
    }
    Keys.onEnterPressed: event => {
        if (button.acceptOnRelease) {
            event.accepted = false
            return
        }
        Sfx.select()
        button.accepted()
    }
}
