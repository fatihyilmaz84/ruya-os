//! The status strings of `api/dbus/org.ruyaos.Platform1.xml` (stable API).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    NotAnApp,
    NotAllowed,
    RateLimited,
    InvalidArgument,
    NotRegistered,
    Saved,
    Timeout,
    Failed,
}

impl Status {
    /// Every status, in the order of the XML header.
    pub const ALL: [Status; 9] = [
        Status::Ok,
        Status::NotAnApp,
        Status::NotAllowed,
        Status::RateLimited,
        Status::InvalidArgument,
        Status::NotRegistered,
        Status::Saved,
        Status::Timeout,
        Status::Failed,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::NotAnApp => "not-an-app",
            Status::NotAllowed => "not-allowed",
            Status::RateLimited => "rate-limited",
            Status::InvalidArgument => "invalid-argument",
            Status::NotRegistered => "not-registered",
            Status::Saved => "saved",
            Status::Timeout => "timeout",
            Status::Failed => "failed",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Status;
    use std::collections::BTreeSet;

    const LIST_START: &str = "Status strings are stable API:";

    /// The statuses the XML header lists: from the `LIST_START` line to the closing `-->`, each
    /// entry is a line `    "<status>"   <description>` (four spaces, then the quote); the
    /// continuation lines of a description are indented further and quote other words freely.
    fn documented_statuses(header: &str) -> BTreeSet<String> {
        let list = header
            .split_once(LIST_START)
            .unwrap_or_else(|| panic!("the XML has no \"{LIST_START}\" list"))
            .1;
        let list = list.split_once("-->").map_or(list, |(list, _)| list);
        list.lines()
            .filter_map(|line| line.strip_prefix("    \""))
            .filter_map(|rest| rest.split_once('"'))
            .map(|(status, _)| status.to_owned())
            .collect()
    }

    /// One message per status that only one side knows; empty when both lists agree.
    fn status_drift(header: &str, all: &[Status]) -> Vec<String> {
        let documented = documented_statuses(header);
        let known: BTreeSet<String> = all.iter().map(|s| s.as_str().to_owned()).collect();
        let missing = known
            .difference(&documented)
            .map(|s| format!("\"{s}\" is in Status::ALL but not in the XML header list"));
        let unknown = documented
            .difference(&known)
            .map(|s| format!("\"{s}\" is in the XML header list but not in Status::ALL"));
        missing.chain(unknown).collect()
    }

    #[test]
    fn every_status_is_in_the_contract() {
        let xml = include_str!("../../../api/dbus/org.ruyaos.Platform1.xml");
        let drift = status_drift(xml, &Status::ALL);
        assert!(drift.is_empty(), "{}", drift.join("; "));
    }

    const HEADER: &str = r#"<!--
  Status strings are stable API:
    "ok"                success
    "not-an-app"        the caller is not an app; a waiting "stopping" is another thing
                        "register" quoted in a continuation line
    "saved"             done
-->
<node>
  <!-- "method-comment" is outside the list -->
</node>"#;

    #[test]
    fn only_the_entries_of_the_list_are_read() {
        let got: Vec<String> = documented_statuses(HEADER).into_iter().collect();
        assert_eq!(got, ["not-an-app", "ok", "saved"]);
    }

    #[test]
    fn a_status_missing_from_the_header_is_named() {
        let drift = status_drift(
            HEADER,
            &[Status::Ok, Status::NotAnApp, Status::Saved, Status::Failed],
        );
        assert_eq!(
            drift,
            ["\"failed\" is in Status::ALL but not in the XML header list"]
        );
    }

    #[test]
    fn a_status_missing_from_status_all_is_named() {
        let drift = status_drift(HEADER, &[Status::Ok, Status::NotAnApp]);
        assert_eq!(
            drift,
            ["\"saved\" is in the XML header list but not in Status::ALL"]
        );
    }

    #[test]
    fn equal_lists_have_no_drift() {
        assert!(status_drift(HEADER, &[Status::Saved, Status::Ok, Status::NotAnApp]).is_empty());
    }
}
