import QtQuick
import QtTest
import RuyaShell

// StickPlot (RUY-465, 04 §5) and GameControls.response: what the game sees for a stick position is
// 06 §7's formula. The table is RUY-42's Rust test (services/ruya-inputd/src/engine.rs,
// the_response_follows_the_formula), row for row; the output dot sits in the stick's direction at
// that radius (inverted per axis after), the response dot at (r, out).
Item {
    id: host
    width: 800
    height: 400

    Component {
        id: plotComponent
        StickPlot { u: 1 }
    }

    TestCase {
        id: tc
        name: "StickPlot"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
        }

        function settings(inner, outer, anti, sensitivity, curve) {
            return { inner_deadzone: inner, outer_deadzone: outer, anti_deadzone: anti, sensitivity: sensitivity,
                     curve: curve, invert_x: false, invert_y: false }
        }

        // [r, settings, expected out]
        function table() {
            const d = GameControls.stickDefaults
            return [
                [0.0, d, 0.0],
                [0.05, d, 0.0],
                [0.08, d, 0.0],
                [0.53, d, (0.53 - 0.08) / 0.9],
                [0.98, d, 1.0],
                [1.0, d, 1.0],
                [0.53, settings(0.08, 0.02, 0.0, 1.0, "precise"), 0.25],
                [0.53, settings(0.08, 0.02, 0.0, 1.0, "aggressive"), Math.sqrt(0.5)],
                [0.53, settings(0.08, 0.02, 0.2, 1.0, "linear"), 0.2 + 0.8 * 0.5],
                [0.08, settings(0.08, 0.02, 0.2, 1.0, "linear"), 0.0],
                [0.53, settings(0.08, 0.02, 0.0, 1.5, "linear"), 0.75],
                [0.89, settings(0.08, 0.02, 0.0, 1.5, "linear"), 1.0],
                [0.53, settings(0.08, 0.02, 0.0, 0.5, "linear"), 0.25],
                [0.3, settings(0.0, 0.0, 0.0, 1.0, "linear"), 0.3],
                [0.59, settings(0.6, 0.5, 0.0, 1.0, "linear"), 0.0],
                [0.61, settings(0.6, 0.5, 0.0, 1.0, "linear"), 1.0],
            ]
        }

        function test_the_defaults_are_06s() {
            compare(GameControls.stickDefaults.inner_deadzone, 0.08)
            compare(GameControls.stickDefaults.outer_deadzone, 0.02)
            compare(GameControls.stickDefaults.anti_deadzone, 0)
            compare(GameControls.stickDefaults.sensitivity, 1)
            compare(GameControls.stickDefaults.curve, "linear")
        }

        function test_the_response_follows_the_formula() {
            for (const row of table())
                fuzzyCompare(GameControls.response(row[0], row[1]), row[2], 1e-9, "r " + row[0] + " " + JSON.stringify(row[1]))
        }

        function test_the_output_dot_sits_at_radius_out() {
            const plot = createTemporaryObject(plotComponent, host, { kind: "position" })
            verify(plot)
            compare(plot.width, 320)
            for (const row of table()) {
                // Leftwards: the dot is on the left at radius out.
                plot.settings = row[1]
                plot.stickX = -row[0]
                plot.stickY = 0
                const dot = findChild(plot, "outputDot")
                const dx = dot.x + dot.width / 2 - 160
                const dy = dot.y + dot.height / 2 - 160
                fuzzyCompare(Math.sqrt(dx * dx + dy * dy) / 160, row[2], 1e-6, "radius for r " + row[0] + " " + JSON.stringify(row[1]))
                verify(dx <= 0, "the same direction")
                const ring = findChild(plot, "rawRing")
                fuzzyCompare(160 - ring.x - ring.width / 2, row[0] * 160, 1e-6, "the raw ring at r")
            }
            // Up and left on the diagonal: the direction is kept.
            plot.settings = GameControls.stickDefaults
            plot.stickX = -Math.SQRT1_2 * 0.53
            plot.stickY = -Math.SQRT1_2 * 0.53
            const diagonal = findChild(plot, "outputDot")
            const ddx = diagonal.x + diagonal.width / 2 - 160
            const ddy = diagonal.y + diagonal.height / 2 - 160
            fuzzyCompare(Math.sqrt(ddx * ddx + ddy * ddy) / 160, 0.5, 1e-6, "radius out on the diagonal")
            fuzzyCompare(ddx, ddy, 1e-6, "on the diagonal")
            verify(ddx < 0, "up and left")
            compare(findChild(plot, "outputDot").width, 28, "28 u markers")
        }

        function test_inversion_flips_the_output_only() {
            const plot = createTemporaryObject(plotComponent, host, { kind: "position" })
            const s = Object.assign({}, GameControls.stickDefaults, { invert_y: true })
            plot.settings = s
            plot.stickX = 0
            plot.stickY = 0.53
            const dot = findChild(plot, "outputDot")
            fuzzyCompare(dot.y + dot.height / 2 - 160, -0.5 * 160, 1e-6, "up, not down")
            const ring = findChild(plot, "rawRing")
            fuzzyCompare(ring.y + ring.height / 2 - 160, 0.53 * 160, 1e-6, "the raw position as it is")
        }

        function test_the_response_dot_and_the_dead_zones() {
            const plot = createTemporaryObject(plotComponent, host, { kind: "response" })
            for (const row of table()) {
                plot.settings = row[1]
                plot.stickX = row[0]
                plot.stickY = 0
                const dot = findChild(plot, "responseDot")
                fuzzyCompare((dot.x + dot.width / 2) / 320, row[0], 1e-6, "x is r")
                fuzzyCompare((320 - dot.y - dot.height / 2) / 320, row[2], 1e-6, "y is out for r " + row[0])
            }
            plot.settings = settings(0.12, 0.05, 0, 1, "precise")
            fuzzyCompare(findChild(plot, "innerBand").width, 0.12 * 320, 1e-6, "the inner dead zone band")
            const position = createTemporaryObject(plotComponent, host, { kind: "position", settings: settings(0.12, 0.05, 0, 1, "linear") })
            fuzzyCompare(findChild(position, "innerZone").width, 2 * 0.12 * 160, 1e-6, "inner dead zone radius")
            fuzzyCompare(findChild(position, "outerBand").border.width, 0.05 * 160, 1e-6, "outer band from 1 - outer to 1")
            verify(findChild(position, "positionPlot").visible && !findChild(position, "responsePlot").visible)
        }
    }
}
