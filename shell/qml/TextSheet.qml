pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import RuyaShell

// A long text to read (04 §5 "Text sheet", 02 §1.8, RUY-534): a `GlassSheet` 1296 wide, centred, from y 54,
// at most 908 high (never into the hint bar's band), padding `spaceXl`. The title is the item's name
// (`typeTitle` DemiBold, one line, elided), `spaceM`, then the text in `typeBody` with a line of 40: the
// description, and (when there are notes) a blank line, their heading and the notes. A text taller than the
// sheet scrolls: Up/Down by 3 lines (120) over `glideMs` (`easeGlide`; none under reduced motion), stopping at
// the ends, and the last 15 % of the text fades out while there is more below.
//
//   open()    opens it (the owner binds title, description, notesTitle and notes); the focus returns to the item that had it
//   closed()                                       it closed (Back)
//
// Modal: it accepts every key. Host it in the modal layer (`Page.overlay`), built on its first opening.
FocusScope {
    id: sheet

    property real u: 1
    property bool shown: false
    property Item returnTo: null
    property string title: ""
    property string description: ""
    property string notesTitle: ""
    property string notes: ""

    readonly property real lineHeight: 40 * u
    readonly property real step: 3 * lineHeight
    // The band the sheet lives in: from y 54 down to the hint bar's band.
    readonly property real bandBottom: height - height * Theme.safeArea - (Theme.glyphSize + Theme.spaceM) * u
    readonly property real maxSheetHeight: Math.max(0, Math.min(908 * u, bandBottom - 54 * u))
    readonly property real pad: Theme.spaceXl * u
    readonly property real viewportHeight: Math.max(0, panel.height - 2 * pad - titleText.height - Theme.spaceM * u)
    readonly property real maxOffset: Math.max(0, bodyColumn.height - viewportHeight)
    // The scroll, in pixels: set by the keys, followed by the text over `glideMs`.
    property real offset: 0
    readonly property bool scrolls: maxOffset > 0.5
    readonly property bool moreBelow: scrolls && offset < maxOffset - 0.5

    // What the hint bar says while this is open (Shell.modalHintsOf).
    readonly property var modalHints: scrolls
        ? [{ actions: ["up", "down"], text: qsTr("Scroll") }, { action: "back", text: qsTr("Close") }]
        : [{ action: "back", text: qsTr("Close") }]

    signal closed()

    function open() {
        returnTo = Window.activeFocusItem
        offset = 0
        shown = true
        sheet.forceActiveFocus()
        Sfx.open()
    }

    function close() {
        if (!shown)
            return
        shown = false
        const target = returnTo
        returnTo = null
        if (target && target.visible && target.enabled)
            target.forceActiveFocus()
        closed()
    }

    function scrollBy(direction) {
        offset = Math.max(0, Math.min(maxOffset, offset + direction * step))
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.pageMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    GlassSheet {
        id: panel
        objectName: "textSheetPanel"
        x: (sheet.width - width) / 2
        y: 54 * sheet.u
        width: 1296 * sheet.u
        height: Math.min(sheet.maxSheetHeight, 2 * sheet.pad + titleText.height + Theme.spaceM * sheet.u + bodyColumn.height)
        u: sheet.u
        shown: sheet.shown
    }

    Text {
        id: titleText
        objectName: "textSheetTitle"
        x: panel.x + sheet.pad
        y: panel.y + sheet.pad
        width: panel.width - 2 * sheet.pad
        textFormat: Text.PlainText      // an app's own name
        elide: Text.ElideRight
        maximumLineCount: 1
        text: sheet.title
        color: Theme.text
        font.pixelSize: Theme.typeTitle * sheet.u
        font.weight: Theme.weightDemiBold
    }

    Item {
        id: viewport
        objectName: "textSheetViewport"
        x: panel.x + sheet.pad
        y: titleText.y + titleText.height + Theme.spaceM * sheet.u
        width: panel.width - 2 * sheet.pad
        height: sheet.viewportHeight
        clip: true
        // The last 15 % fades out while there is more below (a GPU effect: the software renderer draws the text whole).
        layer.enabled: panel.gpu && sheet.moreBelow
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: fadeMask
        }

        Column {
            id: bodyColumn
            objectName: "textSheetBody"
            width: parent.width
            y: -sheet.offset
            Behavior on y {
                NumberAnimation { duration: Theme.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide }
            }

            Text {
                objectName: "textSheetDescription"
                width: parent.width
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                lineHeight: sheet.lineHeight
                lineHeightMode: Text.FixedHeight
                text: sheet.description
                color: Theme.text
                font.pixelSize: Theme.typeBody * sheet.u
            }
            Item {
                width: 1
                height: sheet.lineHeight
                visible: sheet.notes !== ""
            }
            Text {
                objectName: "textSheetNotesTitle"
                width: parent.width
                visible: sheet.notes !== ""
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                lineHeight: sheet.lineHeight
                lineHeightMode: Text.FixedHeight
                text: sheet.notesTitle
                color: Theme.text
                font.pixelSize: Theme.typeBody * sheet.u
                font.weight: Theme.weightDemiBold
            }
            Text {
                objectName: "textSheetNotes"
                width: parent.width
                visible: sheet.notes !== ""
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                lineHeight: sheet.lineHeight
                lineHeightMode: Text.FixedHeight
                text: sheet.notes
                color: Theme.text
                font.pixelSize: Theme.typeBody * sheet.u
            }
        }
    }

    // Opaque down to 85 % of the viewport, then transparent at its foot.
    Rectangle {
        id: fadeMask
        visible: false
        layer.enabled: true
        layer.smooth: true
        width: viewport.width
        height: viewport.height
        gradient: Gradient {
            GradientStop { position: 0.0; color: "white" }   // token-ok: a mask, only its alpha counts
            GradientStop { position: 0.85; color: "white" }   // token-ok: a mask, only its alpha counts
            GradientStop { position: 1.0; color: "transparent" }
        }
    }

    Keys.onPressed: event => {
        if (BackKey.isBackOrBackspace(event.key)) {
            Sfx.back()
            sheet.close()
        } else if (event.key === Qt.Key_Down) {
            sheet.scrollBy(1)
        } else if (event.key === Qt.Key_Up) {
            sheet.scrollBy(-1)
        }
        event.accepted = true      // modal: nothing leaks to the page underneath
    }
}
