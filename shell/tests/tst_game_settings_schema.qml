import QtQuick
import QtTest
import RuyaShell

// The game settings file (RUY-406, ADR-035, docs/developers/game-settings.md) is UNTRUSTED INPUT from
// an app: a game ships /app/share/ruya/settings.json and the shell validates it. These are the trust
// boundary's tests: each refused case has its own test and fails if its check is removed, and a refused
// file always gives one error and no model at all (never a partial one).
TestCase {
    id: tc
    name: "GameSettingsSchema"
    when: windowShown

    function init() {
        verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
    }

    // ---- helpers (top level: qmllint stops checking a file with a local in a nested function)
    function row(extra) {
        return Object.assign({ id: "a", label: "A", type: "bool", category: "graphics", default: true }, extra)
    }
    function file(rows) {
        return { version: 1, settings: rows }
    }
    function parse(obj, language) {
        return GameSettings.parse(JSON.stringify(obj), language || "en")
    }
    function samplePath() {
        const url = Qt.resolvedUrl("../../samples/game-settings-example/settings.json").toString()
        return url.replace(/^file:\/\/\/([A-Za-z]:)/, "$1").replace(/^file:\/\//, "")
    }
    function many(n, extra) {
        const rows = []
        for (let i = 0; i < n; ++i)
            rows.push(row(Object.assign({ id: "s" + i }, extra || {})))
        return file(rows)
    }
    function options(n) {
        const list = []
        for (let i = 0; i < n; ++i)
            list.push({ value: "o" + i, label: "Option " + i })
        return list
    }
    // The file is refused with a message that names `fragment`, and nothing of it is kept.
    function refused(result, fragment, what) {
        verify(!result.ok, what + ": a broken file was accepted")
        verify(result.error.length > 0, what + ": no error message")
        verify(result.error.indexOf(fragment) >= 0, what + ": the message '" + result.error + "' lacks '" + fragment + "'")
        compare(result.categories.length, 0, what + ": a partial model was kept")
        compare(result.count, 0, what + ": rows were counted for a broken file")
    }
    function accepted(result, what) {
        verify(result.ok, what + ": " + result.error)
        compare(result.error, "")
    }
    function rowsOf(result) {
        const out = []
        for (const c of result.categories)
            for (const r of c.rows)
                out.push(r)
        return out
    }
    function rowById(result, id) {
        for (const r of rowsOf(result))
            if (r.id === id)
                return r
        return null
    }
    function types(result) {
        const seen = {}
        for (const r of rowsOf(result))
            seen[r.type] = true
        return Object.keys(seen).sort()
    }

    // ---- the files that must load
    function test_the_example_loads_with_every_type() {
        const r = GameSettings.load(samplePath(), "en")
        accepted(r, "the chapter's example")
        compare(r.count, 7)
        compare(types(r).join(","), "action,bool,enum,float,info,int")
        compare(r.categories.map(c => c.id).join(","), "graphics,controls,advanced", "categories in the fixed order, only those with rows")
        const distance = rowById(r, "graphics.shadow_distance")
        compare(distance.min, 10)
        compare(distance.max, 100)
        compare(distance.step, 10)
        compare(distance.unit, "m")
        compare(distance.visibleWhen.id, "graphics.shadows")
        compare(distance.visibleWhen.equals, true)
        compare(rowById(r, "graphics.textures").restart, true)
        compare(rowById(r, "graphics.shadows").restart, false)
        compare(rowById(r, "graphics.quality").options.length, 2)
        compare(rowById(r, "controls.recalibrate").type, "action")
        compare(rowById(r, "advanced.version").default, "1.0.0")
    }

    function test_the_mock_game_ships_a_file_with_every_feature() {
        compare(GameSettings.mockGameId, "org.example.Racer")
        const r = GameSettings.forApp(GameSettings.mockGameId, "en")
        accepted(r, "the mock game")
        verify(r.present)
        compare(types(r).join(","), "action,bool,enum,float,info,int")
        compare(r.count, 18)
        compare(r.categories.map(c => c.id).join(","), GameSettings.categoryOrder.join(","), "the mock uses every category, in order")
        verify(rowsOf(r).some(x => x.visibleWhen.id !== undefined), "a visibleWhen")
        verify(rowsOf(r).some(x => x.restart), "a restart setting")
    }

    function test_the_mock_game_values_fit_its_file() {
        const r = GameSettings.forApp(GameSettings.mockGameId, "en")
        const values = GameSettings.mockValues()
        for (const x of rowsOf(r)) {
            if (x.type === "action") {
                verify(values[x.id] === undefined, x.id + ": an action has no value")
                continue
            }
            verify(values[x.id] !== undefined, x.id + ": no published value")
            const v = values[x.id]
            if (x.type === "bool")
                compare(typeof v, "boolean", x.id)
            else if (x.type === "enum")
                verify(x.options.some(o => o.value === v), x.id + ": " + v + " is not an option")
            else if (x.type === "int" || x.type === "float")
                verify(v >= x.min && v <= x.max, x.id + ": " + v + " is outside " + x.min + ".." + x.max)
            else
                compare(typeof v, "string", x.id)
        }
        for (const id of Object.keys(values))
            verify(rowById(r, id) !== null, id + ": a value for a setting the file does not have")
    }

    function test_a_game_without_a_file_has_no_entry() {
        const r = GameSettings.forApp("org.example.Puzzle", "en")
        verify(!r.present)
        verify(!r.ok)
        compare(r.error, "", "no file is not an error")
        compare(r.categories.length, 0)
        verify(!GameSettings.load("Z:/no/such/settings.json", "en").present)
    }

    function test_exactly_the_limits_are_accepted() {
        accepted(parse(many(GameSettings.maxSettings)), "200 settings")
        accepted(parse(file([row({ type: "enum", default: "o0", options: options(GameSettings.maxOptions) })])), "32 options")
        accepted(parse(file([row({ label: "x".repeat(GameSettings.maxLabel), description: "y".repeat(GameSettings.maxDescription) })])), "label 40, description 160")
        accepted(parse(file([row({ id: "a".repeat(64) })])), "an id of 64 characters")
        const text = JSON.stringify(file([row({})]))
        accepted(GameSettings.parse(text + " ".repeat(GameSettings.maxFileBytes - text.length), "en"), "a file of exactly 64 KiB")
    }

    // ---- the abuse cases: one test each
    function test_refused_a_file_over_64_KiB() {
        const text = JSON.stringify(file([row({})]))
        refused(GameSettings.parse(text + " ".repeat(GameSettings.maxFileBytes - text.length + 1), "en"), "at most 65536", "65537 bytes")
    }

    function test_refused_201_settings() {
        refused(parse(many(GameSettings.maxSettings + 1)), "201 settings", "201 settings")
    }

    function test_refused_33_enum_options() {
        refused(parse(file([row({ type: "enum", default: "o0", options: options(GameSettings.maxOptions + 1) })])), "33 options", "33 options")
    }

    function test_refused_a_bad_id() {
        refused(parse(file([row({ id: "Shadows" })])), "\"id\" must be", "a capital")
        refused(parse(file([row({ id: "a".repeat(65) })])), "\"id\" must be", "65 characters")
        refused(parse(file([row({ id: "" })])), "\"id\" must be", "empty")
        refused(parse(file([row({ id: "a b" })])), "\"id\" must be", "a space")
        refused(parse(file([row({ id: "../x" })])), "\"id\" must be", "a path")
        refused(parse(file([row({ id: 7 })])), "\"id\" must be", "a number")
    }

    function test_refused_a_duplicate_id() {
        refused(parse(file([row({ id: "x" }), row({ id: "x" })])), "used twice", "two rows with one id")
    }

    function test_refused_an_unknown_type() {
        refused(parse(file([row({ type: "slider" })])), "unknown type \"slider\"", "slider")
        refused(parse(file([row({ type: undefined })])), "\"type\" is missing", "no type")
    }

    function test_refused_an_unknown_category() {
        refused(parse(file([row({ category: "cheats" })])), "unknown category \"cheats\"", "cheats")
        refused(parse(file([row({ category: "Graphics" })])), "unknown category", "a capital")
        refused(parse(file([row({ category: undefined })])), "\"category\" is missing", "no category")
    }

    function test_refused_a_default_outside_min_and_max() {
        const whole = { type: "int", min: 0, max: 100 }
        refused(parse(file([row(Object.assign({ default: 101 }, whole))])), "default 101 is outside 0..100", "above")
        refused(parse(file([row(Object.assign({ default: -1 }, whole))])), "default -1 is outside 0..100", "below")
        refused(parse(file([row({ type: "float", min: 0, max: 1, default: 1.5 })])), "default 1.5 is outside 0..1", "a float")
        refused(parse(file([row(Object.assign({ default: 5.5 }, whole))])), "whole number", "a fraction for an int")
        refused(parse(file([row(Object.assign({ default: "5" }, whole))])), "\"default\" must be", "text for an int")
        refused(parse(file([row({ type: "int", default: 1, min: 5, max: 5 })])), "must be below", "min equal to max")
        refused(parse(file([row({ type: "int", default: 1, min: 0, max: 10, step: 0 })])), "\"step\"", "a step of 0")
        refused(parse(file([row({ type: "int", default: 1, min: 0, max: 10, step: 11 })])), "\"step\"", "a step over max - min")
        refused(parse(file([row({ type: "int", default: 1, min: 0, max: 3000000000 })])), "\"max\" must be a whole number", "beyond 32 bits")
        refused(parse(file([row({ type: "enum", default: "zz", options: options(3) })])), "one of the options", "an enum default that is not an option")
    }

    function test_refused_a_visibleWhen_cycle() {
        refused(parse(file([row({ id: "a", visibleWhen: { id: "b", equals: true } }),
                            row({ id: "b", visibleWhen: { id: "a", equals: true } })])), "forms a cycle", "a to b to a")
        refused(parse(file([row({ id: "a", visibleWhen: { id: "b", equals: true } }),
                            row({ id: "b", visibleWhen: { id: "c", equals: true } }),
                            row({ id: "c", visibleWhen: { id: "a", equals: true } })])), "forms a cycle", "a to b to c to a")
        refused(parse(file([row({ id: "a", visibleWhen: { id: "a", equals: true } })])), "the setting itself", "itself")
    }

    function test_refused_a_visibleWhen_that_cannot_work() {
        refused(parse(file([row({ visibleWhen: { id: "nothing", equals: true } })])), "not in the file", "a missing id")
        refused(parse(file([row({ id: "a" }), row({ id: "b", type: "action", default: undefined })
                            , row({ id: "c", visibleWhen: { id: "b", equals: true } })])), "an action", "an action as the target")
        refused(parse(file([row({ id: "a" }), row({ id: "c", visibleWhen: { id: "a", equals: "yes" } })])), "does not fit", "text for a bool")
        refused(parse(file([row({ id: "a", type: "enum", default: "o0", options: options(2) }),
                            row({ id: "c", visibleWhen: { id: "a", equals: "o9" } })])), "does not fit", "a value that is no option")
        refused(parse(file([row({ id: "a" }), row({ id: "c", visibleWhen: { id: "a", equals: true, and: 1 } })])), "no expressions", "an expression")
        refused(parse(file([row({ id: "a" }), row({ id: "c", visibleWhen: { id: "a" } })])), "needs an \"id\" and an \"equals\"", "no equals")
    }

    function test_refused_a_bidi_override_in_a_label() {
        refused(parse(file([row({ label: "Shadows \u202e" })])), "bidirectional", "an override")
        refused(parse(file([row({ label: "\u2066Shadows" })])), "bidirectional", "an isolate")
        refused(parse(file([row({ label: "Shadows\u200f" })])), "bidirectional", "a right-to-left mark")
        // written as an escape in the JSON text: it is the decoded character that is checked
        refused(GameSettings.parse("{\"version\":1,\"settings\":[{\"id\":\"a\",\"label\":\"Sha\\u202edows\",\"type\":\"bool\",\"category\":\"graphics\",\"default\":true}]}", "en"),
                "bidirectional", "an escaped override")
    }

    function test_refused_bidi_and_control_characters_wherever_text_is() {
        refused(parse(file([row({ description: "x\u202ey" })])), "\"description\"", "in a description")
        refused(parse(file([row({ type: "enum", default: "o0", options: [{ value: "o0", label: "a\u202eb" }] })])), "option 0", "in an option label")
        refused(parse(file([row({ label: { en: "A", tr: "b\u202ec" } })])), "(tr)", "in a translation")
        refused(parse(file([row({ type: "int", default: 1, min: 0, max: 2, unit: "f\u202ep" })])), "\"unit\"", "in a unit")
        refused(parse(file([row({ type: "info", default: "1\u202e0" })])), "\"default\"", "in an info text")
        refused(parse(file([row({ label: "Line\nbreak" })])), "control", "a line break")
        refused(parse(file([row({ label: "Tab\there" })])), "control", "a tab")
        refused(parse(file([row({ label: "Null\u0000byte" })])), "control", "a null")
        refused(parse(file([row({ label: "Sep\u2028arator" })])), "control", "a line separator")
    }

    function test_refused_a_label_or_description_too_long() {
        refused(parse(file([row({ label: "x".repeat(41) })])), "longer than 40", "label 41")
        refused(parse(file([row({ description: "x".repeat(161) })])), "longer than 160", "description 161")
        refused(parse(file([row({ label: { en: "A", tr: "x".repeat(41) } })])), "longer than 40", "a translation of 41")
        refused(parse(file([row({ label: "" })])), "is empty", "an empty label")
        refused(parse(file([row({ label: undefined })])), "\"label\" is missing", "no label")
    }

    function test_refused_an_unknown_key() {
        refused(parse(file([row({ script: "alert(1)" })])), "no key \"script\"", "on a setting")
        refused(parse(file([row({ type: "bool", min: 0 })])), "no key \"min\"", "a number key on a bool")
        refused(parse(file([row({ type: "action", default: true })])), "no key \"default\"", "a default on an action")
        refused(GameSettings.parse(JSON.stringify({ version: 1, settings: [row({})], include: "/etc/passwd" }), "en"), "unknown top-level key", "at the top")
    }

    function test_refused_text_that_is_not_json_or_not_a_file() {
        refused(GameSettings.parse("{ not json", "en"), "not valid JSON", "broken JSON")
        refused(GameSettings.parse("[]", "en"), "must be a JSON object", "a list")
        refused(GameSettings.parse("", "en"), "not valid JSON", "nothing")
        refused(parse({ version: 1, settings: [] }), "empty", "no settings")
        refused(parse({ version: 1 }), "\"settings\"", "no list")
        refused(parse({ version: 1, settings: [5] }), "is not an object", "a number as a setting")
    }

    function test_refused_a_version_other_than_1() {
        refused(parse({ version: 2, settings: [row({})] }), "unsupported \"version\" 2", "version 2")
        refused(parse({ version: "1", settings: [row({})] }), "\"version\" is missing", "version as text")
        refused(parse({ settings: [row({})] }), "\"version\" is missing", "no version")
    }

    function test_refused_bytes_that_are_not_utf8() {
        const bytes = new Uint8Array([0x7b, 0x22, 0xff, 0xfe, 0x22, 0x7d])
        refused(GameSettings.parseBytes(bytes.buffer, "en"), "not valid UTF-8", "0xFF 0xFE")
        // an overlong encoding of "/" (C0 AF) is invalid UTF-8 too
        refused(GameSettings.parseBytes(new Uint8Array([0x7b, 0xc0, 0xaf, 0x7d]).buffer, "en"), "not valid UTF-8", "an overlong encoding")
    }

    function test_refused_a_bad_enum_option() {
        refused(parse(file([row({ type: "enum", default: "a", options: [] })])), "\"options\" is empty", "no options")
        refused(parse(file([row({ type: "enum", default: "a" })])), "needs \"options\"", "options missing")
        refused(parse(file([row({ type: "enum", default: "a b", options: [{ value: "a b", label: "x" }] })])), "\"value\" must be", "a space in a value")
        refused(parse(file([row({ type: "enum", default: "a", options: [{ value: "a", label: "x" }, { value: "a", label: "y" }] })])), "listed twice", "a repeated value")
        refused(parse(file([row({ type: "enum", default: "a", options: [{ value: "a" }] })])), "\"label\" is missing", "an option without a label")
    }

    function test_refused_restart_that_is_not_a_bool() {
        refused(parse(file([row({ restart: "yes" })])), "\"restart\"", "restart as text")
    }

    function test_a_broken_second_row_keeps_no_first_row() {
        const r = parse(file([row({ id: "good" }), row({ id: "bad", category: "nope" })]))
        refused(r, "settings[1]", "the second row is broken")
        verify(r.error.indexOf("\"bad\"") >= 0, "the message names the setting: " + r.error)
    }

    // ---- languages
    function localised() {
        return file([
            row({ id: "q", label: { en: "Quality", tr: "Kalite" }, description: { en: "Detail", tr: "Ayrıntı" },
                    type: "enum", default: "hi", options: [{ value: "hi", label: { en: "High", tr: "Yüksek" } },
                                                         { value: "ult", label: { en: "Ultra" } }] }),
            row({ id: "plain", label: "Plain" }),
        ])
    }

    function test_a_tr_profile_gets_the_tr_texts() {
        const r = parse(localised(), "tr")
        accepted(r, "tr")
        const q = rowById(r, "q")
        compare(q.label, "Kalite")
        compare(q.description, "Ayrıntı")
        compare(q.options[0].label, "Yüksek")
    }

    function test_a_missing_tr_falls_back_to_en() {
        const r = parse(localised(), "tr")
        compare(rowById(r, "q").options[1].label, "Ultra", "an option with no tr")
        compare(rowById(r, "plain").label, "Plain", "a plain string is every language's")
    }

    function test_the_language_is_matched_loosely_and_defaults_to_en() {
        compare(rowById(parse(localised(), "tr_TR.UTF-8"), "q").label, "Kalite")
        compare(rowById(parse(localised(), "TR-tr"), "q").label, "Kalite")
        compare(rowById(parse(localised(), "de"), "q").label, "Quality")
        compare(rowById(parse(localised(), ""), "q").label, "Quality")
        compare(rowById(parse(localised(), "en"), "q").label, "Quality")
        compare(rowById(parse(file([row({ label: { en: "Base", "pt-br": "Brasil", pt: "Portugal" } })]), "pt-BR"), "a").label, "Brasil")
        compare(rowById(parse(file([row({ label: { en: "Base", pt: "Portugal" } })]), "pt-BR"), "a").label, "Portugal", "the region falls back to the language")
    }

    function test_the_mock_game_in_turkish() {
        const r = GameSettings.forApp(GameSettings.mockGameId, "tr")
        accepted(r, "mock in tr")
        compare(rowById(r, "graphics.preset").label, "Kalite ayarı")
        compare(rowById(r, "graphics.raytracing").label, "Ray tracing", "a row with a plain label")
        compare(rowById(r, "graphics.preset").options[3].label, "Ultra", "an option with no tr")
    }

    function test_refused_text_by_language_without_en() {
        refused(parse(file([row({ label: { tr: "Gölgeler" } })]), "tr"), "no \"en\" text", "a translation without en, asked in tr")
        refused(parse(file([row({ label: { tr: "Gölgeler" } })])), "no \"en\" text", "a translation without en, asked in en")
        refused(parse(file([row({ label: { en: "A", Turkish: "B" } })])), "language code", "a key that is not a code")
        const many17 = { en: "A" }
        for (let i = 0; i < 16; ++i)
            many17["x" + String.fromCharCode(97 + i) + "a"] = "B"
        refused(parse(file([row({ label: many17 })])), "more than 16 languages", "17 languages")
    }

    // ---- the model
    function test_categories_are_in_the_fixed_order_with_rows_in_file_order() {
        const r = parse(file([row({ id: "z", category: "advanced" }), row({ id: "y", category: "audio" }),
                              row({ id: "x", category: "graphics" }), row({ id: "w", category: "audio" })]))
        accepted(r, "order")
        compare(r.categories.map(c => c.id).join(","), "graphics,audio,advanced")
        compare(r.categories[1].rows.map(x => x.id).join(","), "y,w", "file order inside a category")
        compare(GameSettings.categoryOrder.join(","), "graphics,display,controls,audio,gameplay,interface,accessibility,advanced")
    }

    function test_defaults_of_the_optional_keys() {
        const r = parse(file([row({ id: "i", type: "int", default: 3, min: 0, max: 10 }),
                              row({ id: "f", type: "float", default: 0.5, min: 0, max: 2 }),
                              row({ id: "n", type: "info", default: undefined })]))
        accepted(r, "optional keys")
        compare(rowById(r, "i").step, 1)
        compare(rowById(r, "i").unit, "")
        compare(rowById(r, "f").step, 0.02)
        compare(rowById(r, "a"), null)
        compare(rowById(r, "n").default, "")
        compare(rowById(r, "i").description, "")
        compare(Object.keys(rowById(r, "i").visibleWhen).length, 0)
    }
}
