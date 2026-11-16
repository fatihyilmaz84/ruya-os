pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import RuyaShell

// Launch splash (04 §5, §5.1, T-147): from Accept on Play until the app's first window. The app's art
// takes the whole screen (it scales 1.0 -> 1.04 and a blurred copy fades in over `launchMs`; the
// Performance tier draws no blur), the title and a status line sit bottom left, three dots show
// that something is happening. It is modal: it takes the focus and every key except the Guide keys
// (the shell decides those, `guideKey`). After the shell's 20 s without a window it says
// "Still starting" and offers Close, which has the focus (A on it, or B anywhere).
// Closing mode (T-458, RUY-736): after Close game. Nothing to press until the shell's `forceQuitAfterMs`
// (5 s) without the game's end; then it is `stuck`: "<title> is not responding", "Force quit loses unsaved
// progress.", and Force quit, which has the focus (A on it), or Wait at Home (B anywhere).
// Reduced motion: `launchMs` is 0, so it appears and goes as a cut, and the dots stand still.
FocusScope {
    id: splash

    property real u: 1
    property bool shown: false
    property string appId
    property string title
    property string picture       // hero or tile path, may be empty (then the generated art)
    property bool started: false  // Session1 said ok: "Starting..."
    property bool slow: false     // 20 s without a window: "Still starting" and Close
    // Closing mode (T-458): Close game was chosen. The line says "Closing <title>…", the dots run, there
    // is nothing to press (Back does not leave it; the shell ends it when the game has ended).
    property bool closing: false
    // Closing and the game has not ended in `forceQuitAfterMs` (RUY-736): it offers Force quit (A) and
    // Wait at Home (B); the text is still, the dots stand still and hide (a screen that waits).
    property bool stuck: false
    readonly property bool offersForceQuit: closing && stuck
    // Keys the shell keeps for itself (Guide): a function key -> bool.
    property var guideKey: function (key) { return false }

    // What the hint bar says while the splash is up: nothing to press until it offers Close (a launch)
    // or Force quit (closing).
    readonly property var hints: offersForceQuit
                                 ? [{ action: "accept", text: qsTr("Force quit") }, { action: "back", text: qsTr("Wait at Home") }]
                                 : slow && !closing ? [{ action: "accept", text: qsTr("Close") }, { action: "back", text: qsTr("Close") }] : []
    // Any of its animations is running (tests: none under reduced motion).
    readonly property bool animating: dotsAnimation.running || zoomAnimation.running
                                      || fadeAnimation.running || blurAnimation.running
    readonly property real zoom: art.scale
    readonly property alias closeButton: closeButton
    readonly property alias forceQuitButton: forceQuitButton
    // The dots breathe while something is happening: not on a launch that is slow, not on a stuck close.
    readonly property bool dotsShown: closing ? !stuck : !slow

    // Position of the lit dot, 0..3 round the three dots.
    property real phase: 0
    function dotOpacity(index) {
        if (Theme.reducedMotion)
            return 1
        const d = ((phase - index) % 3 + 3) % 3
        return 0.35 + 0.65 * (1 - Math.min(d, 3 - d) / 1.5)
    }

    signal closeRequested()
    signal forceQuitRequested()     // A on Force quit (RUY-736)
    signal waitRequested()          // B while it offers Force quit: Home, the game still closing

    function focusClose() {
        closeButton.forceActiveFocus()
    }
    function focusForceQuit() {
        forceQuitButton.forceActiveFocus()
    }
    // The screen itself takes the focus, no button (Force quit was asked: it hides, and a hidden item
    // would keep the focus and its keys).
    function holdFocus() {
        forceQuitButton.focus = false
        closeButton.focus = false
        splash.forceActiveFocus()
    }

    opacity: shown ? 1 : 0
    visible: opacity > 0
    enabled: shown
    Behavior on opacity {
        NumberAnimation { id: fadeAnimation; duration: Theme.launchMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap }
    }

    Accessible.role: Accessible.Pane
    Accessible.name: offersForceQuit ? qsTr("%1 is not responding").arg(title)
                     : closing ? qsTr("Closing %1").arg(title) : slow ? qsTr("Still starting %1").arg(title) : qsTr("Starting %1").arg(title)

    Rectangle {
        anchors.fill: parent
        color: Theme.background
    }

    AppArt {
        id: art
        objectName: "launchArt"
        anchors.fill: parent
        u: splash.u
        radius: 0
        clip: false
        monogram: false
        shimmer: false
        appId: splash.appId
        appName: splash.title
        picture: splash.picture
        scale: splash.shown ? 1.04 : 1.0
        Behavior on scale {
            NumberAnimation { id: zoomAnimation; duration: Theme.launchMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide }
        }
    }

    // The blurred copy (04 §3.6): a quarter-size texture of the art, one blur, faded in over launchMs.
    // None on the Performance tier (blurMax 0).
    property real blurAmount: shown ? 1 : 0
    Behavior on blurAmount {
        NumberAnimation { id: blurAnimation; duration: Theme.launchMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeSnap }
    }
    Loader {
        id: blurLoader
        objectName: "launchBlurLoader"
        anchors.fill: parent
        active: Theme.blurMax > 0 && splash.visible
        sourceComponent: Item {
            scale: art.scale
            ShaderEffectSource {
                id: reduced
                visible: false
                sourceItem: art
                textureSize: Qt.size(Math.max(1, splash.width / 4), Math.max(1, splash.height / 4))
            }
            MultiEffect {
                objectName: "launchBlur"
                anchors.fill: parent
                source: reduced
                opacity: splash.blurAmount
                autoPaddingEnabled: false
                blurEnabled: true
                blur: 1.0
                blurMax: Theme.blurMax
            }
        }
    }

    // Left scrim for the text, bottom fade (as the Home hero, 04 §3.1).
    Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: parent.width * 0.75
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Theme.heroScrim }
            GradientStop { position: 1.0; color: Theme.heroScrimClear }
        }
    }
    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: parent.height * 0.45
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.artCaptionFadeClear }
            GradientStop { position: 1.0; color: Theme.artCaptionFade }
        }
    }

    Column {
        id: column
        anchors {
            left: parent.left; leftMargin: splash.width * Theme.safeArea
            bottom: parent.bottom; bottomMargin: splash.height * Theme.safeArea + Theme.spaceXxxl * splash.u
        }
        width: Math.min(960 * splash.u, splash.width * 0.55)
        spacing: Theme.spaceS * splash.u

        Text {
            objectName: "launchTitle"
            width: parent.width
            textFormat: Text.PlainText
            text: splash.title
            color: Theme.text
            font.pixelSize: Theme.typeHero * splash.u
            font.weight: Theme.weightBold
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }
        Text {
            objectName: "launchStatus"
            width: parent.width
            textFormat: Text.PlainText
            text: splash.offersForceQuit ? qsTr("%1 is not responding").arg(splash.title)
                  : splash.closing ? qsTr("Closing %1…").arg(splash.title)
                  : splash.slow ? qsTr("Still starting…") : (splash.started ? qsTr("Starting…") : "")
            visible: text.length > 0
            color: Theme.text
            font.pixelSize: Theme.typeBody * splash.u
            elide: Text.ElideRight
        }
        Text {
            objectName: "launchDetail"
            width: parent.width
            textFormat: Text.PlainText
            text: qsTr("Force quit loses unsaved progress.")
            visible: splash.offersForceQuit
            color: Theme.textDim
            font.pixelSize: Theme.typeBody * splash.u
            wrapMode: Text.WordWrap
        }

        // Three dots that breathe in turn; they stand still under reduced motion and once the splash
        // says "Still starting" or "is not responding" (nothing may animate for ever on a screen that waits).
        Row {
            id: dotRow
            objectName: "launchDots"
            spacing: Theme.spaceS * splash.u
            visible: splash.dotsShown
            Repeater {
                model: 3
                Rectangle {
                    id: dot
                    required property int index
                    width: Theme.spaceM * splash.u
                    height: width
                    radius: width / 2
                    color: Theme.text
                    opacity: splash.dotOpacity(dot.index)    // the lit one is full, the others dim
                }
            }
        }

        Item { width: 1; height: Theme.spaceS * splash.u; visible: closeButton.visible || forceQuitButton.visible }
        SecondaryButton {
            id: closeButton
            objectName: "launchClose"
            u: splash.u
            visible: splash.slow && !splash.closing
            text: qsTr("Close")
            onAccepted: splash.closeRequested()
        }
        SecondaryButton {
            id: forceQuitButton
            objectName: "launchForceQuit"
            u: splash.u
            visible: splash.offersForceQuit
            text: qsTr("Force quit")
            onAccepted: splash.forceQuitRequested()
        }
    }

    NumberAnimation {
        id: dotsAnimation
        target: splash
        property: "phase"
        from: 0
        to: 3
        duration: Theme.tintMs * 2
        loops: Animation.Infinite
        running: !Theme.reducedMotion && splash.shown && splash.dotsShown && splash.visible
    }

    Keys.onPressed: event => {
        if (splash.guideKey(event.key)) {
            event.accepted = false          // the shell opens the quick menu
            return
        }
        if (splash.slow && !splash.closing && !event.isAutoRepeat && BackKey.isBackOrBackspace(event.key))
            splash.closeRequested()         // once it offers Close, Back closes too (the hint bar says so)
        else if (splash.offersForceQuit && !event.isAutoRepeat && BackKey.isBackOrBackspace(event.key))
            splash.waitRequested()          // B: Wait at Home (the hint bar says so)
        event.accepted = true               // locked: nothing reaches the shell underneath
    }
}
