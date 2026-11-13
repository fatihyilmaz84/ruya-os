import QtQuick
import RuyaShell

// Label plus a bar. Left/Right step by `stepSize` within from..to (clamped, no wrapping) and
// are always consumed, so they never move focus out of the pane. edited(value) reports a
// change made by the user; at a bound nothing changes and nothing is emitted.
SettingControl {
    id: row

    property real from: 0
    property real to: 100
    property real stepSize: 1
    property real value: 0
    // What the bar and the number show; the slider position (`value`) unless a rule raises it above
    // what the keys set (the Dim row: a bright picture is veiled harder than the owner asked, T-286).
    property real shownValue: value
    property string unit: ""          // appended to the number, e.g. "%"
    // Optional short note between the label and the bar (the Dim row: why the keys may change nothing
    // visible, T-312). One line, elided; empty = nothing drawn.
    property string caption: ""

    signal edited(real value)

    accessibleValue: Math.round(shownValue) + unit + (caption.length > 0 ? ", " + caption : "")
    Accessible.role: Accessible.Slider
    hintKind: "slider"

    function step(delta) {
        const next = Math.min(to, Math.max(from, value + delta * stepSize))
        if (next === value)
            return
        Sfx.navigate()
        value = next
        edited(next)
    }

    Text {
        id: valueText
        objectName: "value"
        anchors { right: parent.right; rightMargin: Theme.spaceL * row.u; verticalCenter: parent.verticalCenter }
        width: 90 * row.u
        horizontalAlignment: Text.AlignRight
        text: Math.round(row.shownValue) + row.unit
        color: Theme.text
        font.pixelSize: Theme.typeBody * row.u
    }
    Text {
        objectName: "caption"
        visible: row.caption.length > 0
        anchors {
            left: parent.left; leftMargin: row.labelRight + Theme.spaceM * row.u
            right: track.left; rightMargin: Theme.spaceM * row.u
            verticalCenter: parent.verticalCenter
        }
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: row.caption
        color: Theme.text
        font.pixelSize: Theme.typeCaption * row.u
    }
    // An outlined track with a thumb (RUY-512, 04 §5): a thumb means adjustable. The thumb never leaves
    // the track: its centre runs from one thumb radius to one thumb radius short of the far end.
    readonly property real fraction: to > from ? Math.max(0, Math.min(1, (shownValue - from) / (to - from))) : 0
    readonly property real thumbSize: 32 * u            // token-ok: slider thumb
    Rectangle {
        id: track
        objectName: "sliderTrack"
        anchors { right: valueText.left; rightMargin: Theme.spaceM * row.u; verticalCenter: parent.verticalCenter }
        width: 320 * row.u          // token-ok: slider track
        height: Theme.spaceS * row.u
        radius: height / 2
        color: Qt.alpha(Theme.text, 0)
        border.width: 2 * row.u     // token-ok: slider outline
        border.color: Theme.text

        Rectangle {
            objectName: "valueFill"
            width: row.thumbSize / 2 + (parent.width - row.thumbSize) * row.fraction
            height: parent.height
            radius: parent.radius
            color: Theme.text
        }
        Rectangle {
            objectName: "sliderThumb"
            width: row.thumbSize
            height: width
            radius: width / 2
            x: (parent.width - width) * row.fraction
            y: (parent.height - height) / 2
            color: Theme.text
        }
    }

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
