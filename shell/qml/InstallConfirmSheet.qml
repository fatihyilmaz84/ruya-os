pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// "Install %1?" (04 §5.4, RUY-98): a glass sheet in the modal layer over `scrim` that says what is about to
// be installed (art, trust, key, size and free space) and what the game can do (up to four permission rows),
// with Install (focused) and Cancel. It decides nothing: Install emits confirmed(), and the page asks for an
// admin's PIN when the profile is not an admin's. Modal: it takes every key; Back is Cancel and the focus
// goes back to the item that opened it.
//
//   open(info, opener)   info: the Inspect record; opener: the item that gets the focus back
//   confirmed()          Install was chosen (the sheet has closed)
//   closed()             it closed, whichever button
FocusScope {
    id: sheet

    property real u: 1
    property var info: null
    property bool shown: false
    property Item opener: null
    readonly property var trust: PlayTrust.describe(info)
    // High risk first: the four rows the sheet shows never hide the one that gates the install.
    readonly property var permissions: {
        const all = info ? (info.permissions ?? []) : []
        return all.filter(p => p.risk === "high").concat(all.filter(p => p.risk !== "high"))
    }
    // Inspect's gate: "allowed" | "admin-pin" | "admin-pin-warning" (Play1.xml); the warning line is the third's.
    readonly property string gate: info ? (info.gate ?? "allowed") : "allowed"
    readonly property bool warns: gate === "admin-pin-warning"
    // An update lists what it adds, only when the service knows the installed requests (`updateKnown`).
    readonly property var added: info && info.updateKnown === true ? (info.permissionsAdded ?? []) : []
    readonly property bool addsHighRisk: added.some(p => p.risk === "high")
    readonly property string addedText: added.map(p => PlayTrust.permissionWords(p.key, p.words)).join(", ")
    // Anyone but an admin enters an admin's PIN (05 §18 item 4); the line says why, in the sentence 04 §5.4 gives
    // when the gate is a PIN gate, else the Store's.
    readonly property bool needsPin: (Profiles.active.role ?? "") !== "admin"
    readonly property string key: PlayTrust.shortKey(info ? info.signerKeyId : "")
    readonly property string signer: info ? (info.signerName ?? "") : ""
    readonly property real freeBytes: Storage.internal.valid ? Storage.internal.freeBytes : -1

    // What the hint bar says while this is open (Shell.modalHintsOf).
    readonly property var modalHints: [{ action: "accept", text: qsTr("Select") }, { action: "back", text: qsTr("Cancel") }]

    signal confirmed()
    signal closed()

    function open(record, from) {
        info = record
        opener = from
        Storage.refreshInternal()
        shown = true
        installButton.forceActiveFocus()
    }

    function close() {
        if (!shown)
            return
        shown = false
        if (opener && opener.visible && opener.enabled)
            opener.forceActiveFocus()
        closed()
    }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    enabled: shown
    Behavior on opacity { NumberAnimation { duration: Theme.overlayMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap } }

    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("Install %1?").arg(info ? info.name : "")

    Keys.onPressed: event => {
        if (BackKey.isBackOrBackspace(event.key) && !event.isAutoRepeat) {
            Sfx.back()
            sheet.close()
        } else if (event.key === Qt.Key_Left && cancelButton.activeFocus) {
            Sfx.navigate()
            installButton.forceActiveFocus()
        } else if (event.key === Qt.Key_Right && installButton.activeFocus) {
            Sfx.navigate()
            cancelButton.forceActiveFocus()
        }
        event.accepted = true      // modal: nothing leaks to the page underneath
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
    }

    GlassSheet {
        id: card
        objectName: "installConfirmSheet"
        anchors.centerIn: parent
        u: sheet.u
        shown: sheet.shown
        width: 1100 * sheet.u               // token-ok: 04 §5.4 Confirm sheet
        height: column.implicitHeight + 2 * Theme.spaceXl * sheet.u
    }

    Column {
        id: column
        x: card.x + Theme.spaceXl * sheet.u
        y: card.y + Theme.spaceXl * sheet.u
        width: card.width - 2 * Theme.spaceXl * sheet.u
        spacing: Theme.spaceS * sheet.u

        Row {
            width: parent.width
            spacing: Theme.spaceM * sheet.u

            AppArt {
                objectName: "installConfirmArt"
                width: 256 * sheet.u            // token-ok: 04 §5.4 Confirm sheet
                height: 144 * sheet.u           // token-ok: 04 §5.4 Confirm sheet
                radius: Theme.radiusS * sheet.u
                u: sheet.u
                appId: sheet.info ? sheet.info.id : ""
                appName: sheet.info ? sheet.info.name : ""
                picture: sheet.info && sheet.info.art ? (sheet.info.art.card || sheet.info.art.hero || sheet.info.art.icon || "") : ""
            }

            Column {
                width: parent.width - 256 * sheet.u - Theme.spaceM * sheet.u      // token-ok: 04 §5.4 Confirm sheet
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spaceXs * sheet.u

                Text {
                    objectName: "installConfirmTitle"
                    width: parent.width
                    textFormat: Text.PlainText      // the game's name is the package's text
                    elide: Text.ElideRight
                    text: qsTr("Install %1?").arg(sheet.info ? sheet.info.name : "")
                    color: Theme.text
                    font.pixelSize: Theme.typeTitle * sheet.u
                    font.weight: Theme.weightDemiBold
                }

                Row {
                    width: parent.width
                    spacing: Theme.spaceS * sheet.u

                    Badge {
                        objectName: "installConfirmBadge"
                        anchors.verticalCenter: parent.verticalCenter
                        u: sheet.u
                        solid: true
                        kind: sheet.trust.kind ?? "error"
                        text: sheet.trust.badge ?? ""
                    }
                    Text {
                        objectName: "installConfirmSigner"
                        anchors.verticalCenter: parent.verticalCenter
                        visible: sheet.key !== ""
                        width: Math.min(implicitWidth, parent.width - x)
                        textFormat: Text.PlainText      // the signer's name is the package's text
                        elide: Text.ElideRight
                        text: sheet.signer !== "" ? qsTr("%1 · key %2").arg(sheet.signer).arg(sheet.key)
                                                  : qsTr("Signed by key %1").arg(sheet.key)
                        color: Theme.text
                        font.pixelSize: Theme.typeCaption * sheet.u
                    }
                }

                Text {
                    objectName: "installConfirmNeeds"
                    width: parent.width
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: qsTr("Needs %1 · %2 free").arg(Storage.formatBytes(sheet.info ? sheet.info.size : 0))
                        .arg(sheet.freeBytes >= 0 ? Storage.formatBytes(sheet.freeBytes) : "—")
                    color: Theme.text
                    font.pixelSize: Theme.typeCaption * sheet.u
                }
            }
        }

        Text {
            topPadding: Theme.spaceS * sheet.u
            width: parent.width
            textFormat: Text.PlainText
            text: qsTr("This game can")
            color: Theme.text
            font.pixelSize: Theme.typeBody * sheet.u
            font.weight: Theme.weightDemiBold
        }

        PermissionList {
            objectName: "installConfirmPermissions"
            x: Theme.spaceL * sheet.u
            width: parent.width - 2 * Theme.spaceL * sheet.u
            u: sheet.u
            always: true
            maxRows: 4
            entries: sheet.permissions
        }

        Text {
            objectName: "installConfirmUpdateAdds"
            visible: sheet.added.length > 0
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: qsTr("The update adds: %1").arg(sheet.addedText)
            color: sheet.addsHighRisk ? Theme.warningText : Theme.text
            font.pixelSize: Theme.typeBody * sheet.u
        }

        // Developer-signed with a high-risk request: said to everyone, an admin included (05 §8).
        Text {
            objectName: "installConfirmWarning"
            visible: sheet.warns
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: qsTr("The store has not reviewed this game, and it asks for a high-risk permission.")
            color: Theme.warningText
            font.pixelSize: Theme.typeBody * sheet.u
        }

        Text {
            objectName: "installConfirmPin"
            visible: sheet.needsPin
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: sheet.gate !== "allowed" ? qsTr("A high-risk permission needs an admin's PIN.")
                                           : qsTr("An admin's PIN is needed to install this app.")
            color: sheet.gate !== "allowed" ? Theme.warningText : Theme.text
            font.pixelSize: Theme.typeBody * sheet.u
        }

        Row {
            topPadding: Theme.spaceS * sheet.u
            spacing: Theme.spaceM * sheet.u

            PrimaryButton {
                id: installButton
                objectName: "installConfirmInstall"
                u: sheet.u
                text: qsTr("Install")
                onAccepted: {
                    sheet.close()
                    sheet.confirmed()
                }
            }
            SecondaryButton {
                id: cancelButton
                objectName: "installConfirmCancel"
                width: 300 * sheet.u            // token-ok: 04 §5.4 Confirm sheet
                u: sheet.u
                text: qsTr("Cancel")
                onAccepted: {
                    sheet.close()
                }
            }
        }
    }
}
