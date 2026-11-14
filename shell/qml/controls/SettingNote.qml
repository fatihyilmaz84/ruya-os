import QtQuick
import RuyaShell

// The note under a setting row (RUY-590, 04 §5 "Note under a row"): one explanatory sentence in `text`,
// `typeCaption`, wrapped at the pane column's width, never focusable. `text` colour, not `textDim`: the
// note lies on the pane's glass, where `textDim` is too faint (04 §3.1). Visibility is the pane's.
Text {
    property real u: 1

    width: parent ? parent.width : 0
    color: Theme.text
    font.pixelSize: Theme.typeCaption * u
    wrapMode: Text.Wrap
}
