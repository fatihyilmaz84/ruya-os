import QtQuick
import QtTest
import RuyaShell

// PadDiagram's layouts (RUY-486): every stick, D-pad key, face button, pill and the touchpad lies
// inside the body for every layout, the words on the pad follow the family, and the Wii U Pro's
// triggers are buttons without an analog track.
Item {
    id: host
    width: 1200
    height: 700

    Component {
        id: diagramComponent
        PadDiagram { }
    }

    TestCase {
        id: tc
        name: "PadDiagram"
        when: windowShown

        readonly property var layouts: [
            { family: "playstation", layout: "", kind: "playstation" },
            { family: "xbox", layout: "", kind: "xbox" },
            { family: "generic", layout: "", kind: "xbox" },
            { family: "", layout: "", kind: "xbox" },
            { family: "nintendo", layout: "", kind: "nintendo" },
            { family: "nintendo", layout: "nintendo-wiiu", kind: "nintendo-wiiu" },
            { family: "nintendo", layout: "somethingnew", kind: "nintendo" }
        ]

        function make(family, layout) {
            const d = createTemporaryObject(diagramComponent, host, { family: family, layout: layout })
            verify(d)
            return d
        }

        // The controls that sit inside the body: not the shoulders and the triggers (on its edge).
        function bodyControls(d) {
            const out = []
            const names = ["select", "start", "guide", "dpad_up", "dpad_down", "dpad_left", "dpad_right",
                           "north", "east", "south", "west"]
            for (const n of names)
                out.push(findChild(d, "padCtl_" + n))
            out.push(findChild(d, "padStick_left"), findChild(d, "padStick_right"))
            if (d.playstation)
                out.push(findChild(d, "padTouchpad"))
            for (const c of out)
                verify(c, "a control is missing")
            return out
        }

        // Points that stand for a control's outline, in box units: 16 on a circle, else the corners
        // and the edge middles.
        function outline(c, u) {
            const x = c.x / u, y = c.y / u, w = c.width / u, h = c.height / u
            const pts = []
            if (c.radius >= Math.min(w, h) * u / 2 - 0.5) {
                const r = Math.min(w, h) / 2
                for (let i = 0; i < 16; ++i)
                    pts.push([x + w / 2 + r * Math.cos(i * Math.PI / 8), y + h / 2 + r * Math.sin(i * Math.PI / 8)])
            } else {
                for (const fx of [0, 0.5, 1])
                    for (const fy of [0, 0.5, 1])
                        pts.push([x + w * fx, y + h * fy])
            }
            return pts
        }

        function test_the_kind_follows_the_family_and_the_layout() {
            for (const l of layouts)
                compare(make(l.family, l.layout).kind, l.kind, l.family + "/" + l.layout)
        }

        function test_every_control_lies_inside_the_body() {
            for (const l of layouts) {
                for (const u of [1, 0.5]) {
                    const d = make(l.family, l.layout)
                    d.u = u
                    for (const c of bodyControls(d)) {
                        for (const p of outline(c, u))
                            verify(d.bodyContains(p[0], p[1]),
                                   l.kind + ": " + c.objectName + " leaves the body at " + p[0].toFixed(0) + "," + p[1].toFixed(0))
                    }
                }
            }
        }

        function test_the_body_test_itself_tells_inside_from_outside() {
            const d = make("xbox", "")
            verify(d.bodyContains(550, 300))
            verify(!d.bodyContains(550, 560), "below the centre of the outline")
            verify(!d.bodyContains(10, 300))
            verify(!d.bodyContains(550, 100))
        }

        function test_no_two_body_controls_overlap() {
            for (const l of layouts) {
                const d = make(l.family, l.layout)
                const cs = bodyControls(d)
                for (let i = 0; i < cs.length; ++i) {
                    for (let j = i + 1; j < cs.length; ++j) {
                        const a = cs[i], b = cs[j]
                        const apart = a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.height <= b.y || b.y + b.height <= a.y
                        verify(apart, l.kind + ": " + a.objectName + " overlaps " + b.objectName)
                    }
                }
            }
        }

        function text(d, name) {
            const k = findChild(d, name)
            verify(k, name)
            return k.children.filter(c => c.text !== undefined).map(c => c.text).join("")
        }

        function test_select_start_and_guide_say_the_family_words() {
            const table = [
                ["playstation", "", ["Create", "Options", "Guide", "L2", "R2"]],
                ["xbox", "", ["View", "Menu", "Guide", "LT", "RT"]],
                ["generic", "", ["View", "Menu", "Guide", "LT", "RT"]],
                ["nintendo", "", ["−", "+", "Home", "ZL", "ZR"]],
                ["nintendo", "nintendo-wiiu", ["−", "+", "Home", "ZL", "ZR"]]
            ]
            for (const [family, layout, words] of table) {
                const d = make(family, layout)
                const got = [text(d, "padCtl_select"), text(d, "padCtl_start"), text(d, "padCtl_guide"),
                             text(d, "padCtl_left_trigger"), text(d, "padCtl_right_trigger")]
                compare(got, words, family + "/" + layout)
            }
        }

        function test_the_wii_u_pro_triggers_light_but_their_track_stays_empty() {
            const d = make("nintendo", "nintendo-wiiu")
            d.held = { left_trigger: true }
            d.axes = { left_trigger: 32767 }
            compare(findChild(d, "padCtl_left_trigger").look, "held")
            compare(findChild(d, "padTrackFill_left_trigger").height, 0)
            const x = make("xbox", "")
            x.axes = { left_trigger: 32767 }
            verify(findChild(x, "padTrackFill_left_trigger").height > 0, "an analog trigger fills its track")
        }

        function test_the_wii_u_layout_has_the_dpad_and_the_faces_above_both_sticks() {
            const d = make("nintendo", "nintendo-wiiu")
            const lowest = n => { const c = findChild(d, n); return c.y + c.height }
            const stickTop = Math.min(findChild(d, "padStick_left").y, findChild(d, "padStick_right").y)
            for (const n of ["dpad_up", "dpad_down", "dpad_left", "dpad_right", "north", "south", "east", "west"])
                verify(lowest("padCtl_" + n) <= stickTop + 20 * d.u, n + " is above the sticks")
            const x = make("xbox", "")
            verify(findChild(x, "padCtl_dpad_up").y > findChild(x, "padStick_left").y, "xbox: the D-pad is below the left stick")
        }
    }
}
