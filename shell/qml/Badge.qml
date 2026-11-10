import QtQuick
import RuyaShell

// Small status pill (04 §5): one or two words in caps. kind: neutral | success | info | warning.
Rectangle {
    id: badge

    property string text
    property string kind: "neutral"
    property real u: 1
    // A pill over art (the card's state pill): its own opaque fill (toastBackground) so the word reads at
    // 4.5:1 over any art tint; the status colour is the word and a 4 px edge only (04 §5 Art card, T-147).
    property bool solid: false
    readonly property real edge: solid ? 4 * u + Theme.spaceXs * u : 0

    readonly property color tone: kind === "success" ? Theme.toastSuccess
                                : kind === "info" ? Theme.toastInfo
                                : kind === "warning" ? Theme.toastWarning
                                : Theme.textDim

    implicitWidth: label.implicitWidth + 2 * Theme.spaceS * u + edge
    implicitHeight: label.implicitHeight + Theme.spaceXs * u
    radius: height / 2
    color: solid ? Theme.toastBackground
         : kind === "neutral" ? Theme.background
         : Theme.badgeFill(tone)
    border.color: Theme.glassBorder
    border.width: kind === "neutral" ? Theme.hairlineAt(u) : 0

    Accessible.role: Accessible.StaticText
    Accessible.name: text

    Rectangle {
        objectName: "badgeEdge"
        visible: badge.solid
        x: Theme.spaceXs * badge.u
        width: 4 * badge.u
        height: parent.height / 2
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: badge.tone
    }

    Text {
        id: label
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: badge.edge / 2
        textFormat: Text.PlainText
        text: badge.text
        color: badge.tone
        font.pixelSize: Theme.typeMicro * badge.u
        font.weight: Theme.weightDemiBold
        font.capitalization: Font.AllUppercase
    }
}
