import QtQuick
import RuyaShell

// A controller button as a letter on a filled circle (04 §3.7): A, B, X, Y, LB, RB, Start.
// Two-letter and longer names make a pill.
Rectangle {
    id: glyph

    property string button: "A"
    property real u: 1

    implicitHeight: Theme.glyphSize * u
    implicitWidth: Math.max(implicitHeight, letter.implicitWidth + 2 * Theme.spaceXs * u)
    radius: height / 2
    color: Theme.primaryFill

    Accessible.role: Accessible.StaticText
    Accessible.name: button

    Text {
        id: letter
        anchors.centerIn: parent
        text: glyph.button
        color: Theme.onPrimary
        font.pixelSize: Theme.typeMicro * glyph.u
        font.weight: Theme.weightBold
    }
}
