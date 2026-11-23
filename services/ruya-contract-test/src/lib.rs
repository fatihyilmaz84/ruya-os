//! Test helper (RUY-403): does the D-Bus interface a service serves match its contract?
//!
//! The contract is `api/dbus/*.xml`; the served interface is what zbus's `#[interface]` macro
//! generates, read without a bus through `Interface::introspect_to_writer`. Both are reduced to
//! the same shape per member and compared:
//!
//! - method: the name and every argument in order, as direction and signature (`in:s`, `out:(su)`)
//! - signal: the name and the signature of every argument in order
//! - property: the name, the type and the access (`read`, `write`, `readwrite`)
//!
//! Argument names, annotations and comments are ignored: the names of the Rust parameters are
//! not the contract's, and an annotation only helps the Qt code generator.
//!
//! A service crate adds this crate as a dev-dependency and has one test, `tests/contract.rs`,
//! that builds each interface object with the crate's own fakes and calls [`assert_serves`].

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::str::FromStr;

use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;
use zbus::object_server::Interface;

/// One interface: its members by kind and name, each with its canonical shape.
pub type Members = BTreeMap<String, String>;

/// The directory of the contract files, `api/dbus` at the repository root.
pub fn contract_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../api/dbus")
}

/// The text of one contract file, e.g. `org.ruyaos.Update1.xml`.
pub fn read_contract(file: &str) -> String {
    let path = contract_dir().join(file);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

/// The introspection XML zbus serves for `iface`, read without a bus.
pub fn served_xml<I: Interface>(iface: &I) -> String {
    let mut out = String::new();
    iface.introspect_to_writer(&mut out, 0);
    out
}

fn attribute(e: &BytesStart<'_>, key: &str) -> Result<Option<String>, String> {
    match e.try_get_attribute(key) {
        Ok(Some(a)) => a
            .unescape_value()
            .map(|v| Some(v.into_owned()))
            .map_err(|err| format!("attribute {key}: {err}")),
        Ok(None) => Ok(None),
        Err(err) => Err(format!("attribute {key}: {err}")),
    }
}

fn required(e: &BytesStart<'_>, key: &str, what: &str) -> Result<String, String> {
    attribute(e, key)?.ok_or_else(|| format!("{what} without {key}"))
}

/// Every interface of an introspection document (a contract file or zbus's output) with its
/// members. The member key is `method Name`, `signal Name` or `property Name`.
pub fn parse(xml: &str) -> Result<BTreeMap<String, Members>, String> {
    let mut interfaces: BTreeMap<String, Members> = BTreeMap::new();
    let mut reader = Reader::from_str(xml);
    let mut interface: Option<String> = None;
    // The method or signal whose `arg` elements are being read: (key, is_signal).
    let mut open: Option<(String, bool)> = None;
    let mut shapes: BTreeMap<(String, String), Vec<String>> = BTreeMap::new();
    let mut errors: Vec<String> = Vec::new();

    loop {
        let event = reader
            .read_event()
            .map_err(|e| format!("XML error at {}: {e}", reader.buffer_position()))?;
        let (e, is_empty) = match &event {
            Event::Start(e) => (Some(e), false),
            Event::Empty(e) => (Some(e), true),
            Event::End(e) => {
                match e.name().as_ref() {
                    b"method" | b"signal" => open = None,
                    b"interface" => interface = None,
                    _ => {}
                }
                (None, false)
            }
            Event::Eof => break,
            _ => (None, false),
        };
        let Some(e) = e else { continue };
        match e.name().as_ref() {
            b"interface" => {
                let name = required(e, "name", "interface")?;
                interfaces.entry(name.clone()).or_default();
                interface = if is_empty { None } else { Some(name) };
            }
            b"method" | b"signal" | b"property" => {
                let Some(iface) = interface.clone() else {
                    return Err("a member outside an interface".to_owned());
                };
                let tag = String::from_utf8_lossy(e.name().as_ref()).into_owned();
                let name = required(e, "name", &tag)?;
                let key = format!("{tag} {name}");
                let members = interfaces.entry(iface.clone()).or_default();
                let shape = if tag == "property" {
                    let ty = required(e, "type", &key)?;
                    let access = required(e, "access", &key)?;
                    format!("{ty} {access}")
                } else {
                    shapes.insert((iface.clone(), key.clone()), Vec::new());
                    if !is_empty {
                        open = Some((key.clone(), tag == "signal"));
                    }
                    String::new()
                };
                if members.insert(key.clone(), shape).is_some() {
                    errors.push(format!("{iface}: {key} is written twice"));
                }
            }
            b"arg" => {
                let (Some(iface), Some((key, is_signal))) = (interface.clone(), open.clone())
                else {
                    continue;
                };
                let ty = required(e, "type", &format!("{key} argument"))?;
                let arg = if is_signal {
                    ty
                } else {
                    // A method argument is "in" unless the file says "out".
                    let dir = attribute(e, "direction")?.unwrap_or_else(|| "in".to_owned());
                    format!("{dir}:{ty}")
                };
                shapes.entry((iface, key)).or_default().push(arg);
            }
            _ => {}
        }
    }
    if !errors.is_empty() {
        return Err(errors.join("\n"));
    }
    for ((iface, key), args) in shapes {
        if let Some(members) = interfaces.get_mut(&iface) {
            members.insert(key, format!("({})", args.join(", ")));
        }
    }
    Ok(interfaces)
}

/// The interface names of one contract file, in file order is not kept: sorted.
pub fn interface_names(xml: &str) -> Result<Vec<String>, String> {
    Ok(parse(xml)?.into_keys().collect())
}

/// The comment that documents each method, signal and property of a contract file: the text of
/// the comment right before the member's element (nothing but whitespace between them), "" for
/// a member without one. Keyed `<interface>.<member>` (RUY-158: the conformance runner reads the
/// statuses each method documents from it).
pub fn member_comments(xml: &str) -> Result<BTreeMap<String, String>, String> {
    let mut comments = BTreeMap::new();
    let mut reader = Reader::from_str(xml);
    let mut interface: Option<String> = None;
    let mut last_comment = String::new();
    loop {
        let event = reader
            .read_event()
            .map_err(|e| format!("XML error at {}: {e}", reader.buffer_position()))?;
        match &event {
            Event::Comment(c) => {
                last_comment = String::from_utf8_lossy(c.as_ref()).into_owned();
                continue;
            }
            Event::Text(t) if t.iter().all(u8::is_ascii_whitespace) => continue,
            Event::Start(e) | Event::Empty(e) => match e.name().as_ref() {
                b"interface" => interface = Some(required(e, "name", "interface")?),
                b"method" | b"signal" | b"property" => {
                    let Some(iface) = interface.as_deref() else {
                        return Err("a member outside an interface".to_owned());
                    };
                    let name = required(e, "name", "member")?;
                    comments.insert(format!("{iface}.{name}"), std::mem::take(&mut last_comment));
                }
                _ => {}
            },
            Event::End(e) if e.name().as_ref() == b"interface" => interface = None,
            Event::Eof => break,
            _ => {}
        }
        // A comment documents only the element right after it.
        last_comment.clear();
    }
    Ok(comments)
}

/// Compares what a service serves for `interface` with the contract's `interface`.
///
/// Every member must be the same on both sides, with the same shape. `not_built` names the
/// contract members the service does not serve yet (a draft contract, e.g. `Input1`): they must
/// really be absent from the served interface, so a member that is built later cannot stay on
/// the list, and each must exist in the contract, so a renamed member cannot hide there.
pub fn compare(
    contract: &str,
    interface: &str,
    served: &str,
    not_built: &[&str],
) -> Result<(), String> {
    let contract = parse(contract).map_err(|e| format!("the contract: {e}"))?;
    let served = parse(served).map_err(|e| format!("the served interface: {e}"))?;
    let Some(want) = contract.get(interface) else {
        return Err(format!("{interface} is not in the contract file"));
    };
    let Some(have) = served.get(interface) else {
        let found: Vec<&String> = served.keys().collect();
        return Err(format!(
            "the service does not serve {interface} (it serves {found:?})"
        ));
    };
    let skipped = |key: &str| not_built.iter().any(|n| key.ends_with(&format!(" {n}")));
    let mut problems: Vec<String> = Vec::new();

    for name in not_built {
        let suffix = format!(" {name}");
        let in_contract = want.keys().any(|k| k.ends_with(&suffix));
        let in_served = have.keys().any(|k| k.ends_with(&suffix));
        if !in_contract {
            problems.push(format!(
                "{name} is listed as not built but is not in the contract"
            ));
        } else if in_served {
            problems.push(format!(
                "{name} is listed as not built but the service serves it: take it off the list"
            ));
        }
    }
    for (key, shape) in want {
        if skipped(key) {
            continue;
        }
        match have.get(key) {
            None => problems.push(format!("{key}: in the contract, not served")),
            Some(served_shape) if served_shape != shape => problems.push(format!(
                "{key}: the contract says {}, the service serves {}",
                show(shape),
                show(served_shape)
            )),
            Some(_) => {}
        }
    }
    for (key, shape) in have {
        if !want.contains_key(key) {
            problems.push(format!(
                "{key}{}: served, not in the contract",
                if shape.is_empty() {
                    String::new()
                } else {
                    format!(" {}", show(shape))
                }
            ));
        }
    }
    if problems.is_empty() {
        Ok(())
    } else {
        Err(format!("{interface}:\n  {}", problems.join("\n  ")))
    }
}

fn show(shape: &str) -> &str {
    if shape.is_empty() {
        "()"
    } else {
        shape
    }
}

/// The test of one served interface: panics, listing every difference, when `iface` does not
/// match `interface` in `file` (an `api/dbus` file name). The interface name is the object's own.
pub fn assert_serves<I: Interface>(file: &str, iface: &I, not_built: &[&str]) {
    let name = I::name();
    if let Err(problems) = compare(
        &read_contract(file),
        name.as_str(),
        &served_xml(iface),
        not_built,
    ) {
        panic!("{file} and the served interface differ.\n{problems}");
    }
}

/// The interfaces of `file` are exactly `tested` (so a new interface in the contract file cannot
/// be left without a test).
pub fn assert_interfaces_are(file: &str, tested: &[&str]) {
    let mut want = interface_names(&read_contract(file)).unwrap_or_else(|e| panic!("{file}: {e}"));
    let mut have: Vec<String> = tested.iter().map(|s| (*s).to_owned()).collect();
    want.sort();
    have.sort();
    assert_eq!(
        have, want,
        "{file}: the interfaces this crate's test covers, and the interfaces of the file"
    );
}

/// One key of an `a{sv}` record: its D-Bus signature and whether it may be absent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordKey {
    pub signature: String,
    pub optional: bool,
}

/// The keys of one record, by name.
pub type Record = BTreeMap<String, RecordKey>;

const RECORD_MARK: &str = " record (a{sv}), ";

/// The block being read by [`parse_records`].
struct OpenBlock {
    name: String,
    heading_indent: usize,
    key_indent: Option<usize>,
    /// The heading says "absent": every key of the block is optional.
    all_optional: bool,
    last_key: Option<String>,
}

/// The `a{sv}` records a contract file documents in its comments (RUY-885), by record name.
///
/// A block is a heading line `<Name> record (a{sv}), keys...` (or `..., extra keys of ...`)
/// followed by lines indented deeper than the heading, one per key: `key  signature  description`.
/// A line indented deeper than the first key line continues the description of the key before it.
/// The block ends at a blank line or at a line not indented deeper than its heading. Blocks of the
/// same name merge. One rule makes a key optional: the word "absent" (the contracts' own words:
/// "Optional keys are absent when unknown"). In a key's description it applies to that key; in a
/// block's heading (`..., extra keys of a .play app (... absent for any other item)`) to every key
/// of the block.
pub fn parse_records(xml: &str) -> Result<BTreeMap<String, Record>, String> {
    let mut records: BTreeMap<String, Record> = BTreeMap::new();
    let mut errors: Vec<String> = Vec::new();
    let mut open: Option<OpenBlock> = None;

    for (n, raw) in xml.lines().enumerate() {
        let line = raw.trim_end().trim_end_matches("-->").trim_end();
        let indent = line.len() - line.trim_start().len();
        if line.trim().is_empty() {
            open = None;
            continue;
        }
        if let Some(at) = line.find(RECORD_MARK) {
            let rest = &line[at + RECORD_MARK.len()..];
            if rest.contains("keys") {
                let name = line[..at].trim().to_owned();
                records.entry(name.clone()).or_default();
                open = Some(OpenBlock {
                    name,
                    heading_indent: indent,
                    key_indent: None,
                    all_optional: rest.to_ascii_lowercase().contains("absent"),
                    last_key: None,
                });
                continue;
            }
        }
        let Some(block) = open.as_mut() else { continue };
        if indent <= block.heading_indent {
            open = None;
            continue;
        }
        let name = block.name.clone();
        let key_indent = *block.key_indent.get_or_insert(indent);
        let words: Vec<&str> = line.split_whitespace().collect();
        let record = records.entry(name.clone()).or_default();
        if indent == key_indent {
            let (Some(key), Some(sig)) = (words.first(), words.get(1)) else {
                errors.push(format!("line {}: {name}: a key without a signature", n + 1));
                continue;
            };
            if zbus::zvariant::Signature::from_str(sig).is_err() {
                errors.push(format!(
                    "line {}: {name}.{key}: unknown signature {sig}",
                    n + 1
                ));
                continue;
            }
            let new = RecordKey {
                signature: (*sig).to_owned(),
                optional: block.all_optional,
            };
            if record.insert((*key).to_owned(), new).is_some() {
                errors.push(format!("line {}: {name}.{key} is written twice", n + 1));
            }
            block.last_key = Some((*key).to_owned());
        }
        if line.to_ascii_lowercase().contains("absent") {
            if let Some(key) = block.last_key.as_ref().and_then(|k| record.get_mut(k)) {
                key.optional = true;
            }
        }
    }
    if errors.is_empty() {
        Ok(records)
    } else {
        Err(errors.join("\n"))
    }
}

/// The problems of one served `a{sv}` record against its contract: `served` is key -> signature.
/// A served key the contract does not list, a different signature and a missing always-present
/// key are each one problem.
pub fn compare_record(want: &Record, served: &BTreeMap<String, String>) -> Vec<String> {
    let mut problems = Vec::new();
    for (key, sig) in served {
        match want.get(key) {
            None => problems.push(format!("{key} ({sig}) is served, not in the contract")),
            Some(k) if &k.signature != sig => problems.push(format!(
                "{key}: the contract says {}, the service serves {sig}",
                k.signature
            )),
            Some(_) => {}
        }
    }
    for (key, k) in want {
        if !k.optional && !served.contains_key(key) {
            problems.push(format!(
                "{key} is always present in the contract, not served"
            ));
        }
    }
    problems
}

/// The key -> signature map of a served `a{sv}` record, the shape `assert_record_served` takes.
pub fn record_signatures<'a, I>(record: I) -> BTreeMap<String, String>
where
    I: IntoIterator<Item = (&'a String, &'a zbus::zvariant::OwnedValue)>,
{
    record
        .into_iter()
        .map(|(k, v)| (k.clone(), v.value_signature().to_string()))
        .collect()
}

/// The test of served records: panics, listing every difference, when a record in `served`
/// (a label and key -> signature) does not match the record `name` of `file`, or when a key of
/// the contract is served by none of them (so the samples must cover every key, optional ones
/// included).
pub fn assert_record_served(file: &str, name: &str, served: &[(&str, BTreeMap<String, String>)]) {
    let records = parse_records(&read_contract(file)).unwrap_or_else(|e| panic!("{file}: {e}"));
    let want = records
        .get(name)
        .unwrap_or_else(|| panic!("{file} has no \"{name} record (a{{sv}})\" block"));
    let mut problems: Vec<String> = Vec::new();
    for (label, record) in served {
        problems.extend(
            compare_record(want, record)
                .into_iter()
                .map(|p| format!("{label}: {p}")),
        );
    }
    for key in want.keys() {
        if !served.iter().any(|(_, r)| r.contains_key(key)) {
            problems.push(format!("{key} is in the contract, no sample serves it"));
        }
    }
    assert!(
        problems.is_empty(),
        "{file}, {name} record, and the served keys differ.\n  {}",
        problems.join("\n  ")
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_comment_documents_only_the_member_right_after_it() {
        let xml = "<node><!-- the node --><interface name=\"a.B\">\n\
                   <!-- \"ok\" for M -->\n<method name=\"M\"><arg type=\"s\"/></method>\n\
                   <method name=\"N\"/>\n<!-- for S --><signal name=\"S\"/>\n\
                   <!-- for P -->\n<annotation name=\"x\" value=\"y\"/>\n<property name=\"P\" type=\"s\" access=\"read\"/>\n\
                   </interface></node>";
        let c = member_comments(xml).expect("parses");
        assert_eq!(c["a.B.M"].trim(), "\"ok\" for M");
        assert_eq!(c["a.B.N"], "");
        assert_eq!(c["a.B.S"].trim(), "for S");
        assert_eq!(c["a.B.P"], "", "an element between them takes the comment");
        assert!(member_comments("<node><method name=\"M\"/></node>").is_err());
    }

    const CONTRACT: &str = r#"<node>
  <!-- a comment with <angle> brackets in a doc -->
  <interface name="org.example.One">
    <method name="Get">
      <annotation name="x" value="y"/>
      <arg name="value" type="(su)" direction="out"/>
    </method>
    <method name="Set">
      <arg name="a" type="s" direction="in"/>
      <arg name="b" type="u"/>
      <arg name="status" type="s" direction="out"/>
    </method>
    <method name="Ping"/>
    <property name="Level" type="u" access="read"/>
    <signal name="Changed">
      <arg name="a" type="s"/>
      <arg name="b" type="a{sv}" direction="out"/>
    </signal>
  </interface>
</node>"#;

    /// What zbus writes: a bare `interface` element, signal arguments with no direction.
    const SERVED: &str = r#" <interface name="org.example.One">
   <method name="Get">
     <arg type="(su)" direction="out"/>
   </method>
   <method name="Set">
     <arg name="a" type="s" direction="in"/>
     <arg name="b" type="u" direction="in"/>
     <arg type="s" direction="out"/>
   </method>
   <method name="Ping">
   </method>
   <property name="Level" type="u" access="read">
     <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="true"/>
   </property>
   <signal name="Changed">
     <arg name="x" type="s"/>
     <arg name="y" type="a{sv}"/>
   </signal>
 </interface>
"#;

    fn check(served: &str) -> Result<(), String> {
        compare(CONTRACT, "org.example.One", served, &[])
    }

    #[test]
    fn the_same_shapes_match_whatever_the_argument_names_and_annotations() {
        assert_eq!(check(SERVED), Ok(()));
    }

    /// RUY-403: T-454, `GetBrightness` served `su` where the contract says `(su)`.
    #[test]
    fn a_changed_return_type_is_a_difference() {
        let served = SERVED.replace(
            r#"<arg type="(su)" direction="out"/>"#,
            r#"<arg type="s" direction="out"/><arg type="u" direction="out"/>"#,
        );
        let err = check(&served).expect_err("differs");
        assert!(err.contains("method Get"), "{err}");
        assert!(err.contains("out:(su)"), "{err}");
    }

    #[test]
    fn a_method_missing_in_the_service_is_a_difference() {
        let served = SERVED.replace("<method name=\"Ping\">\n   </method>\n", "");
        assert_ne!(served, SERVED, "the replace found Ping");
        let err = check(&served).expect_err("differs");
        assert!(
            err.contains("method Ping: in the contract, not served"),
            "{err}"
        );
    }

    #[test]
    fn a_method_missing_in_the_contract_is_a_difference() {
        let contract = CONTRACT.replace("<method name=\"Ping\"/>", "");
        let err = compare(&contract, "org.example.One", SERVED, &[]).expect_err("differs");
        assert!(err.contains("method Ping"), "{err}");
        assert!(err.contains("served, not in the contract"), "{err}");
    }

    #[test]
    fn the_argument_order_and_direction_count() {
        let swapped = SERVED
            .replace(r#"<arg name="a" type="s" direction="in"/>"#, "@")
            .replace(
                r#"<arg name="b" type="u" direction="in"/>"#,
                r#"<arg name="a" type="s" direction="in"/>"#,
            )
            .replace('@', r#"<arg name="b" type="u" direction="in"/>"#);
        assert!(check(&swapped).is_err(), "in:u, in:s is not in:s, in:u");
        let direction = SERVED.replace(
            r#"<arg type="s" direction="out"/>"#,
            r#"<arg type="s" direction="in"/>"#,
        );
        assert!(check(&direction).is_err(), "an out argument served as in");
    }

    #[test]
    fn a_property_type_or_access_and_a_signal_signature_count() {
        assert!(
            check(&SERVED.replace(r#"type="u" access="read""#, r#"type="i" access="read""#))
                .is_err()
        );
        assert!(check(&SERVED.replace(
            r#"type="u" access="read""#,
            r#"type="u" access="readwrite""#
        ))
        .is_err());
        assert!(check(
            &SERVED.replace(r#"<arg name="x" type="s"/>"#, r#"<arg name="x" type="u"/>"#)
        )
        .is_err());
        assert!(
            check(&SERVED.replace("<signal name=\"Changed\">", "<signal name=\"Moved\">")).is_err()
        );
    }

    #[test]
    fn a_member_not_built_yet_is_skipped_and_must_stay_unserved() {
        let served = SERVED.replace("<method name=\"Ping\">\n   </method>\n", "");
        assert_eq!(
            compare(CONTRACT, "org.example.One", &served, &["Ping"]),
            Ok(())
        );
        // Served after all: the list is stale.
        let err = compare(CONTRACT, "org.example.One", SERVED, &["Ping"]).expect_err("stale");
        assert!(err.contains("take it off the list"), "{err}");
        // Not in the contract at all: a typo or a rename hides nothing.
        let err =
            compare(CONTRACT, "org.example.One", &served, &["Pong", "Ping"]).expect_err("typo");
        assert!(
            err.contains("Pong is listed as not built but is not in the contract"),
            "{err}"
        );
    }

    #[test]
    fn a_service_that_serves_another_interface_is_named() {
        let served = SERVED.replace("org.example.One", "org.example.Two");
        let err = check(&served).expect_err("other name");
        assert!(err.contains("does not serve org.example.One"), "{err}");
    }

    #[test]
    fn an_interface_missing_in_the_contract_file_is_named() {
        let err = compare(CONTRACT, "org.example.Nine", SERVED, &[]).expect_err("no such");
        assert!(err.contains("not in the contract file"), "{err}");
    }

    #[test]
    fn a_member_written_twice_is_an_error() {
        let twice = CONTRACT.replace(
            "<method name=\"Ping\"/>",
            "<method name=\"Ping\"/><method name=\"Ping\"/>",
        );
        assert!(parse(&twice).is_err());
    }

    const RECORDS: &str = "<!--
  Thing record (a{sv}), keys:
    id    s    the id
    size  t    bytes; absent when unknown
    tags  as   first line
               continued, deeper
    note  s    last, and
               absent for most

  Thing record (a{sv}), extra keys of a special thing (RUY-0; absent for any other thing):
    extra  b   true
  Other record (a{sv}), keys. Words here
    one  u   1 -->
-->";

    #[test]
    fn record_blocks_give_keys_signatures_and_optional() {
        let r = parse_records(RECORDS).unwrap();
        let thing = &r["Thing"];
        let sig = |k: &str| thing[k].signature.as_str();
        assert_eq!((sig("id"), sig("size"), sig("tags")), ("s", "t", "as"));
        let optional: Vec<&str> = thing
            .iter()
            .filter(|(_, k)| k.optional)
            .map(|(k, _)| k.as_str())
            .collect();
        // A continuation line belongs to the key before it, and "absent" in a heading makes every
        // key of that block optional; "Other"'s heading has no "absent", so `one` stays required.
        assert_eq!(optional, ["extra", "note", "size"]);
        assert_eq!(r["Other"]["one"].signature, "u");
    }

    #[test]
    fn a_record_key_with_a_bad_signature_or_written_twice_is_an_error() {
        let bad = RECORDS.replace("size  t ", "size  z ");
        assert!(parse_records(&bad).unwrap_err().contains("Thing.size"));
        let twice = RECORDS.replace("extra  b", "id     b");
        assert!(parse_records(&twice).unwrap_err().contains("written twice"));
    }

    fn served(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, s)| ((*k).to_owned(), (*s).to_owned()))
            .collect()
    }

    #[test]
    fn a_served_record_must_match_the_documented_keys() {
        let want = &parse_records(RECORDS).unwrap()["Thing"];
        let ok = served(&[("id", "s"), ("tags", "as")]);
        assert!(compare_record(want, &ok).is_empty());
        let extra = served(&[("id", "s"), ("tags", "as"), ("colour", "s")]);
        assert!(compare_record(want, &extra)[0].contains("colour"));
        let missing = served(&[("id", "s")]);
        assert!(compare_record(want, &missing)[0].contains("tags is always present"));
        let wrong = served(&[("id", "s"), ("tags", "s")]);
        assert!(compare_record(want, &wrong)[0].contains("contract says as"));
    }

    /// Every record block of every contract parses, so a service can adopt the check (RUY-885).
    #[test]
    fn every_record_block_of_every_contract_parses() {
        let mut found: Vec<String> = Vec::new();
        for entry in std::fs::read_dir(contract_dir()).unwrap() {
            let name = entry.unwrap().file_name().to_string_lossy().into_owned();
            if name.ends_with(".xml") {
                for (record, keys) in
                    parse_records(&read_contract(&name)).unwrap_or_else(|e| panic!("{name}: {e}"))
                {
                    assert!(!keys.is_empty(), "{name}: {record} has no keys");
                    found.push(format!("{name} {record}"));
                }
            }
        }
        found.sort();
        let short: Vec<&str> = found
            .iter()
            .map(|f| f.trim_start_matches("org.ruyaos."))
            .collect();
        assert_eq!(
            short,
            [
                "Input1.xml Device",
                "Input1.xml Player",
                "Library1.xml Item",
                "Library1.xml Resolution",
                "Library1.xml Runner",
                "Play1.xml Inspect",
                "Play1.xml Job",
                "Session1.xml Day",
                "Session1.xml Running",
                "Session1.xml Session",
                "Store1.xml App"
            ],
            "a new record block is listed here; a missing one is not in the shape the parser reads"
        );
    }
}
