//! PIN format rules and argon2id hashing.

use argon2::password_hash::rand_core::OsRng;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;

pub const MIN_LEN: usize = 4;
pub const MAX_LEN: usize = 6;

/// 4–6 ASCII digits (docs/specs/03-services-and-apps.md §1.1).
pub fn is_valid(pin: &str) -> bool {
    (MIN_LEN..=MAX_LEN).contains(&pin.len()) && pin.bytes().all(|b| b.is_ascii_digit())
}

/// PHC-format argon2id hash with a random salt.
pub fn hash(pin: &str) -> Result<String, argon2::password_hash::Error> {
    let salt = SaltString::generate(&mut OsRng);
    Ok(Argon2::default()
        .hash_password(pin.as_bytes(), &salt)?
        .to_string())
}

/// Constant-time check of `pin` against a stored PHC hash. A corrupt hash never matches.
pub fn verify(pin: &str, stored: &str) -> bool {
    PasswordHash::new(stored)
        .map(|parsed| {
            Argon2::default()
                .verify_password(pin.as_bytes(), &parsed)
                .is_ok()
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_rules() {
        assert!(is_valid("1234"));
        assert!(is_valid("123456"));
        assert!(!is_valid("123"));
        assert!(!is_valid("1234567"));
        assert!(!is_valid("12a4"));
        assert!(!is_valid("١٢٣٤")); // non-ASCII digits are rejected
        assert!(!is_valid(""));
    }

    #[test]
    fn hash_round_trip_and_salting() {
        let a = hash("2580").unwrap();
        let b = hash("2580").unwrap();
        assert!(a.starts_with("$argon2id$"));
        assert_ne!(a, b, "salt must differ per hash");
        assert!(verify("2580", &a));
        assert!(!verify("2581", &a));
    }

    #[test]
    fn corrupt_hash_never_matches() {
        assert!(!verify("1234", "not-a-hash"));
        assert!(!verify("1234", ""));
    }
}
