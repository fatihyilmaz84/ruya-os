//! A profile's notification settings (the properties of org.ruyaos.Notifications1): defaults,
//! validation and which properties differ between two profiles' settings. Pure, no I/O.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Quiet mode on a schedule: local "HH:MM" in the console's time zone (`to` may be before
/// `from`: over midnight). The shell evaluates it; the service only keeps it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuietHours {
    pub enabled: bool,
    pub from: String,
    pub to: String,
}

impl Default for QuietHours {
    fn default() -> Self {
        QuietHours {
            enabled: false,
            from: "22:00".to_owned(),
            to: "07:00".to_owned(),
        }
    }
}

/// One profile's settings. Defaults as in the XML. Missing fields in a stored file read as their
/// default, so a file written by an older service still opens.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub quiet: bool,
    pub dont_interrupt_games: bool,
    pub quiet_hours: QuietHours,
    pub toast_seconds: u32,
    pub sounds: bool,
    /// source ("system", "updates", "devices", "store" or "app:<app id>") -> on. A source that is
    /// not listed is on.
    pub sources_enabled: BTreeMap<String, bool>,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            quiet: false,
            dont_interrupt_games: true,
            quiet_hours: QuietHours::default(),
            toast_seconds: 4,
            sounds: true,
            sources_enabled: BTreeMap::new(),
        }
    }
}

pub const TOAST_SECONDS_MIN: u32 = 2;
pub const TOAST_SECONDS_MAX: u32 = 15;

/// The properties, by their D-Bus name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Property {
    Quiet,
    DontInterruptGames,
    QuietHours,
    ToastSeconds,
    Sounds,
    SourcesEnabled,
}

impl Property {
    pub const ALL: [Property; 6] = [
        Property::Quiet,
        Property::DontInterruptGames,
        Property::QuietHours,
        Property::ToastSeconds,
        Property::Sounds,
        Property::SourcesEnabled,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Property::Quiet => "Quiet",
            Property::DontInterruptGames => "DontInterruptGames",
            Property::QuietHours => "QuietHours",
            Property::ToastSeconds => "ToastSeconds",
            Property::Sounds => "Sounds",
            Property::SourcesEnabled => "SourcesEnabled",
        }
    }
}

/// One write of a property.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Change {
    Quiet(bool),
    DontInterruptGames(bool),
    QuietHours(QuietHours),
    ToastSeconds(u32),
    Sounds(bool),
    SourcesEnabled(BTreeMap<String, bool>),
}

/// "HH:MM", 00:00 to 23:59 (the mock's rule).
pub fn valid_clock(text: &str) -> bool {
    let b = text.as_bytes();
    if b.len() != 5
        || b[2] != b':'
        || !b
            .iter()
            .enumerate()
            .all(|(i, c)| i == 2 || c.is_ascii_digit())
    {
        return false;
    }
    let hours = u32::from(b[0] - b'0') * 10 + u32::from(b[1] - b'0');
    let minutes = u32::from(b[3] - b'0') * 10 + u32::from(b[4] - b'0');
    hours < 24 && minutes < 60
}

impl Settings {
    /// Applies a write, or refuses it (nothing changes) when the value is out of range.
    pub fn apply(&mut self, change: Change) -> Result<(), &'static str> {
        match change {
            Change::Quiet(v) => self.quiet = v,
            Change::DontInterruptGames(v) => self.dont_interrupt_games = v,
            Change::Sounds(v) => self.sounds = v,
            Change::ToastSeconds(v) => {
                if !(TOAST_SECONDS_MIN..=TOAST_SECONDS_MAX).contains(&v) {
                    return Err("ToastSeconds must be 2..15");
                }
                self.toast_seconds = v;
            }
            Change::QuietHours(q) => {
                if !valid_clock(&q.from) || !valid_clock(&q.to) {
                    return Err("QuietHours needs \"HH:MM\" for both times");
                }
                self.quiet_hours = q;
            }
            Change::SourcesEnabled(map) => self.sources_enabled = map,
        }
        Ok(())
    }

    /// Is an item of this source kept? `app_id` matters for source "app" only ("app:<app id>").
    pub fn source_enabled(&self, source: &str, app_id: &str) -> bool {
        let key = if source == "app" {
            format!("app:{app_id}")
        } else {
            source.to_owned()
        };
        self.sources_enabled.get(&key).copied().unwrap_or(true)
    }

    /// The properties whose value differs between `self` and `other`.
    pub fn differing(&self, other: &Settings) -> Vec<Property> {
        Property::ALL
            .into_iter()
            .filter(|p| match p {
                Property::Quiet => self.quiet != other.quiet,
                Property::DontInterruptGames => {
                    self.dont_interrupt_games != other.dont_interrupt_games
                }
                Property::QuietHours => self.quiet_hours != other.quiet_hours,
                Property::ToastSeconds => self.toast_seconds != other.toast_seconds,
                Property::Sounds => self.sounds != other.sounds,
                Property::SourcesEnabled => self.sources_enabled != other.sources_enabled,
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_the_contracts() {
        let s = Settings::default();
        assert!(!s.quiet);
        assert!(s.dont_interrupt_games);
        assert_eq!(
            s.quiet_hours,
            QuietHours {
                enabled: false,
                from: "22:00".into(),
                to: "07:00".into()
            }
        );
        assert_eq!(s.toast_seconds, 4);
        assert!(s.sounds);
        assert!(s.sources_enabled.is_empty());
    }

    #[test]
    fn toast_seconds_must_be_2_to_15() {
        let mut s = Settings::default();
        assert!(s.apply(Change::ToastSeconds(1)).is_err());
        assert!(s.apply(Change::ToastSeconds(16)).is_err());
        assert_eq!(s.toast_seconds, 4, "a refused write changes nothing");
        assert!(s.apply(Change::ToastSeconds(2)).is_ok());
        assert!(s.apply(Change::ToastSeconds(15)).is_ok());
        assert_eq!(s.toast_seconds, 15);
    }

    #[test]
    fn quiet_hours_need_hh_mm_for_both_fields() {
        let mut s = Settings::default();
        for (from, to) in [
            ("7:00", "08:00"),
            ("22:00", "24:00"),
            ("22:60", "07:00"),
            ("", "07:00"),
            ("22:00", "07-00"),
            ("22:00 ", "07:00"),
        ] {
            let q = QuietHours {
                enabled: true,
                from: from.into(),
                to: to.into(),
            };
            assert!(
                s.apply(Change::QuietHours(q)).is_err(),
                "{from}-{to} must be refused"
            );
        }
        assert_eq!(s.quiet_hours, QuietHours::default());
        let q = QuietHours {
            enabled: true,
            from: "23:30".into(),
            to: "00:00".into(),
        };
        assert!(s.apply(Change::QuietHours(q.clone())).is_ok());
        assert_eq!(s.quiet_hours, q);
    }

    #[test]
    fn an_unlisted_source_is_on_and_apps_are_keyed_by_id() {
        let mut s = Settings::default();
        assert!(s.source_enabled("updates", ""));
        let mut map = BTreeMap::new();
        map.insert("updates".to_owned(), false);
        map.insert("app:org.example.Game".to_owned(), false);
        map.insert("store".to_owned(), true);
        s.apply(Change::SourcesEnabled(map)).unwrap();
        assert!(!s.source_enabled("updates", ""));
        assert!(s.source_enabled("store", ""));
        assert!(s.source_enabled("system", ""));
        assert!(!s.source_enabled("app", "org.example.Game"));
        assert!(s.source_enabled("app", "org.example.Other"));
    }

    #[test]
    fn differing_names_exactly_the_changed_properties() {
        let a = Settings::default();
        let mut b = Settings::default();
        assert!(a.differing(&b).is_empty());
        b.quiet = true;
        b.toast_seconds = 9;
        assert_eq!(
            a.differing(&b),
            vec![Property::Quiet, Property::ToastSeconds]
        );
    }

    #[test]
    fn a_stored_file_without_some_fields_reads_their_defaults() {
        let s: Settings = serde_json::from_str(r#"{"quiet":true}"#).unwrap();
        assert!(s.quiet);
        assert_eq!(s.toast_seconds, 4);
        assert!(s.dont_interrupt_games);
    }
}
