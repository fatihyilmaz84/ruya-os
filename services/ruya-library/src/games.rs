//! Games out of installations (ADR-028, RUY-137): one library index, many installations of one game.
//!
//! An installation is an `Item` of a source (a Steam game, a Flatpak app, a `.play` app; later a ROM or
//! an app-provided game) with its id unchanged, so Session1 records, runner choices and last played
//! keep working. Installations become one game only by an identical identification key (`Key`,
//! confidence `id`) or by the player's link (confidence `confirmed`), never by title: two games with
//! the same title stay two, and each lists the other as a suggestion ("Are these the same game?").
//!
//! The game's id is the id of the installation its group is anchored on: the anchor of the player's
//! link (the game the other one joined), else the installation whose own key the others share, else the
//! lowest id. An ungrouped game's id is its installation's, so every id that existed before is
//! unchanged. Pure: the player's links and preferences come in as `GameChoices` (`choices.rs` keeps
//! them per profile).

use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap};

use ruya_ids::ItemId;

use crate::catalog::{Item, Source};
use crate::choices::Status;

/// An identification key: two installations with an identical key are one game.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Key {
    /// A Steam app id (a Steam game's own; an app-provided game may declare one, RUY-452).
    SteamAppId(String),
    /// A Flatpak application id (a Flatpak or `.play` app's own).
    FlatpakId(String),
    /// The hash `GameData1.Identify` gives a file (a ROM), once it exists.
    ContentHash(String),
}

/// An installation's keys: the one its own id is, then the ones its source declares.
pub fn keys(item: &Item) -> Vec<Key> {
    let own = match ruya_ids::parse_item(&item.id) {
        Some(ItemId::Steam(appid)) => Some(Key::SteamAppId(appid.to_owned())),
        Some(ItemId::Flatpak(id)) => Some(Key::FlatpakId(id.to_owned())),
        None => None,
    };
    own.into_iter()
        .chain(item.declared.iter().cloned())
        .collect()
}

/// How sure the library is that a game's installations are one game.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Confidence {
    /// One installation.
    Single,
    /// The installations share an identification key.
    Id,
    /// The player linked them (at least one joined through a link).
    Confirmed,
}

impl Confidence {
    pub fn as_str(self) -> &'static str {
        match self {
            Confidence::Single => "single",
            Confidence::Id => "id",
            Confidence::Confirmed => "confirmed",
        }
    }
}

/// A profile's own say over its games: the links it confirmed and the installation Play uses. A link
/// or a preference naming an installation that is not installed is kept and ignored; it counts again
/// when the installation comes back.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GameChoices {
    /// Anchor installation id -> the installation ids the player linked to it, in the order linked.
    pub links: BTreeMap<String, Vec<String>>,
    /// Game id -> the installation Play uses.
    pub preferred: BTreeMap<String, String>,
}

impl GameChoices {
    pub fn is_empty(&self) -> bool {
        self.links.is_empty() && self.preferred.is_empty()
    }
}

/// One game: its installations in the fixed order (`rank`) and the one Play uses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Game {
    /// The anchor installation's id (module comment).
    pub id: String,
    /// Where its preference and its link are kept: the anchor of a link that holds one of its
    /// installations (also while that anchor is missing, so nothing moves for good), else `id`.
    pub key: String,
    /// At least one, in the fixed order.
    pub installations: Vec<Item>,
    /// Index into `installations`.
    pub preferred: usize,
    pub confidence: Confidence,
    /// The ids of the other games with the same title, in the library's order.
    pub suggestions: Vec<String>,
}

impl Game {
    /// The game of one installation that nothing groups with another.
    pub fn alone(item: Item) -> Game {
        Game {
            id: item.id.clone(),
            key: item.id.clone(),
            installations: vec![item],
            preferred: 0,
            confidence: Confidence::Single,
            suggestions: Vec::new(),
        }
    }

    /// The installation Play uses: the game's title, art, kind and launch are its.
    pub fn preferred(&self) -> &Item {
        &self.installations[self.preferred]
    }

    /// The latest of its installations.
    pub fn last_played(&self) -> i64 {
        self.installations
            .iter()
            .map(|i| i.last_played)
            .max()
            .unwrap_or(0)
    }

    pub fn holds(&self, installation: &str) -> bool {
        self.installations.iter().any(|i| i.id == installation)
    }
}

/// The fixed order of a game's installations, and the fallback for Play: a `.play` app, then a
/// Flatpak app, then a Steam game, then by id.
fn rank(item: &Item) -> u8 {
    match (item.source, item.play.is_some()) {
        (Source::Flatpak, true) => 0,
        (Source::Flatpak, false) => 1,
        (Source::Steam, _) => 2,
    }
}

fn installation_order(a: &Item, b: &Item) -> Ordering {
    rank(a).cmp(&rank(b)).then_with(|| a.id.cmp(&b.id))
}

/// Whether an installation can start now. Always true until drives can go missing (RUY-139).
pub fn available(_item: &Item) -> bool {
    true
}

/// A title as suggestions compare it: its letters and digits, lower case.
fn title_key(title: &str) -> String {
    title
        .chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// Disjoint sets over the installations' indexes.
struct Sets(Vec<usize>);

impl Sets {
    fn root(&mut self, mut i: usize) -> usize {
        while self.0[i] != i {
            self.0[i] = self.0[self.0[i]];
            i = self.0[i];
        }
        i
    }

    fn join(&mut self, a: usize, b: usize) {
        let (a, b) = (self.root(a), self.root(b));
        if a != b {
            self.0[b.max(a)] = a.min(b);
        }
    }
}

/// The games of `items` (installations with distinct ids, `catalog::merge`'s output) under the
/// profile's `choices`, in the library's order: last played first, then title (case-insensitive),
/// then id.
pub fn group(items: &[Item], choices: &GameChoices) -> Vec<Game> {
    let index: HashMap<&str, usize> = items
        .iter()
        .enumerate()
        .map(|(n, i)| (i.id.as_str(), n))
        .collect();
    let item_keys: Vec<Vec<Key>> = items.iter().map(keys).collect();
    let mut sets = Sets((0..items.len()).collect());

    // An identical key is one game.
    let mut first_with: HashMap<&Key, usize> = HashMap::new();
    for (n, ks) in item_keys.iter().enumerate() {
        for k in ks {
            match first_with.get(k) {
                Some(&m) => sets.join(m, n),
                None => {
                    first_with.insert(k, n);
                }
            }
        }
    }

    // A link is one game; only its installations that are here count.
    let mut linked = vec![false; items.len()];
    let anchors: Vec<&String> = choices.links.keys().collect();
    let link_sets: Vec<Vec<usize>> = choices
        .links
        .iter()
        .map(|(anchor, members)| {
            std::iter::once(anchor)
                .chain(members)
                .filter_map(|id| index.get(id.as_str()).copied())
                .collect()
        })
        .collect();
    for present in link_sets.iter().filter(|p| p.len() > 1) {
        for pair in present.windows(2) {
            sets.join(pair[0], pair[1]);
        }
        for &n in present {
            linked[n] = true;
        }
    }

    let mut groups: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
    for n in 0..items.len() {
        let root = sets.root(n);
        groups.entry(root).or_default().push(n);
    }

    let mut games: Vec<Game> = groups
        .into_values()
        .map(|members| {
            let id = anchor(items, &item_keys, &link_sets, &members);
            let key = link_sets
                .iter()
                .zip(&anchors)
                .find(|(p, _)| p.iter().any(|n| members.contains(n)))
                .map_or_else(|| id.clone(), |(_, a)| (*a).clone());
            let mut installations: Vec<Item> = members.iter().map(|&n| items[n].clone()).collect();
            installations.sort_by(installation_order);
            let confidence = if members.len() == 1 {
                Confidence::Single
            } else if members.iter().any(|&n| linked[n]) {
                Confidence::Confirmed
            } else {
                Confidence::Id
            };
            let chosen = choices.preferred.get(&key).and_then(|want| {
                installations
                    .iter()
                    .position(|i| &i.id == want && available(i))
            });
            let preferred = chosen
                .or_else(|| installations.iter().position(available))
                .unwrap_or(0);
            Game {
                id,
                key,
                installations,
                preferred,
                confidence,
                suggestions: Vec::new(),
            }
        })
        .collect();

    games.sort_by(|a, b| {
        b.last_played()
            .cmp(&a.last_played())
            .then_with(|| {
                a.preferred()
                    .title
                    .to_lowercase()
                    .cmp(&b.preferred().title.to_lowercase())
            })
            .then_with(|| a.id.cmp(&b.id))
    });

    // A title match is only ever a question.
    let titles: Vec<String> = games
        .iter()
        .map(|g| title_key(&g.preferred().title))
        .collect();
    let mut by_title: HashMap<&str, Vec<usize>> = HashMap::new();
    for (n, t) in titles.iter().enumerate().filter(|(_, t)| !t.is_empty()) {
        by_title.entry(t.as_str()).or_default().push(n);
    }
    let suggestions: Vec<Vec<String>> = titles
        .iter()
        .enumerate()
        .map(|(n, t)| {
            by_title
                .get(t.as_str())
                .map(|same| {
                    same.iter()
                        .filter(|&&m| m != n)
                        .map(|&m| games[m].id.clone())
                        .collect()
                })
                .unwrap_or_default()
        })
        .collect();
    for (game, s) in games.iter_mut().zip(suggestions) {
        game.suggestions = s;
    }
    games
}

/// The id of the game of `members` (indexes into `items`, ascending): the first installation here
/// of the first link touching the group (its anchor while it is installed), else the installation
/// whose own key another member shares (a Steam game for its app id), else the lowest id.
fn anchor(
    items: &[Item],
    keys: &[Vec<Key>],
    link_sets: &[Vec<usize>],
    members: &[usize],
) -> String {
    if members.len() > 1 {
        if let Some(&n) = link_sets
            .iter()
            .filter(|p| p.len() > 1)
            .find_map(|p| p.first().filter(|n| members.contains(n)))
        {
            return items[n].id.clone();
        }
        let owner = members
            .iter()
            .filter(|&&n| {
                keys[n].first().is_some_and(|own| {
                    members
                        .iter()
                        .any(|&m| m != n && keys[m].iter().skip(1).any(|k| k == own))
                })
            })
            .map(|&n| &items[n].id)
            .min();
        if let Some(id) = owner {
            return id.clone();
        }
    }
    members
        .iter()
        .map(|&n| &items[n].id)
        .min()
        .cloned()
        .unwrap_or_default()
}

/// The game that holds installation `id`.
pub fn game_of<'a>(games: &'a [Game], id: &str) -> Option<&'a Game> {
    games.iter().find(|g| g.holds(id))
}

/// Takes every link set that names an installation of `game` out of `links`: its ids, anchors first,
/// in order.
fn take_sets(links: &mut BTreeMap<String, Vec<String>>, game: &Game) -> Vec<String> {
    let touching: Vec<String> = links
        .iter()
        .filter(|(anchor, members)| {
            std::iter::once(*anchor)
                .chain(members.iter())
                .any(|id| game.holds(id))
        })
        .map(|(anchor, _)| anchor.clone())
        .collect();
    let mut ids = Vec::new();
    for anchor in touching {
        if let Some(members) = links.remove(&anchor) {
            ids.push(anchor);
            ids.extend(members);
        }
    }
    ids
}

/// `LinkInstallations`: the game of `b` joins the game of `a` (whose id stays). Ok(false) when they
/// are one game already; `Unknown` when either is not installed, `Invalid` for the same installation.
/// The joined game keeps the key of `a`'s game (its link's anchor, also while that installation is
/// missing) and the installation Play used for it: the stored choice, else the one it had, so a link
/// never changes what Play starts. The game of `b` loses its link and its preference.
pub fn link(choices: &mut GameChoices, games: &[Game], a: &str, b: &str) -> Result<bool, Status> {
    let ga = game_of(games, a).ok_or(Status::Unknown)?;
    let gb = game_of(games, b).ok_or(Status::Unknown)?;
    if a == b {
        return Err(Status::Invalid);
    }
    if ga.id == gb.id {
        return Ok(false);
    }
    let mut ids = take_sets(&mut choices.links, ga);
    ids.push(gb.id.clone());
    ids.extend(take_sets(&mut choices.links, gb));
    let mut members: Vec<String> = Vec::new();
    for id in ids {
        if id != ga.key && !members.contains(&id) {
            members.push(id);
        }
    }
    choices.links.insert(ga.key.clone(), members);
    choices.preferred.remove(&gb.key);
    choices
        .preferred
        .entry(ga.key.clone())
        .or_insert_with(|| ga.preferred().id.clone());
    Ok(true)
}

/// `UnlinkInstallation`: the installation leaves the link that put it in its game. `Unknown` when it
/// is not installed, `Invalid` when no link holds it (an installation on its own, or one there by an
/// identical key, has nothing to separate). When the anchor itself leaves, the next linked
/// installation is the anchor. The game's preference goes when it named the leaving installation or
/// the game is left with one installation; otherwise it moves with the game.
pub fn unlink(
    choices: &mut GameChoices,
    games: &[Game],
    installation: &str,
) -> Result<bool, Status> {
    let game = game_of(games, installation).ok_or(Status::Unknown)?;
    let anchor = choices
        .links
        .iter()
        .find(|(anchor, members)| {
            *anchor == installation || members.iter().any(|m| m == installation)
        })
        .map(|(anchor, _)| anchor.clone())
        .ok_or(Status::Invalid)?;
    let mut members = choices.links.remove(&anchor).unwrap_or_default();
    let new_anchor = if anchor == installation {
        (!members.is_empty()).then(|| members.remove(0))
    } else {
        members.retain(|m| m != installation);
        Some(anchor)
    };
    if let Some(new_anchor) = new_anchor.filter(|_| !members.is_empty()) {
        choices.links.insert(new_anchor, members);
    }
    // The game's preference stays with what is left, under its key (a new one when the anchor left),
    // while that is still a game of more than one installation; one for the leaving installation goes.
    if let Some(kept) = choices
        .preferred
        .remove(&game.key)
        .filter(|kept| kept != installation)
    {
        let rest: Vec<Item> = game
            .installations
            .iter()
            .filter(|i| i.id != installation)
            .cloned()
            .collect();
        if let Some(g) =
            game_of(&group(&rest, choices), &kept).filter(|g| g.installations.len() > 1)
        {
            choices.preferred.insert(g.key.clone(), kept);
        }
    }
    Ok(true)
}

/// `SetPreferredInstallation`: Play of `game` uses `installation`. `Unknown` when no such game or
/// installation is installed, `Invalid` when the installation is another game's.
pub fn prefer(
    choices: &mut GameChoices,
    games: &[Game],
    game: &str,
    installation: &str,
) -> Result<bool, Status> {
    let g = games.iter().find(|g| g.id == game).ok_or(Status::Unknown)?;
    if !g.holds(installation) {
        return Err(if game_of(games, installation).is_some() {
            Status::Invalid
        } else {
            Status::Unknown
        });
    }
    if choices.preferred.get(&g.key).map(String::as_str) == Some(installation) {
        return Ok(false);
    }
    choices
        .preferred
        .insert(g.key.clone(), installation.to_owned());
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::Kind;
    use crate::play::PlayInfo;

    fn item(id: &str, title: &str, last_played: i64) -> Item {
        let steam = id.starts_with("steam:");
        Item {
            id: id.into(),
            kind: Kind::Game,
            title: title.into(),
            source: if steam {
                Source::Steam
            } else {
                Source::Flatpak
            },
            launch: id.into(),
            art: Vec::new(),
            last_played,
            play: id.starts_with("flatpak:play.").then(PlayInfo::default),
            declared: Vec::new(),
        }
    }

    fn ids(games: &[Game]) -> Vec<&str> {
        games.iter().map(|g| g.id.as_str()).collect()
    }

    fn installs(g: &Game) -> Vec<&str> {
        g.installations.iter().map(|i| i.id.as_str()).collect()
    }

    fn none() -> GameChoices {
        GameChoices::default()
    }

    /// The calls as the service makes them: on the games `items` make under `c` now.
    fn link_in(c: &mut GameChoices, items: &[Item], a: &str, b: &str) -> Result<bool, Status> {
        let games = group(items, c);
        link(c, &games, a, b)
    }

    fn unlink_in(c: &mut GameChoices, items: &[Item], id: &str) -> Result<bool, Status> {
        let games = group(items, c);
        unlink(c, &games, id)
    }

    fn prefer_in(
        c: &mut GameChoices,
        items: &[Item],
        game: &str,
        id: &str,
    ) -> Result<bool, Status> {
        let games = group(items, c);
        prefer(c, &games, game, id)
    }

    #[test]
    fn the_same_title_with_different_ids_is_two_games_and_a_suggestion() {
        let items = [
            item("steam:220", "Turbo Racer", 10),
            item("flatpak:org.example.Racer", "turbo racer!", 0),
            item("flatpak:org.example.Other", "Other", 5),
        ];
        let games = group(&items, &none());
        assert_eq!(
            ids(&games),
            [
                "steam:220",
                "flatpak:org.example.Other",
                "flatpak:org.example.Racer"
            ]
        );
        assert!(games.iter().all(|g| g.confidence == Confidence::Single));
        assert_eq!(games[0].suggestions, ["flatpak:org.example.Racer"]);
        assert_eq!(games[2].suggestions, ["steam:220"]);
        assert!(games[1].suggestions.is_empty());
    }

    #[test]
    fn an_identical_steam_app_id_from_two_sources_is_one_game() {
        let mut provided = item("flatpak:org.example.Launcher", "Turbo Racer (launcher)", 50);
        provided.declared = vec![Key::SteamAppId("220".into())];
        let items = [item("steam:220", "Turbo Racer", 10), provided];
        let games = group(&items, &none());
        assert_eq!(games.len(), 1);
        let g = &games[0];
        assert_eq!(g.id, "steam:220", "the Steam game owns its app id");
        assert_eq!(g.confidence, Confidence::Id);
        assert_eq!(installs(g), ["flatpak:org.example.Launcher", "steam:220"]);
        assert_eq!(g.last_played(), 50);
        assert_eq!(
            g.preferred().id,
            "flatpak:org.example.Launcher",
            "Flatpak before Steam"
        );
        assert!(g.suggestions.is_empty());
    }

    #[test]
    fn every_ungrouped_id_is_unchanged() {
        let items = [
            item("steam:220", "A", 0),
            item("flatpak:org.example.B", "B", 0),
            item("flatpak:play.com.example.c", "C", 0),
        ];
        let games = group(&items, &none());
        for i in &items {
            let g = game_of(&games, &i.id).unwrap();
            assert_eq!(g.id, i.id);
            assert_eq!(installs(g), [i.id.as_str()]);
            assert_eq!(g.preferred().id, i.id);
        }
    }

    #[test]
    fn a_link_is_one_game_under_the_anchor_and_unlink_splits_it() {
        let items = [
            item("flatpak:org.example.Racer", "Turbo Racer", 0),
            item("flatpak:play.org.example.racer", "Turbo Racer", 7),
        ];
        let mut c = none();
        let games = group(&items, &c);
        assert_eq!(
            link(
                &mut c,
                &games,
                "flatpak:org.example.Racer",
                "flatpak:play.org.example.racer"
            ),
            Ok(true)
        );
        let games = group(&items, &c);
        assert_eq!(
            ids(&games),
            ["flatpak:org.example.Racer"],
            "the anchor's id"
        );
        assert_eq!(games[0].confidence, Confidence::Confirmed);
        assert_eq!(
            installs(&games[0]),
            [
                "flatpak:play.org.example.racer",
                "flatpak:org.example.Racer"
            ]
        );
        assert_eq!(
            games[0].preferred().id,
            "flatpak:org.example.Racer",
            "the anchor game keeps the installation Play used"
        );
        assert_eq!(games[0].last_played(), 7);
        assert!(games[0].suggestions.is_empty(), "one game asks nothing");
        assert_eq!(
            link(
                &mut c,
                &games,
                "flatpak:play.org.example.racer",
                "flatpak:org.example.Racer"
            ),
            Ok(false),
            "one game already"
        );

        assert_eq!(
            unlink(&mut c, &games, "flatpak:play.org.example.racer"),
            Ok(true)
        );
        assert!(c.is_empty(), "{c:?}");
        let games = group(&items, &c);
        assert_eq!(games.len(), 2);
        assert!(games.iter().all(|g| g.confidence == Confidence::Single));
        assert_eq!(
            unlink(&mut c, &games, "flatpak:org.example.Racer"),
            Err(Status::Invalid),
            "nothing to separate"
        );
    }

    #[test]
    fn linking_two_linked_games_keeps_one_anchor() {
        let items = [
            item("flatpak:a.A", "A", 0),
            item("flatpak:b.B", "B", 0),
            item("flatpak:c.C", "C", 0),
            item("flatpak:d.D", "D", 0),
        ];
        let mut c = none();
        link_in(&mut c, &items, "flatpak:a.A", "flatpak:b.B").unwrap();
        link_in(&mut c, &items, "flatpak:c.C", "flatpak:d.D").unwrap();
        link_in(&mut c, &items, "flatpak:d.D", "flatpak:b.B").unwrap();
        let games = group(&items, &c);
        assert_eq!(ids(&games), ["flatpak:c.C"]);
        assert_eq!(c.links.len(), 1, "{c:?}");
        prefer(&mut c, &games, "flatpak:c.C", "flatpak:b.B").unwrap();
        // The anchor leaves: the next linked one carries the game, and its preference.
        unlink(&mut c, &games, "flatpak:c.C").unwrap();
        let games = group(&items, &c);
        assert_eq!(
            c.preferred.get("flatpak:d.D").map(String::as_str),
            Some("flatpak:b.B")
        );
        assert_eq!(c.preferred.len(), 1);
        // d.D's game shows a.A's title "A" (its first installation), so it sorts first.
        assert_eq!(ids(&games), ["flatpak:d.D", "flatpak:c.C"]);
        assert_eq!(
            installs(&games[0]),
            ["flatpak:a.A", "flatpak:b.B", "flatpak:d.D"]
        );
    }

    #[test]
    fn link_refuses_what_is_not_installed_and_itself() {
        let items = [item("flatpak:a.A", "A", 0)];
        let mut c = none();
        let games = group(&items, &c);
        assert_eq!(
            link(&mut c, &games, "flatpak:a.A", "flatpak:gone"),
            Err(Status::Unknown)
        );
        assert_eq!(
            link(&mut c, &games, "flatpak:gone", "flatpak:a.A"),
            Err(Status::Unknown)
        );
        assert_eq!(
            link(&mut c, &games, "flatpak:a.A", "flatpak:a.A"),
            Err(Status::Invalid)
        );
        assert_eq!(unlink(&mut c, &games, "flatpak:gone"), Err(Status::Unknown));
        assert!(c.is_empty());
    }

    #[test]
    fn the_preference_is_kept_and_falls_back_while_its_installation_is_gone() {
        let racer = item("flatpak:org.example.Racer", "Turbo Racer", 0);
        let play = item("flatpak:play.org.example.racer", "Turbo Racer", 0);
        let both = [racer.clone(), play.clone()];
        let mut c = none();
        link_in(&mut c, &both, &racer.id, &play.id).unwrap();
        let games = group(&both, &c);
        assert_eq!(
            c.preferred.get(&racer.id),
            Some(&racer.id),
            "the link stored it"
        );
        assert_eq!(prefer(&mut c, &games, &racer.id, &play.id), Ok(true));
        assert_eq!(prefer(&mut c, &games, &racer.id, &play.id), Ok(false));
        prefer_in(&mut c, &both, &racer.id, &racer.id).unwrap();
        assert_eq!(group(&both, &c)[0].preferred().id, racer.id);

        // A second .play is installed and linked; the chosen Flatpak goes away: .play first.
        let other = item("flatpak:play.org.example.racer2", "Turbo Racer", 0);
        let three = [racer.clone(), play.clone(), other.clone()];
        link_in(&mut c, &three, &racer.id, &other.id).unwrap();
        let without = [play.clone(), other.clone()];
        let games = group(&without, &c);
        assert_eq!(games.len(), 1, "the link holds without its anchor");
        assert_eq!(games[0].preferred().id, play.id, "the fallback order");
        assert_eq!(c.preferred.get(&racer.id), Some(&racer.id), "kept, ignored");
        // It comes back, and so does the choice.
        assert_eq!(group(&three, &c)[0].preferred().id, racer.id);
    }

    #[test]
    fn a_link_takes_the_joined_games_preference_away() {
        let items = [
            item("flatpak:a.A", "A", 0),
            item("flatpak:b.B", "B", 0),
            item("flatpak:c.C", "B", 0),
        ];
        let mut c = none();
        link_in(&mut c, &items, "flatpak:b.B", "flatpak:c.C").unwrap();
        prefer_in(&mut c, &items, "flatpak:b.B", "flatpak:c.C").unwrap();
        link_in(&mut c, &items, "flatpak:a.A", "flatpak:b.B").unwrap();
        assert_eq!(
            c.preferred.get("flatpak:b.B"),
            None,
            "b's game is gone, so is its choice"
        );
        assert_eq!(
            c.preferred.get("flatpak:a.A").map(String::as_str),
            Some("flatpak:a.A")
        );
        assert_eq!(c.preferred.len(), 1, "{c:?}");
    }

    #[test]
    fn a_link_made_while_the_anchor_is_missing_keeps_its_anchor_and_preference() {
        let a = item("flatpak:a.A", "A", 0);
        let b = item("flatpak:b.B", "A", 0);
        let d = item("flatpak:d.D", "A", 0);
        let mut c = none();
        link_in(&mut c, &[a.clone(), b.clone()], &a.id, &b.id).unwrap();
        // a.A is gone (a drive is away): its game is b.B for now; d.D joins it.
        let away = [b.clone(), d.clone()];
        assert_eq!(
            group(&away, &c).len(),
            2,
            "b.B alone: its link has one installation here"
        );
        link_in(&mut c, &away, &b.id, &d.id).unwrap();
        prefer_in(&mut c, &away, &b.id, &d.id).unwrap();
        assert_eq!(
            c.links.keys().collect::<Vec<_>>(),
            [&a.id],
            "the anchor stays a.A: {c:?}"
        );
        assert_eq!(
            c.preferred.keys().collect::<Vec<_>>(),
            [&a.id],
            "the choice under it: {c:?}"
        );
        // a.A comes back: one game under a.A again, with the choice; nothing orphaned.
        let all = [a.clone(), b.clone(), d.clone()];
        let games = group(&all, &c);
        assert_eq!(games.len(), 1, "{c:?}");
        assert_eq!(games[0].id, a.id);
        assert_eq!(
            games[0].preferred().id,
            d.id,
            "the choice is found under the game's key"
        );
        assert!(
            c.preferred.keys().all(|k| *k == games[0].key),
            "no orphaned preference: {c:?}"
        );
    }

    #[test]
    fn prefer_needs_an_installation_of_that_game() {
        let items = [item("flatpak:a.A", "A", 0), item("flatpak:b.B", "B", 0)];
        let mut c = none();
        let games = group(&items, &c);
        assert_eq!(
            prefer(&mut c, &games, "flatpak:a.A", "flatpak:b.B"),
            Err(Status::Invalid)
        );
        assert_eq!(
            prefer(&mut c, &games, "flatpak:a.A", "flatpak:gone"),
            Err(Status::Unknown)
        );
        assert_eq!(
            prefer(&mut c, &games, "flatpak:gone", "flatpak:a.A"),
            Err(Status::Unknown)
        );
        assert!(c.is_empty());
    }

    #[test]
    fn unlink_drops_the_preference_for_the_installation_that_left() {
        let items = [item("flatpak:a.A", "A", 0), item("flatpak:b.B", "A", 0)];
        let mut c = none();
        link_in(&mut c, &items, "flatpak:a.A", "flatpak:b.B").unwrap();
        prefer_in(&mut c, &items, "flatpak:a.A", "flatpak:b.B").unwrap();
        unlink_in(&mut c, &items, "flatpak:b.B").unwrap();
        assert!(c.is_empty(), "{c:?}");
        // A preference for the one that stays goes too: a game of one installation has no choice.
        link_in(&mut c, &items, "flatpak:a.A", "flatpak:b.B").unwrap();
        prefer_in(&mut c, &items, "flatpak:a.A", "flatpak:a.A").unwrap();
        unlink_in(&mut c, &items, "flatpak:b.B").unwrap();
        assert!(c.is_empty(), "{c:?}");
    }

    #[test]
    fn the_game_takes_its_title_and_order_from_the_preferred_installation() {
        let items = [
            item("flatpak:org.example.Racer", "Racer (Flatpak)", 0),
            item("flatpak:play.org.example.racer", "Racer", 0),
            item("flatpak:org.example.Middle", "Middle", 0),
        ];
        let mut c = none();
        link_in(
            &mut c,
            &items,
            "flatpak:org.example.Racer",
            "flatpak:play.org.example.racer",
        )
        .unwrap();
        let games = group(&items, &c);
        assert_eq!(
            ids(&games),
            ["flatpak:org.example.Middle", "flatpak:org.example.Racer"]
        );
        prefer(
            &mut c,
            &games,
            "flatpak:org.example.Racer",
            "flatpak:org.example.Racer",
        )
        .unwrap();
        let games = group(&items, &c);
        assert_eq!(games[0].preferred().title, "Middle");
        assert_eq!(games[1].preferred().title, "Racer (Flatpak)");
    }
}
