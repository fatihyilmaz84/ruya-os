//! The private key never appears in any output or error, text or JSON, and a key is never an
//! option value.

mod common;
use base64ct::{Base64, Encoding};
use common::*;
use ruya_pack::{Context, Outcome};

const SEED_FIRST: u8 = 7;

fn secrets() -> Vec<String> {
    let seed: [u8; 32] = core::array::from_fn(|i| SEED_FIRST + i as u8);
    let hex: String = seed.iter().map(|b| format!("{b:02x}")).collect();
    vec![Base64::encode_string(&seed), hex]
}

fn nothing_leaks(o: &Outcome) {
    let all = format!("{}\n{}", o.text, o.json);
    for s in secrets() {
        assert!(!all.contains(&s), "the key appears in:\n{all}");
        // Also not the unpadded form or its first 16 characters.
        assert!(!all.contains(s.trim_end_matches('=')));
        assert!(!all.contains(&s[..16]));
    }
}

#[test]
fn keygen_and_sign_print_the_key_id_and_never_the_key() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("g");
    native(&dir);
    assert_ok(&build(&dir, &[]).0);

    // A generated key: its seed is in the file, nowhere in the output.
    let name = t.path().join("gen");
    let kg = run(&["keygen", name.to_str().unwrap(), "--json"]);
    assert_ok(&kg);
    let text = std::fs::read_to_string(t.path().join("gen.key")).unwrap();
    let seed_line = text.lines().nth(1).unwrap();
    assert!(text.starts_with("ruyaos-play-key-v1\n"));
    for o in [&kg, &run(&["keygen", name.to_str().unwrap()])] {
        let all = format!("{}\n{}", o.text, o.json);
        assert!(!all.contains(seed_line), "the generated seed leaked");
    }
    assert_eq!(kg.json["key_id"].as_str().unwrap().len(), 32);
    let again = run(&["keygen", name.to_str().unwrap()]);
    assert_eq!(
        problem_codes(&again),
        ["key.exists", "key.exists"],
        "a key is never replaced silently"
    );
    assert_eq!(
        std::fs::read_to_string(t.path().join("gen.key")).unwrap(),
        text
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(t.path().join("gen.key"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    // A fixed key: sign with it from a file and from the environment, in text and JSON.
    let key = key_file(t.path(), "k.key", SEED_FIRST);
    let env = Some(secrets()[0].clone());
    let outs = [
        run_p(&["sign", "--key", key.to_str().unwrap()], &[&dir]),
        run_p(&["sign", "--json", "--key", key.to_str().unwrap()], &[&dir]),
        run_with(
            &["sign", "--json", dir.to_str().unwrap()],
            &Context::new(NOW, env.clone()),
        ),
        run_with(
            &["inspect", "--json", dir.to_str().unwrap()],
            &Context::new(NOW, env.clone()),
        ),
        run_with(
            &["validate", dir.to_str().unwrap()],
            &Context::new(NOW, env),
        ),
    ];
    for o in &outs {
        assert_ok(o);
        nothing_leaks(o);
    }
    assert_ok(&outs[0]);
    assert!(outs[0]
        .text
        .contains(outs[1].json["key_id"].as_str().unwrap()));
}

#[test]
fn errors_about_a_bad_key_do_not_repeat_it() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("g");
    native(&dir);
    assert_ok(&build(&dir, &[]).0);
    let secret = &secrets()[0];

    // A key file with a good header and a bad body.
    let bad = t.path().join("bad.key");
    std::fs::write(&bad, format!("ruyaos-play-key-v1\n{secret}extra-junk\n")).unwrap();
    let o = run_p(&["sign", "--key", bad.to_str().unwrap()], &[&dir]);
    assert_eq!(o.exit, 2);
    nothing_leaks(&o);
    assert!(!format!("{}{}", o.text, o.json).contains("extra-junk"));

    // A file with the right body under a wrong header, and with a third line.
    for body in [
        format!("not-a-key-header\n{secret}\n"),
        format!("ruyaos-play-key-v1\n{secret}\nmore\n"),
    ] {
        std::fs::write(&bad, body).unwrap();
        let o = run_p(&["sign", "--key", bad.to_str().unwrap()], &[&dir]);
        assert_eq!(o.exit, 2, "{}", o.text);
        nothing_leaks(&o);
    }

    // A bad environment value.
    let o = run_with(
        &["sign", dir.to_str().unwrap()],
        &Context::new(NOW, Some("hunter2-not-a-key".into())),
    );
    assert_eq!(o.exit, 2);
    assert!(!format!("{}{}", o.text, o.json).contains("hunter2"));

    // The key typed where a file name belongs is not echoed, and no option takes key text.
    let o = run_p(&["sign", "--key", secret], &[&dir]);
    assert_eq!(o.exit, 2);
    nothing_leaks(&o);
    assert!(o.text.contains("not the key itself"), "{}", o.text);
    for flag in ["--private-key", "--seed", "--secret"] {
        let o = run_p(&["sign", flag, secret], &[&dir]);
        assert_eq!(o.exit, 2);
        nothing_leaks(&o);
    }
    // No key at all.
    let o = run_p(&["sign"], &[&dir]);
    assert_eq!(o.exit, 2);
    assert!(o.text.contains("key.missing"), "{}", o.text);
}

#[test]
fn the_debug_form_of_the_context_hides_the_environment_key() {
    let c = Context::new(1, Some(secrets()[0].clone()));
    let shown = format!("{c:?}");
    assert!(
        !shown.contains(&secrets()[0]) && shown.contains("<set>"),
        "{shown}"
    );
}
