import QtQuick
import RuyaShell

// What a focused card shows on top of the ring and the 1.08 scale (04 §3.8): a white sheen over
// its top third (every tier) and a one-time glare, a soft diagonal band that crosses the card
// when focus *enters* it. The glare is skipped when focus entered another card less than
// `Theme.glareGapMs` ago (GlareGate), under reduced motion and on the Performance tier. No
// resting glare. Put it inside the card's art (the art clips it), `anchors.fill: parent`.
Item {
    id: fx

    property bool focused: false
    property real radius: 0
    property real u: 1

    // How many glares have started (tests count them; the animation's `running` says one is on now).
    property int glareCount: 0

    readonly property alias glareAnimation: glareAnim

    onFocusedChanged: {
        if (focused) {
            if (GlareGate.claim() && Theme.glareOn && Theme.glareMs > 0) {
                glareCount += 1
                glareAnim.restart()
            }
        } else {
            glareAnim.stop()
        }
    }

    Rectangle {
        objectName: "cardSheen"
        anchors.fill: parent
        visible: fx.focused
        radius: fx.radius
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.cardSheen }
            GradientStop { position: Theme.cardSheenSpan; color: Theme.glassSheenEnd }
            GradientStop { position: 1.0; color: Theme.glassSheenEnd }
        }
    }

    // The band is drawn into a hidden layer and masked by the card's rounded shape while it runs
    // (a plain `clip` is rectangular and would light the corners). One transient texture, one glare at a time.
    Item {
        id: glareLayer
        anchors.fill: parent
        visible: false
        layer.enabled: glareAnim.running

        Rectangle {
            id: band
            objectName: "cardGlare"
            width: fx.width * 0.4
            height: fx.height * 2
            y: -fx.height / 2
            rotation: 20
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Theme.glassSheenEnd }
                GradientStop { position: 0.5; color: Theme.glarePeak }
                GradientStop { position: 1.0; color: Theme.glassSheenEnd }
            }
        }

        NumberAnimation {
            id: glareAnim
            objectName: "glareAnimation"
            target: band
            property: "x"
            from: -band.width
            to: fx.width
            duration: Math.max(1, Theme.glareMs)
            easing.type: Easing.InOutQuad
        }
    }
    Rectangle {
        id: glareMask
        anchors.fill: parent
        radius: fx.radius
        visible: false
        layer.enabled: glareAnim.running
        layer.smooth: true
    }
    SmoothMask {
        objectName: "glareEffect"
        anchors.fill: parent
        visible: glareAnim.running
        source: glareLayer
        maskSource: glareMask
    }
}
