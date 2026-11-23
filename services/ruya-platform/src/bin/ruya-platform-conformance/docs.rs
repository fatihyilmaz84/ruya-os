//! What the contract documents per element: the statuses (`Status::ALL`, the service's own list,
//! whose every string `status.rs` checks against the XML header) that the comment of each method
//! names. A case's expected status and the target's answer must both be documented for the
//! element, so neither the runner nor the service can drift from the XML unseen. The XML is read
//! with the one contract reader, `ruya_contract_test::member_comments`; the stability tags are
//! read only by `scripts/lint-dev-docs.ps1` (into apis.json).

use std::collections::{BTreeMap, BTreeSet};

use ruya_platform::Status;

#[derive(Debug, Default)]
pub struct Docs {
    /// "<interface>.<member>" -> the statuses its comment names.
    by_element: BTreeMap<String, BTreeSet<&'static str>>,
}

/// Every `"..."` in `text`.
fn quoted(text: &str) -> impl Iterator<Item = &str> {
    text.split('"').skip(1).step_by(2)
}

impl Docs {
    pub fn parse(xml: &str) -> Result<Docs, String> {
        let comments = ruya_contract_test::member_comments(xml)?;
        let by_element = comments
            .into_iter()
            .map(|(element, comment)| {
                let named = Status::ALL
                    .iter()
                    .map(|s| s.as_str())
                    .filter(|s| quoted(&comment).any(|q| q == *s))
                    .collect();
                (element, named)
            })
            .collect();
        Ok(Docs { by_element })
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
    fn each_method_has_its_own_statuses() {
        let docs = real();
        let register = format!("{LIFECYCLE}.Register");
        for s in [
            Status::Ok,
            Status::NotAnApp,
            Status::NotAllowed,
            Status::RateLimited,
        ] {
            assert!(docs.allows(&register, s.as_str()), "Register {s:?}");
        }
        assert!(!docs.allows(&register, Status::NotRegistered.as_str()));
        assert!(!docs.allows(&register, Status::Saved.as_str()));
        let save = format!("{LIFECYCLE}.SaveDone");
        for s in [
            Status::Ok,
            Status::NotAnApp,
            Status::NotAllowed,
            Status::NotRegistered,
            Status::RateLimited,
        ] {
            assert!(docs.allows(&save, s.as_str()), "SaveDone {s:?}");
        }
        let notify = format!("{MANAGE}.NotifyLifecycle");
        for s in [
            Status::Ok,
            Status::Saved,
            Status::Timeout,
            Status::NotRegistered,
            Status::InvalidArgument,
        ] {
            assert!(docs.allows(&notify, s.as_str()), "NotifyLifecycle {s:?}");
        }
        // Event names are quoted in its comment too, but they are no statuses.
        assert!(!docs.allows(&notify, "stopping"));
        assert!(!docs.allows("org.ruyaos.Platform1.Lifecycle.Missing", "ok"));
    }

    #[test]
    fn only_the_comment_of_the_element_counts() {
        let xml = "<node><interface name=\"a.B\">\n<!-- \"ok\" -->\n<method name=\"M\"/>\n\
                   <method name=\"N\"/>\n<!-- \"failed\" \"other\" -->\n<signal name=\"S\"/>\n\
                   </interface></node>";
        let docs = Docs::parse(xml).expect("parses");
        assert!(docs.allows("a.B.M", "ok"));
        assert!(!docs.allows("a.B.N", "ok"));
        assert!(docs.allows("a.B.S", "failed"));
        assert!(!docs.allows("a.B.S", "other"), "not a status");
        assert!(Docs::parse("<node><method name=\"M\"/></node>").is_err());
    }
}
