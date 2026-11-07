pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Gliding highlight (04 §3.8, T-205) for a list or row of siblings where one item is focused: ONE
// fill that glides to the focused item instead of every item switching its own fill, and that
// stretches with speed so a fast scroll reads as a stroke.
//
// It is a picture only. Focus, keys, hit areas and the accessible name stay on the real items,
// and the item's own focus ring stays on the item (04 §4: the ring never fades during a move), so
// the highlight is under the ring, never instead of it. It never takes focus.
//
// Use: declare it in the same coordinate space as the items (a sibling of the Row, or a child of
// a ListView, whose items are in the content item), below them, with
//   target: the focused item (null: nothing to show)
//   shown:  whether the owner has focus (false: the highlight fades out)
// and let each item hide its own focus fill while `active` is true (that fill is the fallback
// when the highlight cannot be shown). `targetX/Y/Width/Height` are the goal; `x/y/width/height`
// are the animated position. The glide retargets from where it is (no jump, no restart from
// zero), and snaps when `Theme.motionScale` is 0 (reduced motion).
Item {
    id: glide

    property Item target
    property bool shown: true
    property int orientation: Qt.Horizontal      // the axis the stretch follows
    property real u: 1
    property real radius: -1                     // < 0: a full pill (half the shorter side)
    property color color: Theme.focusFill

    // The target's geometry in this item's parent's coordinates, or null when the target is not
    // below the parent. Reads x/y of every item on the way, so it follows scrolling and layouts.
    function measure(item) {
        if (!item || !glide.parent)
            return null
        let gx = 0
        let gy = 0
        let p = item
        while (p && p !== glide.parent) {
            gx += p.x
            gy += p.y
            p = p.parent
        }
        return p === glide.parent ? { x: gx, y: gy, w: item.width, h: item.height } : null
    }

    readonly property var geometry: measure(target)
    property var lastGeometry: null              // the last real geometry: where a hidden highlight rests
    onGeometryChanged: if (geometry) lastGeometry = geometry

    readonly property var goal: geometry ? geometry : lastGeometry
    readonly property real targetX: goal ? goal.x : 0
    readonly property real targetY: goal ? goal.y : 0
    readonly property real targetWidth: goal ? goal.w : 0
    readonly property real targetHeight: goal ? goal.h : 0

    // True while the highlight is drawn for a target. Items hide their own focus fill then.
    readonly property bool active: shown && geometry !== null && geometry.w > 0

    // Behaviours are off until the first real geometry has landed (so the first placement snaps
    // rather than gliding from 0,0) and while hidden (a hidden highlight follows without moving
    // visibly, and shows at the right place).
    property bool primed: false
    onGoalChanged: if (goal && !primed) Qt.callLater(() => { glide.primed = true })
    readonly property bool animated: active && primed && Theme.motionScale > 0

    // Speed stretch: 0..1, smoothed. `stepStretch` is the whole rule; the frame loop feeds it the
    // measured speed and a test feeds it a scripted one.
    property real stretch: 0
    property int direction: 1                    // +1 moving right/down, -1 left/up
    function stretchFor(speed) {                 // speed in design px per second
        return Math.max(0, Math.min(1, Math.abs(speed) / Theme.glideSpeedRef))
    }
    function stepStretch(dt, speed) {
        if (Theme.reducedMotion || dt <= 0) {
            stretch = 0
            return
        }
        const follow = 1 - Math.exp(-Theme.glideSmoothing * dt)
        const goal = stretchFor(speed)
        stretch += (goal - stretch) * follow
        if (goal === 0 && stretch < 0.001)
            stretch = 0                          // settled: lets the frame loop stop
        if (Math.abs(speed) > 1)
            direction = speed > 0 ? 1 : -1
    }

    onActiveChanged: if (!active) stretch = 0

    readonly property bool gliding: xAnim.running || yAnim.running || widthAnim.running || heightAnim.running

    x: targetX
    y: targetY
    width: targetWidth
    height: targetHeight
    opacity: active ? 1 : 0
    visible: opacity > 0

    Behavior on x {
        enabled: glide.animated
        NumberAnimation { id: xAnim; duration: Theme.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide }
    }
    Behavior on y {
        enabled: glide.animated
        NumberAnimation { id: yAnim; duration: Theme.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide }
    }
    Behavior on width {
        enabled: glide.animated
        NumberAnimation { id: widthAnim; duration: Theme.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide }
    }
    Behavior on height {
        enabled: glide.animated
        NumberAnimation { id: heightAnim; duration: Theme.glideMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide }
    }
    Behavior on opacity {
        NumberAnimation { duration: Theme.focusMs }
    }

    // The speed is measured from the animated position, one frame at a time, only while something
    // moves or the stretch is still settling.
    property real lastPos: 0
    property bool haveLast: false
    FrameAnimation {
        running: glide.active && !Theme.reducedMotion && (glide.gliding || glide.stretch > 0.001)
        onRunningChanged: if (!running) glide.haveLast = false
        onTriggered: {
            const pos = glide.orientation === Qt.Horizontal ? glide.x : glide.y
            if (glide.haveLast && frameTime > 0)
                glide.stepStretch(frameTime, (pos - glide.lastPos) / frameTime / glide.u)
            glide.lastPos = pos
            glide.haveLast = true
        }
    }

    Rectangle {
        id: body
        objectName: "focusGlideBody"
        readonly property bool horizontal: glide.orientation === Qt.Horizontal
        readonly property real extra: glide.stretch * Theme.glideStretchMax * (horizontal ? glide.width : glide.height)
        // The extra length trails behind the motion.
        x: horizontal && glide.direction > 0 ? -extra : 0
        y: !horizontal && glide.direction > 0 ? -extra : 0
        width: glide.width + (horizontal ? extra : 0)
        height: glide.height + (horizontal ? 0 : extra)
        radius: glide.radius >= 0 ? glide.radius : Math.min(width, height) / 2
        color: glide.color
    }
}
