//! The journal line of `ruya-devices` for something that happened (T-335). The service writes to
//! stderr and systemd's journal collects it (`journalctl --user-unit ruya-devices`). Under
//! `cfg(test)` the lines are also kept in a buffer of the calling thread that a test can read.
//!
//! A line says what happened to which device and why. It never holds a PIN, a passkey, a link key
//! or what an agent call carried: the callers pass names and addresses only.

/// Writes `ruya-devices: <line>` to stderr.
pub fn info(line: &str) {
    eprintln!("ruya-devices: {line}");
    #[cfg(test)]
    buffer::push(line);
}

/// A name or address made safe for one journal line: control characters (a newline in a name
/// a remote device chose) become `?`.
pub fn clean(text: &str) -> String {
    text.chars()
        .map(|c| if c.is_control() { '?' } else { c })
        .collect()
}

#[cfg(test)]
mod buffer {
    use std::cell::RefCell;

    thread_local! {
        static LINES: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
    }

    pub fn push(line: &str) {
        LINES.with(|l| l.borrow_mut().push(line.to_owned()));
    }

    pub fn take() -> Vec<String> {
        LINES.with(|l| std::mem::take(&mut *l.borrow_mut()))
    }
}

/// The lines written by this thread since the last call (they are removed).
#[cfg(test)]
pub fn take() -> Vec<String> {
    buffer::take()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_are_kept_for_the_thread_and_taken_once() {
        take();
        info("one");
        info("two");
        assert_eq!(take(), vec!["one".to_owned(), "two".to_owned()]);
        assert!(take().is_empty());
    }

    #[test]
    fn a_newline_in_a_name_cannot_make_a_second_line() {
        assert_eq!(clean("Pad\nruya-devices: fake"), "Pad?ruya-devices: fake");
    }
}
