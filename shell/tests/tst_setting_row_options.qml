import QtQuick
import QtTest
import RuyaShell

// A Settings row that has an Options menu (RUY-1176, 02 section 1.7, 04 section 5): `hasOptions` (A acts on release,
// holding A for longPressMs or Start asks for the menu, the Hold ring at the row's right end) and `acceptOpensOptions`
// (A asks for it on press, no hold and no ring). The row only asks (`optionsRequested`); the pane and the Shell
// open the menu (tst_bluetooth). A row without a menu keeps acting on the press and lets Start bubble.
Item {
    id: host
    width: 800
    height: 600

    property int menuKeys: 0

    SettingsPane {
        id: pane
        objectName: "pane"
        anchors.fill: parent
        u: 1

        SettingRow {
            id: plain
            objectName: "plain"
            kind: "item"
            label: "Plain"
        }
        SettingRow {
            id: withMenu
            objectName: "withMenu"
            kind: "item"
            label: "Main action"
            hasOptions: true
        }
        SettingRow {
            id: opensMenu
            objectName: "opensMenu"
            kind: "item"
            label: "Several actions"
            hasOptions: true
            acceptOpensOptions: true
        }
        SettingRow {
            id: verbed
            objectName: "verbed"
            kind: "item"
            label: "Named verb"
            hasOptions: true
            acceptVerb: "Connect"
        }
        SettingRow {
            id: fact
            objectName: "fact"
            kind: "info"
            label: "A fact"
            hasOptions: true
        }
    }

    SignalSpy { id: plainActivated; target: plain; signalName: "activated" }
    SignalSpy { id: plainOptions; target: plain; signalName: "optionsRequested" }
    SignalSpy { id: mainActivated; target: withMenu; signalName: "activated" }
    SignalSpy { id: mainOptions; target: withMenu; signalName: "optionsRequested" }
    SignalSpy { id: severalActivated; target: opensMenu; signalName: "activated" }
    SignalSpy { id: severalOptions; target: opensMenu; signalName: "optionsRequested" }

    // Start on the page above the pane: a row that has no menu lets it through.
    Keys.onMenuPressed: host.menuKeys += 1

    TestCase {
        id: tc
        name: "SettingRowOptions"
        when: windowShown

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            host.menuKeys = 0
            for (const spy of [plainActivated, plainOptions, mainActivated, mainOptions, severalActivated, severalOptions])
                spy.clear()
            pane.forceActiveFocus()
        }

        function focusRow(row) {
            row.forceActiveFocus()
            tryVerify(() => row.activeFocus)
        }

        function ring(row) { return findChild(row, "rowHoldRing") }

        function hintTexts(row) { return row.hints.map(h => (h.action ?? h.actions.join("_")) + " " + h.text).join("|") }

        // A row without a menu: A acts on the press, as before; Start bubbles to whoever is above.
        function test_a_row_without_a_menu_acts_on_press_and_start_bubbles() {
            focusRow(plain)
            keyPress(Qt.Key_Return)
            compare(plainActivated.count, 1, "on the press, not the release")
            keyRelease(Qt.Key_Return)
            compare(plainActivated.count, 1)
            keyClick(Qt.Key_Menu)
            compare(plainOptions.count, 0)
            compare(host.menuKeys, 1, "Start reached the page above")
            compare(ring(plain), null, "no Hold ring is built for it")
            compare(hintTexts(plain), "accept Select|back Back")
        }

        // RUY-1177: an item row can name its own verb on A (a network's "Connect"); the Options hint still follows it.
        function test_an_item_row_can_name_its_verb() {
            compare(hintTexts(verbed), "accept Connect|options Options|back Back")
            compare(hintTexts(withMenu), "accept Select|options Options|back Back", "the default is untouched")
        }

        // hasOptions: a tap acts on release.
        function test_a_tap_acts_on_release() {
            focusRow(withMenu)
            keyPress(Qt.Key_Return)
            compare(mainActivated.count, 0, "nothing on the press")
            keyRelease(Qt.Key_Return)
            compare(mainActivated.count, 1)
            compare(mainOptions.count, 0)
            tryVerify(() => !ring(withMenu).shown, 2000, "and the ring never stays")
        }

        // hasOptions: holding A shows the Hold ring at the row's right end, then asks for the menu; the release does nothing.
        function test_a_hold_shows_the_ring_and_asks_for_the_menu() {
            focusRow(withMenu)
            keyPress(Qt.Key_Return)
            tryVerify(() => ring(withMenu).shown, 2000, "the ring after holdRingDelayMs")
            const r = ring(withMenu)
            const end = r.mapToItem(withMenu, r.width, 0).x
            compare(Math.round(end), Math.round(withMenu.width - Theme.spaceXs * withMenu.u), "`spaceXs` inside the right end")
            compare(Math.round(r.mapToItem(withMenu, 0, r.height / 2).y), Math.round(withMenu.height / 2), "vertically centred")
            tryCompare(mainOptions, "count", 1, 3000)
            verify(!ring(withMenu).shown, "the disc goes when the menu is asked for")
            keyRelease(Qt.Key_Return)
            compare(mainActivated.count, 0, "the release after a hold does nothing")
            compare(mainOptions.count, 1)
        }

        // The press must have been seen on this row: a release that began elsewhere does nothing.
        function test_a_release_whose_press_began_elsewhere_does_nothing() {
            focusRow(withMenu)
            keyRelease(Qt.Key_Return)
            compare(mainActivated.count, 0)
            wait(Theme.longPressMs + 100)
            compare(mainOptions.count, 0, "and starts no hold")
        }

        // Leaving the row while A is held cancels the hold: a hold belongs to one row.
        function test_moving_the_focus_cancels_a_hold() {
            focusRow(withMenu)
            keyPress(Qt.Key_Return)
            tryVerify(() => ring(withMenu).shown, 2000)
            focusRow(plain)
            tryVerify(() => !ring(withMenu).shown, 2000, "the ring is cut")
            wait(Theme.longPressMs + 100)
            compare(mainOptions.count, 0, "no menu opens for a row that lost the focus")
            keyRelease(Qt.Key_Return)
            compare(mainActivated.count, 0)
        }

        // hasOptions: Start asks for the menu at once, the hint says so.
        function test_start_asks_for_the_menu_and_the_hint_says_so() {
            focusRow(withMenu)
            keyClick(Qt.Key_Menu)
            compare(mainOptions.count, 1)
            compare(host.menuKeys, 0, "Start was taken by the row")
            compare(hintTexts(withMenu), "accept Select|options Options|back Back")
            compare(pane.hints.map(h => h.text).join("|"), "Select|Options|Back", "the pane shows the focused row's hints")
        }

        // acceptOpensOptions: A asks on the press, no ring and no hold; Start asks too; the hint is "A Options" alone.
        function test_a_that_opens_the_menu_on_press() {
            focusRow(opensMenu)
            keyPress(Qt.Key_Return)
            compare(severalOptions.count, 1, "on the press")
            compare(severalActivated.count, 0)
            keyRelease(Qt.Key_Return)
            compare(severalOptions.count, 1)
            compare(ring(opensMenu), null, "no Hold ring where A opens the menu")
            keyClick(Qt.Key_Menu)
            compare(severalOptions.count, 2, "the options button opens the same menu")
            compare(hintTexts(opensMenu), "accept Options|back Back", "no second Start Options hint")
        }

        // A fact has no menu, whatever it is told.
        function test_a_fact_ignores_options() {
            fact.enabled = true
            focusRow(fact)
            keyClick(Qt.Key_Return)
            keyClick(Qt.Key_Menu)
            compare(host.menuKeys, 1, "Start bubbles past a fact")
            compare(hintTexts(fact), "back Back")
        }

        // The anchor look: selectedFill and a DemiBold label while the menu is open, with no focus ring.
        function test_the_anchor_look() {
            focusRow(plain)                         // the menu holds the focus in the Shell; any other row stands in here
            const fill = findChild(withMenu, "rowFill")
            const label = findChild(withMenu, "label")
            verify(fill.color !== Theme.selectedFill)
            compare(label.font.weight, Font.Normal)
            withMenu.anchored = true
            tryCompare(fill, "color", Theme.selectedFill)
            compare(label.font.weight, Theme.weightDemiBold)
            compare(fill.border.width, 0, "no ring")
            withMenu.anchored = false
            tryCompare(label.font, "weight", Font.Normal)
            verify(fill.color !== Theme.selectedFill)
        }
    }
}
