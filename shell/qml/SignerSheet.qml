pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Who signed this" (04 §5.4, 05 §9.2, RUY-802): a glass sheet in the modal layer over `scrim` with four
// read-only rows (Signed by, Key, Seen before, Trust), a note for the tier and one Close button. The
// words come from PlayTrust; the package's own text (the signer's name) is plain text. Modal: it takes
// every key; Accept or Back closes it and the focus goes back to the item that opened it.
//
//   open(info, opener)   info: the Inspect record; opener: the item that gets the focus back (the trust row)
//   closed()             it closed
FocusScope {
    id: sheet

    property real u: 1
    property var info: null
    property bool shown: false
    property Item opener: null
    readonly property var trust: PlayTrust.describe(info)
    readonly property string signerName: info ? (info.signerName ?? "") : ""
    readonly property string keyId: info ? (info.signerKeyId ?? "") : ""
    readonly property string keyState: info ? (info.keyState ?? "") : ""

    // What the hint bar says while this is open (Shell.modalHintsOf).
    readonly property var modalHints: [{ action: "back", text: qsTr("Close") }]

    signal closed()

    function open(record, from) {
        info = record
        opener = from
        shown = true
        closeButton.forceActiveFocus()
    }

    function close() {
        if (!shown)
            return
        shown = false
        if (opener)
            opener.forceActiveFocus()
        closed()
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.overlayMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("Who signed this")

    Keys.onPressed: event => {
        if (BackKey.isBackOrBackspace(event.key)) {
            Sfx.back()
            sheet.close()
        }
        event.accepted = true      // modal: nothing leaks to the page underneath
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    GlassSheet {
        id: card
        objectName: "signerSheet"
        anchors.centerIn: parent
        u: sheet.u
        shown: sheet.shown
        width: 1100 * sheet.u               // token-ok: 04 §5.4 Signer sheet
        height: column.implicitHeight + 2 * Theme.spaceXl * sheet.u
    }

    // One read-only row: the key column and the value (text, or a badge through `badge`).
    component FactRow: Rectangle {
        id: fact

        property string label
        property string value
        property bool error: false
        default property alias extra: slot.data

        width: parent ? parent.width : 0
        height: Theme.rowHeight * sheet.u
        radius: height / 2
        color: Theme.glass
        border.width: Theme.hairlineAt(sheet.u)
        border.color: Theme.glassBorder

        Text {
            x: Theme.spaceL * sheet.u
            width: 300 * sheet.u            // token-ok: 04 §5.4 Signer sheet
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: fact.label
            color: Theme.text
            font.pixelSize: Theme.typeBody * sheet.u
            font.weight: Theme.weightDemiBold
        }
        Text {
            objectName: "signerValue"
            x: (Theme.spaceL + 300) * sheet.u         // token-ok: 04 §5.4 Signer sheet
            width: parent.width - x - Theme.spaceL * sheet.u
            anchors.verticalCenter: parent.verticalCenter
            visible: fact.value !== ""
            textFormat: Text.PlainText          // the signer's name is the package's text
            elide: Text.ElideRight
            text: fact.value
            color: fact.error ? Theme.errorText : Theme.text
            font.pixelSize: Theme.typeBody * sheet.u
            font.features: { "tnum": 1 }
        }
        Item {
            id: slot
            x: (Theme.spaceL + 300) * sheet.u         // token-ok: 04 §5.4 Signer sheet
            height: parent.height
            width: parent.width - x - Theme.spaceL * sheet.u
        }
    }

    Column {
        id: column
        x: card.x + Theme.spaceXl * sheet.u
        y: card.y + Theme.spaceXl * sheet.u
        width: card.width - 2 * Theme.spaceXl * sheet.u
        spacing: Theme.spaceS * sheet.u
        opacity: 1

        Text {
            objectName: "signerTitle"
            width: parent.width
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: qsTr("Who signed this")
            color: Theme.text
            font.pixelSize: Theme.typeTitle * sheet.u
            font.weight: Theme.weightDemiBold
        }

        FactRow {
            objectName: "signerRowName"
            visible: sheet.signerName !== ""
            label: qsTr("Signed by")
            value: sheet.signerName
        }
        FactRow {
            objectName: "signerRowKey"
            visible: sheet.keyId !== ""         // an unsigned package has no key to show
            label: qsTr("Key")
            value: PlayTrust.groupedKey(sheet.keyId)
        }
        FactRow {
            objectName: "signerRowSeen"
            visible: sheet.keyId !== ""
            label: qsTr("Seen before")
            value: PlayTrust.keyStateText(sheet.keyState)
            error: sheet.keyState === "different"
        }
        FactRow {
            objectName: "signerRowTrust"
            label: qsTr("Trust")
            Badge {
                objectName: "signerBadge"
                anchors.verticalCenter: parent.verticalCenter
                u: sheet.u
                solid: true             // its own opaque fill: 4.5:1 on every theme over glass (04 7)
                kind: sheet.trust.kind ?? "error"
                text: sheet.trust.badge ?? ""
            }
        }

        Text {
            objectName: "signerNote"
            topPadding: Theme.spaceXs * sheet.u
            leftPadding: Theme.spaceL * sheet.u
            rightPadding: Theme.spaceL * sheet.u
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: PlayTrust.noteText(sheet.trust.state)
            color: Theme.text
            font.pixelSize: Theme.typeBody * sheet.u
        }

        SecondaryButton {
            id: closeButton
            objectName: "signerClose"
            u: sheet.u
            text: qsTr("Close")
            onAccepted: sheet.close()
        }
    }
}
