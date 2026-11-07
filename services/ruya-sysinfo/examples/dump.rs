//! Prints what the collector reads from the machine it runs on, one `key = value` per line
//! (a table as `key[n].field`): `cargo run -p ruya-sysinfo --example dump`. For checking the parsers
//! against a real kernel and for support.

use ruya_sysinfo::{collect, Info, RootSource, Value};

fn show(prefix: &str, info: &Info) {
    for (key, value) in info.iter() {
        match value {
            Value::Text(t) => println!("{prefix}{key} = {t}"),
            Value::Unsigned(n) => println!("{prefix}{key} = {n}"),
            Value::Bool(b) => println!("{prefix}{key} = {b}"),
            Value::Table(rows) => {
                for (i, row) in rows.iter().enumerate() {
                    show(&format!("{prefix}{key}[{i}]."), row);
                }
            }
        }
    }
}

fn main() {
    let info = collect(&RootSource::system());
    show("", &info);
}
