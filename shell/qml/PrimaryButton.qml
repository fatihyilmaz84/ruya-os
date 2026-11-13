import QtQuick
import RuyaShell

// Primary button (04 §5): the one main verb of a screen (Play, Open Store). A pill filled with
// `primaryFill`; focus is the white ring one `focusRingOffset` outside, so a dark gap separates
// it from the fill.
FocusScope {
    id: button

    property real u: 1
    property string text
    // Its action is unavailable for now (a game still closing, T-458): the fill and label dim to
    // disabledOpacity, the focus ring does not, and Accept still fires so the screen can say why.
    property bool dimmed: false
    // Accept is handled by the owner (AcceptHold: on release, with a long press): the button then lets the
    // key through instead of acting on the press (HeroBlock, RUY-16).
    property bool acceptOnRelease: false
    // Its Options menu is open (04 §5): the button keeps its look and loses only the focus ring.
    property bool anchored: false
    // The Hold ring replaces the label while it shows (the owner feeds both).
    property bool holdShown: false
    property real holdProgress: 0

    signal accepted()

    implicitWidth: label.implicitWidth + 2 * Theme.spaceXl * u
    implicitHeight: Theme.rowHeight * u

    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.focusable: true

    Rectangle {
        id: face
        anchors.fill: parent
        radius: height / 2
        color: Theme.primaryFill
        opacity: button.dimmed ? Theme.disabledOpacity : 1

        Text {
            id: label
            objectName: "buttonLabel"
            anchors.centerIn: parent
            text: button.text
            color: Theme.onPrimary
            font.pixelSize: Theme.typeHeadline * button.u
            font.weight: Theme.weightDemiBold
            visible: !holdRing.shown
        }
    }

    // Always visible while focused, never animated away mid-move (04 §4).
    Rectangle {
        objectName: "focusRing"
        anchors.fill: face
        anchors.margins: -Theme.focusRingOffset * button.u
        radius: height / 2
        color: "transparent"
        border.width: Theme.focusRingWidth * button.u
        border.color: Theme.focusRing
        opacity: button.activeFocus && !button.anchored ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.focusMs } }
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
