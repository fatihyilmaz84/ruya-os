//! The status strings of `api/dbus/org.ruyaos.Platform1.xml` (stable API).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok,
    NotAnApp,
    NotAllowed,
    RateLimited,
    InvalidArgument,
    NotRegistered,
    Failed,
}

impl Status {
    pub fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::NotAnApp => "not-an-app",
            Status::NotAllowed => "not-allowed",
            Status::RateLimited => "rate-limited",
            Status::InvalidArgument => "invalid-argument",
            Status::NotRegistered => "not-registered",
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
        for s in [
            Status::Ok,
            Status::NotAnApp,
            Status::NotAllowed,
            Status::RateLimited,
            Status::InvalidArgument,
            Status::NotRegistered,
            Status::Failed,
        ] {
            assert!(
                xml.contains(&format!("\"{}\"", s.as_str())),
                "{} is not in the XML header",
                s.as_str()
            );
        }
    }
}
