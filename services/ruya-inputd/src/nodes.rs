//! Which `/dev/input/event*` nodes the scanner has already looked at and need not open again.
//! Pure, so the rule is tested on any host; `linux` supplies the real directory listing.
//!
//! A node is known by its path **and its inode**. The kernel hands a freed `eventN` number to the
//! next device at once, so a virtual pad that is destroyed and a controller that is plugged in
//! within one scan interval can share a path; devtmpfs creates a new inode for the new node
//! (the device number alone is not enough). Keyed by path only (RUY-624), the new controller was
//! taken for the old, ignored node and never opened until it was replugged.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// One event node as the scan saw it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Node {
    pub path: PathBuf,
    pub ino: u64,
}

/// The nodes that were checked and found not to be physical gamepads (our own virtual pads,
/// keyboards, mice, sensors).
#[derive(Debug, Default)]
pub struct Ignored {
    seen: HashMap<PathBuf, u64>,
}

impl Ignored {
    /// Remember `node` as not worth opening, for as long as path and inode both stay the same.
    pub fn insert(&mut self, node: &Node) {
        self.seen.insert(node.path.clone(), node.ino);
    }

    /// The nodes of this scan that must be looked at: not served by a pump thread (`active`) and
    /// not remembered with the same inode. Entries for nodes that are gone, or that now have
    /// another inode (a new device on a reused path), are forgotten.
    pub fn to_open(&mut self, nodes: Vec<Node>, active: impl Fn(&Path) -> bool) -> Vec<Node> {
        self.seen
            .retain(|path, ino| nodes.iter().any(|n| &n.path == path && n.ino == *ino));
        nodes
            .into_iter()
            .filter(|n| !self.seen.contains_key(&n.path) && !active(&n.path))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(path: &str, ino: u64) -> Node {
        Node {
            path: PathBuf::from(path),
            ino,
        }
    }

    fn never_active(_: &Path) -> bool {
        false
    }

    /// A fake scanner round: the nodes the directory lists, what `open` finds in each (true = a
    /// physical pad to serve), the paths that are ignored afterwards and the paths served.
    fn round(
        ignored: &mut Ignored,
        listing: Vec<Node>,
        is_pad: impl Fn(&Node) -> bool,
    ) -> Vec<PathBuf> {
        let mut served = Vec::new();
        for n in ignored.to_open(listing, never_active) {
            if is_pad(&n) {
                served.push(n.path);
            } else {
                ignored.insert(&n);
            }
        }
        served
    }

    #[test]
    fn a_node_ignored_as_own_stays_ignored_while_nothing_changes() {
        let mut ignored = Ignored::default();
        // inode 10 is our virtual pad, never a physical one.
        assert!(round(&mut ignored, vec![node("/dev/input/event7", 10)], |_| false).is_empty());
        assert!(
            ignored
                .to_open(vec![node("/dev/input/event7", 10)], never_active)
                .is_empty(),
            "the same node is not opened again"
        );
    }

    #[test]
    fn a_new_pad_that_reuses_the_path_of_an_ignored_node_is_opened() {
        let mut ignored = Ignored::default();
        // Only inode 11 is a physical pad. Scan 1: event7 is our virtual pad (inode 10): ignored.
        let is_pad = |n: &Node| n.ino == 11;
        assert!(round(&mut ignored, vec![node("/dev/input/event7", 10)], is_pad).is_empty());
        // The virtual pad is destroyed and a controller gets event7, all within one scan
        // interval: scan 2 never saw the node missing, only a new inode on the same path.
        let served = round(&mut ignored, vec![node("/dev/input/event7", 11)], is_pad);
        assert_eq!(served, vec![PathBuf::from("/dev/input/event7")]);
    }

    #[test]
    fn a_new_node_that_is_ignored_again_is_remembered_with_its_new_inode() {
        let mut ignored = Ignored::default();
        round(&mut ignored, vec![node("/dev/input/event7", 10)], |_| false);
        // Recreated as another virtual pad: looked at once, ignored again, then left alone.
        assert!(round(&mut ignored, vec![node("/dev/input/event7", 12)], |_| false).is_empty());
        assert!(ignored
            .to_open(vec![node("/dev/input/event7", 12)], never_active)
            .is_empty());
        assert_eq!(
            ignored.to_open(vec![node("/dev/input/event7", 10)], never_active),
            vec![node("/dev/input/event7", 10)],
            "the old inode is gone from the memory"
        );
    }

    #[test]
    fn a_node_that_disappears_is_forgotten() {
        let mut ignored = Ignored::default();
        round(&mut ignored, vec![node("/dev/input/event7", 10)], |_| false);
        assert!(ignored.to_open(Vec::new(), never_active).is_empty());
        assert_eq!(
            ignored.to_open(vec![node("/dev/input/event7", 10)], never_active).len(),
            1
        );
    }

    #[test]
    fn a_node_served_by_a_pump_thread_is_skipped() {
        let mut ignored = Ignored::default();
        let listing = vec![node("/dev/input/event3", 5), node("/dev/input/event4", 6)];
        let open = ignored.to_open(listing, |p| p == Path::new("/dev/input/event3"));
        assert_eq!(open, vec![node("/dev/input/event4", 6)]);
    }
}
