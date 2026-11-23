//! Where capabilities plug into the door: each is `(interface name, capability key, handler)`.
//! The door (`door.rs`) gates every call of an interface by its key (identity, rate, the player's
//! permission) and tells every handler what it must forget (a connection that left, a profile
//! that was removed, a permission turned off). A new capability registers here; the door is not
//! edited. Lifecycle (`lifecycle.rs`) is the first.

use std::any::Any;

use crate::capabilities::valid_capability;

/// A capability's state. The default hooks keep nothing.
pub trait Handler: Any + Send {
    /// The unique bus name `name` left the bus.
    fn name_gone(&mut self, _name: &str) {}
    /// The profile `profile` no longer exists.
    fn profile_gone(&mut self, _profile: &str) {}
    /// The player turned this capability off for `app_id` in `profile`.
    fn withdrawn(&mut self, _profile: &str, _app_id: &str) {}
    fn as_any_mut(&mut self) -> &mut dyn Any;
}

struct Entry {
    interface: &'static str,
    key: &'static str,
    handler: Box<dyn Handler>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistryError {
    /// The interface is registered already.
    Duplicate(&'static str),
    /// Not a capability key (`valid_capability`).
    BadKey(&'static str),
    /// Not an interface of the door (`org.ruyaos.Platform1.<Name>`).
    BadInterface(&'static str),
}

impl std::fmt::Display for RegistryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RegistryError::Duplicate(i) => write!(f, "{i} is registered already"),
            RegistryError::BadKey(k) => write!(f, "{k:?} is not a capability key"),
            RegistryError::BadInterface(i) => write!(f, "{i:?} is not a Platform1 interface"),
        }
    }
}

impl std::error::Error for RegistryError {}

#[derive(Default)]
pub struct Registry {
    entries: Vec<Entry>,
}

impl Registry {
    /// Every capability the service serves, registered: the one list the service and the developer
    /// mock (RUY-158) both start from. A new capability adds its line here.
    pub fn served() -> Result<Registry, RegistryError> {
        let mut registry = Registry::default();
        registry.register(
            crate::lifecycle::INTERFACE,
            crate::lifecycle::KEY,
            Box::<crate::lifecycle::Lifecycle>::default(),
        )?;
        Ok(registry)
    }

    pub fn register(
        &mut self,
        interface: &'static str,
        key: &'static str,
        handler: Box<dyn Handler>,
    ) -> Result<(), RegistryError> {
        let name = interface.strip_prefix("org.ruyaos.Platform1.");
        if !name.is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_alphanumeric())) {
            return Err(RegistryError::BadInterface(interface));
        }
        if !valid_capability(key) {
            return Err(RegistryError::BadKey(key));
        }
        if self.entries.iter().any(|e| e.interface == interface) {
            return Err(RegistryError::Duplicate(interface));
        }
        self.entries.push(Entry {
            interface,
            key,
            handler,
        });
        Ok(())
    }

    /// The capability key that gates `interface`, `None` for an interface nobody registered.
    pub fn key_of(&self, interface: &str) -> Option<&'static str> {
        self.entries
            .iter()
            .find(|e| e.interface == interface)
            .map(|e| e.key)
    }

    /// Is `key` the key of a registered capability?
    pub fn has_key(&self, key: &str) -> bool {
        self.entries.iter().any(|e| e.key == key)
    }

    /// The handler of `interface` as its own type.
    pub fn handler_mut<H: Handler>(&mut self, interface: &str) -> Option<&mut H> {
        self.entries
            .iter_mut()
            .find(|e| e.interface == interface)
            .and_then(|e| e.handler.as_any_mut().downcast_mut::<H>())
    }

    pub(crate) fn name_gone(&mut self, name: &str) {
        for e in &mut self.entries {
            e.handler.name_gone(name);
        }
    }

    pub(crate) fn profile_gone(&mut self, profile: &str) {
        for e in &mut self.entries {
            e.handler.profile_gone(profile);
        }
    }

    pub(crate) fn withdrawn(&mut self, profile: &str, app_id: &str, key: &str) {
        for e in self.entries.iter_mut().filter(|e| e.key == key) {
            e.handler.withdrawn(profile, app_id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Probe {
        seen: Vec<String>,
    }

    impl Handler for Probe {
        fn name_gone(&mut self, name: &str) {
            self.seen.push(format!("gone {name}"));
        }
        fn profile_gone(&mut self, profile: &str) {
            self.seen.push(format!("profile {profile}"));
        }
        fn withdrawn(&mut self, profile: &str, app_id: &str) {
            self.seen.push(format!("withdrawn {profile} {app_id}"));
        }
        fn as_any_mut(&mut self) -> &mut dyn Any {
            self
        }
    }

    #[derive(Default)]
    struct Quiet;

    impl Handler for Quiet {
        fn as_any_mut(&mut self) -> &mut dyn Any {
            self
        }
    }

    #[test]
    fn a_capability_plugs_in_by_interface_and_key() {
        let mut r = Registry::default();
        r.register(
            "org.ruyaos.Platform1.Probe",
            "probe",
            Box::<Probe>::default(),
        )
        .expect("registers");
        r.register("org.ruyaos.Platform1.Quiet", "quiet", Box::new(Quiet))
            .expect("registers");
        assert_eq!(r.key_of("org.ruyaos.Platform1.Probe"), Some("probe"));
        assert_eq!(r.key_of("org.ruyaos.Platform1.Other"), None);
        assert!(r.has_key("quiet") && !r.has_key("other"));
        r.name_gone(":1.5");
        r.profile_gone("p2");
        r.withdrawn("p1", "org.x.App", "probe");
        r.withdrawn("p1", "org.x.App", "quiet");
        let probe = r
            .handler_mut::<Probe>("org.ruyaos.Platform1.Probe")
            .expect("typed access");
        assert_eq!(
            probe.seen,
            ["gone :1.5", "profile p2", "withdrawn p1 org.x.App"]
        );
        assert!(
            r.handler_mut::<Probe>("org.ruyaos.Platform1.Quiet")
                .is_none(),
            "another type"
        );
    }

    #[test]
    fn bad_registrations_are_refused() {
        let mut r = Registry::default();
        r.register(
            "org.ruyaos.Platform1.Probe",
            "probe",
            Box::<Probe>::default(),
        )
        .expect("registers");
        assert_eq!(
            r.register("org.ruyaos.Platform1.Probe", "other", Box::new(Quiet)),
            Err(RegistryError::Duplicate("org.ruyaos.Platform1.Probe"))
        );
        assert_eq!(
            r.register("org.ruyaos.Platform1.Q", "Bad Key", Box::new(Quiet)),
            Err(RegistryError::BadKey("Bad Key"))
        );
        for bad in [
            "org.ruyaos.Profiles1",
            "org.ruyaos.Platform1.",
            "org.ruyaos.Platform1.A.B",
        ] {
            assert_eq!(
                r.register(bad, "x", Box::new(Quiet)),
                Err(RegistryError::BadInterface(bad))
            );
        }
    }
}
