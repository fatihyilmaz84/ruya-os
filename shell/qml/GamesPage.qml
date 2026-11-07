pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell
import "controls"

// Games (spec 02 §1): the installed games as hero-size art cards (04 §5: 400 design px wide,
// as many columns as fit, 4 at 1080p), with a source filter. Accept asks the library to launch the
// game (Library.launch); the session service does the rest later. An empty library shows an empty
// state with a button to the Store.
Page {
    id: page

    title: qsTr("Games")

    readonly property real gap: Theme.cardGap * u
    readonly property real cardWidth: Theme.cardWidthHero * u
    readonly property int columns: Math.max(1, Math.floor((grid.width - grid.leftMargin) / (cardWidth + gap)))
    property string sourceFilter: "all"

    // Ids of the games to show; a list of ids keeps the grid from rebuilding on unrelated changes.
    readonly property var shownIds: Library.games
        .filter(g => page.sourceFilter === "all" || g.source === page.sourceFilter)
        .map(g => g.id)

    function launch(id) {
        const g = Library.item(id)
        Sfx.select()
        Library.launch(id)
        Notifications.show(qsTr("Starting %1…").arg(g.title ?? id), "info")
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
            anchors { left: parent.left; right: parent.right; top: filterRow.bottom; topMargin: Theme.spaceM * page.u; bottom: parent.bottom }
            clip: true
            focus: true
            leftMargin: Theme.spaceS * page.u
            topMargin: Theme.spaceS * page.u
            cellWidth: page.cardWidth + page.gap
            cellHeight: Theme.cardArtHeight(page.cardWidth) + page.gap
            keyNavigationEnabled: true
            highlightMoveDuration: 0
            model: page.shownIds
            onCurrentIndexChanged: if (activeFocus) Sfx.navigate()

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
            }

            Keys.onReturnPressed: page.acceptCurrent()
            Keys.onEnterPressed: page.acceptCurrent()
            Keys.onUpPressed: {
                if (currentIndex < page.columns) {
                    Sfx.navigate()
                    filterRow.forceActiveFocus()
                } else {
                    moveCurrentIndexUp()
                }
            }
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
