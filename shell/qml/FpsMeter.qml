import QtQuick

// Informational only: QEMU/llvmpipe numbers are not KPI data (docs/specs/02-shell.md §8).
Text {
    id: meter

    property real fps: 0
    property int frames: 0
    property real elapsed: 0

    text: Math.round(fps) + " FPS"
    color: Theme.textDim

    FrameAnimation {
        running: meter.visible
        onTriggered: {
            meter.frames += 1
            meter.elapsed += frameTime
            if (meter.elapsed >= 0.5) {
                meter.fps = meter.frames / meter.elapsed
                meter.frames = 0
                meter.elapsed = 0
            }
        }
    }
}
