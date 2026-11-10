import QtQuick
import QtTest
import RuyaShell

// ArtCard: fallback art, title, state pill.
Item {
    id: host
    width: 400
    height: 300

    Component {
        id: cardComponent
        ArtCard { itemId: "steam:620"; title: "Portal 2" }
    }

    TestCase {
        id: tc
        name: "ArtCard"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
        }

        function test_fallback_title_and_pills() {
            const card = createTemporaryObject(cardComponent, host)
            verify(card)
            compare(findChild(card, "artCardTitle").text, "Portal 2")
            verify(!findChild(card, "artCardPill").visible, "no pill by default")
            compare(card.height, card.width * 9 / 16)
            compare(findChild(card, "artMonogram").text, "P", "fallback art shows the initial")
            card.width = 400
            compare(card.height, 225, "stays 16:9 when the caller sets the width")
            card.running = true
            verify(findChild(card, "artCardPill").visible)
            compare(card.stateText, "Running")
            card.running = false
            card.installing = true
            card.installPercent = 40
            compare(card.stateText, "Installing 40 %")
            verify(findChild(card, "artCardPill").visible)
            compare(card.Accessible.name, "Portal 2, Installing 40 %")
        }

        // T-147 (04 §7): the state pill carries its own opaque fill (toastBackground), so its word reads at
        // 4.5:1 or better over any art tint, a saturated green included (the Running pill was green on green).
        function test_pill_word_reads_over_any_art_tint_data() {
            return Themes.all.map(s => ({ tag: s.key, key: s.key }))
        }

        function test_pill_word_reads_over_any_art_tint(data) {
            const t = Themes.snapshot(Themes.byKey(data.key))
            const tints = [Qt.rgba(0, 0.8, 0, 1), Qt.rgba(0.2, 1, 0.2, 1), Qt.rgba(0, 0.35, 0.1, 1),
                           Qt.rgba(1, 1, 1, 1), Qt.rgba(0, 0, 0, 1), Qt.rgba(1, 0.85, 0, 1)]
            for (const [name, word] of [["Running", t.toastSuccess], ["Installing", t.toastInfo]]) {
                for (const tint of tints) {
                    const fill = ThemeMath.over(t.toastBackground, tint)
                    verify(ThemeMath.contrast(word, fill) >= 4.5,
                           data.tag + " " + name + " over " + tint + ": " + ThemeMath.contrast(word, fill))
                }
            }
        }

        // The pill in the card is that solid pill: toastBackground fill, the status colour on the word and an edge.
        function test_the_cards_pill_is_solid() {
            const card = createTemporaryObject(cardComponent, host)
            card.running = true
            const pill = findChild(card, "artCardPill")
            compare(pill.solid, true)
            compare(pill.color, Theme.toastBackground)
            compare(findChild(pill, "badgeEdge").visible, true)
            compare(findChild(pill, "badgeEdge").color, Theme.toastSuccess)
        }

        function test_hue_follows_id() {
            const a = createTemporaryObject(cardComponent, host)
            const b = createTemporaryObject(cardComponent, host, { itemId: "steam:730" })
            verify(a.focused === false)
            const hueA = findChild(a, "artMonogram").parent.hue
            const hueB = findChild(b, "artMonogram").parent.hue
            verify(hueA !== hueB, "different ids get different tints")
        }
    }
}
