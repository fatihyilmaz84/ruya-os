import QtQuick
import RuyaShell

// The inline progress bar (04 §5, extracted by RUY-465): a pill track in `glass` (or `trackColor`)
// with a `glassBorder` hairline, `spaceS` high, and a fill in `text` (or `fillColor`) from the
// left, `value` 0..1 of the width. The fill eases over `focusMs` unless `animated` is false (a
// fill that moves on its own every frame, such as the capture dialog's 5 s drain). Users: the app
// detail page (install progress), the Storage pane and System information (usage bars), the
// capture dialog of Remap buttons (the time left). `fillName` is the fill's objectName for tests.
Rectangle {
    id: bar

    property real u: 1
    property real value: 0
    property color trackColor: Theme.glass
    property color fillColor: Theme.text
    property bool animated: true
    property string fillName: ""

    implicitWidth: 260 * u
    implicitHeight: Theme.spaceS * u
    radius: height / 2
    color: trackColor
    border.width: Theme.hairlineAt(u)
    border.color: Theme.glassBorder

    Rectangle {
        objectName: bar.fillName
        width: bar.width * Math.max(0, Math.min(1, bar.value))
        height: parent.height
        radius: height / 2
        color: bar.fillColor
        Behavior on width {
            enabled: bar.animated
            NumberAnimation { duration: Theme.focusMs }
        }
    }
}
