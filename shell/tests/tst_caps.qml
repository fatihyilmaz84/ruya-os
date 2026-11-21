import QtQuick
import QtTest
import RuyaShell

// Capitals in the UI language (RUY-804): the hero's eyebrow and the initials of an app's art and a profile card
// follow Turkish, where "i" is "İ" in capitals. Badge and the Install-from-USB heading are in tst_badge / tst_installusb.
Item {
    width: 800
    height: 600

    Component {
        id: heroComponent
        HeroBlock { eyebrow: "Devam et"; title: "Game"; width: 600 }
    }
    Component {
        id: artComponent
        AppArt { appId: "x"; appName: "ilker's game"; width: 200; height: 120 }
    }
    Component {
        id: cardList
        ListView {
            width: 300
            height: 300
            model: [{ name: "ilker", kind: "profile", hasPin: false, avatar: "#336699" }]
            delegate: ProfileCard { width: 200; height: 200 }
        }
    }

    TestCase {
        name: "Caps"
        when: windowShown

        function init() { DeviceSettings.language = "en" }
        function cleanup() { DeviceSettings.language = "en" }

        function test_the_eyebrow_is_in_capitals() {
            const hero = createTemporaryObject(heroComponent, this)
            const eyebrow = findChild(hero, "heroEyebrow")
            compare(eyebrow.text, "DEVAM ET")
            hero.eyebrow = "Pick it in"
            compare(eyebrow.text, "PICK IT IN")
            DeviceSettings.language = "tr"
            tryCompare(CapsText, "language", "tr")
            compare(eyebrow.text, "PİCK İT İN", "the dotted capital I")
            DeviceSettings.language = "en"
            tryCompare(eyebrow, "text", "PICK IT IN")
        }

        function test_an_app_initial_follows_the_language() {
            const art = createTemporaryObject(artComponent, this)
            const letter = findChild(art, "artMonogram")
            compare(letter.text, "I")
            DeviceSettings.language = "tr"
            tryCompare(letter, "text", "İ")
        }

        function test_a_profile_initial_follows_the_language() {
            const list = createTemporaryObject(cardList, this)
            const letter = findChild(list, "profileCardInitial")
            compare(letter.text, "I")
            DeviceSettings.language = "tr"
            tryCompare(letter, "text", "İ")
        }
    }
}
