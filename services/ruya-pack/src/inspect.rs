//! `inspect <pkg>`: what the console will show for the package: name, signer and tier, the
//! permissions in the plain words of 05 section 8, the size, the runner and how it resolves, and
//! the state of the art. The signature and tier are decided by the console's own `inspect` step
//! (`ruya-play-trust`), with developer mode on and no store key pinned, as on a developer's console.

use crate::args::{parse, Spec};
use crate::pkg::{self, OpenError};
use crate::report::{items, Reply, Stop};
use crate::validate::{self, RUNNER_VALUES};
use crate::Context;
use ruya_play_format::manifest::Permissions;
use ruya_play_trust::tier::{Gate, Risk, Tier, TierReason};
use ruya_play_trust::{inspect, ListCheck, MemoryTrustStore, StoreKeys, TrustStore};
use serde_json::json;

const SPEC: Spec = Spec {
    values: RUNNER_VALUES,
    switches: &[],
    positionals: (1, 1),
};

/// The words the console shows for a permission request (05 section 8).
pub fn plain_words(key: &str, value: &str) -> String {
    match (key, value) {
        ("input", "controllers") => "Uses controllers",
        ("input", "controllers+keyboard-mouse") => "Uses controllers and keyboard and mouse",
        ("input", "all-devices") => "Accesses all devices",
        ("network", _) => "Uses the network",
        ("removable_media", "read") => "Reads files on USB drives",
        ("removable_media", "write") => "Changes files on USB drives",
        ("multiarch", _) => "Runs 32-bit programs",
        ("gamemode" | "realtime", _) => "Asks the system to prioritise it",
        ("devel", _) => "Can inspect other programs",
        ("network+removable_media", _) => "Uses the network and reaches USB drives",
        _ => "Asks for a permission this tool has no words for",
    }
    .to_string()
}

fn risk_name(r: Risk) -> &'static str {
    match r {
        Risk::Low => "low",
        Risk::Medium => "medium",
        Risk::High => "high",
    }
}

fn gate_name(g: Gate) -> &'static str {
    match g {
        Gate::Allowed => "allowed",
        Gate::AdminPin => "admin PIN",
        Gate::AdminPinWithWarning => "admin PIN with a warning",
        Gate::Refused => "refused",
    }
}

/// The requests of `p` with their words, for the confirm page.
pub fn permission_lines(p: &Permissions, tier: Tier) -> Vec<(String, String, Risk)> {
    ruya_play_trust::assess(tier, p)
        .requests
        .into_iter()
        .map(|r| (r.key.clone(), plain_words(&r.key, &r.value), r.risk))
        .collect()
}

/// `inspect`.
pub fn run(args: &[String], _ctx: &Context) -> Result<Reply, Stop> {
    let p = parse(args, &SPEC)?;
    let runners = validate::runners_from(&p)?;
    let opened = match pkg::open(&p.positional[0]) {
        Ok(o) => o,
        Err(OpenError::Stop(s)) => return Err(s),
        Err(OpenError::Problems(problems)) => {
            return Ok(Reply {
                problems,
                ..Reply::default()
            })
        }
    };
    let mut trust = MemoryTrustStore::new();
    let _ = trust.set_developer_mode(true);
    let store_keys = StoreKeys::none();
    let ctx = ruya_play_trust::Context {
        store_keys: &store_keys,
        trust: &trust,
        blocklist: ListCheck::NotChecked,
        runner_hashes: &[],
        verify_content: true,
    };
    let inspection = match inspect(&*opened.source, &ctx) {
        Ok(i) => i,
        Err(refusal) => {
            return Ok(Reply {
                problems: items(&refusal.problems()),
                ..Reply::default()
            })
        }
    };
    let checked = validate::check(&*opened.source, &runners, opened.file_bytes);
    let pk = &inspection.package;
    let m = &pk.manifest;
    let name = m
        .name
        .get("en")
        .or_else(|| m.name.values().next())
        .cloned()
        .unwrap_or_default();
    let tier = inspection.tier.tier;
    let signer = inspection.signatures.key().map(|k| k.key_id());
    let reason = match inspection.tier.reason {
        TierReason::StoreCountersigned => "countersigned by the store",
        TierReason::DeveloperSigned => "signed by a developer key",
        TierReason::UnsignedInDeveloperMode => "not signed; installs only in developer mode",
    };
    let mut text = format!("{name} {} (build {})\n  id: {}\n", m.version, m.build, m.id);
    if let Some(d) = &m.developer {
        text.push_str(&format!("  developer (self-asserted): {}\n", d.name));
    }
    text.push_str(&match &signer {
        Some(id) => format!("  signer: key {id}; tier {} ({reason})\n", tier.as_str()),
        None => format!("  signer: none; tier {} ({reason})\n", tier.as_str()),
    });
    text.push_str("  permissions:\n    Plays sound, uses graphics\n");
    let mut perms = Vec::new();
    for (key, words, risk) in permission_lines(&m.permissions, tier) {
        text.push_str(&format!("    {words} [{}]\n", risk_name(risk)));
        perms.push(json!({"key": key, "words": words, "risk": risk_name(risk)}));
    }
    text.push_str(&format!(
        "  admin gate on a console: {}\n",
        gate_name(inspection.assessment.gate)
    ));
    text.push_str(&format!(
        "  size: {} MB installed ({} files){}\n",
        pk.installed_mb(),
        pk.files.len(),
        if opened.is_dir {
            String::new()
        } else {
            format!("; the zip is {} bytes", opened.file_bytes)
        }
    ));
    text.push_str(&format!("  runner: {}\n", m.run.runner));
    if let Some(r) = &checked.resolution {
        text.push_str(&validate::resolution_text(r));
    }
    if !checked.not_checked.is_empty() {
        text.push_str(&format!(
            "  runner choice not checked for: {} (name the system runners with --system-wine and friends)\n",
            checked.not_checked.join(", ")
        ));
    }
    text.push_str("  art:\n");
    for a in &checked.art {
        text.push_str(&format!(
            "    {}: {}\n",
            a.slot,
            a.refused.as_deref().unwrap_or("ok")
        ));
    }

    let mut reply = Reply {
        text,
        warnings: checked.warnings.clone(),
        ..Reply::default()
    };
    let f = &mut reply.fields;
    f.insert("id".into(), json!(m.id));
    f.insert("name".into(), json!(name));
    f.insert("version".into(), json!(m.version));
    f.insert("build".into(), json!(m.build));
    f.insert("tier".into(), json!(tier.as_str()));
    f.insert("tier_reason".into(), json!(reason));
    f.insert("signer_key_id".into(), json!(signer));
    f.insert("permissions".into(), json!(perms));
    f.insert("gate".into(), json!(gate_name(inspection.assessment.gate)));
    f.insert("installed_bytes".into(), json!(pk.installed_bytes));
    f.insert("package_bytes".into(), json!(opened.file_bytes));
    f.insert("runner".into(), json!(m.run.runner));
    f.insert("art".into(), validate::art_json(&checked.art));
    f.insert(
        "resolution".into(),
        checked
            .resolution
            .as_ref()
            .map_or(json!(null), validate::resolution_json),
    );
    f.insert("not_checked".into(), json!(checked.not_checked));
    Ok(reply)
}
