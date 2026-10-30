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
            compare(card.implicitHeight, card.implicitWidth * 9 / 16)
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

        function test_hue_follows_id() {
            const a = createTemporaryObject(cardComponent, host)
            const b = createTemporaryObject(cardComponent, host, { itemId: "steam:730" })
            verify(a.focused === false)
            verify(a !== b)
        }
    }
}
