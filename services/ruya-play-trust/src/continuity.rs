//! Key continuity (05 §9.2, §18 items 16 to 18): trust on first use per id, key rotation by a
//! statement of the old key, and what happens to the record at uninstall and on "forget".

use crate::error::TrustError;
use crate::keys::PublicKey;
use crate::signing::Signatures;
use crate::statement::RotationStatement;
use crate::store::{IdRecord, TrustStore, MAX_RETIRED};
use crate::time::UnixSeconds;

/// How the package's key relates to the id's record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Continuity {
    /// No record: the package's key will own the id once it is installed. `seq` is the newest
    /// rotation the package carries that ends at its key (0 without one), recorded so that
    /// statement cannot be replayed. The carried rotations are bound to the package key's own
    /// signature (`rotations_sha256`), so only that key decides this number.
    FirstSight { seq: u64 },
    /// The id's key signed the package.
    SameKey,
    /// The package carries rotations from the recorded key to its own: the id moves to the new
    /// key at `seq` once it is installed.
    Rotated {
        from: PublicKey,
        to: PublicKey,
        seq: u64,
    },
    /// An unsigned package for an id without a record: nothing is recorded.
    Unsigned,
}

fn different(id: &str, record: &IdRecord, found: Option<&PublicKey>) -> TrustError {
    TrustError::DifferentDeveloper {
        id: id.to_string(),
        known: record.key.key_id(),
        found: found.map(PublicKey::key_id),
    }
}

/// Decide continuity for a package of `id` signed by `key` (`None`: unsigned) carrying
/// `rotations`, against the id's `record`.
///
/// - No record: first sight (or unsigned).
/// - Same key: fine; the rotations it carries are ignored.
/// - Another key: walk the rotations from the recorded key, each signed by the key it hands over
///   from and bound to the package key's signature (both checked when `play.sig` was read) and
///   with a `seq` above the last applied one, until the package's key is reached. A step to a key
///   retired for this id is `rotation.to_retired_key`; a matching rotation whose `seq` is not above
///   is `rotation.replayed`; no path is `trust.different_developer`.
/// - Unsigned with a record: `trust.different_developer`.
pub fn check_continuity(
    record: Option<&IdRecord>,
    id: &str,
    key: Option<&PublicKey>,
    rotations: &[RotationStatement],
) -> Result<Continuity, TrustError> {
    let Some(record) = record else {
        return Ok(match key {
            None => Continuity::Unsigned,
            Some(k) => Continuity::FirstSight {
                seq: rotations
                    .iter()
                    .filter(|r| &r.new_key == k)
                    .map(|r| r.seq)
                    .max()
                    .unwrap_or(0),
            },
        });
    };
    let Some(key) = key else {
        return Err(different(id, record, None));
    };
    if *key == record.key {
        return Ok(Continuity::SameKey);
    }
    let (mut current, mut seq) = (record.key.clone(), record.seq);
    let mut replayed = None;
    for _ in 0..rotations.len() {
        let next = rotations
            .iter()
            .filter(|r| r.old_key == current && r.seq > seq)
            .min_by_key(|r| r.seq);
        if replayed.is_none() {
            replayed = rotations
                .iter()
                .find(|r| r.old_key == current && r.seq <= seq)
                .map(|r| r.seq);
        }
        let Some(r) = next else { break };
        if record.retired.contains(&r.new_key.key_id()) {
            return Err(TrustError::RotationToRetiredKey {
                key_id: r.new_key.key_id(),
            });
        }
        current = r.new_key.clone();
        seq = r.seq;
        if current == *key {
            return Ok(Continuity::Rotated {
                from: record.key.clone(),
                to: key.clone(),
                seq,
            });
        }
    }
    match replayed {
        Some(s) => Err(TrustError::RotationReplayed {
            seq: s,
            applied: record.seq,
        }),
        None => Err(different(id, record, Some(key))),
    }
}

/// Continuity of verified signatures for `id` against `store`.
pub fn continuity_of(
    store: &dyn TrustStore,
    id: &str,
    sigs: &Signatures,
) -> Result<Continuity, TrustError> {
    let record = store.get(id)?;
    let rotations = sigs
        .developer
        .as_ref()
        .map(|d| d.rotations.as_slice())
        .unwrap_or(&[]);
    check_continuity(record.as_ref(), id, sigs.key(), rotations)
}

/// Record a finished install of `id` (after the commit step succeeded): first sight records the
/// key, a rotation moves the id to the new key and retires the old one.
pub fn record_install(
    store: &mut dyn TrustStore,
    id: &str,
    key: Option<&PublicKey>,
    continuity: &Continuity,
    now: UnixSeconds,
) -> Result<(), TrustError> {
    match (continuity, key) {
        (Continuity::FirstSight { seq }, Some(key)) => store.put(IdRecord {
            id: id.to_string(),
            key: key.clone(),
            first_seen: now,
            seq: *seq,
            retired: Vec::new(),
        }),
        (Continuity::Rotated { from, to, seq }, _) => {
            let Some(mut record) = store.get(id)? else {
                return Err(TrustError::StateCorrupt {
                    detail: "the record of a rotated id is gone".into(),
                });
            };
            if record.key != *from {
                return Err(TrustError::StateCorrupt {
                    detail: "the record changed since the package was inspected".into(),
                });
            }
            if record.retired.len() >= MAX_RETIRED {
                record.retired.remove(0);
            }
            record.retired.push(from.key_id());
            record.key = to.clone();
            record.seq = *seq;
            store.put(record)
        }
        _ => Ok(()),
    }
}

/// Record an uninstall of `id`. The record survives while any profile keeps data for the id
/// (`data_kept`), so another key cannot take over the saves (05 §18 item 16); otherwise the id is
/// free again.
pub fn record_uninstall(
    store: &mut dyn TrustStore,
    id: &str,
    data_kept: bool,
) -> Result<(), TrustError> {
    if data_kept {
        return Ok(());
    }
    store.remove(id).map(|_| ())
}

/// The admin's "Forget this game's data and key": drop the record, so the next install of `id`
/// starts trust on first use again (the way out for a squatted id or a lost key, 05 §18 items 17
/// and 18). The caller removes the data. True when there was a record.
pub fn forget(store: &mut dyn TrustStore, id: &str) -> Result<bool, TrustError> {
    store.remove(id)
}
