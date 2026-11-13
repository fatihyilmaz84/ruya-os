#!/usr/bin/env python3
"""Game settings schema check (RUY-406, ADR-035). Standard library only.

  1. api/settings/game-settings.schema.json is valid JSON and every keyword it uses is one this checker
     implements (so a new keyword cannot slip in unchecked);
  2. the sample (samples/game-settings-example/settings.json), the shell's mock game
     (shell/src/gamesettings/mock-game-settings.json) and the example in the developer chapter
     (docs/developers/game-settings.md) pass the schema, and the chapter's example IS the sample;
  3. the schema refuses what it is meant to refuse (bad id, unknown type or category, 33 options, 201
     settings, a bidi override, a label of 41 characters, an unknown key, a wrong version, ...).

The checks that JSON Schema cannot express (a default outside min..max, a visibleWhen cycle, a file
over 64 KiB, duplicate ids) are the shell loader's and are tested in shell/tests/tst_game_settings_schema.qml.

  python -I scripts/check-game-settings-schema.py [repo]
Exit code 0 = clean, 1 = findings.
"""
import copy
import json
import re
import sys
from pathlib import Path

KEYWORDS = {
    "$schema", "$defs", "$ref", "title", "description", "type", "const", "enum", "properties", "required",
    "additionalProperties", "patternProperties", "items", "minItems", "maxItems", "minLength", "maxLength",
    "pattern", "minimum", "maximum", "exclusiveMinimum", "maxProperties", "oneOf",
}


def unknown_keywords(node, path="#"):
    """Keywords in the schema that validate() does not implement."""
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key in ("properties", "patternProperties", "$defs"):
                for name, sub in value.items():
                    found += unknown_keywords(sub, f"{path}/{key}/{name}")
            elif key in KEYWORDS:
                if key in ("items", "additionalProperties") and isinstance(value, dict):
                    found += unknown_keywords(value, f"{path}/{key}")
                elif key == "oneOf":
                    for i, sub in enumerate(value):
                        found += unknown_keywords(sub, f"{path}/oneOf/{i}")
            else:
                found.append(f"{path}: keyword {key!r}")
    return found


def json_type_ok(value, name):
    if name == "string":
        return isinstance(value, str)
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        return (isinstance(value, int) and not isinstance(value, bool)) or (isinstance(value, float) and value.is_integer())
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "object":
        return isinstance(value, dict)
    if name == "array":
        return isinstance(value, list)
    raise ValueError(f"unknown type {name}")


def ecma(pattern):
    """JSON Schema patterns are ECMA 262: `$` is the end of the text, not before a final newline."""
    return pattern[:-1] + r"\Z" if pattern.endswith("$") else pattern


def validate(value, schema, root, path="$"):
    """Returns a list of problems (empty: valid)."""
    if "$ref" in schema:
        ref = schema["$ref"]
        assert ref.startswith("#/$defs/"), ref
        problems = validate(value, root["$defs"][ref[len("#/$defs/"):]], root, path)
        rest = {k: v for k, v in schema.items() if k != "$ref"}
        return problems + (validate(value, rest, root, path) if rest else [])
    problems = []
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(json_type_ok(value, n) for n in names):
            return [f"{path}: not of type {names}"]
    if "const" in schema and (value != schema["const"] or type(value) is not type(schema["const"])):
        problems.append(f"{path}: not {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        problems.append(f"{path}: {value!r} is not one of {schema['enum']}")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            problems.append(f"{path}: shorter than {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            problems.append(f"{path}: longer than {schema['maxLength']}")
        if "pattern" in schema and not re.search(ecma(schema["pattern"]), value):
            problems.append(f"{path}: does not match {schema['pattern']}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            problems.append(f"{path}: below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            problems.append(f"{path}: above {schema['maximum']}")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            problems.append(f"{path}: not above {schema['exclusiveMinimum']}")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            problems.append(f"{path}: fewer than {schema['minItems']} items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            problems.append(f"{path}: more than {schema['maxItems']} items")
        if "items" in schema:
            for i, item in enumerate(value):
                problems += validate(item, schema["items"], root, f"{path}[{i}]")
    if isinstance(value, dict):
        if "maxProperties" in schema and len(value) > schema["maxProperties"]:
            problems.append(f"{path}: more than {schema['maxProperties']} keys")
        for key in schema.get("required", []):
            if key not in value:
                problems.append(f"{path}: {key!r} is missing")
        props = schema.get("properties", {})
        patterns = schema.get("patternProperties", {})
        for key, sub in value.items():
            matched = False
            if key in props:
                matched = True
                problems += validate(sub, props[key], root, f"{path}.{key}")
            for pattern, psub in patterns.items():
                if re.search(ecma(pattern), key):
                    matched = True
                    problems += validate(sub, psub, root, f"{path}.{key}")
            if not matched and schema.get("additionalProperties", True) is False:
                problems.append(f"{path}: unexpected key {key!r}")
    if "oneOf" in schema:
        passing = [i for i, sub in enumerate(schema["oneOf"]) if not validate(value, sub, root, path)]
        if len(passing) != 1:
            problems.append(f"{path}: matches {len(passing)} of the oneOf alternatives (needs exactly 1)")
    return problems


def chapter_examples(text):
    """The JSON blocks of the chapter that look like a settings file."""
    out = []
    for block in re.findall(r"```json\n(.*?)\n```", text, re.S):
        try:
            data = json.loads(block)
        except ValueError:
            continue
        if isinstance(data, dict) and "settings" in data:
            out.append(data)
    return out


def main(repo):
    problems = []
    schema_path = repo / "api" / "settings" / "game-settings.schema.json"
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    for item in unknown_keywords(schema):
        problems.append(f"schema uses a keyword the checker does not know: {item}")

    def must_pass(name, data):
        for p in validate(data, schema, schema):
            problems.append(f"{name}: {p}")

    sample = json.loads((repo / "samples" / "game-settings-example" / "settings.json").read_text(encoding="utf-8"))
    must_pass("samples/game-settings-example/settings.json", sample)
    mock = json.loads((repo / "shell" / "src" / "gamesettings" / "mock-game-settings.json").read_text(encoding="utf-8"))
    must_pass("shell/src/gamesettings/mock-game-settings.json", mock)

    chapter = repo / "docs" / "developers" / "game-settings.md"
    examples = chapter_examples(chapter.read_text(encoding="utf-8")) if chapter.exists() else []
    if not examples:
        problems.append("docs/developers/game-settings.md has no complete settings example (a ```json block)")
    for i, example in enumerate(examples):
        must_pass(f"docs/developers/game-settings.md example {i + 1}", example)
    if examples and examples[0] != sample:
        problems.append("the first example in docs/developers/game-settings.md differs from samples/game-settings-example/settings.json")

    # The schema must refuse these. Each case changes one thing in a file that is valid.
    def with_setting(index, change):
        data = copy.deepcopy(sample)
        change(data["settings"][index])
        return data

    def set_key(key, value):
        return lambda s: s.__setitem__(key, value)

    def drop_key(key):
        return lambda s: s.pop(key)

    first = 0  # an enum
    shadows = 1  # a bool
    distance = 2  # an int with a unit and visibleWhen
    sensitivity = 4  # a float
    action = 5
    many = copy.deepcopy(sample)
    many["settings"] = [dict(sample["settings"][1], id=f"s{i}") for i in range(201)]
    exactly = copy.deepcopy(sample)
    exactly["settings"] = [dict(sample["settings"][1], id=f"s{i}") for i in range(200)]
    wrong_version = dict(copy.deepcopy(sample), version=2)
    extra_top = dict(copy.deepcopy(sample), notes="x")
    refused = {
        "an id with a capital": with_setting(shadows, set_key("id", "Shadows")),
        "an id of 65 characters": with_setting(shadows, set_key("id", "a" * 65)),
        "an unknown type": with_setting(shadows, set_key("type", "slider")),
        "an unknown category": with_setting(shadows, set_key("category", "cheats")),
        "a missing category": with_setting(shadows, drop_key("category")),
        "a label of 41 characters": with_setting(shadows, set_key("label", "x" * 41)),
        "a description of 161 characters": with_setting(shadows, set_key("description", "x" * 161)),
        "a bidi override in a label": with_setting(shadows, set_key("label", "Shadows ‮")),
        "a zero-width space in a label": with_setting(shadows, set_key("label", "Sha\u200bdows")),
        "a zero-width joiner in a label": with_setting(shadows, set_key("label", "Sha\u200ddows")),
        "a word joiner in a label": with_setting(shadows, set_key("label", "Sha\u2060dows")),
        "a byte order mark in a label": with_setting(shadows, set_key("label", "\ufeffShadows")),
        "a soft hyphen in a label": with_setting(shadows, set_key("label", "Sha\u00addows")),
        "a Hangul filler as the whole label": with_setting(shadows, set_key("label", "\u3164")),
        "a halfwidth Hangul filler in a label": with_setting(shadows, set_key("label", "A\uffa0B")),
        "a label of spaces only": with_setting(shadows, set_key("label", "   ")),
        "a label of a no-break space only": with_setting(shadows, set_key("label", "\u00a0\u3000")),
        "four combining marks in a row": with_setting(shadows, set_key("label", "e\u0301\u0302\u0303\u0304")),
        "an invisible character in a unit": with_setting(distance, set_key("unit", "m\u200b")),
        "an invisible character in a translation": with_setting(shadows, set_key("label", {"en": "Shadows", "tr": "G\u200bolgeler"})),
        "a control character in a label": with_setting(shadows, set_key("label", "Sha\ndows")),
        "a localised label with no en": with_setting(shadows, set_key("label", {"tr": "Gölgeler"})),
        "a language key that is not a code": with_setting(shadows, set_key("label", {"en": "Shadows", "Turkish": "Gölgeler"})),
        "an unknown key": with_setting(shadows, set_key("script", "alert(1)")),
        "a string default for a bool": with_setting(shadows, set_key("default", "yes")),
        "a bool with options": with_setting(shadows, set_key("options", [])),
        "33 enum options": with_setting(first, set_key("options", [{"value": f"o{i}", "label": "x"} for i in range(33)])),
        "no enum options": with_setting(first, set_key("options", [])),
        "an option value with a space": with_setting(first, set_key("options", [{"value": "a b", "label": "x"}])),
        "an int default that is not whole": with_setting(distance, set_key("default", 50.5)),
        "an int with no min": with_setting(distance, drop_key("min")),
        "a step of 0": with_setting(distance, set_key("step", 0)),
        "a unit of 17 characters": with_setting(distance, set_key("unit", "u" * 17)),
        "a float step of 0": with_setting(sensitivity, set_key("step", 0)),
        "a default on an action": with_setting(action, set_key("default", True)),
        "a visibleWhen with an expression": with_setting(distance, set_key("visibleWhen", {"id": "graphics.shadows", "equals": True, "and": 1})),
        "a visibleWhen with no equals": with_setting(distance, set_key("visibleWhen", {"id": "graphics.shadows"})),
        "restart that is not a bool": with_setting(shadows, set_key("restart", "yes")),
        "201 settings": many,
        "a version other than 1": wrong_version,
        "an unknown top-level key": extra_top,
        "no settings": dict(copy.deepcopy(sample), settings=[]),
    }
    for name, data in refused.items():
        if not validate(data, schema, schema):
            problems.append(f"the schema accepts {name}")
    three_marks = with_setting(shadows, set_key("label", "e\u0301\u0302\u0303 and Gölgeler \u0131\u0307"))
    if validate(three_marks, schema, schema):
        problems.append("the schema refuses three combining marks in a row, or a plain accented text")
    if validate(exactly, schema, schema):
        problems.append("the schema refuses a file of exactly 200 settings")

    for p in problems:
        print("FAIL:", p)
    if not problems:
        print(f"game settings schema: sample, mock, chapter example OK; {len(refused)} refusals hold")
    return 1 if problems else 0


if __name__ == "__main__":
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    sys.exit(main(root.resolve()))
