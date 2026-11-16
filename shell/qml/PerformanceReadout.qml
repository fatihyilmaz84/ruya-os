pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The performance overlay over a running game (T-469, 02 §1.6, 04 §5): the numbers the Hub's switch turns
// on, in the top corners inside the safe area. Top left the frame numbers (FPS, frame time), top right
// the system numbers (CPU, GPU, RAM, VRAM, temperatures, power). Plain text on a small opaque scrim: no
// blur, no shadow, no animation; a Text redraws only when its string changes.
//
// It takes no focus and no input (`enabled: false`, nothing here is focusable), so a game keeps every
// key. `shown` is decided by the Shell (switch on for the signed-in profile, a game in front, no Hub,
// splash or Home); `rightBlocked` hides the right block while a toast stack sits in that corner. The
// service is asked and the frames counted only while `shown` (PerformanceConsumer), every
// DeviceSettings.performanceIntervalMs. Each value keeps T-452's words: "Not available on this console",
// "Measuring...", "<value> (last reading)".
Item {
    id: readout

    property real u: 1
    property real marginX: 0
    property real marginY: 0
    // The overlay is wanted and nothing covers it.
    property bool shown: false
    // A toast stack is in the top right corner.
    property bool rightBlocked: false
    readonly property bool leftVisible: shown
    readonly property bool rightVisible: shown && !rightBlocked

    visible: shown
    enabled: false
    activeFocusOnTab: false

    PerformanceConsumer { active: readout.shown }

    // ---- the words (the Hub's Performance panel had them, T-452) ---------------------------------------------
    // "Worst" state of the names wins: unsupported, then unavailable, then stale. Reads `Performance.metrics`,
    // so a line follows every answer.
    function metricState(names) {
        const all = Performance.metrics
        let state = "supported"
        for (const n of names) {
            const s = all[n] ? all[n].state : "unavailable"
            if (s === "unsupported")
                return s
            if (s === "unavailable")
                state = s
            else if (s === "stale" && state === "supported")
                state = s
        }
        return state
    }
    // "<label>: <number>", else "<label>: <why there is none>".
    function metricText(label, names, format) {
        const state = metricState(names)
        if (state === "supported" || state === "stale") {
            const text = format(names.map(n => Performance.metrics[n].value))
            return qsTr("%1: %2").arg(label).arg(state === "stale" ? qsTr("%1 (last reading)").arg(text) : text)
        }
        return qsTr("%1: %2").arg(label).arg(state === "unsupported" ? qsTr("Not available on this console") : qsTr("Measuring..."))
    }
    function percentText(v) { return qsTr("%1 %").arg(Math.round(v)) }
    function bytesPair(v) { return qsTr("%1 of %2").arg(Storage.formatBytes(v[0])).arg(Storage.formatBytes(v[1])) }
    function msText(ms) { return qsTr("%1 ms").arg(ms < 10 ? ms.toFixed(1) : Math.round(ms)) }
    // The frame lines: the number when a whole second was counted, else why there is none.
    function fpsText() {
        switch (Performance.frameState) {
        case "supported": return qsTr("%1 FPS").arg(Performance.fps)
        case "unsupported": return qsTr("FPS: %1").arg(qsTr("Not available on this console"))
        }
        return qsTr("FPS: %1").arg(Performance.frameSource === null ? qsTr("No game in front") : qsTr("Measuring..."))
    }
    function frameTimeText() {
        switch (Performance.frameState) {
        case "supported": return qsTr("%1, slowest %2").arg(msText(Performance.frameTimeMs)).arg(msText(Performance.frameTimeP99Ms))
        case "unsupported": return qsTr("Frame time: %1").arg(qsTr("Not available on this console"))
        }
        return qsTr("Frame time: %1").arg(Performance.frameSource === null ? qsTr("No game in front") : qsTr("Measuring..."))
    }
    // "1% low 48 FPS · 0.1% low 31 FPS": percentile frame intervals of the last 60 s (RUY-738); a low with too
    // few intervals says "Measuring..." in its place.
    // One low: the label ("1%", Turkish "%1") and the value. A single pass, so a "%1" inside the label is never
    // taken for the next placeholder.
    function both(pattern, first, second) {
        return pattern.replace(/%([12])/g, (m, d) => d === "1" ? first : second)
    }
    function oneLow(label, fps) {
        if (fps < 0)
            return both(qsTr("%1 low: measuring..."), label, "")
        return both(qsTr("%1 low %2"), label, qsTr("%1 FPS").arg(fps))
    }
    function lowText() {
        switch (Performance.frameState) {
        case "supported":
            return both(qsTr("%1 · %2"), oneLow(qsTr("1%"), Performance.fpsLow1), oneLow(qsTr("0.1%"), Performance.fpsLow01))
        case "unsupported": return qsTr("Lows: %1").arg(qsTr("Not available on this console"))
        }
        return qsTr("Lows: %1").arg(Performance.frameSource === null ? qsTr("No game in front") : qsTr("Measuring..."))
    }

    // ---- the two corners ---------------------------------------------------------------------------------
    component Corner: Rectangle {
        default property alias lines: column.data
        color: Theme.panel                     // opaque: 4.5:1 for `text` on every theme, whatever the game draws
        radius: Theme.radiusS * readout.u
        implicitWidth: column.implicitWidth + 2 * Theme.spaceS * readout.u
        implicitHeight: column.implicitHeight + 2 * Theme.spaceXs * readout.u
        width: implicitWidth
        height: implicitHeight
        Column {
            id: column
            x: Theme.spaceS * readout.u
            y: Theme.spaceXs * readout.u
            spacing: Theme.spaceXxs * readout.u
        }
    }
    component Line: Text {
        color: Theme.text
        font.pixelSize: Theme.typeCaption * readout.u
        font.weight: Theme.weightDemiBold
        elide: Text.ElideNone
        wrapMode: Text.NoWrap
    }

    Corner {
        objectName: "perfOverlayLeft"
        visible: readout.leftVisible
        x: readout.marginX
        y: readout.marginY
        Line { objectName: "perfOverlayFps"; text: readout.fpsText() }
        Line { objectName: "perfOverlayFrameTime"; text: readout.frameTimeText() }
        Line { objectName: "perfOverlayLows"; text: readout.lowText() }
    }

    Corner {
        objectName: "perfOverlayRight"
        visible: readout.rightVisible
        x: readout.width - readout.marginX - width
        y: readout.marginY
        Line { objectName: "perfOverlayCpu"; text: readout.metricText(qsTr("CPU"), ["cpu_percent"], v => readout.percentText(v[0])) }
        Line { objectName: "perfOverlayGpu"; text: readout.metricText(qsTr("GPU"), ["gpu_percent"], v => readout.percentText(v[0])) }
        Line { objectName: "perfOverlayRam"; text: readout.metricText(qsTr("RAM"), ["ram_used", "ram_total"], readout.bytesPair) }
        Line { objectName: "perfOverlayVram"; text: readout.metricText(qsTr("VRAM"), ["vram_used", "vram_total"], readout.bytesPair) }
        Line { objectName: "perfOverlayCpuTemp"; text: readout.metricText(qsTr("CPU temperature"), ["cpu_temp"], v => qsTr("%1 °C").arg(Math.round(v[0]))) }
        Line { objectName: "perfOverlayGpuTemp"; text: readout.metricText(qsTr("GPU temperature"), ["gpu_temp"], v => qsTr("%1 °C").arg(Math.round(v[0]))) }
        Line { objectName: "perfOverlayPower"; text: readout.metricText(qsTr("Power"), ["power_w"], v => qsTr("%1 W").arg(v[0].toFixed(1))) }
    }
}
