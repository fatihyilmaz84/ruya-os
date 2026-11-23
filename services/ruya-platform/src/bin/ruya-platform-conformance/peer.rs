//! An app for the runner: a child process (`ruya-platform-conformance peer`) that is one app of
//! the mock's scenario (`RUYA_MOCK_APP`), opens connections and calls Lifecycle on them as the
//! runner says on stdin, and reports every reply and every Lifecycle signal on stdout:
//!
//!     open            -> opened <n>
//!     call <n> <M>    -> reply <n> <status>  |  error <n> <D-Bus error name>
//!     close <n>       -> closed <n>
//!     (any time)         signal <n> <Member> [<argument>] unicast|broadcast
//!
//! [`Peer`] is the runner's side.

use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, ExitCode, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures_lite::StreamExt;
use ruya_platform::dbus::{BUS_NAME, OBJECT_PATH};
use ruya_platform::lifecycle::INTERFACE;
use ruya_platform::mock::APP_ENV;
use zbus::{Connection, MatchRule, MessageStream};

/// How long the runner waits for a reply or a signal it expects.
pub const PATIENCE: Duration = Duration::from_secs(10);

type Out = Arc<Mutex<std::io::Stdout>>;

fn say(out: &Out, line: &str) {
    if let Ok(mut o) = out.lock() {
        let _ = writeln!(o, "{line}");
        let _ = o.flush();
    }
}

/// The signal of `msg` as a line, `None` for anything else.
fn signal_line(n: usize, msg: &zbus::Message, me: &str) -> Option<String> {
    let header = msg.header();
    if header.message_type() != zbus::message::Type::Signal
        || header.interface().map(|i| i.as_str()) != Some(INTERFACE)
    {
        return None;
    }
    let member = header.member()?.as_str().to_owned();
    let arg = match member.as_str() {
        "Resume" => format!(" {}", msg.body().deserialize::<u64>().ok()?),
        "Stopping" => format!(" {}", msg.body().deserialize::<u32>().ok()?),
        _ => String::new(),
    };
    let to = match header.destination() {
        Some(d) if d.as_str() == me => "unicast",
        Some(_) => "to-another",
        None => "broadcast",
    };
    Some(format!("signal {n} {member}{arg} {to}"))
}

async fn open(n: usize, out: Out) -> zbus::Result<Connection> {
    let conn = Connection::session().await?;
    let me = conn
        .unique_name()
        .map(|u| u.as_str().to_owned())
        .unwrap_or_default();
    let rule = MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(BUS_NAME)?
        .interface(INTERFACE)?
        .path(OBJECT_PATH)?
        .build();
    let mut stream = MessageStream::for_match_rule(rule, &conn, None).await?;
    std::thread::spawn(move || {
        futures_lite::future::block_on(async {
            while let Some(Ok(msg)) = stream.next().await {
                if let Some(line) = signal_line(n, &msg, &me) {
                    say(&out, &line);
                }
            }
        })
    });
    Ok(conn)
}

async fn call(conn: &Connection, member: &str) -> String {
    let reply = conn
        .call_method(Some(BUS_NAME), OBJECT_PATH, Some(INTERFACE), member, &())
        .await;
    match reply {
        Ok(msg) => match msg.body().deserialize::<String>() {
            Ok(status) => format!("reply {status}"),
            Err(err) => format!("error not-a-status:{err}"),
        },
        Err(zbus::Error::MethodError(name, _, _)) => format!("error {}", name.as_str()),
        Err(err) => format!("error {err}"),
    }
}

/// The peer process: commands on stdin until it closes.
pub fn serve() -> ExitCode {
    let out: Out = Arc::new(Mutex::new(std::io::stdout()));
    let mut conns: Vec<Option<Connection>> = Vec::new();
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let words: Vec<&str> = line.split_whitespace().collect();
        let conn_at = |w: Option<&&str>| w.and_then(|n| n.parse::<usize>().ok());
        match words.as_slice() {
            ["open"] => {
                let n = conns.len();
                match futures_lite::future::block_on(open(n, out.clone())) {
                    Ok(c) => {
                        conns.push(Some(c));
                        say(&out, &format!("opened {n}"));
                    }
                    Err(err) => say(&out, &format!("failed open: {err}")),
                }
            }
            ["call", _, member] => {
                let n = conn_at(words.get(1));
                let reply = match n.and_then(|n| conns.get(n)).and_then(Option::as_ref) {
                    Some(c) => futures_lite::future::block_on(call(c, member)),
                    None => "error no-such-connection".into(),
                };
                let (kind, rest) = reply.split_once(' ').unwrap_or((&reply, ""));
                say(&out, &format!("{kind} {} {rest}", n.unwrap_or(usize::MAX)));
            }
            ["close", _] => {
                let n = conn_at(words.get(1)).unwrap_or(usize::MAX);
                if let Some(c) = conns.get_mut(n).and_then(Option::take) {
                    let _ = futures_lite::future::block_on(c.close());
                }
                say(&out, &format!("closed {n}"));
            }
            _ => say(&out, &format!("failed unknown command: {line}")),
        }
    }
    ExitCode::SUCCESS
}

/// The runner's side of one peer process.
pub struct Peer {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
    /// Signals that arrived while something else was awaited, per connection.
    signals: HashMap<usize, VecDeque<String>>,
}

impl Peer {
    /// A peer that is the scenario app `app` (a name the scenario lacks: an unsandboxed caller).
    pub fn spawn(app: &str) -> Result<Peer, String> {
        let exe = std::env::current_exe().map_err(|e| format!("no runner path: {e}"))?;
        let mut child = Command::new(exe)
            .arg("peer")
            .env(APP_ENV, app)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .map_err(|e| format!("peer not started: {e}"))?;
        let stdin = child.stdin.take().ok_or("peer has no stdin")?;
        let stdout = child.stdout.take().ok_or("peer has no stdout")?;
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        Ok(Peer {
            child,
            stdin,
            lines: rx,
            signals: HashMap::new(),
        })
    }

    fn send(&mut self, line: &str) -> Result<(), String> {
        writeln!(self.stdin, "{line}")
            .and_then(|()| self.stdin.flush())
            .map_err(|e| format!("peer gone: {e}"))
    }

    /// The next line that is not a signal (signals are kept for [`Peer::signal`]).
    fn answer(&mut self) -> Result<String, String> {
        let until = Instant::now() + PATIENCE;
        loop {
            let line = self.line(until)?;
            if !self.keep_signal(&line) {
                return Ok(line);
            }
        }
    }

    fn line(&self, until: Instant) -> Result<String, String> {
        let left = until.saturating_duration_since(Instant::now());
        match self.lines.recv_timeout(left) {
            Ok(line) => Ok(line),
            Err(RecvTimeoutError::Timeout) => Err("the peer did not answer in time".into()),
            Err(RecvTimeoutError::Disconnected) => Err("the peer exited".into()),
        }
    }

    /// Queues `line` if it is a signal.
    fn keep_signal(&mut self, line: &str) -> bool {
        let Some(rest) = line.strip_prefix("signal ") else {
            return false;
        };
        let Some((n, sig)) = rest.split_once(' ') else {
            return false;
        };
        let Ok(n) = n.parse() else { return false };
        self.signals.entry(n).or_default().push_back(sig.to_owned());
        true
    }

    /// Opens a connection; its number.
    pub fn open(&mut self) -> Result<usize, String> {
        self.send("open")?;
        let line = self.answer()?;
        line.strip_prefix("opened ")
            .and_then(|n| n.parse().ok())
            .ok_or_else(|| format!("open: {line}"))
    }

    /// Calls `member` on connection `n`: the status, or `error <name>` for a D-Bus error.
    pub fn call(&mut self, n: usize, member: &str) -> Result<String, String> {
        self.send(&format!("call {n} {member}"))?;
        let line = self.answer()?;
        let mut words = line.splitn(3, ' ');
        match (words.next(), words.next(), words.next()) {
            (Some("reply"), _, Some(status)) => Ok(status.to_owned()),
            (Some("error"), _, Some(name)) => Ok(format!("error {name}")),
            _ => Err(format!("{member}: {line}")),
        }
    }

    pub fn close(&mut self, n: usize) -> Result<(), String> {
        self.send(&format!("close {n}"))?;
        let line = self.answer()?;
        if line == format!("closed {n}") {
            Ok(())
        } else {
            Err(format!("close: {line}"))
        }
    }

    /// The next signal connection `n` received, waiting for it: `Member [arg] unicast|...`.
    pub fn signal(&mut self, n: usize) -> Result<String, String> {
        let until = Instant::now() + PATIENCE;
        loop {
            if let Some(sig) = self.signals.get_mut(&n).and_then(VecDeque::pop_front) {
                return Ok(sig);
            }
            let line = self
                .line(until)
                .map_err(|e| format!("no signal on connection {n}: {e}"))?;
            if !self.keep_signal(&line) {
                return Err(format!("unexpected line from the peer: {line}"));
            }
        }
    }
}

impl Drop for Peer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
