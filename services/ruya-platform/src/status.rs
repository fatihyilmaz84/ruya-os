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

    #[test]
    fn every_status_is_in_the_contract() {
        let xml = include_str!("../../../api/dbus/org.ruyaos.Platform1.xml");
        for s in Status::ALL {
            assert!(
                xml.contains(&format!("\"{}\"", s.as_str())),
                "{} is not in the XML header",
                s.as_str()
            );
        }
    }
}
