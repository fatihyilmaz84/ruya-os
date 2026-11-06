import QtQuick
import RuyaShell

// The liquid look of a top-bar pill (04 §3.8, T-205): draws `blurSource` (the pill's already
// blurred and masked crop) through shaders/liquid.frag, which bends it at the edge and adds a slow
// specular. One small texture per pill. Only GlassPill creates it, and only on the High tier with
// `Theme.liquidPill` on. `compiled` says it is drawing; whenever it is not (no ShaderTools in the
// build, an invalid .qsb, the software renderer) the pill keeps drawing itself as the plain pill.
Item {
    id: liquid

    property Item blurSource
    property real u: 1

    property url shader: "shaders/liquid.frag.qsb"

    // Drawing: the scene graph is on a GPU (the software renderer, used by the offscreen tests,
    // draws no shader) and the .qsb loaded. With a working shader `status` stayed `Uncompiled` on
    // Qt 6.10 / D3D11 (measured), and only `Error` tells that the .qsb is missing or invalid, so
    // that is what is tested. (The build compiles the GLSL with qsb, so GLSL that does not
    // compile fails the build, not the shell.)
    readonly property bool compiled: fx.status !== ShaderEffect.Error
                                     && liquid.GraphicsInfo.api !== GraphicsInfo.Software
                                     && liquid.GraphicsInfo.api !== GraphicsInfo.Null
                                     && liquid.GraphicsInfo.api !== GraphicsInfo.Unknown
    // Seconds on the specular's clock. It loops at the common period of the three sines, so the
    // jump at the loop point is invisible; it stands still under reduced motion.
    property real clock: 0

    NumberAnimation on clock {
        running: Theme.ambientMotion && liquid.compiled && liquid.visible
        from: 0
        to: Theme.liquidCycleMs / 1000
        duration: Theme.liquidCycleMs
        loops: Animation.Infinite
    }

    ShaderEffectSource {
        id: blurred
        visible: false
        sourceItem: liquid.blurSource
        live: true
    }

    ShaderEffect {
        id: fx
        objectName: "liquidShader"
        anchors.fill: parent
        visible: liquid.blurSource !== null
        // Names are the uniforms of liquid.frag.
        property var source: blurred
        property size pillSize: Qt.size(width, height)
        property real bend: Math.min(Theme.liquidBendFactor * height, Theme.liquidBendMax * liquid.u)
        property real time: liquid.clock
        property color specular: Theme.glassSpecular
        property vector3d periods: Qt.vector3d(Theme.liquidPeriods[0], Theme.liquidPeriods[1], Theme.liquidPeriods[2])
        fragmentShader: liquid.shader
    }
}
