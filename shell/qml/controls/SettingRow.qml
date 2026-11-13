import QtQuick
import RuyaShell

// Label plus a value text, in one of four kinds (RUY-512, 04 §5 "Setting row kinds"): what A does is
// drawn at the row's right end.
//  - "item" (default): a glass pill, the value at the right; A acts on the thing (Connect, Select).
//    `current: true` marks the one in use: DemiBold label and a filled check at the right.
//  - "page": the value, then a chevron; A opens a page, a picker or the keyboard.
//  - "action": the label centred, DemiBold; a `value` (or `detail`) is the status line under it.
//    `emphasis: "primary"` makes it the one main verb of a flow (`primaryFill`).
//  - "info": a fact. No pill, no sound, no signal; A is silent. `inert` is the same kind.
// A row with `enabled: false` is a message: flat like a fact, never focused, with an info icon.
SettingControl {
    id: row

    property string value
    property string kind: "item"
    // "" or "primary" (kind "action").
    property string emphasis: ""
    // The one in use, in a list where exactly one thing is (kind "item").
    property bool current: false
    // A row that does nothing on Accept (a fact, a result): it makes no sound and emits nothing.
    // The pane then also offers Back only in the hint bar while it has focus (04 section 5).
    // Kept for the panes that set it; it means kind "info".
    property bool inert: false

    // A message: disabled itself (`enabled` is false for a row under a disabled pane too, which is no message).
    readonly property bool isMessage: !enabled && (!parent || parent.enabled)
    readonly property bool isFact: kind === "info" || inert
    readonly property bool isAction: kind === "action" && !isFact
    readonly property bool isPage: kind === "page" && !isFact
    readonly property bool isCurrent: current && kind === "item" && !isFact
    // The room the mark at the right end takes: its box plus the gap to the value.
    readonly property real markWidth: Theme.iconM + Theme.spaceXxs

    signal activated()

    flat: isFact || isMessage
    primary: isAction && emphasis === "primary"
    centered: isAction
    labelWeight: isCurrent ? Theme.weightDemiBold : isAction ? Theme.weightDemiBold : Font.Normal
    labelColor: primary ? Theme.onPrimary : Theme.text
    defaultIconName: isMessage ? "info" : ""
    hintKind: isFact ? "info" : isPage ? "page" : "item"
    detailFallback: isAction ? value : ""

    accessibleValue: value
    Accessible.role: isFact || isMessage ? Accessible.StaticText : Accessible.Button
    Accessible.checkable: isCurrent
    Accessible.checked: isCurrent
    // What the right end takes beyond the usual spaceL margin, for the label and detail to end before.
    trailingWidth: isAction ? 0
                   : (value !== "" ? valueText.implicitWidth + Theme.spaceS * u : 0)
                     + (isPage || isCurrent ? (markWidth + Theme.spaceS - Theme.spaceL) * u : 0)

    Text {
        id: valueText
        objectName: "value"
        visible: !row.isAction
        // The value ends `spaceXxs` before the mark's box, or `spaceL` from the edge with no mark.
        anchors {
            right: row.isPage ? chevron.left : row.isCurrent ? currentMark.left : parent.right
            rightMargin: (row.isPage || row.isCurrent ? Theme.spaceXxs : Theme.spaceL) * row.u
            verticalCenter: parent.verticalCenter
        }
        textFormat: Text.PlainText      // a value may be a name from a drive (a wallpaper): never markup
        text: row.value
        color: Theme.text
        font.pixelSize: Theme.typeBody * row.u
    }

    // Opens a page, a picker or the keyboard.
    Icon {
        id: chevron
        objectName: "chevron"
        visible: row.isPage
        anchors { right: parent.right; rightMargin: Theme.spaceS * row.u; verticalCenter: parent.verticalCenter }
        u: row.u
        name: "chevron_right"
        color: Qt.alpha(Theme.text, row.dimmed ? Theme.disabledOpacity : 1)
    }

    // The one in use.
    Icon {
        id: currentMark
        objectName: "currentMark"
        visible: row.isCurrent
        anchors { right: parent.right; rightMargin: Theme.spaceS * row.u; verticalCenter: parent.verticalCenter }
        u: row.u
        name: "check_circle"
        filled: true
        color: Qt.alpha(Theme.text, row.dimmed ? Theme.disabledOpacity : 1)
    }

    function accept() {
        if (isFact)
            return
        Sfx.select()
        activated()
    }
    Keys.onReturnPressed: accept()
    Keys.onEnterPressed: accept()
}
