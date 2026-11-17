import QtQuick
import RuyaShell

// The trust row of a .play package page (04 §5.4, RUY-802): one pill under the title that says who signed
// the package. `info` is the Inspect record; the words come from PlayTrust. It is focusable only when
// Accept opens the signer sheet (official, developer, unverified): a changed or revoked package has
// nothing to open, so the row is disabled and the focus never lands on it. Width is fitted to the content,
// at most 960 u.
//
//   activated()   Accept on a focusable row: the owner opens the signer sheet (SignerSheet.open)
FocusScope {
    id: row

    property real u: 1
    property var info: null
    readonly property var trust: PlayTrust.describe(info)
    readonly property bool opensSheet: trust.opensSheet === true

    signal activated()

    enabled: opensSheet
    activeFocusOnTab: opensSheet
    height: Theme.rowHeight * u
    implicitHeight: height
    // Fitted to the content: padding, icon, line (measured, so the row's own width is not an input) and the chevron.
    implicitWidth: Math.min(960 * u,      // token-ok: 04 §5.4 Trust row
                            2 * Theme.spaceL * u + Theme.iconM * u + Theme.spaceS * u + metrics.advanceWidth
                            + (opensSheet ? Theme.spaceS * u + Theme.iconM * u : 0))
    width: implicitWidth

    Accessible.role: opensSheet ? Accessible.Button : Accessible.StaticText
    Accessible.name: trust.line ?? ""
    Accessible.focusable: opensSheet

    TextMetrics {
        id: metrics
        text: row.trust.line ?? ""
        font.pixelSize: Theme.typeBody * row.u
    }

    Rectangle {
        objectName: "trustFace"
        anchors.fill: parent
        radius: height / 2
        color: row.activeFocus ? Theme.focusFill : Theme.glass
        border.width: row.activeFocus ? Theme.focusRingWidth * row.u : Theme.hairlineAt(row.u)
        border.color: row.activeFocus ? Theme.focusRing : Theme.glassBorder
        Behavior on color { ColorAnimation { duration: Theme.focusMs } }
    }
    GlassLayers {
        objectName: "trustLayers"
        anchors.fill: parent
        u: row.u
        radius: height / 2
        grain: false
        rim: !row.activeFocus
    }

    Row {
        id: content
        x: Theme.spaceL * row.u
        height: parent.height
        width: parent.width - 2 * Theme.spaceL * row.u
        spacing: Theme.spaceS * row.u

        Icon {
            id: lead
            objectName: "trustIcon"
            anchors.verticalCenter: parent.verticalCenter
            u: row.u
            name: row.trust.icon ?? "info"
            color: row.trust.iconError ? Theme.errorText : Theme.text
        }

        Text {
            objectName: "trustLine"
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, content.width - lead.width - content.spacing * (row.opensSheet ? 2 : 1)
                            - (row.opensSheet ? chevron.width : 0))
            textFormat: Text.PlainText          // the signer's name is the package's text
            elide: Text.ElideRight
            text: row.trust.line ?? ""
            color: row.trust.bad ? Theme.errorText : Theme.text
            font.pixelSize: Theme.typeBody * row.u
        }

        Icon {
            id: chevron
            objectName: "trustChevron"
            anchors.verticalCenter: parent.verticalCenter
            visible: row.opensSheet
            u: row.u
            name: "chevron_right"
            color: Theme.text
        }
    }

    Keys.onReturnPressed: event => row.accept(event)
    Keys.onEnterPressed: event => row.accept(event)

    function accept(event) {
        if (!opensSheet || event.isAutoRepeat) {      // a held key opens nothing again
            event.accepted = event.isAutoRepeat
            return
        }
        Sfx.select()
        activated()
        event.accepted = true
    }
}
