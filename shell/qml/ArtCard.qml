import QtQuick
import RuyaShell

// Art card (04 §5): 16:9 art edge to edge (AppArt: the picture, else initials on a tint from
// the id hash), the title on a caption fade at the bottom, a state pill in words and the card
// focus (ring, scale, lift shadow, top sheen and a one-time glare: 04 §3.8). The owner sets
// `focused` from its view and handles Accept.
Item {
    id: card

    property real u: 1
    property string itemId
    property string title
    property string picture      // path or URL, may be empty
    property bool focused: false
    // Its Options menu is open (04 §5, 02 §1.7): the card keeps its lift (scale, shadow, sheen, glow) but
    // not the ring, so the menu's ring is the only one on screen. The owner sets it before the menu takes
    // the focus, so the card does not blink.
    property bool anchored: false
    // The Hold ring (HoldRing) on the art while the owner holds Accept on this card.
    property bool holdShown: false
    property real holdProgress: 0
    readonly property bool lit: focused || anchored
    property bool running: false
    property bool closing: false         // Close game was asked and the game has not ended yet (T-458)
    property bool installing: false
    property int installPercent: 0

    readonly property string stateText: closing ? qsTr("Closing")
                                      : running ? qsTr("Running")
                                      : installing ? qsTr("Installing %1 %").arg(installPercent) : ""

    implicitWidth: Theme.cardWidthShelf * u
    implicitHeight: Theme.cardArtHeight(width)      // stays 16:9 when a grid or row sets the width
    scale: lit ? Theme.focusScale : 1.0
    z: lit ? 1 : 0
    Behavior on scale { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide } }

    Accessible.role: Accessible.Button
    Accessible.name: stateText.length > 0 ? title + ", " + stateText : title

    // Accept feedback, run by the owner. It shrinks the art, not the card, so it does not fight
    // the focus scale; skipped under reduced motion (the launch toast that follows is the feedback).
    function pulse() {
        if (!Theme.reducedMotion)
            pulseAnimation.restart()
    }

    SequentialAnimation {
        id: pulseAnimation
        objectName: "pulseAnimation"
        NumberAnimation { target: art; property: "scale"; to: Theme.pulseScale; duration: Theme.pulseDownMs; easing.type: Easing.OutQuad }
        NumberAnimation { target: art; property: "scale"; to: 1.0; duration: Theme.pulseUpMs; easing.type: Easing.OutBack; easing.overshoot: Theme.popOvershoot }
    }

    GlassShadow {
        id: liftShadow
        objectName: "cardLiftShadow"
        anchors.fill: parent
        u: card.u
        radius: art.radius        // one radius for the picture, the shadow's cut-out and the ring (T-314)
        kind: "lift"
        active: card.lit
        glow: art.glowColor       // the colour of the picture (T-281): the lift shadow takes it, and a halo on High
        glowStrength: art.glowStrength
        halo: true
        scale: art.scale          // the Accept pulse shrinks the art; the shadow follows it
    }

    AppArt {
        id: art
        anchors.fill: parent
        u: card.u
        appId: card.itemId
        appName: card.title
        picture: card.picture
        glowing: true

        CardFocusLayers {
            id: focusLayers
            objectName: "cardFocusLayers"
            anchors.fill: parent
            u: card.u
            radius: art.radius
            focused: card.lit
        }

        Rectangle {
            objectName: "artCaptionFade"
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: parent.height * 0.5
            radius: parent.radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.artCaptionFadeClear }
                GradientStop { position: 1.0; color: Theme.artCaptionFade }
            }
        }

        Text {
            objectName: "artCardTitle"
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: Theme.spaceS * card.u }
            textFormat: Text.PlainText
            text: card.title
            color: Theme.text
            font.pixelSize: Theme.typeCaption * card.u
            font.weight: Theme.weightDemiBold
            elide: Text.ElideRight
        }

        Badge {
            objectName: "artCardPill"
            anchors { right: parent.right; top: parent.top; margins: Theme.spaceXs * card.u }
            u: card.u
            visible: card.stateText.length > 0
            solid: true             // its own opaque fill: readable over any art tint (04 §5)
            text: card.stateText
            kind: card.closing ? "neutral" : card.running ? "success" : "info"
        }
    }

    // The long-press feedback, centred on the art (the ring below stays the last child: it lies on top of all).
    HoldRing {
        objectName: "cardHoldRing"
        anchors.centerIn: art
        u: card.u
        shown: card.holdShown
        progress: card.holdProgress
    }

    // The focus ring (04 §4): its own item above the picture, the caption, the badge and the card
    // layers (a border on the art would be covered by the picture). It follows the art's scale, so
    // the Accept pulse shrinks it with the art.
    Rectangle {
        id: ring
        objectName: "cardRing"
        anchors.fill: art
        scale: art.scale
        radius: art.radius
        color: "transparent"
        border.width: card.focused && !card.anchored ? Theme.focusRingWidth * card.u : 0
        border.color: Theme.focusRing
    }
}
