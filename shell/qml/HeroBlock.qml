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
    property bool primaryShown: true   // false: no Play (an item with no launch path, T-147); Details takes the focus
    property bool primaryDimmed: false // the primary's action is unavailable for now (PrimaryButton.dimmed)
    readonly property alias playButton: play
    readonly property alias detailsButton: details
    // The item has an Options menu (02 §1.7): Accept acts on release and a long press opens the menu
    // (`optionsRequested`, with the focused button); false (an empty library): Accept acts on press.
    property bool holdEnabled: false
    // The button whose menu is open: it keeps its look but not its ring (the owner clears it on close).
    property Item anchoredItem: null

    signal primaryAccepted()
    signal secondaryAccepted()
    signal optionsRequested(Item anchor)
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
            textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
                visible: hero.primaryShown
                focus: hero.primaryShown
                u: hero.u
                text: hero.primaryText
                dimmed: hero.primaryDimmed
                acceptOnRelease: hero.holdEnabled
                anchored: hero.anchoredItem === play
                holdShown: hold.ringShown && play.activeFocus
                holdProgress: hold.ringProgress
                onActiveFocusChanged: hold.cancel()
                onAccepted: hero.primaryAccepted()
            }
            SecondaryButton {
                id: details
                objectName: "homeDetails"
                visible: hero.secondaryText.length > 0
                focus: !hero.primaryShown
                u: hero.u
                text: hero.secondaryText
                acceptOnRelease: hero.holdEnabled
                anchored: hero.anchoredItem === details
                holdShown: hold.ringShown && details.activeFocus
                holdProgress: hold.ringProgress
                onActiveFocusChanged: hold.cancel()
                onAccepted: hero.secondaryAccepted()
            }
        }
    }

    // Accept on release and the long press (AcceptHold): a tap runs the focused button as a press did.
    AcceptHold {
        id: hold
        objectName: "heroHold"
        active: hero.holdEnabled
        onTapped: {
            Sfx.select()
            if (play.activeFocus)
                hero.primaryAccepted()
            else if (details.activeFocus)
                hero.secondaryAccepted()
        }
        onLongPressed: hero.openOptions()
    }

    // The menu of the hero's item, anchored to the focused pill.
    function openOptions() {
        const button = play.activeFocus ? play : details.activeFocus ? details : null
        if (!button)
            return
        hero.anchoredItem = button
        hero.optionsRequested(button)
    }

    onActiveFocusChanged: hold.cancel()

    onPrimaryShownChanged: {
        if (!primaryShown && hero.activeFocus && details.visible)
            details.forceActiveFocus()
        else if (primaryShown && hero.activeFocus)
            play.forceActiveFocus()
    }

    Keys.onReleased: event => {
        if (hero.holdEnabled && hold.release(event))
            event.accepted = true
    }

    Keys.onPressed: event => {
        if (hero.holdEnabled && hold.press(event)) {
            event.accepted = true
            return
        }
        if (hero.holdEnabled && event.key === Qt.Key_Menu) {
            if (!event.isAutoRepeat)
                hero.openOptions()
            event.accepted = true
            return
        }
        // Left/Right are visual: under a mirrored layout Play's neighbour is on its left.
        const toDetails = hero.LayoutMirroring.enabled ? Qt.Key_Left : Qt.Key_Right
        const toPlay = hero.LayoutMirroring.enabled ? Qt.Key_Right : Qt.Key_Left
        if (event.key === toDetails && play.activeFocus && details.visible) {
            Sfx.navigate()
            details.forceActiveFocus()
            event.accepted = true
        } else if (event.key === toPlay && details.activeFocus && play.visible) {
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
