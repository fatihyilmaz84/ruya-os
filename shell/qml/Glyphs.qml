pragma Singleton
import QtQuick

// The one action-to-glyph table (ADR-027, 06 §11.1 and §11.4, 04 §3.7; RUY-41): what `ButtonGlyph`
// draws for an action or a button position, per family. Families: "xbox", "playstation", "nintendo",
// "keyboard" and "generic" (any other pad family, the position diamonds); "" (no press since the shell
// started) draws the Xbox letters, the look before RUY-41, since 04 and 06 name no default.
//
// A glyph is { kind, text, shape, position, name }:
//   kind "text"  - `text` on the primaryFill circle, a pill when it is longer (letters, L1, Enter);
//   kind "shape" - one of our own PlayStation shapes (`shape`: cross, circle, square, triangle);
//   kind "dots"  - four dots in a diamond with the one at `position` filled (the generic set);
//   name         - the words for a screen reader.
// Accept and back follow the Confirm setting (Input1.ConfirmButton: "family" | "south" | "east", 06
// §11.2): the button that confirms is south under "south", east under "east" and, under "family",
// east on a Nintendo pad and south on every other; back is the other one. The keyboard's keys do not
// depend on it. Positions are Input1's button names (south east west north, l1 r1, left_trigger
// right_trigger, l3 r3, dpad_up ..., select start guide; "none"), as GameControls and the Button test
// use them. Vendor artwork never: the shapes are drawn by ButtonGlyph, the rest is letters and words.
QtObject {
    id: glyphs

    // The set a family draws: one of xbox, playstation, nintendo, keyboard, generic.
    function setOf(family) {
        switch (family) {
        case "":
        case "xbox": return "xbox"
        case "playstation":
        case "nintendo":
        case "keyboard": return family
        }
        return "generic"
    }

    // The position that confirms ("south" | "east") for a pad family under a Confirm mode.
    function acceptPosition(family, confirmMode) {
        if (confirmMode === "south" || confirmMode === "east")
            return confirmMode
        return setOf(family) === "nintendo" ? "east" : "south"
    }

    function textGlyph(t, name) { return { kind: "text", text: t, shape: "", position: "", name: name ?? t } }

    // The printed label of a button position on a family's pad (also RUY-500's "Games see [B] as A").
    function glyphForPosition(position, family) {
        const set = setOf(family)
        const face = ["south", "east", "west", "north"].indexOf(position)
        if (face >= 0) {
            if (set === "playstation")
                return { kind: "shape", text: "", shape: ["cross", "circle", "square", "triangle"][face], position: position,
                         name: labelForPosition(position, family) }
            if (set === "generic")
                return { kind: "dots", text: "", shape: "", position: position, name: labelForPosition(position, family) }
            return textGlyph(labelForPosition(position, family))
        }
        const ps = set === "playstation"
        const nin = set === "nintendo"
        switch (position) {
        case "none": return textGlyph("–", qsTr("Nothing"))
        case "l1": return textGlyph(ps ? "L1" : nin ? "L" : "LB")
        case "r1": return textGlyph(ps ? "R1" : nin ? "R" : "RB")
        case "left_trigger": return textGlyph(ps ? "L2" : nin ? "ZL" : "LT")
        case "right_trigger": return textGlyph(ps ? "R2" : nin ? "ZR" : "RT")
        case "l3": return textGlyph(ps ? "L3" : "LS", qsTr("Left stick click"))
        case "r3": return textGlyph(ps ? "R3" : "RS", qsTr("Right stick click"))
        case "dpad_up": return textGlyph("↑", qsTr("Up"))
        case "dpad_down": return textGlyph("↓", qsTr("Down"))
        case "dpad_left": return textGlyph("←", qsTr("Left"))
        case "dpad_right": return textGlyph("→", qsTr("Right"))
        // At most two letters, so they fit a row's icon slot (Controls in games); the words are the names.
        case "select": return ps ? textGlyph("C", qsTr("Create")) : nin ? textGlyph("−", qsTr("Minus")) : textGlyph("V", qsTr("View"))
        case "start": return ps ? textGlyph("O", qsTr("Options")) : nin ? textGlyph("+", qsTr("Plus")) : textGlyph("M", qsTr("Menu"))
        case "guide": return guideGlyph(set)
        }
        return textGlyph(position)
    }

    // The face buttons' printed names: Xbox Y B A X, PlayStation Triangle Circle Cross Square,
    // Nintendo X A B Y, the generic set by place (north east south west).
    function labelForPosition(position, family) {
        const set = setOf(family)
        switch (position) {
        case "south": return set === "playstation" ? qsTr("Cross") : set === "nintendo" ? "B" : set === "generic" ? qsTr("Bottom button") : "A"
        case "east": return set === "playstation" ? qsTr("Circle") : set === "nintendo" ? "A" : set === "generic" ? qsTr("Right button") : "B"
        case "west": return set === "playstation" ? qsTr("Square") : set === "nintendo" ? "Y" : set === "generic" ? qsTr("Left button") : "X"
        case "north": return set === "playstation" ? qsTr("Triangle") : set === "nintendo" ? "X" : set === "generic" ? qsTr("Top button") : "Y"
        }
        return glyphForPosition(position, family).name
    }

    // Guide is the `home` icon for every pad (04 §3.7) once the icon subset has it; until then the word.
    function guideGlyph(set) {
        return set === "keyboard" ? textGlyph("Super") : set === "nintendo" ? textGlyph(qsTr("Home")) : textGlyph(qsTr("Guide"))
    }

    // The glyph of an action (06 §11.1) on the family's device, after the Confirm setting.
    function glyphFor(action, family, confirmMode) {
        const set = setOf(family)
        if (set === "keyboard")
            return keyGlyph(action)
        const ps = set === "playstation"
        const nin = set === "nintendo"
        const acceptAt = acceptPosition(family, confirmMode)
        switch (action) {
        case "accept": return glyphForPosition(acceptAt, family)
        case "back": return glyphForPosition(acceptAt === "east" ? "south" : "east", family)
        case "options":
        case "done": return nin ? textGlyph("+", qsTr("Plus")) : ps ? textGlyph(qsTr("Options")) : textGlyph(qsTr("Menu"))
        case "view": return nin ? textGlyph("−", qsTr("Minus")) : ps ? textGlyph(qsTr("Create")) : textGlyph(qsTr("View"))
        case "guide": return guideGlyph(set)
        case "tabPrev": return glyphForPosition("l1", family)
        case "tabNext": return glyphForPosition("r1", family)
        case "pagePrev": return glyphForPosition("left_trigger", family)
        case "pageNext": return glyphForPosition("right_trigger", family)
        case "up": return glyphForPosition("dpad_up", family)
        case "down": return glyphForPosition("dpad_down", family)
        case "left": return glyphForPosition("dpad_left", family)
        case "right": return glyphForPosition("dpad_right", family)
        case "dpad": return textGlyph(qsTr("D-pad"))
        }
        return textGlyph(action)
    }

    // The shell action a pad input has (06 §11.1), after the Confirm setting: the inverse of glyphFor.
    // "accept" | "back" | "options" | "view" | "guide" | "tabPrev" | "tabNext" | "pagePrev" | "pageNext" |
    // "move" (D-pad, left stick), or "" when the shell does nothing with it. The input is Input1's name.
    function actionFor(input, family, confirmMode) {
        const acceptAt = acceptPosition(family, confirmMode)
        switch (input) {
        case "south":
        case "east": return input === acceptAt ? "accept" : "back"
        case "start": return "options"
        case "select": return "view"
        case "guide": return "guide"
        case "l1": return "tabPrev"
        case "r1": return "tabNext"
        case "left_trigger": return "pagePrev"
        case "right_trigger": return "pageNext"
        case "dpad_up":
        case "dpad_down":
        case "dpad_left":
        case "dpad_right":
        case "left_x":
        case "left_y": return "move"
        }
        return ""
    }

    // Key caps (pills with the key's name): the keys the shell takes for each action.
    function keyGlyph(action) {
        switch (action) {
        case "accept":
        case "done": return textGlyph("Enter")
        case "back": return textGlyph("Esc")
        case "options": return textGlyph("Menu")
        case "view": return textGlyph("Tab")
        case "guide": return guideGlyph("keyboard")
        case "tabPrev": return textGlyph("PgUp", qsTr("Page Up"))
        case "tabNext": return textGlyph("PgDn", qsTr("Page Down"))
        case "pagePrev": return textGlyph("Home")
        case "pageNext": return textGlyph("End")
        case "up": return textGlyph("↑", qsTr("Up"))
        case "down": return textGlyph("↓", qsTr("Down"))
        case "left": return textGlyph("←", qsTr("Left"))
        case "right": return textGlyph("→", qsTr("Right"))
        case "dpad": return textGlyph(qsTr("Arrows"))
        }
        return textGlyph(action)
    }
}
