//! What the contract documents: the status strings of the XML header ("Status strings are stable
//! API:") and, per method, the statuses its comment names. A case's expected status and the
//! target's answer must both be documented for the element, so neither the runner nor the
//! service can drift from the XML unseen. (The stability tags are read once, by
//! `scripts/lint-dev-docs.ps1` into apis.json; this reads only comments.)

use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Default)]
pub struct Docs {
    statuses: BTreeSet<String>,
    /// "<interface>.<member>" -> the header statuses its comment names.
    by_element: BTreeMap<String, BTreeSet<String>>,
}

/// Every `"..."` in `text`.
fn quoted(text: &str) -> impl Iterator<Item = &str> {
    text.split('"').skip(1).step_by(2)
}

/// The value of `attr="..."` in a tag's text.
fn attribute<'a>(tag: &'a str, attr: &str) -> Option<&'a str> {
    let start = tag.find(&format!("{attr}=\""))? + attr.len() + 2;
    let len = tag[start..].find('"')?;
    Some(&tag[start..start + len])
}

impl Docs {
    pub fn parse(xml: &str) -> Result<Docs, String> {
        let header = xml
            .split("Status strings are stable API:")
            .nth(1)
            .ok_or("the XML has no \"Status strings are stable API:\" block")?;
        let statuses: BTreeSet<String> = header
            .lines()
            .skip(1)
            .map(str::trim_start)
            .take_while(|l| !l.starts_with("-->"))
            .filter_map(|l| l.strip_prefix('"')?.split('"').next())
            .map(str::to_owned)
            .collect();
        if statuses.is_empty() {
            return Err("the XML's status block lists no status".into());
        }
        let mut docs = Docs {
            statuses,
            by_element: BTreeMap::new(),
        };
        let mut interface = "";
        let mut comment = "";
        let mut rest = xml;
        while let Some(at) = rest.find('<') {
            rest = &rest[at..];
            if let Some(body) = rest.strip_prefix("<!--") {
                let end = body.find("-->").ok_or("an unclosed comment")?;
                comment = &body[..end];
                rest = &body[end + 3..];
                continue;
            }
            let end = rest.find('>').ok_or("an unclosed tag")?;
            let tag = &rest[..=end];
            rest = &rest[end + 1..];
            if tag.starts_with("<interface ") {
                interface = attribute(tag, "name").unwrap_or("");
            } else if tag.starts_with("<method ") || tag.starts_with("<signal ") {
                if let Some(member) = attribute(tag, "name") {
                    let named = quoted(comment)
                        .filter(|s| docs.statuses.contains(*s))
                        .map(str::to_owned)
                        .collect();
                    docs.by_element
                        .insert(format!("{interface}.{member}"), named);
                }
            }
            // A comment documents only the element right after it.
            if !tag.starts_with("<!") && !tag.starts_with("<?") {
                comment = "";
            }
        }
        Ok(docs)
    }

    /// Whether `status` is documented for `element` ("<interface>.<member>").
    pub fn allows(&self, element: &str, status: &str) -> bool {
        self.by_element
            .get(element)
            .is_some_and(|s| s.contains(status))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIFECYCLE: &str = "org.ruyaos.Platform1.Lifecycle";
    const MANAGE: &str = "org.ruyaos.Platform1.Manage";

    fn real() -> Docs {
        Docs::parse(include_str!(
            "../../../../../api/dbus/org.ruyaos.Platform1.xml"
        ))
        .expect("the contract parses")
    }

    #[test]
    fn the_header_statuses_are_the_services() {
        let docs = real();
        let want: BTreeSet<String> = [
            "ok",
            "not-an-app",
            "not-allowed",
            "rate-limited",
            "invalid-argument",
            "not-registered",
            "saved",
            "timeout",
            "failed",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
        assert_eq!(docs.statuses, want);
    }

    #[test]
    fn each_method_has_its_own_statuses() {
        let docs = real();
        let register = format!("{LIFECYCLE}.Register");
        for s in ["ok", "not-an-app", "not-allowed", "rate-limited"] {
            assert!(docs.allows(&register, s), "Register {s}");
        }
        assert!(!docs.allows(&register, "not-registered"));
        assert!(!docs.allows(&register, "saved"));
        let save = format!("{LIFECYCLE}.SaveDone");
        for s in [
            "ok",
            "not-an-app",
            "not-allowed",
            "not-registered",
            "rate-limited",
        ] {
            assert!(docs.allows(&save, s), "SaveDone {s}");
        }
        let notify = format!("{MANAGE}.NotifyLifecycle");
        for s in [
            "ok",
            "saved",
            "timeout",
            "not-registered",
            "invalid-argument",
        ] {
            assert!(docs.allows(&notify, s), "NotifyLifecycle {s}");
        }
        // Event names are quoted in its comment too, but they are no statuses.
        assert!(!docs.allows(&notify, "stopping"));
        assert!(!docs.allows("org.ruyaos.Platform1.Lifecycle.Missing", "ok"));
    }

    #[test]
    fn a_comment_documents_only_the_next_element() {
        let xml = "<!--\n  Status strings are stable API:\n    \"ok\" fine\n    \"bad\" no\n-->\n\
                   <node><interface name=\"a.B\">\n<!-- \"ok\" -->\n<method name=\"M\"/>\n\
                   <method name=\"N\"/>\n<!-- \"bad\" \"other\" -->\n<signal name=\"S\"/>\n\
                   </interface></node>";
        let docs = Docs::parse(xml).expect("parses");
        assert!(docs.allows("a.B.M", "ok"));
        assert!(!docs.allows("a.B.N", "ok"));
        assert!(docs.allows("a.B.S", "bad"));
        assert!(!docs.allows("a.B.S", "other"), "not a header status");
        assert!(Docs::parse("<node/>").is_err());
    }
}
