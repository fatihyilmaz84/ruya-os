pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Label plus a value text, in one of four kinds (RUY-512, 04 §5 "Setting row kinds"): what A does is
// drawn at the row's right end.
//  - "item": a glass pill, the value at the right; A acts on the thing (Connect, Select).
//    `current: true` marks the one in use: DemiBold label and a filled check at the right.
//  - "page": the value, then a chevron; A opens a page, a picker or the keyboard.
//  - "action": the label centred, DemiBold; a `value` (or `detail`) is the status line under it.
//    `emphasis: "primary"` makes it the one main verb of a flow (`primaryFill`).
//  - "info": a fact. No pill, no sound, no signal; A is silent.
// `kind` is required: a row that forgets it fails when it is created (RUY-575), it never silently looks like an item.
// A row that has an Options menu (RUY-1176, 02 §1.7 "What Accept does"; the menu itself is the pane's, through
// `optionsRequested()` and `Page.surfaceOptions`) is one of two kinds:
//  - `hasOptions`: A does the row's main action and Start opens the menu; so does holding A for `longPressMs`, with
//    the Hold ring at the row's right end (Accept then acts on release, a tap as before). Hint: A <verb>, Start Options.
//  - `hasOptions` and `acceptOpensOptions`: several actions and none main; A opens the menu on press (no hold, no
//    ring) and so does Start. Hint: A Options.
// While the menu is open the owner sets `anchored`: `selectedFill` and a DemiBold label, no ring.
// A row with `enabled: false` is a message: flat like a fact, never focused, with an info icon.
SettingControl {
    id: row

    property string value
    required property string kind
    // "" or "primary" (kind "action").
    property string emphasis: ""
    // The one in use, in a list where exactly one thing is (kind "item").
    property bool current: false
    // A message: disabled itself (`enabled` is false for a row under a disabled pane too, which is no message).
    readonly property bool isMessage: !enabled && (!parent || parent.enabled)
    readonly property bool isFact: kind === "info"
    readonly property bool isAction: kind === "action" && !isFact
    readonly property bool isPage: kind === "page" && !isFact
    readonly property bool isCurrent: current && kind === "item" && !isFact
    // The room the mark at the right end takes: its box plus the gap to the value.
    readonly property real markWidth: Theme.iconM + Theme.spaceXxs

    // The row has an Options menu; see above. `acceptOpensOptions` makes A open it.
    property bool hasOptions: false
    property bool acceptOpensOptions: false
    // The colour of the value: `warningText` for a state the player must fix (Not fully paired).
    property color valueColor: Theme.text
    readonly property bool holdsAccept: hasOptions && !acceptOpensOptions && !isFact

    signal activated()
    // Start, a long A, or A on a row that `acceptOpensOptions`: the pane asks the Shell to open the menu.
    signal optionsRequested()

    flat: isFact || isMessage
    primary: isAction && emphasis === "primary"
    centered: isAction
    labelWeight: isCurrent || anchored || isAction ? Theme.weightDemiBold : Font.Normal
    labelColor: primary ? Theme.onPrimary : Theme.text
    defaultIconName: isMessage ? "info" : ""
    hintKind: isFact ? "info" : hasOptions && acceptOpensOptions ? "options" : isPage ? "page" : "item"
    optionsHint: holdsAccept
    detailFallback: isAction ? value : ""

    accessibleValue: value
    Accessible.role: isFact || isMessage ? Accessible.StaticText : Accessible.Button
    Accessible.checkable: isCurrent
    Accessible.checked: isCurrent
    // What the right end takes beyond the usual spaceL margin, for the label and detail to end before.
    trailingWidth: isAction ? 0
                   : (value !== "" ? valueText.width + Theme.spaceS * u : 0)
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
        // A value never takes more than half the row (04 §5), so the label always stays readable; a longer one is elided.
        // The label comes first (RUY-609): the value gets only what the label leaves (its whole width, the gap and the
        // mark), but at least a quarter of the row, and then the label elides instead.
        readonly property real labelLeaves: row.width - row.labelLeft - row.labelWanted -Theme.spaceS * row.u
                                            - (row.isPage || row.isCurrent ? Theme.spaceS + row.markWidth : Theme.spaceL) * row.u
        width: Math.min(implicitWidth, row.width * 0.5, Math.max(row.width * 0.25, labelLeaves))     // 0.5, 0.25: layout ratios, not design tokens
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText      // a value may be a name from a drive (a wallpaper): never markup
        text: row.value
        opacity: row.endOpacity
        color: row.valueColor
        font.pixelSize: Theme.typeBody * row.u
    }

    // Opens a page, a picker or the keyboard.
    Icon {
        id: chevron
        objectName: "chevron"
        visible: row.isPage
        opacity: row.endOpacity
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
        opacity: row.endOpacity
        anchors { right: parent.right; rightMargin: Theme.spaceS * row.u; verticalCenter: parent.verticalCenter }
        u: row.u
        name: "check_circle"
        filled: true
        color: Qt.alpha(Theme.text, row.dimmed ? Theme.disabledOpacity : 1)
    }

    // While the Hold ring shows, what the row shows at its right end (the value, the current mark, a chevron) gives way to
    // it: it fades to 0 over `focusMs` as the ring fades in, and comes back at once when the ring goes (a release, or the
    // menu opening), as the ring itself is cut. The layout never changes, no width is reserved for the ring (04 section 5).
    property real endOpacity: 1
    Connections {
        target: hold
        function onRingShownChanged() {
            if (hold.ringShown && Theme.focusMs > 0) {
                endFade.restart()
            } else {
                endFade.stop()
                row.endOpacity = hold.ringShown ? 0 : 1
            }
        }
    }
    NumberAnimation {
        id: endFade
        target: row
        property: "endOpacity"
        from: 1
        to: 0
        duration: Theme.focusMs
    }

    // The Hold ring of a row that has a menu and a main action, `spaceXs` inside the right end.
    // Built only for a row that has one: most rows of a pane never hold.
    Loader {
        anchors { right: parent.right; rightMargin: Theme.spaceXs * row.u; verticalCenter: parent.verticalCenter }
        active: row.holdsAccept
        sourceComponent: HoldRing {
            objectName: "rowHoldRing"
            u: row.u
            shown: hold.ringShown
            progress: hold.ringProgress
        }
    }

    function accept() {
        if (isFact)
            return
        Sfx.select()
        activated()
    }

    // Accept on release and a long press (AcceptHold, as on the cards): a tap does the main action, a hold opens the menu.
    AcceptHold {
        id: hold
        objectName: "rowHold"
        active: row.holdsAccept
        onTapped: row.accept()
        onLongPressed: row.optionsRequested()
    }
    onActiveFocusChanged: if (!activeFocus) hold.cancel()

    function acceptPressed(event) {
        if (isFact)
            return
        if (acceptOpensOptions && hasOptions) {
            if (!event.isAutoRepeat)
                optionsRequested()              // the Shell plays the select sound
        } else if (!hold.press(event)) {
            accept()
        }
    }
    Keys.onReturnPressed: event => acceptPressed(event)
    Keys.onEnterPressed: event => acceptPressed(event)
    Keys.onReleased: event => {
        if (!(holdsAccept && hold.release(event)))
            event.accepted = false
    }
    // Start (the options button) opens the menu of a row that has one; on any other row it bubbles on.
    Keys.onMenuPressed: event => {
        if (!hasOptions || isFact) {
            event.accepted = false
            return
        }
        if (!event.isAutoRepeat)
            optionsRequested()
    }
}
