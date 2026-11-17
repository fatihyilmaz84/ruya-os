//! Runner resolution (05 §6.2): one pure function for the developer tool and the launcher.

use ruya_play_format::manifest::{Bundled, Component};
use ruya_play_format::resolve::{
    compare_versions, major_of, resolve, resolve_one, Chosen, Note, Override, SystemRunner,
    Unresolved,
};
use std::cmp::Ordering;
use std::collections::BTreeMap;

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
    resolve_one(c, sys, &none(), o).outcome
}

fn none() -> BTreeMap<String, String> {
    BTreeMap::new()
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
    let r = resolve_one(&c, &[wine("10.2")], &none(), Override::PackageDefault);
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
    let r = resolve_one(&c, &old, &none(), Override::System);
    assert_eq!(r.outcome, Ok(bundled("9.20")));
    assert_eq!(r.notes, vec![Note::OverrideSystemUnavailable]);
    // Bundled asked for, but there is none.
    let r = resolve_one(
        &comp("system", Some("9.0"), None),
        &sys,
        &none(),
        Override::Bundled,
    );
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
        &none(),
        Override::PackageDefault,
    );
    assert!(r.ok());
    assert_eq!(r.components[0].id, "wine");
    assert_eq!(r.components[0].outcome, Ok(system("wine", "10.2")));
    assert_eq!(r.components[0].tested.as_deref(), Some("9.20"));
    assert_eq!(r.components[1].outcome, Ok(bundled("1.0")));
}

fn proton(source: &str, min: Option<&str>, bundled: Option<&str>) -> Component {
    let mut c = comp(source, min, bundled);
    c.id = "proton".into();
    c.kind = "proton".into();
    c
}

fn ge(v: &str) -> SystemRunner {
    SystemRunner::new("proton-ge", v)
}

#[test]
fn a_bundled_valve_proton_is_never_replaced_by_the_system_ge_proton() {
    let sys = [ge("GE-Proton10-9")];
    for source in ["newest", "prefer-system", "prefer-bundled"] {
        let c = proton(source, Some("9"), Some("9.0"));
        // No runner.json family given: a bundled proton is Valve's `proton`.
        assert_eq!(
            chosen(&c, &sys, Override::PackageDefault),
            Ok(bundled("9.0")),
            "{source}"
        );
        // The player's System override cannot cross families either.
        let r = resolve_one(&c, &sys, &none(), Override::System);
        assert_eq!(r.outcome, Ok(bundled("9.0")), "{source}");
        assert_eq!(r.notes, vec![Note::OverrideSystemUnavailable], "{source}");
    }
    // A system `proton` of the same family does count.
    let c = proton("newest", Some("9"), Some("9.0"));
    assert_eq!(
        chosen(
            &c,
            &[SystemRunner::new("proton", "9.5")],
            Override::PackageDefault
        ),
        Ok(system("proton", "9.5"))
    );
}

#[test]
fn the_bundled_copys_declared_family_decides_what_a_system_runner_must_be() {
    let mut families = BTreeMap::new();
    families.insert("proton".to_string(), "proton-ge".to_string());
    let c = proton("newest", Some("9"), Some("GE-Proton9-20"));
    let sys = [ge("GE-Proton10-9")];
    let r = resolve_one(&c, &sys, &families, Override::PackageDefault);
    assert_eq!(r.outcome, Ok(system("proton-ge", "GE-Proton10-9")));
    // And a bundled copy that declares an unrelated family is compared with nothing here.
    families.insert("proton".to_string(), "proton-cachy".to_string());
    let r = resolve_one(&c, &sys, &families, Override::PackageDefault);
    assert_eq!(r.outcome, Ok(bundled("GE-Proton9-20")));
}

#[test]
fn source_system_with_type_proton_means_the_os_ge_proton() {
    let c = proton("system", Some("9"), None);
    assert_eq!(
        chosen(&c, &[ge("GE-Proton10-9")], Override::PackageDefault),
        Ok(system("proton-ge", "GE-Proton10-9"))
    );
    // Valve's proton is accepted for a system lookup only when there is no proton-ge.
    assert_eq!(
        chosen(
            &c,
            &[SystemRunner::new("proton", "9.5")],
            Override::PackageDefault
        ),
        Ok(system("proton", "9.5"))
    );
    // A wine runner never serves a proton component.
    assert!(matches!(
        chosen(&c, &[wine("10.2")], Override::PackageDefault),
        Err(Unresolved::NoSystemRunner { .. })
    ));
}

#[test]
fn a_too_old_ge_proton_never_falls_back_to_another_family() {
    let c = proton("system", Some("GE-Proton10-0"), None);
    let sys = [
        ge("GE-Proton9-27"),
        SystemRunner::new("proton", "GE-Proton11-1"),
    ];
    assert_eq!(
        chosen(&c, &sys, Override::PackageDefault),
        Err(Unresolved::SystemTooOld {
            have: "GE-Proton9-27".into(),
            min: "GE-Proton10-0".into()
        })
    );
}

#[test]
fn the_system_override_does_not_apply_to_source_bundled() {
    let c = comp("bundled", None, Some("9.20"));
    let r = resolve_one(&c, &[wine("10.2")], &none(), Override::System);
    assert_eq!(r.outcome, Ok(bundled("9.20")));
    assert_eq!(r.notes, vec![Note::OverrideSystemUnavailable]);
}

#[test]
fn a_bundled_component_needs_no_runner_list_and_no_family_entry() {
    let c = comp("bundled", None, Some("9.20"));
    assert_eq!(
        chosen(&c, &[], Override::PackageDefault),
        Ok(bundled("9.20"))
    );
    // Runners of other families are not looked at.
    assert_eq!(
        chosen(&c, &[ge("GE-Proton10-9")], Override::PackageDefault),
        Ok(bundled("9.20"))
    );
    let r = resolve_one(&c, &[], &none(), Override::PackageDefault);
    assert!(r.notes.is_empty());
}
