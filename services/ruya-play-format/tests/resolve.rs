//! Runner resolution (05 §6.2): one pure function for the developer tool and the launcher.

use ruya_play_format::manifest::{Bundled, Component};
use ruya_play_format::resolve::{
    compare_versions, major_of, resolve, resolve_one, Chosen, Note, Override, SystemRunner,
    Unresolved,
};
use std::cmp::Ordering;

fn comp(source: &str, min: Option<&str>, bundled: Option<&str>) -> Component {
    Component {
        id: "wine".into(),
        kind: "wine".into(),
        source: source.into(),
        min: min.map(Into::into),
        tested: Some("9.20".into()),
        max_major: None,
        bundled: bundled.map(|v| Bundled {
            path: "components/wine".into(),
            version: v.into(),
            licence: "LGPL-2.1-or-later".into(),
            source_url: None,
        }),
    }
}

fn wine(v: &str) -> SystemRunner {
    SystemRunner::new("wine", v)
}

fn chosen(c: &Component, sys: &[SystemRunner], o: Override) -> Result<Chosen, Unresolved> {
    resolve_one(c, sys, o).outcome
}

fn bundled(v: &str) -> Chosen {
    Chosen::Bundled { version: v.into() }
}

fn system(f: &str, v: &str) -> Chosen {
    Chosen::System {
        family: f.into(),
        version: v.into(),
    }
}

#[test]
fn versions_compare_as_numbers() {
    assert_eq!(compare_versions("10.2", "9.20"), Ordering::Greater);
    assert_eq!(compare_versions("9.0", "9"), Ordering::Equal);
    assert_eq!(compare_versions("9.20", "9.3"), Ordering::Greater);
    assert_eq!(
        compare_versions("GE-Proton10-9", "GE-Proton9-27"),
        Ordering::Greater
    );
    assert_eq!(
        (major_of("10.2"), major_of("GE-Proton9-20"), major_of("rc")),
        (10, 9, 0)
    );
}

#[test]
fn newest_takes_the_higher_version_and_a_tie_goes_to_bundled() {
    let c = comp("newest", Some("9.0"), Some("9.20"));
    assert_eq!(
        chosen(&c, &[wine("10.2")], Override::PackageDefault),
        Ok(system("wine", "10.2"))
    );
    assert_eq!(
        chosen(&c, &[wine("9.0")], Override::PackageDefault),
        Ok(bundled("9.20"))
    );
    assert_eq!(
        chosen(&c, &[wine("9.20")], Override::PackageDefault),
        Ok(bundled("9.20"))
    );
    assert_eq!(
        chosen(&c, &[], Override::PackageDefault),
        Ok(bundled("9.20"))
    );
}

#[test]
fn newest_skips_a_system_runner_below_min() {
    let c = comp("newest", Some("11.0"), Some("9.20"));
    assert_eq!(
        chosen(&c, &[wine("10.2")], Override::PackageDefault),
        Ok(bundled("9.20"))
    );
}

#[test]
fn max_major_fences_the_system_runner() {
    let mut c = comp("newest", Some("9.0"), Some("9.20"));
    c.max_major = Some(9);
    let r = resolve_one(&c, &[wine("10.2")], Override::PackageDefault);
    assert_eq!(r.outcome, Ok(bundled("9.20")));
    assert_eq!(
        r.notes,
        vec![Note::FencedByMaxMajor {
            have: "10.2".into()
        }]
    );
    // Inside the fence the higher system version still wins; the fence is on the major only.
    assert_eq!(
        chosen(&c, &[wine("9.22")], Override::PackageDefault),
        Ok(system("wine", "9.22"))
    );
    // Without a bundled copy to fall back on a fenced `system` source fails with a clear cause.
    let mut s = comp("system", Some("9.0"), None);
    s.max_major = Some(9);
    assert_eq!(
        chosen(&s, &[wine("10.2")], Override::PackageDefault),
        Err(Unresolved::SystemTooNew {
            have: "10.2".into(),
            max_major: 9
        })
    );
}

#[test]
fn every_source_has_its_rule() {
    let sys = [wine("10.2")];
    let d = Override::PackageDefault;
    assert_eq!(
        chosen(&comp("bundled", None, Some("9.20")), &sys, d),
        Ok(bundled("9.20"))
    );
    assert_eq!(
        chosen(&comp("prefer-bundled", None, Some("9.20")), &sys, d),
        Ok(bundled("9.20"))
    );
    assert_eq!(
        chosen(&comp("system", Some("9.0"), None), &sys, d),
        Ok(system("wine", "10.2"))
    );
    assert_eq!(
        chosen(&comp("system", Some("11.0"), None), &sys, d),
        Err(Unresolved::SystemTooOld {
            have: "10.2".into(),
            min: "11.0".into()
        })
    );
    assert!(matches!(
        chosen(&comp("system", Some("9.0"), None), &[], d),
        Err(Unresolved::NoSystemRunner { .. })
    ));
    assert_eq!(
        chosen(&comp("prefer-system", Some("9.0"), Some("9.20")), &sys, d),
        Ok(system("wine", "10.2"))
    );
    assert_eq!(
        chosen(&comp("prefer-system", Some("11.0"), Some("9.20")), &sys, d),
        Ok(bundled("9.20"))
    );
    assert_eq!(
        chosen(&comp("bundled", None, None), &sys, d),
        Err(Unresolved::NoBundled)
    );
}

#[test]
fn the_player_override_wins_only_when_it_can() {
    let c = comp("prefer-bundled", Some("9.0"), Some("9.20"));
    let sys = [wine("10.2")];
    assert_eq!(
        chosen(&c, &sys, Override::System),
        Ok(system("wine", "10.2"))
    );
    assert_eq!(
        chosen(
            &comp("system", Some("9.0"), Some("9.20")),
            &sys,
            Override::Bundled
        ),
        Ok(bundled("9.20"))
    );
    // System asked for, but too old: the package default runs, and it says so.
    let old = [wine("8.0")];
    let r = resolve_one(&c, &old, Override::System);
    assert_eq!(r.outcome, Ok(bundled("9.20")));
    assert_eq!(r.notes, vec![Note::OverrideSystemUnavailable]);
    // Bundled asked for, but there is none.
    let r = resolve_one(&comp("system", Some("9.0"), None), &sys, Override::Bundled);
    assert_eq!(r.outcome, Ok(system("wine", "10.2")));
    assert_eq!(r.notes, vec![Note::OverrideBundledUnavailable]);
}

#[test]
fn families_never_replace_each_other() {
    let c = comp("system", Some("9.0"), None);
    let only_proton = [SystemRunner::new("proton-ge", "10.9")];
    assert!(matches!(
        chosen(&c, &only_proton, Override::PackageDefault),
        Err(Unresolved::NoSystemRunner { .. })
    ));
    // A proton component is served by the OS's GE-Proton.
    let mut p = comp("system", Some("9"), None);
    p.id = "proton".into();
    p.kind = "proton".into();
    assert_eq!(
        chosen(&p, &only_proton, Override::PackageDefault),
        Ok(system("proton-ge", "10.9"))
    );
    // An emulator is its own family, named by the component id.
    let mut e = comp("system", Some("0.0.30"), None);
    e.id = "rpcs3".into();
    e.kind = "emulator".into();
    let emus = [SystemRunner::new("rpcs3", "0.0.35"), wine("10.2")];
    assert_eq!(
        chosen(&e, &emus, Override::PackageDefault),
        Ok(system("rpcs3", "0.0.35"))
    );
}

#[test]
fn the_newest_runner_of_a_family_is_used_and_all_components_resolve_in_order() {
    let a = comp("system", Some("9.0"), None);
    let mut b = comp("bundled", None, Some("1.0"));
    b.id = "other".into();
    let r = resolve(
        &[a, b],
        &[wine("9.5"), wine("10.2"), wine("10.1")],
        Override::PackageDefault,
    );
    assert!(r.ok());
    assert_eq!(r.components[0].id, "wine");
    assert_eq!(r.components[0].outcome, Ok(system("wine", "10.2")));
    assert_eq!(r.components[0].tested.as_deref(), Some("9.20"));
    assert_eq!(r.components[1].outcome, Ok(bundled("1.0")));
}
