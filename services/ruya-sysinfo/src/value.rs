//! The collector's result: values by key.

use std::collections::BTreeMap;

/// One value. Sizes are bytes, frequencies MHz, durations seconds.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Text(String),
    Unsigned(u64),
    Bool(bool),
    /// A list of records (the drives).
    Table(Vec<Info>),
}

/// Values by key. `BTreeMap`, so every output is in the same order.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Info(BTreeMap<String, Value>);

impl Info {
    pub fn new() -> Self {
        Info::default()
    }

    pub fn set(&mut self, key: &str, value: Value) {
        self.0.insert(key.to_owned(), value);
    }

    /// A text; an empty one is not set (absent, not "").
    pub fn text(&mut self, key: &str, value: impl AsRef<str>) {
        let value = value.as_ref().trim();
        if !value.is_empty() {
            self.set(key, Value::Text(value.to_owned()));
        }
    }

    pub fn unsigned(&mut self, key: &str, value: u64) {
        self.set(key, Value::Unsigned(value));
    }

    pub fn flag(&mut self, key: &str, value: bool) {
        self.set(key, Value::Bool(value));
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.0.get(key)
    }

    pub fn get_text(&self, key: &str) -> Option<&str> {
        match self.0.get(key) {
            Some(Value::Text(t)) => Some(t),
            _ => None,
        }
    }

    pub fn get_unsigned(&self, key: &str) -> Option<u64> {
        match self.0.get(key) {
            Some(Value::Unsigned(n)) => Some(*n),
            _ => None,
        }
    }

    pub fn get_flag(&self, key: &str) -> Option<bool> {
        match self.0.get(key) {
            Some(Value::Bool(b)) => Some(*b),
            _ => None,
        }
    }

    pub fn get_table(&self, key: &str) -> Option<&[Info]> {
        match self.0.get(key) {
            Some(Value::Table(rows)) => Some(rows),
            _ => None,
        }
    }

    pub fn contains(&self, key: &str) -> bool {
        self.0.contains_key(key)
    }

    pub fn iter(&self) -> impl Iterator<Item = (&String, &Value)> {
        self.0.iter()
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Everything of `other` on top of this.
    pub fn merge(&mut self, other: Info) {
        self.0.extend(other.0);
    }

    /// Only the keys the filter lets through.
    pub fn retain(&mut self, keep: impl Fn(&str) -> bool) {
        self.0.retain(|k, _| keep(k));
    }
}
