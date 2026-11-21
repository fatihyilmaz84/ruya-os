//! An in-memory [`LaunchOs`] for tests and development: a tree of files, folders and links, the
//! modes the launcher set, and a record of the programs run. It keeps the real one's rules: a link
//! is never followed by a read, a list, a write, a copy or a move.

use crate::os::{join, too_deep, Command, Exit, Kind, LaunchOs, NotFollowed, MAX_COPY_DEPTH};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::io::{self, Read};
use std::time::Duration;

/// One node of the tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Node {
    /// A regular file and its bytes.
    File(Vec<u8>),
    /// A folder.
    Dir,
    /// A link and its target as written.
    Link(String),
}

/// How a program run ends, for the runs whose argv contains `needle`.
#[derive(Debug, Clone)]
pub struct RunRule {
    /// Matched against the argv joined with spaces.
    pub needle: String,
    /// How it ends.
    pub exit: Exit,
    /// How long it takes.
    pub took: Duration,
}

/// The fake.
#[derive(Debug, Default)]
pub struct FakeOs {
    /// Absolute path to node; folders above a node are present too.
    pub nodes: BTreeMap<String, Node>,
    /// Every program run, in order.
    pub runs: Vec<Command>,
    /// How runs end (first match); unmatched runs exit 0 after one second.
    pub rules: Vec<RunRule>,
    /// Every log line.
    pub lines: RefCell<Vec<String>>,
    /// Paths whose [`LaunchOs::kind`] fails with this error instead of answering (an `EACCES`).
    pub kind_errors: BTreeMap<String, io::ErrorKind>,
    /// Paths whose [`LaunchOs::open`] fails with this error (an `EACCES` on a file that is there).
    pub open_errors: BTreeMap<String, io::ErrorKind>,
    /// The permission bits set with [`LaunchOs::set_mode`] (or copied with a node), by path; a
    /// node without one has the mode it was made with, which the fake does not model.
    pub modes: BTreeMap<String, u32>,
    /// Paths whose [`LaunchOs::rename`] (as the source) fails with this error, to cut a rebuild
    /// short at a known step.
    pub rename_errors: BTreeMap<String, io::ErrorKind>,
}

fn parent(path: &str) -> Option<&str> {
    path.rfind('/')
        .map(|i| &path[..i])
        .filter(|p| !p.is_empty())
}

impl FakeOs {
    /// An empty tree.
    pub fn new() -> Self {
        Self::default()
    }

    fn add_parents(&mut self, path: &str) {
        let mut p = parent(path);
        while let Some(d) = p {
            self.nodes.entry(d.to_string()).or_insert(Node::Dir);
            p = parent(d);
        }
    }

    /// Put a file at `path` (its folders too).
    pub fn file(&mut self, path: &str, bytes: impl Into<Vec<u8>>) -> &mut Self {
        self.add_parents(path);
        self.nodes
            .insert(path.to_string(), Node::File(bytes.into()));
        self
    }

    /// Put a folder at `path`.
    pub fn dir(&mut self, path: &str) -> &mut Self {
        self.add_parents(path);
        self.nodes.insert(path.to_string(), Node::Dir);
        self
    }

    /// Put a link to `target` at `path`.
    pub fn link(&mut self, path: &str, target: &str) -> &mut Self {
        self.add_parents(path);
        self.nodes
            .insert(path.to_string(), Node::Link(target.to_string()));
        self
    }

    /// Make [`LaunchOs::kind`] of `path` fail with `kind` instead of answering (an `EACCES`).
    pub fn fail_kind(&mut self, path: &str, kind: io::ErrorKind) -> &mut Self {
        self.kind_errors.insert(path.to_string(), kind);
        self
    }

    /// Make [`LaunchOs::open`] of `path` fail with `kind` (the file is there, `kind` still answers).
    pub fn fail_open(&mut self, path: &str, kind: io::ErrorKind) -> &mut Self {
        self.open_errors.insert(path.to_string(), kind);
        self
    }

    /// Runs whose argv contains `needle` end with `exit` after `took`.
    pub fn on_run(&mut self, needle: &str, exit: Exit, took: Duration) -> &mut Self {
        self.rules.insert(
            0,
            RunRule {
                needle: needle.to_string(),
                exit,
                took,
            },
        );
        self
    }

    /// The bytes of the file at `path`.
    pub fn read(&self, path: &str) -> Option<&[u8]> {
        match self.nodes.get(path) {
            Some(Node::File(b)) => Some(b),
            _ => None,
        }
    }

    /// Every path at or below `path`.
    pub fn below(&self, path: &str) -> Vec<String> {
        let inner = format!("{path}/");
        self.nodes
            .keys()
            .filter(|k| *k == path || k.starts_with(&inner))
            .cloned()
            .collect()
    }

    /// The folders of `base/rel` below `base` (the last part too when `last`) are folders, not
    /// links or files.
    fn check(&self, base: &str, rel: &str, last: bool) -> io::Result<()> {
        let parts: Vec<&str> = rel.split('/').filter(|c| !c.is_empty()).collect();
        let n = if last {
            parts.len()
        } else {
            parts.len().saturating_sub(1)
        };
        let mut cur = base.trim_end_matches('/').to_string();
        for part in &parts[..n] {
            cur = join(&cur, part);
            match self.nodes.get(&cur) {
                None | Some(Node::Dir) => {}
                Some(Node::Link(_)) => return Err(NotFollowed::error(&cur)),
                Some(Node::File(_)) => return Err(crate::os::not_a_folder(&cur)),
            }
        }
        Ok(())
    }

    /// `path` as a read on the real system sees it: links among its folders followed (at most 8
    /// hops), the link at its end too when `last`. Writes never resolve: they refuse ([`Self::check`]).
    pub fn resolve(&self, path: &str, last: bool) -> String {
        let mut cur = String::new();
        let parts: Vec<&str> = path.split('/').filter(|c| !c.is_empty()).collect();
        let mut hops = 0;
        for (i, part) in parts.iter().enumerate() {
            cur = format!("{cur}/{part}");
            while let Some(Node::Link(to)) = self.nodes.get(&cur) {
                if (i + 1 == parts.len() && !last) || hops == 8 {
                    break;
                }
                hops += 1;
                cur = if to.starts_with('/') {
                    to.trim_end_matches('/').to_string()
                } else {
                    join(parent(&cur).unwrap_or(""), to)
                };
            }
        }
        if cur.is_empty() {
            "/".into()
        } else {
            cur
        }
    }

    fn remove_tree(&mut self, path: &str) {
        for k in self.below(path) {
            self.nodes.remove(&k);
            self.modes.remove(&k);
        }
    }

    /// Every node at or below `src` with its mode, at the path it has below `dst` instead (what a
    /// copy or a move of `src` to `dst` makes).
    fn subtree(&self, src: &str, dst: &str) -> Vec<(String, Node, Option<u32>)> {
        self.below(src)
            .into_iter()
            .map(|k| {
                let to = format!("{dst}{}", &k[src.len()..]);
                (to, self.nodes[&k].clone(), self.modes.get(&k).copied())
            })
            .collect()
    }

    /// Put `node` at `path`, with `mode` when it has one.
    fn put(&mut self, path: String, node: Node, mode: Option<u32>) {
        if let Some(m) = mode {
            self.modes.insert(path.clone(), m);
        }
        self.nodes.insert(path, node);
    }

    /// The mode set on `path`, if one was.
    pub fn mode(&self, path: &str) -> Option<u32> {
        self.modes.get(path).copied()
    }

    /// Make [`LaunchOs::rename`] of `path` (the source) fail with `kind`.
    pub fn fail_rename(&mut self, path: &str, kind: io::ErrorKind) -> &mut Self {
        self.rename_errors.insert(path.to_string(), kind);
        self
    }
}

impl LaunchOs for FakeOs {
    fn kind(&self, base: &str, rel: &str) -> io::Result<Option<Kind>> {
        let path = join(base, rel);
        if let Some(kind) = self.kind_errors.get(&path) {
            return Err(io::Error::new(*kind, path));
        }
        self.check(base, rel, false)?;
        Ok(self
            .nodes
            .get(&self.resolve(&path, false))
            .map(|n| match n {
                Node::File(_) => Kind::File,
                Node::Dir => Kind::Dir,
                Node::Link(_) => Kind::Link,
            }))
    }

    fn list(&self, base: &str, rel: &str) -> io::Result<Vec<(String, Kind)>> {
        self.check(base, rel, true)?;
        let path = self.resolve(&join(base, rel), true);
        if self.nodes.get(&path) != Some(&Node::Dir) {
            return Err(io::Error::new(io::ErrorKind::NotFound, path.to_string()));
        }
        let inner = format!("{path}/");
        Ok(self
            .nodes
            .keys()
            .filter_map(|k| k.strip_prefix(&inner))
            .filter(|rest| !rest.contains('/'))
            .filter_map(|name| {
                let full = format!("{inner}{name}");
                self.kind(&full, "")
                    .ok()
                    .flatten()
                    .map(|k| (name.to_string(), k))
            })
            .collect())
    }

    fn open(&self, base: &str, rel: &str) -> io::Result<Box<dyn Read + '_>> {
        self.check(base, rel, false)?;
        let path = join(base, rel);
        if let Some(kind) = self.open_errors.get(&path) {
            return Err(io::Error::new(*kind, path));
        }
        match self.nodes.get(&self.resolve(&path, false)) {
            Some(Node::File(b)) => Ok(Box::new(io::Cursor::new(b.as_slice()))),
            Some(_) => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "not a regular file",
            )),
            None => Err(io::Error::new(io::ErrorKind::NotFound, path)),
        }
    }

    fn make_dirs(&mut self, base: &str, rel: &str) -> io::Result<()> {
        self.check(base, rel, true)?;
        let mut cur = base.trim_end_matches('/').to_string();
        for part in rel.split('/').filter(|c| !c.is_empty()) {
            cur = join(&cur, part);
            self.nodes.entry(cur.clone()).or_insert(Node::Dir);
        }
        Ok(())
    }

    fn copy(
        &mut self,
        src_base: &str,
        src_rel: &str,
        dst_base: &str,
        dst_rel: &str,
    ) -> io::Result<bool> {
        self.check(src_base, src_rel, false)?;
        let src = join(src_base, src_rel);
        if !self.nodes.contains_key(&src) {
            return Ok(false);
        }
        if let Some(deep) = self
            .below(&src)
            .iter()
            .find(|k| k[src.len()..].matches('/').count() > MAX_COPY_DEPTH)
        {
            return Err(too_deep(deep));
        }
        let dst = self.make_parent(dst_base, dst_rel)?;
        let copied = self.subtree(&src, &dst);
        let merge = matches!(
            (self.nodes.get(&dst), self.nodes.get(&src)),
            (Some(Node::Dir), Some(Node::Dir))
        );
        if !merge {
            self.remove_tree(&dst);
        }
        for (k, n, mode) in copied {
            if matches!(self.nodes.get(&k), Some(Node::Dir)) && n == Node::Dir {
                continue;
            }
            self.remove_tree(&k);
            self.put(k, n, mode);
        }
        Ok(true)
    }

    fn rename(
        &mut self,
        src_base: &str,
        src_rel: &str,
        dst_base: &str,
        dst_rel: &str,
    ) -> io::Result<()> {
        self.check(src_base, src_rel, false)?;
        let src = join(src_base, src_rel);
        if let Some(kind) = self.rename_errors.get(&src) {
            return Err(io::Error::new(*kind, src));
        }
        let Some(node) = self.nodes.get(&src).cloned() else {
            return Err(io::Error::new(io::ErrorKind::NotFound, src));
        };
        let dst = self.make_parent(dst_base, dst_rel)?;
        if dst == src {
            return Ok(());
        }
        match (self.nodes.get(&dst), &node) {
            (Some(Node::Dir), Node::Dir) if self.below(&dst).len() > 1 => {
                return Err(io::Error::other(format!(
                    "{dst} is a folder that is not empty"
                )))
            }
            (Some(Node::Dir), Node::File(_) | Node::Link(_)) => {
                return Err(io::Error::other(format!("{dst} is a folder")))
            }
            (Some(Node::File(_) | Node::Link(_)), Node::Dir) => {
                return Err(io::Error::other(format!("{dst} is not a folder")))
            }
            _ => {}
        }
        let moved = self.subtree(&src, &dst);
        self.remove_tree(&src);
        self.remove_tree(&dst);
        for (k, n, mode) in moved {
            self.put(k, n, mode);
        }
        Ok(())
    }

    fn set_mode(&mut self, base: &str, rel: &str, mode: u32) -> io::Result<()> {
        self.check(base, rel, false)?;
        let path = join(base, rel);
        match self.nodes.get(&path) {
            None => Err(io::Error::new(io::ErrorKind::NotFound, path)),
            Some(Node::Link(_)) => Err(NotFollowed::error(&path)),
            Some(_) => {
                self.modes.insert(path, mode);
                Ok(())
            }
        }
    }

    fn read_link(&self, base: &str, rel: &str) -> io::Result<String> {
        self.check(base, rel, false)?;
        let path = join(base, rel);
        match self.nodes.get(&path) {
            Some(Node::Link(to)) => Ok(to.clone()),
            Some(_) => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{path} is not a link"),
            )),
            None => Err(io::Error::new(io::ErrorKind::NotFound, path)),
        }
    }

    fn remove(&mut self, base: &str, rel: &str) -> io::Result<()> {
        self.check(base, rel, false)?;
        self.remove_tree(&join(base, rel));
        Ok(())
    }

    fn symlink(&mut self, target: &str, base: &str, rel: &str) -> io::Result<()> {
        self.check(base, rel, false)?;
        let path = join(base, rel);
        self.remove_tree(&path);
        self.nodes.insert(path, Node::Link(target.to_string()));
        Ok(())
    }

    fn write_atomic(&mut self, base: &str, rel: &str, bytes: &[u8]) -> io::Result<()> {
        let path = self.make_parent(base, rel)?;
        self.remove_tree(&path);
        self.nodes.insert(path, Node::File(bytes.to_vec()));
        Ok(())
    }

    fn run(&mut self, cmds: &[Command], timeout: Duration) -> io::Result<(Exit, Duration)> {
        let (mut exit, mut total) = (Exit::Code(0), Duration::ZERO);
        for cmd in cmds {
            self.runs.push(cmd.clone());
            let line = cmd.argv.join(" ");
            let (e, took) = self
                .rules
                .iter()
                .find(|r| line.contains(&r.needle))
                .map_or((Exit::Code(0), Duration::from_secs(1)), |r| {
                    (r.exit, r.took)
                });
            total += took;
            if total > timeout {
                return Ok((Exit::TimedOut, timeout));
            }
            exit = e;
            if exit != Exit::Code(0) {
                break;
            }
        }
        Ok((exit, total))
    }

    fn log(&self, line: &str) {
        self.lines.borrow_mut().push(line.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_never_pass_a_link() {
        let mut os = FakeOs::new();
        os.dir("/d")
            .link("/d/prefix", "/etc")
            .file("/etc/passwd", "root");
        let e = os.make_dirs("/d", "prefix/drive_c").unwrap_err();
        assert!(NotFollowed::is(&e));
        let e = os.write_atomic("/d", "prefix/x", b"y").unwrap_err();
        assert!(NotFollowed::is(&e));
        assert_eq!(os.below("/etc"), vec!["/etc", "/etc/passwd"]);
    }

    #[test]
    fn copy_keeps_links_as_links() {
        let mut os = FakeOs::new();
        os.file("/a/t/f", "x").link("/a/t/l", "/etc");
        assert!(os.copy("/a", "t", "/d", "p").unwrap());
        assert_eq!(os.read("/d/p/f"), Some(&b"x"[..]));
        assert_eq!(os.nodes.get("/d/p/l"), Some(&Node::Link("/etc".into())));
        assert!(!os.copy("/a", "none", "/d", "q").unwrap());
    }

    #[test]
    fn a_long_run_times_out() {
        let mut os = FakeOs::new();
        os.on_run("slow", Exit::Code(0), Duration::from_secs(700));
        let cmd = Command {
            argv: vec!["slow".into()],
            env: BTreeMap::new(),
            cwd: "/".into(),
        };
        let (exit, _) = os.run(&[cmd], Duration::from_secs(600)).unwrap();
        assert_eq!(exit, Exit::TimedOut);
    }
}
