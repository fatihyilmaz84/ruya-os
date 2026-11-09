import QtQuick

// One line of a name from outside (a device's) that may end in a tail that must stay whole: the end of its
// address, "(00:05)" (DeviceIcons.shownParts, T-334/T-359). When the line is too long the NAME is cut at its end
// and the tail follows: "Wireless Controll... (00:05)" (04 section 3, "Names from outside"). `maxWidth` is the
// width the whole line may take (the caller sets the item's `width` too: `Math.min(implicitWidth, maxWidth)`, or
// anchors); the full text, name and tail, is the accessible name. Plain text, never markup.
Text {
    id: line

    property string name: ""
    property string tail: ""
    property real maxWidth: -1                       // < 0: no cap
    readonly property string fullText: line.name + line.tail

    TextMetrics {
        id: tailMetrics
        font: line.font
        text: line.tail
    }

    TextMetrics {
        id: nameMetrics
        font: line.font
        elide: Text.ElideRight
        elideWidth: line.maxWidth < 0 ? 100000 : Math.max(0, line.maxWidth - tailMetrics.advanceWidth)
        text: line.name
    }

    textFormat: Text.PlainText
    maximumLineCount: 1
    text: nameMetrics.elidedText + line.tail
    Accessible.role: Accessible.StaticText
    Accessible.name: line.fullText
}
