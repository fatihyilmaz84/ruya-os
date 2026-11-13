import QtQuick
import RuyaShell

// Label plus the value between two round arrows (RUY-512, 04 §5). Left/Right cycle through `options`
// (wrapping) and are always consumed, so they can never move focus out of the pane; Accept steps to the
// next option. `options` is a list of { value, label }; `value` is the selected option's value.
// edited(value) reports a change made by the user. The arrows are drawn with two or more options
// and not while `dimmed`: otherwise the value stands alone.
SettingControl {
    id: row

    property var options: []
    property var value

    readonly property int currentIndex: {
        for (let i = 0; i < options.length; ++i) {
            if (options[i].value === value)
                return i
        }
        return -1
    }
    readonly property string currentLabel: currentIndex >= 0 ? options[currentIndex].label : ""
    readonly property alias valueText: valueLabel   // the value text, for subtypes that decorate it
    readonly property alias leftArrow: arrowLeft    // the left circle (ThemeRow's chips sit before it)
    readonly property bool arrowsShown: options.length >= 2 && !dimmed
    // Each circle is 48 (literal), `spaceXs` from the value; the right one ends `spaceS` from the edge.
    readonly property real circle: 48 * u

    signal edited(var value)

    accessibleValue: currentLabel
    hintKind: "choice"
    trailingWidth: valueLabel.implicitWidth + (arrowsShown ? 2 * (circle + Theme.spaceXs * u) : 0)
    Accessible.role: Accessible.ComboBox

    function step(delta) {
        if (options.length === 0)
            return
        const from = currentIndex >= 0 ? currentIndex : 0
        const next = (from + delta + options.length) % options.length
        Sfx.navigate()
        value = options[next].value
        edited(value)
    }

    Text {
        id: valueLabel
        objectName: "value"
        anchors {
            right: parent.right
            rightMargin: row.arrowsShown ? Theme.spaceS * row.u + row.circle + Theme.spaceXs * row.u : Theme.spaceL * row.u
            verticalCenter: parent.verticalCenter
        }
        textFormat: Text.PlainText
        text: row.currentLabel
        color: Theme.text
        font.pixelSize: Theme.typeBody * row.u
    }

    Rectangle {
        id: arrowLeft
        objectName: "arrowLeft"
        visible: row.arrowsShown
        anchors { right: valueLabel.left; rightMargin: Theme.spaceXs * row.u; verticalCenter: parent.verticalCenter }
        width: row.circle
        height: width
        radius: width / 2
        color: Theme.selectedFill
        Icon {
            anchors.centerIn: parent
            u: row.u
            name: "chevron_left"
            color: Theme.text
        }
    }
    Rectangle {
        id: arrowRight
        objectName: "arrowRight"
        visible: row.arrowsShown
        anchors { left: valueLabel.right; leftMargin: Theme.spaceXs * row.u; verticalCenter: parent.verticalCenter }
        width: row.circle
        height: width
        radius: width / 2
        color: Theme.selectedFill
        Icon {
            anchors.centerIn: parent
            u: row.u
            name: "chevron_right"
            color: Theme.text
        }
    }

    // Accept steps to the next option. A row whose screen uses Accept for something else (the Setup wizard's
    // language step: "Press A to continue") sets this false, and Accept bubbles.
    property bool acceptSteps: true
    Keys.onReturnPressed: event => { if (row.acceptSteps) row.step(1); else event.accepted = false }
    Keys.onEnterPressed: event => { if (row.acceptSteps) row.step(1); else event.accepted = false }
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Left) {
            row.step(-1)
            event.accepted = true
        } else if (event.key === Qt.Key_Right) {
            row.step(1)
            event.accepted = true
        }
    }
}
