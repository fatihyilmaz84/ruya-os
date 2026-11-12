//! The access control list of a virtual pad's node, as the `system.posix_acl_access` extended
//! attribute (the format `setfacl` writes). Pure, so the "one entry, for the profile's user" rule
//! is tested on any host; the Linux backend only reads and writes the bytes.

pub const XATTR_NAME: &str = "system.posix_acl_access";

const VERSION: u32 = 2;
const USER_OBJ: u16 = 0x01;
const USER: u16 = 0x02;
const GROUP_OBJ: u16 = 0x04;
const GROUP: u16 = 0x08;
const MASK: u16 = 0x10;
const OTHER: u16 = 0x20;
const UNDEFINED_ID: u32 = u32::MAX;
const RW: u16 = 0o6;

/// The ACL of a virtual pad: the owner (`ruya-input`) and `uid` may read and write, nobody else
/// (no group, no other, no further named user: logind's `ruya-shell` entry is dropped).
pub fn only_user(uid: u32) -> Vec<u8> {
    let mut out = VERSION.to_le_bytes().to_vec();
    for (tag, perm, id) in [
        (USER_OBJ, RW, UNDEFINED_ID),
        (USER, RW, uid),
        (GROUP_OBJ, 0, UNDEFINED_ID),
        (MASK, RW, UNDEFINED_ID),
        (OTHER, 0, UNDEFINED_ID),
    ] {
        out.extend_from_slice(&tag.to_le_bytes());
        out.extend_from_slice(&perm.to_le_bytes());
        out.extend_from_slice(&id.to_le_bytes());
    }
    out
}

/// One entry: (tag, perm, id).
type Entry = (u16, u16, u32);

fn parse(bytes: &[u8]) -> Option<Vec<Entry>> {
    if bytes.len() < 4 || (bytes.len() - 4) % 8 != 0 {
        return None;
    }
    if u32::from_le_bytes(bytes[0..4].try_into().ok()?) != VERSION {
        return None;
    }
    bytes[4..]
        .chunks_exact(8)
        .map(|c| {
            Some((
                u16::from_le_bytes(c[0..2].try_into().ok()?),
                u16::from_le_bytes(c[2..4].try_into().ok()?),
                u32::from_le_bytes(c[4..8].try_into().ok()?),
            ))
        })
        .collect()
}

/// The named users (uid, perm) of an ACL; `None` when the bytes are not an ACL.
pub fn named_users(bytes: &[u8]) -> Option<Vec<(u32, u16)>> {
    Some(
        parse(bytes)?
            .into_iter()
            .filter(|&(tag, _, _)| tag == USER)
            .map(|(_, perm, id)| (id, perm))
            .collect(),
    )
}

/// True when the ACL is exactly what `only_user(uid)` writes: nothing to re-assert.
pub fn is_only_user(bytes: &[u8], uid: u32) -> bool {
    let Some(entries) = parse(bytes) else {
        return false;
    };
    let mut want = parse(&only_user(uid)).unwrap_or_default();
    let mut have = entries;
    want.sort();
    have.sort();
    have == want && !have.iter().any(|&(tag, _, _)| tag == GROUP)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What logind's uaccess builtin leaves: the owner, `ruya-shell` (uid 990), group, mask.
    fn logind_acl() -> Vec<u8> {
        let mut out = VERSION.to_le_bytes().to_vec();
        for (tag, perm, id) in [
            (USER_OBJ, RW, UNDEFINED_ID),
            (USER, RW, 990),
            (GROUP_OBJ, 0, UNDEFINED_ID),
            (MASK, RW, UNDEFINED_ID),
            (OTHER, 0, UNDEFINED_ID),
        ] {
            out.extend_from_slice(&tag.to_le_bytes());
            out.extend_from_slice(&perm.to_le_bytes());
            out.extend_from_slice(&id.to_le_bytes());
        }
        out
    }

    #[test]
    fn the_pad_acl_names_one_user() {
        let acl = only_user(1001);
        assert_eq!(acl.len(), 4 + 5 * 8);
        assert_eq!(named_users(&acl), Some(vec![(1001, RW)]));
        assert!(is_only_user(&acl, 1001));
        assert!(!is_only_user(&acl, 1002));
    }

    #[test]
    fn a_logind_acl_must_be_reasserted() {
        assert_eq!(named_users(&logind_acl()), Some(vec![(990, RW)]));
        assert!(!is_only_user(&logind_acl(), 1001));
    }

    #[test]
    fn garbage_is_not_an_acl() {
        assert_eq!(named_users(&[1, 2, 3]), None);
        assert_eq!(named_users(&[1, 0, 0, 0]), None);
        assert!(!is_only_user(&[], 1001));
    }
}
