//! Following PipeWire by events instead of polling (T-133). `pw-dump --monitor` stays running and
//! prints one JSON array per batch of changes; a batch that is not only client chatter means "read
//! the graph again". The rules are here and tested on any host: splitting the stream into
//! batches, telling changes from chatter, the debounce that turns a burst into one refresh, and
//! the restart back-off. The child process itself is Linux-only.

use std::collections::HashSet;
use std::future::Future;
use std::time::Duration;

use futures_lite::future;
use serde_json::Value;

/// A burst of graph updates (a device appearing changes many objects) gives one refresh.
pub const DEBOUNCE: Duration = Duration::from_millis(100);
/// First wait before the monitor is started again; doubles up to `BACKOFF_MAX`.
pub const BACKOFF_START: Duration = Duration::from_secs(1);
pub const BACKOFF_MAX: Duration = Duration::from_secs(30);

/// The most a single batch may hold (the whole graph is a few hundred KiB). A longer one is
/// cut; the filter then takes it as relevant.
const MAX_BATCH: usize = 16 << 20;

/// Cuts a byte stream into its top-level JSON arrays, however the reads cut it. Only the
/// brackets are looked at (strings and escapes are skipped).
#[derive(Debug, Default)]
pub struct BatchSplitter {
    depth: usize,
    in_string: bool,
    escaped: bool,
    current: Vec<u8>,
}

impl BatchSplitter {
    /// Feeds a chunk and returns the arrays it completed, as text.
    pub fn push(&mut self, chunk: &[u8]) -> Vec<String> {
        let mut done = Vec::new();
        for &byte in chunk {
            if (self.depth > 0 || byte == b'[') && self.current.len() < MAX_BATCH {
                self.current.push(byte);
            }
            if self.in_string {
                if self.escaped {
                    self.escaped = false;
                } else if byte == b'\\' {
                    self.escaped = true;
                } else if byte == b'"' {
                    self.in_string = false;
                }
                continue;
            }
            match byte {
                b'"' => self.in_string = true,
                b'[' | b'{' => self.depth += 1,
                b']' | b'}' => {
                    self.depth = self.depth.saturating_sub(1);
                    // Objects only appear inside arrays; the closing of depth 0 ends a batch.
                    if self.depth == 0 && byte == b']' {
                        let text = String::from_utf8_lossy(&self.current).into_owned();
                        self.current.clear();
                        done.push(text);
                    }
                }
                _ => {}
            }
        }
        done
    }
}

/// Decides which batches mean "the audio graph changed". `pw-dump --monitor` is itself a
/// PipeWire client and reports changes of its own and of every other client over and over (500
/// batches in 12 s on an idle system), so entries about clients are not changes of the outputs.
#[derive(Debug, Default)]
pub struct Relevance {
    clients: HashSet<u64>,
}

impl Relevance {
    /// Whether a batch holds anything but updates of PipeWire clients. The first batch (the
    /// whole graph) always does; text that cannot be read counts as a change, so a format
    /// change in `pw-dump` costs CPU, not correctness.
    pub fn is_change(&mut self, batch: &str) -> bool {
        let Ok(Value::Array(entries)) = serde_json::from_str::<Value>(batch) else {
            return true;
        };
        let mut change = false;
        for entry in &entries {
            let id = entry["id"].as_u64();
            match entry["type"].as_str() {
                Some("PipeWire:Interface:Client") => {
                    if let Some(id) = id {
                        self.clients.insert(id);
                    }
                }
                // A removal carries no type: it is a client's when the id was one.
                None if id.is_some_and(|id| self.clients.contains(&id)) => {
                    if entry["info"].is_null() {
                        self.clients.remove(&id.unwrap_or_default());
                    }
                }
                _ => change = true,
            }
        }
        change
    }
}

/// The wait before each restart of a dead event source: 1 s, doubling, at most 30 s. `reset`
/// once the source has delivered something.
#[derive(Debug, Clone)]
pub struct Backoff {
    next: Duration,
}

impl Default for Backoff {
    fn default() -> Self {
        Backoff {
            next: BACKOFF_START,
        }
    }
}

impl Backoff {
    pub fn next_delay(&mut self) -> Duration {
        let now = self.next;
        self.next = (self.next * 2).min(BACKOFF_MAX);
        now
    }

    pub fn reset(&mut self) {
        self.next = BACKOFF_START;
    }
}

/// Where change batches come from. `Err` means the source is gone (it is started again).
pub trait EventSource {
    /// Waits for the next batch of changes.
    fn next(&mut self) -> impl Future<Output = Result<(), String>>;
}

/// Calls `refresh` once on every (re)connect and once per quiet burst of events, for ever. A
/// source that cannot be started, or that ends, is started again after `Backoff`; each restart
/// is logged once. `refresh` returns `false` to stop (tests); `sleep` is injected for the same
/// reason.
pub async fn follow<S, C, R, RFut, Sl, SlFut>(mut connect: C, mut sleep: Sl, mut refresh: R)
where
    S: EventSource,
    C: FnMut() -> Result<S, String>,
    R: FnMut() -> RFut,
    RFut: Future<Output = bool>,
    Sl: FnMut(Duration) -> SlFut,
    SlFut: Future<Output = ()>,
{
    let mut backoff = Backoff::default();
    loop {
        let why = match connect() {
            Ok(mut source) => {
                if !refresh().await {
                    return;
                }
                match drain(&mut source, &mut sleep, &mut refresh, &mut backoff).await {
                    Some(why) => why,
                    None => return,
                }
            }
            Err(why) => why,
        };
        let delay = backoff.next_delay();
        eprintln!("ruya-devices: PipeWire events ended ({why}); trying again in {delay:?}");
        sleep(delay).await;
    }
}

/// Runs one source until it dies (`Some(why)`) or `refresh` asks to stop (`None`).
async fn drain<S, R, RFut, Sl, SlFut>(
    source: &mut S,
    sleep: &mut Sl,
    refresh: &mut R,
    backoff: &mut Backoff,
) -> Option<String>
where
    S: EventSource,
    R: FnMut() -> RFut,
    RFut: Future<Output = bool>,
    Sl: FnMut(Duration) -> SlFut,
    SlFut: Future<Output = ()>,
{
    loop {
        if let Err(why) = source.next().await {
            return Some(why);
        }
        // It delivered, so the next death starts the back-off from the beginning again.
        backoff.reset();
        // Swallow the rest of the burst: the refresh comes when it has been quiet for DEBOUNCE.
        loop {
            let step = future::or(async { Some(source.next().await) }, async {
                sleep(DEBOUNCE).await;
                None
            })
            .await;
            match step {
                Some(Ok(())) => {}
                Some(Err(why)) => return Some(why),
                None => break,
            }
        }
        if !refresh().await {
            return None;
        }
    }
}

#[cfg(target_os = "linux")]
pub use linux::PwMonitor;

#[cfg(target_os = "linux")]
mod linux {
    use std::process::{Child, ChildStdout, Command, Stdio};

    use async_io::Async;
    use futures_lite::AsyncReadExt;

    use super::{BatchSplitter, EventSource, Relevance};

    /// `pw-dump --monitor --no-colors`: one JSON array on start-up (the whole graph) and one per
    /// change after. The child is killed when this is dropped.
    pub struct PwMonitor {
        child: Child,
        stdout: Async<ChildStdout>,
        splitter: BatchSplitter,
        relevance: Relevance,
        /// Batches read but not yet handed out (one read can hold several).
        pending: usize,
        buffer: Vec<u8>,
    }

    impl PwMonitor {
        pub fn start() -> Result<Self, String> {
            let mut child = Command::new("pw-dump")
                .args(["--monitor", "--no-colors"])
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| format!("pw-dump: {e}"))?;
            let stdout = match child.stdout.take().map(Async::new) {
                Some(Ok(stdout)) => stdout,
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err("pw-dump: no stdout".to_owned());
                }
            };
            Ok(PwMonitor {
                child,
                stdout,
                splitter: BatchSplitter::default(),
                relevance: Relevance::default(),
                pending: 0,
                buffer: vec![0; 64 * 1024],
            })
        }
    }

    impl EventSource for PwMonitor {
        async fn next(&mut self) -> Result<(), String> {
            loop {
                if self.pending > 0 {
                    self.pending -= 1;
                    return Ok(());
                }
                let n = self
                    .stdout
                    .read(&mut self.buffer)
                    .await
                    .map_err(|e| format!("pw-dump: {e}"))?;
                if n == 0 {
                    return Err("pw-dump exited".to_owned());
                }
                for batch in self.splitter.push(&self.buffer[..n]) {
                    if self.relevance.is_change(&batch) {
                        self.pending += 1;
                    }
                }
            }
        }
    }

    impl Drop for PwMonitor {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::VecDeque;
    use std::rc::Rc;

    use super::*;

    #[test]
    fn splitter_counts_arrays_across_reads() {
        let mut s = BatchSplitter::default();
        assert_eq!(s.push(b"[{\"a\":1}]\n[{\"b\""), ["[{\"a\":1}]"]);
        assert_eq!(s.push(b":[2,3]}]"), ["[{\"b\":[2,3]}]"]);
        assert_eq!(s.push(b"[]"), ["[]"]);
        assert_eq!(s.push(b"[][]").len(), 2);
    }

    #[test]
    fn client_chatter_is_not_a_change() {
        let mut r = Relevance::default();
        // The first batch: the whole graph, with a client and a sink.
        let graph = r#"[{"id":57,"type":"PipeWire:Interface:Client","info":{"props":{}}},
                        {"id":43,"type":"PipeWire:Interface:Node","info":{"props":{"media.class":"Audio/Sink"}}}]"#;
        assert!(r.is_change(graph));
        let chatter =
            r#"[{"id":57,"type":"PipeWire:Interface:Client","info":{"change-mask":["props"]}}]"#;
        assert!(!r.is_change(chatter));
        // The client is removed (no type) and added again.
        assert!(!r.is_change(r#"[{"id":57,"info":null}]"#));
        assert!(!r.is_change(chatter));
        // Anything else is a change: a sink's parameters (volume), a removed node, new objects.
        assert!(r.is_change(
            r#"[{"id":43,"type":"PipeWire:Interface:Node","info":{"change-mask":["params"]}}]"#
        ));
        assert!(r.is_change(r#"[{"id":43,"info":null}]"#));
        assert!(r.is_change(r#"[{"id":90,"type":"PipeWire:Interface:Device","info":{}}]"#));
        // A batch with chatter and a change is a change.
        assert!(r.is_change(
            r#"[{"id":57,"type":"PipeWire:Interface:Client","info":{}},{"id":43,"type":"PipeWire:Interface:Node","info":{}}]"#
        ));
    }

    #[test]
    fn unreadable_text_counts_as_a_change() {
        let mut r = Relevance::default();
        assert!(r.is_change("[{\"id\":"));
        assert!(r.is_change("{}"));
    }

    #[test]
    fn splitter_ignores_brackets_in_strings() {
        let mut s = BatchSplitter::default();
        assert_eq!(s.push(br#"[{"name":"a]b\"]c[","k":"\\"}]"#).len(), 1);
        // A backslash at the end of one read escapes the quote at the start of the next.
        assert!(s.push(br#"[{"n":"x\"#).is_empty());
        assert_eq!(s.push(br#""]"}]"#).len(), 1);
    }

    #[test]
    fn backoff_doubles_to_the_cap_and_resets() {
        let mut b = Backoff::default();
        let secs: Vec<u64> = (0..8).map(|_| b.next_delay().as_secs()).collect();
        assert_eq!(secs, [1, 2, 4, 8, 16, 30, 30, 30]);
        b.reset();
        assert_eq!(b.next_delay(), Duration::from_secs(1));
    }

    /// What a fake source does on each call to `next`.
    #[derive(Clone, Copy)]
    enum Step {
        Event,
        Die,
        /// Nothing more ever happens.
        Silence,
    }

    struct Fake {
        steps: VecDeque<Step>,
    }

    impl EventSource for Fake {
        async fn next(&mut self) -> Result<(), String> {
            match self.steps.pop_front() {
                Some(Step::Event) => Ok(()),
                Some(Step::Die) => Err("gone".to_owned()),
                Some(Step::Silence) | None => future::pending().await,
            }
        }
    }

    /// Runs `follow` over the sources (one per connect; `None` is a connect that fails) and
    /// returns the sleeps and the number of refreshes. The `stop_after`-th refresh ends the run.
    fn run(sources: Vec<Option<Vec<Step>>>, stop_after: usize) -> (Vec<Duration>, usize) {
        let sleeps = Rc::new(RefCell::new(Vec::new()));
        let refreshes = Rc::new(RefCell::new(0usize));
        let mut sources: VecDeque<Option<Vec<Step>>> = sources.into();
        let (s, r) = (sleeps.clone(), refreshes.clone());
        future::block_on(follow(
            move || {
                sources
                    .pop_front()
                    .flatten()
                    .map(|steps| Fake {
                        steps: steps.into(),
                    })
                    .ok_or_else(|| "no pw-dump".to_owned())
            },
            move |d| {
                s.borrow_mut().push(d);
                // Sleeping costs nothing in a test: the debounce window ends when nothing is ready.
                async {}
            },
            move || {
                *r.borrow_mut() += 1;
                let go = *r.borrow() < stop_after;
                async move { go }
            },
        ));
        let sleeps = sleeps.borrow().clone();
        let refreshes = *refreshes.borrow();
        (sleeps, refreshes)
    }

    fn secs(sleeps: &[Duration]) -> Vec<u64> {
        sleeps.iter().map(|d| d.as_secs()).collect()
    }

    #[test]
    fn a_burst_gives_one_refresh() {
        // Refresh 1 on connect; five events in a row give refresh 2, then silence.
        let mut steps = vec![Step::Event; 5];
        steps.push(Step::Silence);
        let (sleeps, refreshes) = run(vec![Some(steps)], 2);
        assert_eq!(refreshes, 2);
        assert_eq!(
            sleeps,
            [DEBOUNCE],
            "one debounce window for the whole burst"
        );
    }

    #[test]
    fn a_quiet_event_refreshes_after_the_window() {
        // Refresh 1 on connect; one event, then quiet: the window runs out and refresh 2 follows.
        let (sleeps, refreshes) = run(vec![Some(vec![Step::Event, Step::Silence])], 2);
        assert_eq!(refreshes, 2);
        assert_eq!(sleeps, [DEBOUNCE]);
    }

    #[test]
    fn a_dead_source_is_restarted_with_backoff() {
        let dead = || Some(vec![Step::Die]);
        let (sleeps, refreshes) = run(
            vec![dead(), dead(), dead(), dead(), Some(vec![Step::Silence])],
            5,
        );
        assert_eq!(refreshes, 5, "one refresh per successful connect");
        assert_eq!(secs(&sleeps), [1, 2, 4, 8]);
    }

    #[test]
    fn a_failing_start_backs_off_too() {
        let (sleeps, refreshes) = run(vec![None, None, None, Some(vec![Step::Silence])], 1);
        assert_eq!(refreshes, 1);
        assert_eq!(secs(&sleeps), [1, 2, 4]);
    }

    #[test]
    fn delivering_events_resets_the_backoff() {
        let sources = vec![
            Some(vec![Step::Die]),
            Some(vec![Step::Die]),
            Some(vec![Step::Event, Step::Die]),
            Some(vec![Step::Silence]),
        ];
        let (sleeps, _) = run(sources, 4);
        assert_eq!(secs(&sleeps), [1, 2, 1]);
    }
}
