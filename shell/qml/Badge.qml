import QtQuick
import RuyaShell

// Small status pill (04 §5): one or two words in caps. kind: neutral | success | info | warning.
Rectangle {
    id: badge

    property string text
    property string kind: "neutral"
    property real u: 1

    readonly property color tone: kind === "success" ? Theme.toastSuccess
                                : kind === "info" ? Theme.toastInfo
                                : kind === "warning" ? Theme.toastWarning
                                : Theme.textDim

    implicitWidth: label.implicitWidth + 2 * Theme.spaceS * u
    implicitHeight: label.implicitHeight + Theme.spaceXs * u
    radius: height / 2
    color: kind === "neutral" ? Theme.background
         : Theme.badgeFill(tone)
    border.color: Theme.glassBorder
    border.width: kind === "neutral" ? Math.max(1, u) : 0

    Accessible.role: Accessible.StaticText
    Accessible.name: text

    Text {
        id: label
        anchors.centerIn: parent
        text: badge.text
        color: badge.tone
        font.pixelSize: Theme.typeMicro * badge.u
        font.weight: Theme.weightDemiBold
        font.capitalization: Font.AllUppercase
    }
}
