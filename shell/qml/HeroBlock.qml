import QtQuick
import RuyaShell

// Hero block (04 §5): eyebrow, title, meta and the buttons of the focused item, over the hero
// art. Play is the primary button and takes focus first; Left/Right move to Details. Up and
// Down are the owner's: it decides what lies above and below.
FocusScope {
    id: hero

    property real u: 1
    property string eyebrow
    property string title
    property string meta
    property string primaryText
    property string secondaryText      // empty: no secondary button
    readonly property alias playButton: play

    signal primaryAccepted()
    signal secondaryAccepted()
    signal upRequested()
    signal downRequested()

    implicitWidth: 960 * u
    implicitHeight: column.implicitHeight

    Column {
        id: column
        width: parent.width
        spacing: Theme.spaceS * hero.u

        Text {
            objectName: "heroEyebrow"
            width: parent.width
            visible: text.length > 0
            text: hero.eyebrow.toUpperCase()
            color: Theme.text
            font.pixelSize: Theme.typeCaption * hero.u
            font.weight: Theme.weightDemiBold
            font.letterSpacing: 2 * hero.u
            elide: Text.ElideRight
        }
        Text {
            objectName: "heroTitle"
            width: parent.width
            text: hero.title
            color: Theme.text
            font.pixelSize: Theme.typeHero * hero.u
            font.weight: Theme.weightBold
            font.letterSpacing: -0.02 * Theme.typeHero * hero.u
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }
        Text {
            objectName: "heroMeta"
            width: parent.width
            visible: text.length > 0
            text: hero.meta
            color: Theme.text
            font.pixelSize: Theme.typeBody * hero.u
            elide: Text.ElideRight
        }
        Item { width: 1; height: Theme.spaceS * hero.u }
        Row {
            spacing: Theme.spaceM * hero.u

            PrimaryButton {
                id: play
                objectName: "homePlay"
                focus: true
                u: hero.u
                text: hero.primaryText
                onAccepted: hero.primaryAccepted()
            }
            SecondaryButton {
                id: details
                objectName: "homeDetails"
                visible: hero.secondaryText.length > 0
                u: hero.u
                text: hero.secondaryText
                onAccepted: hero.secondaryAccepted()
            }
        }
    }

    Keys.onPressed: event => {
        // Left/Right are visual: under a mirrored layout Play's neighbour is on its left.
        const toDetails = hero.LayoutMirroring.enabled ? Qt.Key_Left : Qt.Key_Right
        const toPlay = hero.LayoutMirroring.enabled ? Qt.Key_Right : Qt.Key_Left
        if (event.key === toDetails && play.activeFocus && details.visible) {
            Sfx.navigate()
            details.forceActiveFocus()
            event.accepted = true
        } else if (event.key === toPlay && details.activeFocus) {
            Sfx.navigate()
            play.forceActiveFocus()
            event.accepted = true
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            event.accepted = true          // the ends of the row
        } else if (event.key === Qt.Key_Up) {
            hero.upRequested()
            event.accepted = true
        } else if (event.key === Qt.Key_Down) {
            hero.downRequested()
            event.accepted = true
        }
    }
}
