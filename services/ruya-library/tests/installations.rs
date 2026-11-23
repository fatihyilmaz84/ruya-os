//! RUY-137: one game, several installations, through the interface the service serves (its rules,
//! without a bus): the player's link and preference per profile, kept across a restart of the
//! service, and what ListItems serves for them.

use std::path::Path;

use ruya_library::choices::Status;
use ruya_library::dbus::{Dict, LibraryIface, Sources};
use ruya_library::flatpak::FixtureLister;
use zbus::zvariant::OwnedValue;

mod common;
use common::{full_deployment, FULL_ROW};

const PLAY: &str = "flatpak:play.com.example.starhopper";
const FLAT: &str = "flatpak:org.example.Hopper";

/// A plain Flatpak app with the .play app's title, and the full .play app of `common`.
fn rows(with_flatpak: bool) -> String {
    let plain = if with_flatpak {
        "org.example.Hopper\tStar Hopper\tflathub\n"
    } else {
        ""
    };
    format!("{plain}{FULL_ROW}")
}

fn library(root: &Path, state: &Path, with_flatpak: bool) -> LibraryIface {
    full_deployment(root);
    let lib = LibraryIface::new(Sources {
        lister: Box::new(FixtureLister::new(&rows(with_flatpak))),
        play_root: root.to_path_buf(),
        play_runners: root.join("runners"),
        choices_dir: state.to_path_buf(),
    });
    lib.activate("p1").unwrap();
    lib
}

fn text(v: &OwnedValue) -> String {
    String::try_from(v.try_clone().unwrap()).unwrap()
}

/// (id, launch, confidence, [(installation id, preferred)]) of each record ListItems serves.
type Seen = (String, String, String, Vec<(String, bool)>);

fn seen(lib: &LibraryIface) -> Vec<Seen> {
    lib.list()
        .iter()
        .map(|rec: &Dict| {
            let installs = Vec::<Dict>::try_from(rec["installations"].try_clone().unwrap())
                .unwrap()
                .iter()
                .map(|i| {
                    let preferred = bool::try_from(i["preferred"].try_clone().unwrap()).unwrap();
                    (text(&i["id"]), preferred)
                })
                .collect();
            (
                text(&rec["id"]),
                text(&rec["launch"]),
                text(&rec["confidence"]),
                installs,
            )
        })
        .collect()
}

fn suggestions(lib: &LibraryIface, id: &str) -> Vec<String> {
    let list = lib.list();
    let rec = list.iter().find(|r| text(&r["id"]) == id).unwrap();
    rec.get("suggestions")
        .map(|s| Vec::<String>::try_from(s.try_clone().unwrap()).unwrap())
        .unwrap_or_default()
}

#[test]
fn two_installations_with_one_title_are_two_games_until_the_player_links_them() {
    let (root, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let lib = library(root.path(), state.path(), true);
    let before = seen(&lib);
    assert_eq!(before.len(), 2, "{before:?}");
    assert!(before
        .iter()
        .all(|(_, _, c, i)| c == "single" && i.len() == 1));
    assert_eq!(suggestions(&lib, PLAY), [FLAT]);
    assert_eq!(suggestions(&lib, FLAT), [PLAY]);

    assert_eq!(
        lib.link("p1", FLAT, PLAY),
        Ok(true),
        "the served list changed"
    );
    assert_eq!(
        seen(&lib),
        [(
            FLAT.to_owned(),
            PLAY.to_owned(),
            "confirmed".to_owned(),
            vec![(PLAY.to_owned(), true), (FLAT.to_owned(), false)]
        )],
        "the anchor's id, the .play's launch (it comes first)"
    );
    assert!(suggestions(&lib, FLAT).is_empty());

    assert_eq!(lib.unlink("p1", PLAY), Ok(true));
    assert_eq!(seen(&lib), before);
    assert_eq!(
        lib.unlink("p1", PLAY),
        Err(Status::Invalid),
        "nothing to separate"
    );
    assert!(
        std::fs::read_dir(state.path()).unwrap().next().is_none(),
        "nothing left to store"
    );
}

#[test]
fn the_preference_survives_a_restart_and_falls_back_while_its_installation_is_gone() {
    let (root, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let lib = library(root.path(), state.path(), true);
    lib.link("p1", FLAT, PLAY).unwrap();
    assert_eq!(lib.prefer("p1", FLAT, FLAT), Ok(true));
    assert_eq!(lib.prefer("p1", FLAT, FLAT), Ok(false), "no change");
    let chosen = vec![(
        FLAT.to_owned(),
        FLAT.to_owned(),
        "confirmed".to_owned(),
        vec![(PLAY.to_owned(), false), (FLAT.to_owned(), true)],
    )];
    assert_eq!(seen(&lib), chosen, "Play launches the Flatpak");

    // The service restarts: ruya-session sets the active profile again, the state is back.
    let again = library(root.path(), state.path(), true);
    assert_eq!(seen(&again), chosen);

    // The Flatpak goes: the .play is a game of its own again, the link and the choice are kept.
    let without = library(root.path(), state.path(), false);
    assert_eq!(
        seen(&without),
        [(
            PLAY.to_owned(),
            PLAY.to_owned(),
            "single".to_owned(),
            vec![(PLAY.to_owned(), true)]
        )]
    );
    assert_eq!(
        seen(&library(root.path(), state.path(), true)),
        chosen,
        "and back"
    );
}

#[test]
fn the_links_are_each_profiles_own() {
    let (root, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let lib = library(root.path(), state.path(), true);
    assert_eq!(lib.link("p2", FLAT, PLAY), Ok(false), "p2 is not in front");
    assert_eq!(seen(&lib).len(), 2, "p1 sees two games");
    assert_eq!(lib.activate("p2"), Ok((true, true)));
    assert_eq!(seen(&lib).len(), 1, "p2's link");
    assert_eq!(lib.activate(""), Ok((true, true)), "nobody: no link");
    assert_eq!(seen(&lib).len(), 2);
}

#[test]
fn the_installation_calls_answer_the_contracts_statuses() {
    let (root, state) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let lib = library(root.path(), state.path(), true);
    assert_eq!(
        lib.link("p1", FLAT, "flatpak:org.gone"),
        Err(Status::Unknown)
    );
    assert_eq!(lib.link("p1", FLAT, FLAT), Err(Status::Invalid));
    assert_eq!(lib.link("../x", FLAT, PLAY), Err(Status::Invalid));
    assert_eq!(
        lib.prefer("p1", FLAT, PLAY),
        Err(Status::Invalid),
        "another game's"
    );
    assert_eq!(
        lib.prefer("p1", "flatpak:org.gone", PLAY),
        Err(Status::Unknown)
    );
    assert_eq!(lib.unlink("p1", "steam:1"), Err(Status::Unknown));
    assert_eq!(lib.activate("../x"), Err(Status::Invalid));
    assert!(std::fs::read_dir(state.path()).unwrap().next().is_none());
}
