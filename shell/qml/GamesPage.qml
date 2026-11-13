pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell
import "controls"

// Games (spec 02 §1): the installed games as hero-size art cards (04 §5: 400 design px wide,
// as many columns as fit, 4 at 1080p), with a source filter. Accept asks the library to launch the
// game (Library.launch; the shell shows the launch splash and starts it, T-147); a game with no
// launch path through Session1 opens its details. An empty library shows an empty state with a
// button to the Store.
Page {
    id: page

    title: qsTr("Games")

    readonly property real gap: Theme.cardGap * u
    readonly property real cardWidth: Theme.cardWidthHero * u
    // The grid is `glowPad` larger than its place on every side, so the glow of a card at an edge is
    // not cut off (04 §3.8). Its width is the columns that fit the place (`root.width`) plus the pad, and
    // it is centred, which splits the leftover width between left and right.
    readonly property real glowPad: Theme.glowPad * u
    // Above and below the free gap is only `spaceM` (the filter row, the hint bar): the grid extends
    // that far and no more, so no card is drawn over the hint bar; the glow is clipped there.
    readonly property real glowPadV: Math.min(Theme.glowPad, Theme.spaceM) * u
    readonly property int columns: Math.max(1, Math.floor((root.width + gap) / (cardWidth + gap)))
    property string sourceFilter: "all"

    // Ids of the games to show; a list of ids keeps the grid from rebuilding on unrelated changes.
    readonly property var shownIds: Library.games
        .filter(g => page.sourceFilter === "all" || g.source === page.sourceFilter)
        .map(g => g.id)

    // Accept on a game: it starts (the launch splash is the feedback, T-147). One with no launch path
    // through Session1 (a Steam game) has no Play, so Accept opens its details instead.
    function launch(id) {
        Sfx.select()
        if (Library.sessionAppId(id) === "")
            page.openRequested("details", { id: id })
        else
            Library.launch(id)
    }

    // The game under the cursor has an Options menu with at least one row: the hint bar offers Options
    // (02 §1.7). An item with an empty menu gets no hint; its Menu key still opens the empty menu.
    readonly property bool optionsOffered: grid.activeFocus && grid.currentIndex >= 0 && page.optionRows !== null
        && page.optionRows("games", page.shownIds[grid.currentIndex] ?? "").length > 0
    hints: optionsOffered ? [{ button: "A", text: qsTr("Select") },
                             { button: "Start", text: qsTr("Options") },
                             { button: "B", text: qsTr("Back") },
                             { buttons: ["LB", "RB"], text: qsTr("Sections") }]
                          : [{ button: "A", text: qsTr("Select") }, { button: "B", text: qsTr("Back") }]

    function openOptions() {
        if (grid.currentIndex >= 0 && grid.currentItem)
            page.optionsRequested("games", page.shownIds[grid.currentIndex], grid.currentItem, "card")
    }

    function acceptCurrent() {
        if (grid.currentIndex < 0)
            return
        (grid.currentItem as ArtCard)?.pulse()
        launch(shownIds[grid.currentIndex])
    }

    function focusContent() {
        if (Library.games.length === 0)
            storeButton.forceActiveFocus()
        else if (grid.count > 0)
            grid.forceActiveFocus()
        else
            filterRow.forceActiveFocus()
    }

    // The library answers after the page opens: take focus once something can hold it.
    function settleFocus() {
        const holder = Window.activeFocusItem
        if (!holder || holder === root || holder === page)
            page.focusContent()
    }

    Connections {
        target: Library
        function onItemsChanged() { Qt.callLater(page.settleFocus) }
    }

    FocusScope {
        id: root
        anchors.fill: parent
        focus: true

        ChoiceRow {
            id: filterRow
            objectName: "gamesFilter"
            visible: Library.games.length > 0
            width: parent.width * 0.5
            u: page.u
            label: qsTr("Show")
            options: [
                { value: "all", label: qsTr("All") },
                { value: "steam", label: qsTr("Steam") },
                { value: "flatpak", label: qsTr("Flatpak") }
            ]
            value: page.sourceFilter
            onEdited: v => page.sourceFilter = v
            Keys.onDownPressed: { if (grid.count > 0) { Sfx.navigate(); grid.forceActiveFocus() } }
        }

        GridView {
            id: grid
            objectName: "gamesGrid"
            Accessible.role: Accessible.List
            Accessible.name: currentItem ? currentItem.Accessible.name : qsTr("Games")
            visible: Library.games.length > 0
            width: page.columns * grid.cellWidth - page.gap + 2 * page.glowPad
            anchors {
                horizontalCenter: parent.horizontalCenter
                top: filterRow.bottom; topMargin: Theme.spaceM * page.u - page.glowPadV
                bottom: parent.bottom; bottomMargin: -page.glowPadV
            }
            clip: true
            focus: true
            leftMargin: page.glowPad
            topMargin: page.glowPadV + Theme.spaceS * page.u
            cellWidth: page.cardWidth + page.gap
            cellHeight: Theme.cardArtHeight(page.cardWidth) + page.gap
            keyNavigationEnabled: true
            highlightMoveDuration: 0
            model: page.shownIds
            onCurrentIndexChanged: {
                hold.cancel()
                if (activeFocus)
                    Sfx.navigate()
            }

            delegate: ArtCard {
                id: gameCard

                required property int index
                required property string modelData
                readonly property var game: Library.item(modelData)

                objectName: "gameCard_" + modelData
                u: page.u
                width: page.cardWidth
                itemId: modelData
                title: game.title ?? ""
                picture: game.art ? (game.art.tile ?? "") : ""
                focused: GridView.isCurrentItem && GridView.view.activeFocus
                anchored: GridView.isCurrentItem && page.optionsOpenFor === modelData
                holdShown: GridView.isCurrentItem && hold.ringShown
                holdProgress: hold.ringProgress
            }

            onActiveFocusChanged: if (!activeFocus) hold.cancel()
            // Accept acts on release and a long press opens the Options menu (02 §1.7); Menu opens it at once.
            Keys.onPressed: event => {
                if (hold.press(event)) {
                    event.accepted = true
                } else if (event.key === Qt.Key_Menu) {
                    if (!event.isAutoRepeat)
                        page.openOptions()
                    event.accepted = true
                }
            }
            Keys.onReleased: event => {
                if (hold.release(event))
                    event.accepted = true
            }
            Keys.onUpPressed: {
                if (currentIndex < page.columns) {
                    Sfx.navigate()
                    filterRow.forceActiveFocus()
                } else {
                    moveCurrentIndexUp()
                }
            }
        }

        AcceptHold {
            id: hold
            objectName: "gamesHold"
            onTapped: page.acceptCurrent()
            onLongPressed: page.openOptions()
        }

        Column {
            objectName: "gamesEmpty"
            visible: Library.games.length === 0
            anchors.centerIn: parent
            spacing: Theme.spaceL * page.u

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("No games yet — visit the Store")
                color: Theme.text
                font.pixelSize: Theme.typeBody * page.u
            }

            SettingRow {
                id: storeButton
                objectName: "gamesOpenStore"
                width: 480 * page.u
                u: page.u
                label: qsTr("Open the Store")
                focus: true
                onActivated: page.openRequested("store", {})
            }
        }
    }

    Component.onCompleted: Qt.callLater(page.focusContent)
}
