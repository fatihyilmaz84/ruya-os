//! Unix accounts backing each profile (ADR-004: one Unix user per profile).

use std::io;

pub trait Accounts {
    fn create(&self, profile_id: &str) -> io::Result<()>;
    /// Removes the Unix user and its home directory.
    fn remove(&self, profile_id: &str) -> io::Result<()>;
}

impl<T: Accounts + ?Sized> Accounts for Box<T> {
    fn create(&self, profile_id: &str) -> io::Result<()> {
        (**self).create(profile_id)
    }
    fn remove(&self, profile_id: &str) -> io::Result<()> {
        (**self).remove(profile_id)
    }
}

/// Unix user name for a profile id ("p3" -> "ruya-p3").
pub fn unix_user(profile_id: &str) -> String {
    format!("ruya-{profile_id}")
}

/// For tests and non-Linux development hosts.
#[derive(Debug, Default)]
pub struct NoAccounts;

impl Accounts for NoAccounts {
    fn create(&self, _profile_id: &str) -> io::Result<()> {
        Ok(())
    }
    fn remove(&self, _profile_id: &str) -> io::Result<()> {
        Ok(())
    }
}

/// Creates real users with `useradd`. Homes live in /var/home (persistent on bootc).
#[cfg(target_os = "linux")]
#[derive(Debug, Default)]
pub struct UnixAccounts;

#[cfg(target_os = "linux")]
impl Accounts for UnixAccounts {
    fn create(&self, profile_id: &str) -> io::Result<()> {
        let user = unix_user(profile_id);
        let status = std::process::Command::new("useradd")
            .args(["--create-home", "--home-dir"])
            .arg(format!("/var/home/{user}"))
            .args([
                "--user-group",
                "--shell",
                "/usr/sbin/nologin",
                "--comment",
                "RuyaOS profile",
            ])
            .arg(&user)
            .status()?;
        if status.success() {
            Ok(())
        } else {
            Err(io::Error::other(format!("useradd {user} failed: {status}")))
        }
    }

    fn remove(&self, profile_id: &str) -> io::Result<()> {
        let user = unix_user(profile_id);
        let status = std::process::Command::new("userdel")
            .arg("--remove")
            .arg(&user)
            .status()?;
        // userdel exits 6 when the user does not exist: nothing left to remove.
        if status.success() || status.code() == Some(6) {
            Ok(())
        } else {
            Err(io::Error::other(format!("userdel {user} failed: {status}")))
        }
    }
}
