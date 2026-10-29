//! org.ruyaos.Profiles1 on D-Bus. Thin adapter: all rules live in `service.rs`.

use std::time::{Duration, Instant};

use zbus::interface;
use zbus::object_server::SignalEmitter;

use crate::accounts::Accounts;
use crate::service::ProfileService;

/// Chosen at runtime: real Unix users on the system bus, none in `--session` dev mode.
pub type DynAccounts = Box<dyn Accounts + Send + Sync>;

pub const BUS_NAME: &str = "org.ruyaos.Profiles1";
pub const OBJECT_PATH: &str = "/org/ruyaos/Profiles1";

/// Whole seconds for the wire, rounded up so the shell never shows "retry in 0 s" while the
/// profile is still locked.
fn retry_secs(retry_after: Duration) -> u32 {
    let secs = retry_after.as_secs() + u64::from(retry_after.subsec_nanos() > 0);
    secs.min(u64::from(u32::MAX)) as u32
}

pub struct ProfilesIface {
    svc: ProfileService<DynAccounts>,
}

impl ProfilesIface {
    pub fn new(svc: ProfileService<DynAccounts>) -> Self {
        ProfilesIface { svc }
    }
}

#[interface(name = "org.ruyaos.Profiles1")]
impl ProfilesIface {
    fn list_profiles(&self) -> Vec<(String, String, String, String, bool)> {
        self.svc
            .profiles()
            .iter()
            .map(|p| {
                (
                    p.id.clone(),
                    p.name.clone(),
                    p.avatar.clone(),
                    p.role.as_str().to_owned(),
                    p.has_pin(),
                )
            })
            .collect()
    }

    async fn switch_to(
        &mut self,
        id: &str,
        pin: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> (String, u32, u32) {
        let before = self.svc.active().map(str::to_owned);
        let outcome = self.svc.switch_to(id, pin, Instant::now());
        if self.svc.active().map(str::to_owned) != before {
            let _ = self.active_profile_changed(&emitter).await;
        }
        (
            outcome.status.as_str().to_owned(),
            outcome.attempts_left,
            retry_secs(outcome.retry_after),
        )
    }

    async fn lock(&mut self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) {
        if self.svc.active().is_some() {
            self.svc.lock();
            let _ = self.active_profile_changed(&emitter).await;
        }
    }

    async fn create_profile(
        &mut self,
        admin_id: &str,
        admin_pin: &str,
        name: &str,
        role: &str,
        pin: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> (String, String, u32, u32) {
        let (outcome, id) =
            self.svc
                .create_profile(admin_id, admin_pin, name, role, pin, Instant::now());
        if id.is_some() {
            let _ = Self::profiles_changed(&emitter).await;
        }
        (
            outcome.status.as_str().to_owned(),
            id.unwrap_or_default(),
            outcome.attempts_left,
            retry_secs(outcome.retry_after),
        )
    }

    async fn set_pin(
        &mut self,
        id: &str,
        old_pin: &str,
        new_pin: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> (String, u32, u32) {
        let outcome = self.svc.set_pin(id, old_pin, new_pin, Instant::now());
        if outcome.status == crate::Status::Ok {
            let _ = Self::profiles_changed(&emitter).await; // has_pin may have changed
        }
        (
            outcome.status.as_str().to_owned(),
            outcome.attempts_left,
            retry_secs(outcome.retry_after),
        )
    }

    async fn rename_profile(
        &mut self,
        actor_id: &str,
        actor_pin: &str,
        id: &str,
        name: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> (String, u32, u32) {
        let outcome = self
            .svc
            .rename_profile(actor_id, actor_pin, id, name, Instant::now());
        if outcome.status == crate::Status::Ok {
            let _ = Self::profiles_changed(&emitter).await;
        }
        (
            outcome.status.as_str().to_owned(),
            outcome.attempts_left,
            retry_secs(outcome.retry_after),
        )
    }

    async fn delete_profile(
        &mut self,
        admin_id: &str,
        admin_pin: &str,
        id: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> (String, u32, u32) {
        let outcome = self
            .svc
            .delete_profile(admin_id, admin_pin, id, Instant::now());
        if outcome.status == crate::Status::Ok {
            let _ = Self::profiles_changed(&emitter).await;
        }
        (
            outcome.status.as_str().to_owned(),
            outcome.attempts_left,
            retry_secs(outcome.retry_after),
        )
    }

    async fn verify_admin(&mut self, admin_id: &str, admin_pin: &str) -> (String, u32, u32) {
        let outcome = self.svc.verify_admin(admin_id, admin_pin, Instant::now());
        (
            outcome.status.as_str().to_owned(),
            outcome.attempts_left,
            retry_secs(outcome.retry_after),
        )
    }

    #[zbus(property)]
    fn active_profile(&self) -> String {
        self.svc.active().unwrap_or_default().to_owned()
    }

    #[zbus(signal)]
    async fn profiles_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}
