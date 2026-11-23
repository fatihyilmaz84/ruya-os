//! The profile items document, JSON v1 (ADR-045, Library1 XML): what `ruya-library profile-scan`
//! prints as the profile's user and what `PutProfileItems` takes. The one owner of the format,
//! both ways: `encode` for the reader, `decode` for the service, which checks everything again
//! because the document comes from a process that runs as the profile.
//!
//! `{"version":1,"items":[{"appid":"<1-10 digits>","name":s,"last_played":x}]}`. Unknown keys are
//! ignored at both levels; `art` (RUY-958) and `facts` (RUY-1070) are reserved for later readers.

use std::collections::HashSet;

use serde_json::{json, Map, Value};

use crate::catalog::{self, Item, Kind, Source};

/// The one version this service reads and the reader writes.
pub const VERSION: u64 = 1;
/// The most bytes a document may have (a real one is a few hundred KiB at most).
pub const MAX_DOCUMENT: usize = 32 * 1024 * 1024;
/// The most items a document may hold; the reader stops there too.
pub const MAX_ITEMS: usize = 4096;

/// One Steam game as the reader found it: the document's item.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Game {
    /// `ruya_ids::valid_steam_appid` digits.
    pub appid: String,
    pub name: String,
    /// Unix seconds, 0 if unknown.
    pub last_played: i64,
}

/// Why a whole document was refused (`PutProfileItems` answers "invalid").
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refused {
    TooLarge,
    NotJson,
    /// Not an object with `"version": 1` and an `items` array.
    WrongShape,
    TooManyItems,
}

impl Refused {
    /// For the journal.
    pub fn as_str(&self) -> &'static str {
        match self {
            Refused::TooLarge => "over 32 MiB",
            Refused::NotJson => "not JSON",
            Refused::WrongShape => "not a version 1 document",
            Refused::TooManyItems => "more than 4096 items",
        }
    }
}

/// The document for `games` (the reader's stdout), at most `MAX_ITEMS` of them.
pub fn encode(games: &[Game]) -> String {
    let items: Vec<Value> = games
        .iter()
        .take(MAX_ITEMS)
        .map(|g| json!({"appid": g.appid, "name": g.name, "last_played": g.last_played}))
        .collect();
    json!({"version": VERSION, "items": items}).to_string()
}

/// The Library items of a document, in the order of `catalog::merge`. The whole document is
/// refused for its size, its syntax, its shape or its item count; a bad item is dropped alone.
pub fn decode(data: &str) -> Result<Vec<Item>, Refused> {
    if data.len() > MAX_DOCUMENT {
        return Err(Refused::TooLarge);
    }
    let doc: Value = serde_json::from_str(data).map_err(|_| Refused::NotJson)?;
    let doc = doc.as_object().ok_or(Refused::WrongShape)?;
    if doc.get("version").and_then(Value::as_u64) != Some(VERSION) {
        return Err(Refused::WrongShape);
    }
    let items = doc
        .get("items")
        .and_then(Value::as_array)
        .ok_or(Refused::WrongShape)?;
    if items.len() > MAX_ITEMS {
        return Err(Refused::TooManyItems);
    }
    let mut seen = HashSet::new();
    let games: Vec<Item> = items
        .iter()
        .filter_map(|v| v.as_object().and_then(game))
        .filter(|g| seen.insert(g.appid.clone()))
        .map(|g| item(&g))
        .collect();
    Ok(catalog::merge(games, Vec::new()))
}

/// One item of the document, `None` when it is to be dropped.
fn game(v: &Map<String, Value>) -> Option<Game> {
    let appid = v.get("appid")?.as_str()?;
    if !ruya_ids::valid_steam_appid(appid) {
        return None;
    }
    let name = catalog::clip(v.get("name")?.as_str()?)?;
    let last_played = match v.get("last_played") {
        None => 0,
        Some(n) => n.as_i64().filter(|n| *n >= 0)?,
    };
    Some(Game {
        appid: appid.to_owned(),
        name,
        last_played,
    })
}

/// The Library item of a Steam game; its launch spec is built here, never read.
pub fn item(g: &Game) -> Item {
    Item {
        id: ruya_ids::steam_item(&g.appid),
        kind: Kind::Game,
        title: g.name.clone(),
        source: Source::Steam,
        launch: format!("steam://rungameid/{}", g.appid),
        art: Vec::new(),
        last_played: g.last_played,
        play: None,
        declared: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn game(appid: &str, name: &str, last_played: i64) -> Game {
        Game {
            appid: appid.into(),
            name: name.into(),
            last_played,
        }
    }

    fn ids(items: &[Item]) -> Vec<&str> {
        items.iter().map(|i| i.id.as_str()).collect()
    }

    #[test]
    fn encode_and_decode_agree() {
        let games = [
            game("220", "Turbo Racer", 5),
            game("400", "Block Puzzle", 0),
        ];
        let items = decode(&encode(&games)).unwrap();
        assert_eq!(ids(&items), ["steam:220", "steam:400"]);
        assert_eq!(items[0].title, "Turbo Racer");
        assert_eq!(items[0].last_played, 5);
        assert_eq!(items[0].kind, Kind::Game);
        assert_eq!(items[0].source, Source::Steam);
        assert_eq!(items[0].launch, "steam://rungameid/220");
    }

    #[test]
    fn whole_documents_are_refused_for_size_syntax_shape_and_count() {
        let big = format!(
            "{{\"version\":1,\"items\":[],\"pad\":\"{}\"}}",
            "x".repeat(MAX_DOCUMENT)
        );
        assert_eq!(decode(&big), Err(Refused::TooLarge));
        assert_eq!(decode("{\"version\":1,"), Err(Refused::NotJson));
        assert_eq!(decode("[]"), Err(Refused::WrongShape));
        assert_eq!(decode("{\"items\":[]}"), Err(Refused::WrongShape));
        assert_eq!(
            decode("{\"version\":2,\"items\":[]}"),
            Err(Refused::WrongShape)
        );
        assert_eq!(
            decode("{\"version\":\"1\",\"items\":[]}"),
            Err(Refused::WrongShape)
        );
        assert_eq!(
            decode("{\"version\":1,\"items\":{}}"),
            Err(Refused::WrongShape)
        );
        let many: Vec<Game> = (0..=MAX_ITEMS)
            .map(|n| game(&n.to_string(), "G", 0))
            .collect();
        let items: Vec<Value> = many
            .iter()
            .map(|g| json!({"appid": g.appid, "name": g.name}))
            .collect();
        let doc = json!({"version": 1, "items": items}).to_string();
        assert_eq!(decode(&doc), Err(Refused::TooManyItems));
        assert_eq!(
            decode(&encode(&many)).unwrap().len(),
            MAX_ITEMS,
            "encode stops at the cap"
        );
        assert_eq!(
            decode("{\"version\":1,\"items\":[]}").unwrap(),
            Vec::new(),
            "an empty list is a list"
        );
    }

    #[test]
    fn only_the_bad_item_is_dropped() {
        let doc = r#"{"version":1,"items":[
            {"appid":"10","name":"Good"},
            {"appid":"12345678901","name":"Eleven digits"},
            {"appid":"","name":"Empty id"},
            {"appid":"1x","name":"Not digits"},
            {"appid":11,"name":"A number"},
            {"appid":"13","name":"   "},
            {"appid":"14","name":"\u0007\u0008"},
            {"appid":"15"},
            {"appid":"16","name":"Negative","last_played":-1},
            {"appid":"17","name":"Text time","last_played":"5"},
            {"appid":"18","name":"Fraction","last_played":1.5},
            "not an object",
            {"appid":"1234567890","name":"Ten digits","last_played":7}
        ]}"#;
        let items = decode(doc).unwrap();
        assert_eq!(ids(&items), ["steam:1234567890", "steam:10"]);
    }

    #[test]
    fn names_are_cut_and_cleaned_and_duplicates_keep_the_first() {
        let long = "n".repeat(200);
        let doc = json!({"version": 1, "items": [
            {"appid": "1", "name": format!(" A\u{1b}[31mb\tc\n ")},
            {"appid": "2", "name": long},
            {"appid": "1", "name": "Second copy", "last_played": 99},
        ]})
        .to_string();
        let items = decode(&doc).unwrap();
        assert_eq!(ids(&items), ["steam:1", "steam:2"]);
        assert_eq!(items[0].title, "A[31mbc");
        assert_eq!(items[0].last_played, 0, "the first copy is kept");
        assert_eq!(items[1].title.chars().count(), 120);
    }

    #[test]
    fn launch_and_unknown_keys_are_never_taken_from_the_document() {
        let doc = r#"{"version":1,"future":true,"items":[
            {"appid":"5","name":"Five","launch":"flatpak:evil","id":"flatpak:x","art":{"tile":"/etc/shadow"},"facts":{}}
        ]}"#;
        let items = decode(doc).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "steam:5");
        assert_eq!(items[0].launch, "steam://rungameid/5");
        assert!(items[0].art.is_empty(), "art is reserved, not read by v1");
    }

    #[test]
    fn order_is_the_merge_order() {
        let games = [
            game("1", "banana", 0),
            game("2", "Apple", 0),
            game("3", "Zeta", 100),
        ];
        assert_eq!(
            ids(&decode(&encode(&games)).unwrap()),
            ["steam:3", "steam:2", "steam:1"]
        );
    }
}
