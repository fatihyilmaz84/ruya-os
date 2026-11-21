//! Ed25519 keys (ed25519-dalek): the public key as base64 and as a key id, a secret key that never
//! prints itself, and the generator `ruya-pack` (T-233) and the tests use. No private key is ever in
//! the repository: the tests generate theirs.

use base64ct::{Base64, Encoding};
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use ruya_play_format::hex;
use sha2::{Digest, Sha256};

/// Characters of the key id (128 bits): the first 32 hex characters of the SHA-256 of the 32 key bytes.
pub const KEY_ID_CHARS: usize = 32;

/// The lower-case hex SHA-256 of `data`.
pub fn sha256_hex(data: &[u8]) -> String {
    hex(&Sha256::digest(data))
}

/// True for 64 lower-case hex characters (a SHA-256 as the statements write it).
pub fn is_sha256_hex(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// True for a key id: [`KEY_ID_CHARS`] lower-case hex characters.
pub fn is_key_id(s: &str) -> bool {
    s.len() == KEY_ID_CHARS
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Why a public key could not be read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyFault {
    /// Not base64 of 32 bytes, or not a point of the curve.
    Invalid,
    /// A small-order point: it would "verify" forged signatures.
    Weak,
}

/// An Ed25519 public key: 32 bytes that were checked to be a point of the curve of large order.
#[derive(Clone, PartialEq, Eq)]
pub struct PublicKey([u8; 32]);

impl PublicKey {
    /// Read 32 key bytes; weak (small-order) keys are refused.
    pub fn from_bytes(bytes: &[u8]) -> Result<PublicKey, KeyFault> {
        let arr: [u8; 32] = bytes.try_into().map_err(|_| KeyFault::Invalid)?;
        let key = VerifyingKey::from_bytes(&arr).map_err(|_| KeyFault::Invalid)?;
        if key.is_weak() {
            return Err(KeyFault::Weak);
        }
        Ok(PublicKey(arr))
    }

    /// Read the standard base64 (with padding) of the 32 key bytes.
    pub fn from_base64(text: &str) -> Result<PublicKey, KeyFault> {
        let bytes = Base64::decode_vec(text).map_err(|_| KeyFault::Invalid)?;
        PublicKey::from_bytes(&bytes)
    }

    /// The 32 key bytes.
    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    /// The standard base64 of the key bytes, as `play.sig` writes it.
    pub fn to_base64(&self) -> String {
        Base64::encode_string(self.as_bytes())
    }

    /// The key id: the first [`KEY_ID_CHARS`] hex characters of the SHA-256 of the key bytes.
    pub fn key_id(&self) -> String {
        let mut id = sha256_hex(self.as_bytes());
        id.truncate(KEY_ID_CHARS);
        id
    }

    /// Verify `sig` over `message` with the strict rules (no malleable signatures, no weak keys).
    pub(crate) fn verify(&self, message: &[u8], sig: &[u8; 64]) -> bool {
        let sig = ed25519_dalek::Signature::from_bytes(sig);
        VerifyingKey::from_bytes(&self.0).is_ok_and(|key| key.verify_strict(message, &sig).is_ok())
    }
}

impl std::fmt::Debug for PublicKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "PublicKey({})", self.key_id())
    }
}

/// An Ed25519 secret key. It is held only by the developer's tool and by tests; `Debug` shows the
/// key id of its public half, never the secret.
#[derive(Clone)]
pub struct SecretKey(SigningKey);

impl SecretKey {
    /// The key for a 32-byte seed (the form a key file keeps).
    pub fn from_seed(seed: &[u8; 32]) -> SecretKey {
        SecretKey(SigningKey::from_bytes(seed))
    }

    /// The 32-byte seed, for the developer's key file (T-233). Never log or ship it.
    pub fn seed(&self) -> [u8; 32] {
        self.0.to_bytes()
    }

    /// The public half.
    pub fn public(&self) -> PublicKey {
        PublicKey(self.0.verifying_key().to_bytes())
    }

    /// Sign `message` (already carrying its domain prefix).
    pub(crate) fn sign_raw(&self, message: &[u8]) -> [u8; 64] {
        self.0.sign(message).to_bytes()
    }
}

impl std::fmt::Debug for SecretKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SecretKey(public {})", self.public().key_id())
    }
}

/// A new random key from the operating system's generator.
pub fn generate_key() -> Result<SecretKey, getrandom::Error> {
    let mut seed = [0u8; 32];
    getrandom::getrandom(&mut seed)?;
    let key = SecretKey::from_seed(&seed);
    seed.fill(0);
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_round_trips_through_base64_and_has_a_short_id() {
        let k = generate_key().unwrap().public();
        let b = k.to_base64();
        assert_eq!(b.len(), 44);
        assert_eq!(PublicKey::from_base64(&b).unwrap(), k);
        assert!(is_key_id(&k.key_id()));
        assert_eq!(k.key_id(), sha256_hex(k.as_bytes())[..32]);
    }

    #[test]
    fn two_generated_keys_differ_and_debug_hides_the_seed() {
        let (a, b) = (generate_key().unwrap(), generate_key().unwrap());
        assert_ne!(a.seed(), b.seed());
        let shown = format!("{a:?}");
        assert!(shown.contains(&a.public().key_id()));
        assert!(!shown.contains(&hex(&a.seed())));
        assert_eq!(SecretKey::from_seed(&a.seed()).public(), a.public());
    }

    #[test]
    fn bad_and_weak_keys_are_refused() {
        assert_eq!(PublicKey::from_base64("not base64"), Err(KeyFault::Invalid));
        assert_eq!(PublicKey::from_bytes(&[1u8; 31]), Err(KeyFault::Invalid));
        // The identity point (y = 1) is of small order.
        let mut identity = [0u8; 32];
        identity[0] = 1;
        assert_eq!(PublicKey::from_bytes(&identity), Err(KeyFault::Weak));
    }
}
