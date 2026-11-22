//! The one reader of the GKeyFile subset RuyaOS files use (RUY-1050, ADR-043): `[Group]` headers,
//! `key=value` lines, `#` comment lines and blank lines. No locales (`Name[de]` is an ordinary key
//! name), no escapes, no continuation lines. The reader refuses what it cannot read exactly: a
//! line that is none of the above, a duplicate group or key, a text over `MAX_BYTES`.
//!
//! What a key means is the caller's: the app table refuses a key it does not know
//! (`Group::only_keys`), Flatpak metadata readers just ask for the keys they want.

/// The size cap of a keyfile text. Image tables and Flatpak metadata are far below it.
pub const MAX_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyfileError {
    TooLarge,
    /// A line that is not a group, a `key=value`, a comment or blank (1-based line number).
    Syntax(usize),
    /// A `key=value` before any group header.
    KeyOutsideGroup(usize),
    DuplicateGroup(String),
    DuplicateKey(String, String),
}

impl std::fmt::Display for KeyfileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            KeyfileError::TooLarge => write!(f, "larger than {MAX_BYTES} bytes"),
            KeyfileError::Syntax(n) => {
                write!(f, "line {n} is not a group, a key=value or a comment")
            }
            KeyfileError::KeyOutsideGroup(n) => write!(f, "line {n} is a key before any [group]"),
            KeyfileError::DuplicateGroup(g) => write!(f, "group [{g}] appears twice"),
            KeyfileError::DuplicateKey(g, k) => write!(f, "key {k} appears twice in [{g}]"),
        }
    }
}

impl std::error::Error for KeyfileError {}

/// One `[Group]`: its keys in file order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
    pub name: String,
    entries: Vec<(String, String)>,
}

impl Group {
    /// The value of `key`, if the group has it.
    pub fn get(&self, key: &str) -> Option<&str> {
        self.entries
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }

    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.entries.iter().map(|(k, _)| k.as_str())
    }

    /// The first key that is not in `known`, for a table that refuses what it does not know.
    pub fn unknown_key(&self, known: &[&str]) -> Option<&str> {
        self.keys().find(|k| !known.contains(k))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Keyfile {
    groups: Vec<Group>,
}

impl Keyfile {
    pub fn parse(text: &str) -> Result<Keyfile, KeyfileError> {
        if text.len() > MAX_BYTES {
            return Err(KeyfileError::TooLarge);
        }
        let mut groups: Vec<Group> = Vec::new();
        for (index, raw) in text.lines().enumerate() {
            let number = index + 1;
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(rest) = line.strip_prefix('[') {
                let name = rest
                    .strip_suffix(']')
                    .filter(|n| !n.is_empty() && !n.contains(['[', ']']))
                    .ok_or(KeyfileError::Syntax(number))?;
                if groups.iter().any(|g| g.name == name) {
                    return Err(KeyfileError::DuplicateGroup(name.to_owned()));
                }
                groups.push(Group {
                    name: name.to_owned(),
                    entries: Vec::new(),
                });
                continue;
            }
            let (key, value) = line.split_once('=').ok_or(KeyfileError::Syntax(number))?;
            let key = key.trim();
            if key.is_empty() {
                return Err(KeyfileError::Syntax(number));
            }
            let group = groups
                .last_mut()
                .ok_or(KeyfileError::KeyOutsideGroup(number))?;
            if group.get(key).is_some() {
                return Err(KeyfileError::DuplicateKey(
                    group.name.clone(),
                    key.to_owned(),
                ));
            }
            group
                .entries
                .push((key.to_owned(), value.trim().to_owned()));
        }
        Ok(Keyfile { groups })
    }

    pub fn group(&self, name: &str) -> Option<&Group> {
        self.groups.iter().find(|g| g.name == name)
    }

    /// The value of `key` in `group`.
    pub fn get(&self, group: &str, key: &str) -> Option<&str> {
        self.group(group).and_then(|g| g.get(key))
    }

    pub fn groups(&self) -> &[Group] {
        &self.groups
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_keys_comments_and_blank_lines_are_read() {
        let kf = Keyfile::parse(
            "# top comment\n\n[App]\nargs = -a -b  \n# inside\nname[de]=Wert\n\n[Other]\nx=1=2\n",
        )
        .expect("parses");
        assert_eq!(kf.groups().len(), 2);
        assert_eq!(kf.get("App", "args"), Some("-a -b"));
        // No locales: the bracket is part of the key name.
        assert_eq!(kf.get("App", "name[de]"), Some("Wert"));
        // The first `=` splits.
        assert_eq!(kf.get("Other", "x"), Some("1=2"));
        assert_eq!(kf.get("App", "x"), None);
        assert!(kf.group("Missing").is_none());
        assert_eq!(kf.group("App").expect("group").keys().count(), 2);
        assert!(Keyfile::parse("").expect("empty").groups().is_empty());
    }

    #[test]
    fn what_cannot_be_read_exactly_is_refused() {
        assert_eq!(
            Keyfile::parse("a=1\n"),
            Err(KeyfileError::KeyOutsideGroup(1))
        );
        assert_eq!(
            Keyfile::parse("[G]\nnonsense\n"),
            Err(KeyfileError::Syntax(2))
        );
        assert_eq!(Keyfile::parse("[G\n"), Err(KeyfileError::Syntax(1)));
        assert_eq!(Keyfile::parse("[]\n"), Err(KeyfileError::Syntax(1)));
        assert_eq!(Keyfile::parse("[G]\n=v\n"), Err(KeyfileError::Syntax(2)));
    }

    #[test]
    fn a_duplicate_key_or_group_is_refused() {
        assert_eq!(
            Keyfile::parse("[G]\na=1\na=2\n"),
            Err(KeyfileError::DuplicateKey("G".into(), "a".into()))
        );
        // The same key in two groups is fine.
        assert!(Keyfile::parse("[G]\na=1\n[H]\na=2\n").is_ok());
        assert_eq!(
            Keyfile::parse("[G]\n[G]\n"),
            Err(KeyfileError::DuplicateGroup("G".into()))
        );
    }

    #[test]
    fn the_size_cap_is_enforced() {
        let at_cap = format!("[G]\nk={}\n", "x".repeat(MAX_BYTES - 7));
        assert_eq!(at_cap.len(), MAX_BYTES);
        assert!(Keyfile::parse(&at_cap).is_ok());
        let over = format!("{at_cap}#\n");
        assert_eq!(Keyfile::parse(&over), Err(KeyfileError::TooLarge));
    }

    #[test]
    fn unknown_keys_are_reported_for_a_table_that_refuses_them() {
        let kf = Keyfile::parse("[G]\na=1\nb=2\n").expect("parses");
        let g = kf.group("G").expect("group");
        assert_eq!(g.unknown_key(&["a", "b"]), None);
        assert_eq!(g.unknown_key(&["a"]), Some("b"));
    }
}
