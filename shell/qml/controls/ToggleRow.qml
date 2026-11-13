import QtQuick
import RuyaShell

// Label plus a switch. Only Accept toggles it; Left/Right are left to the pane.
// `checked` is changed by the control itself; toggled() reports a change made by the user.
SettingControl {
    id: row

    property bool checked: false

    signal toggled(bool checked)

    Accessible.role: Accessible.CheckBox
    Accessible.checkable: true
    Accessible.checked: checked

    hintKind: "toggle"

    // The outline carries the state in both positions (RUY-512): `text` on the row is 3.6:1 or better on every
    // theme (04 §7), where the old glass track was 1.0 to 1.3:1. Off: empty; on: `primaryFill`, the knob `onPrimary`.
    Rectangle {
        id: track
        objectName: "switchTrack"
        anchors { right: parent.right; rightMargin: Theme.spaceL * row.u; verticalCenter: parent.verticalCenter }
        width: 96 * row.u           // token-ok: switch track, 04 §5 Setting row kinds
        height: 48 * row.u          // token-ok: switch track
        radius: height / 2
        opacity: row.dimmed ? Theme.disabledOpacity : 1
        color: row.checked ? Theme.primaryFill : Qt.alpha(Theme.primaryFill, 0)
        border.width: 3 * row.u     // token-ok: switch outline
        border.color: Theme.text
        Behavior on color { ColorAnimation { duration: Theme.focusMs } }

        Rectangle {
            objectName: "switchKnob"
            width: 32 * row.u       // token-ok: switch knob
            height: width
            radius: width / 2
            y: (parent.height - height) / 2
            x: row.checked ? parent.width - width - 8 * row.u : 8 * row.u     // token-ok: knob inset
            color: row.checked ? Theme.onPrimary : Theme.text
            Behavior on x { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: Theme.focusMs } }
        }
    }

    function toggle() {
        checked = !checked
        Sfx.toggled(checked)          // the cue says which way the switch went
        toggled(checked)
    }
    Keys.onReturnPressed: toggle()
    Keys.onEnterPressed: toggle()
}
