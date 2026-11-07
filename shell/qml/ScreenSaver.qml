pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The screen saver and the dark screen (T-202, 02 "Power saving").
//
// Stage "saver" (`IdleClock.stage`): a near-black ground (OLED-friendly on every theme), the
// installed apps' art drifting slowly and cross-fading, dimmed, and a small clock that moves to a
// new place every minute so that nothing stays lit in one spot. Stage "off" and "sleep": a black
// frame only (the display itself is switched off through `ScreenPower`; the frame is what the user
// sees when the platform cannot do that), with no timers and no animation running.
//
// Performance tier: no art (the ground and the moving clock). Reduced motion: the art is one still,
// dimmed frame, the clock still moves (it is not an animation, it is a jump). There is no focus
// ring and nothing here takes focus: `KeyRouter.swallowInput` (Shell) eats the first key, button or
// pointer event, so it wakes the console and reaches no page, and the page below keeps the focus it had.
Item {
    id: saver

    property real u: 1

    readonly property string stage: IdleClock.stage
    readonly property bool active: stage !== "active"
    readonly property bool dark: stage === "off" || stage === "sleep"
    // The art: the installed apps that have a picture, else every installed app (their generated art).
    readonly property var pool: {
        const withArt = Library.items.filter(i => (i.art ?? {}).hero || (i.art ?? {}).tile)
        return withArt.length > 0 ? withArt : Library.items
    }
    readonly property bool showArt: !dark && DeviceSettings.effectsQuality !== "performance" && pool.length > 0
    readonly property bool animating: stage === "saver" && Theme.ambientMotion && pool.length > 1

    // Near black on every theme, from the theme's own background (a missing token, Inbox).
    readonly property color ground: Qt.darker(Theme.background, 20)

    // The clock's place: one of many, chosen from the minute of the day, so it differs every minute.
    // IdleClock's clock is the one the tests replace; the tick below reads it.
    property int slot: 0
    property date shownTime: new Date()
    readonly property real golden: 0.6180339887
    function place(index, span) {
        const f = (index * golden) % 1
        return f * Math.max(0, span)
    }
    readonly property real clockX: Theme.safeArea * width + place(slot, width - clockLabel.width - 2 * Theme.safeArea * width)
    readonly property real clockY: Theme.safeArea * height + place(slot * 2 + 1, height - clockLabel.height - 2 * Theme.safeArea * height)

    // Which art is in front.
    property int artIndex: 0

    visible: active || opacity > 0
    opacity: active ? 1 : 0
    // Fading in is gentle; waking is immediate (the console "wakes up instantly").
    Behavior on opacity {
        enabled: saver.active
        NumberAnimation { duration: Theme.overlayMs; easing.type: Easing.OutQuad }
    }
    Accessible.role: Accessible.Pane
    Accessible.name: qsTr("Screen saver")

    Rectangle {
        anchors.fill: parent
        color: saver.ground
    }

    // Two layers cross-fade; each drifts (a slow zoom and pan) while it is in front.
    Item {
        id: art
        objectName: "saverArt"
        anchors.fill: parent
        visible: saver.showArt
        opacity: 0.3                           // dimmed: art on a dark ground, never at full strength
        clip: true

        Repeater {
            model: 2
            delegate: AppArt {
                id: layer
                required property int index
                objectName: "saverLayer" + index
                readonly property int pick: saver.pool.length > 0 ? (saver.artIndex + index) % saver.pool.length : 0
                readonly property bool front: (saver.artIndex % 2) === index
                readonly property var entry: saver.pool.length > 0 ? saver.pool[pick] : ({})
                u: saver.u
                width: art.width
                height: art.height
                x: drift * art.width * 0.04
                y: 0
                appId: entry.id ?? ""
                appName: entry.title ?? ""
                picture: (entry.art ?? {}).hero ?? (entry.art ?? {}).tile ?? ""
                monogram: false
                shimmer: false
                radius: 0
                opacity: front ? 1 : 0
                property real drift: 0
                scale: 1.1                   // already larger than the screen, so the drift never shows an edge
                Behavior on opacity { NumberAnimation { duration: Theme.tintMs * 4 } }
                SequentialAnimation on drift {
                    running: saver.animating && layer.front
                    loops: Animation.Infinite
                    NumberAnimation { from: -1; to: 1; duration: Theme.tintMs * 40; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 1; to: -1; duration: Theme.tintMs * 40; easing.type: Easing.InOutSine }
                }
                NumberAnimation on scale {
                    running: saver.animating && layer.front
                    from: 1.1
                    to: 1.22
                    duration: Theme.tintMs * 80
                    easing.type: Easing.InOutSine
                }
            }
        }
    }

    // The next picture, a while after the last one. Not while the screen is dark, reduced motion
    // keeps the first frame.
    Timer {
        objectName: "saverSlides"
        interval: 20000
        repeat: true
        running: saver.animating
        onTriggered: saver.artIndex = saver.artIndex + 1
    }

    // The clock: shown while the saver is up (not on the dark screen), at a new place each minute.
    Text {
        id: clockLabel
        objectName: "saverClock"
        visible: saver.stage === "saver"
        x: saver.clockX
        y: saver.clockY
        text: Qt.formatTime(saver.shownTime, "hh:mm")
        color: Theme.glarePeak
        font.pixelSize: Theme.typeDisplay * saver.u
        font.weight: Theme.weightDemiBold
    }

    // Looks at the clock every 20 s (the minute only has to be right to within that) while the saver
    // is up. Off with the dark screen: nothing wakes the console for a clock nobody sees.
    Timer {
        objectName: "saverTick"
        interval: 20000
        repeat: true
        running: saver.stage === "saver"
        triggeredOnStart: true
        onTriggered: {
            saver.shownTime = new Date(IdleClock.now())
            saver.slot = Math.floor(IdleClock.now() / 60000)
        }
    }
}
