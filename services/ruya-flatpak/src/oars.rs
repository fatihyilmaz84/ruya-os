//! The age label of an OARS 1.1 answer: the one mapping from content attributes to `all`, `7+`,
//! `12+`, `16+` or `18+` (docs/specs/05-play-packages.md section 3: the shell derives the label),
//! and the one table of severity words.
//!
//! `ruya-store` rates a Flathub app's AppStream `content_rating` with it and `ruya-play` rates a
//! package's `age_rating`, so both show the same label for the same answers; `ruya-play-format`
//! validates a manifest's answers against the same [`OARS_VALUES`].

/// OARS severity words in order, `none` (0) to `intense` (3): the values of `content_attribute`
/// (AppStream) and of a manifest's `age_rating.content` (05 section 3), closed.
pub const OARS_VALUES: [&str; 4] = ["none", "mild", "moderate", "intense"];

/// A severity word's level, 0 (none) to 3 (intense); a word that is not one counts as none.
fn severity(word: &str) -> u8 {
    let word = word.trim();
    OARS_VALUES
        .iter()
        .position(|v| *v == word)
        .map_or(0, |level| level as u8)
}

/// The OARS 1.1 attributes whose `intense` level means 18+ (the others top out at 16+): sex,
/// sexual violence, drugs and gambling. OARS names gambling `money-gambling`.
fn adult_attribute(id: &str) -> bool {
    ["sex-", "violence-sexual", "drugs-", "money-gambling"]
        .iter()
        .any(|prefix| id.starts_with(prefix))
}

/// The label of `attributes` (OARS attribute id, severity word): the worst answer decides, and an
/// `intense` answer to an [`adult_attribute`] makes it 18+. `None` when there is no answer at all:
/// an unrated app is "Not rated", never "all" (05 section 3).
pub fn age_label<'a>(
    attributes: impl IntoIterator<Item = (&'a str, &'a str)>,
) -> Option<&'static str> {
    let mut rated = false;
    let mut worst = 0;
    let mut adult = false;
    for (id, word) in attributes {
        rated = true;
        let level = severity(word);
        worst = worst.max(level);
        adult |= level >= 3 && adult_attribute(id);
    }
    rated.then_some(match worst {
        0 => "all",
        1 => "7+",
        2 => "12+",
        _ if adult => "18+",
        _ => "16+",
    })
}

#[cfg(test)]
mod tests {
    use super::age_label;

    #[test]
    fn no_answer_is_not_rated() {
        assert_eq!(age_label([]), None);
    }

    #[test]
    fn the_worst_answer_decides() {
        assert_eq!(age_label([("drugs-alcohol", "none")]), Some("all"));
        assert_eq!(
            age_label([("language-humor", "mild"), ("social-chat", "none")]),
            Some("7+")
        );
        assert_eq!(age_label([("violence-fantasy", "moderate")]), Some("12+"));
        assert_eq!(
            age_label([("violence-fantasy", "intense"), ("social-chat", "mild")]),
            Some("16+")
        );
    }

    #[test]
    fn an_intense_adult_attribute_is_18() {
        for id in [
            "sex-nudity",
            "violence-sexual",
            "drugs-tobacco",
            "money-gambling",
        ] {
            assert_eq!(age_label([(id, "intense")]), Some("18+"), "{id}");
            assert_eq!(age_label([(id, "moderate")]), Some("12+"), "{id}");
        }
        // Another attribute's intense answer alongside a milder adult one stays 16+.
        assert_eq!(
            age_label([("violence-fantasy", "intense"), ("sex-nudity", "mild")]),
            Some("16+")
        );
    }

    #[test]
    fn a_word_that_is_not_a_severity_counts_as_none() {
        assert_eq!(age_label([("social-chat", "extreme")]), Some("all"));
    }
}
