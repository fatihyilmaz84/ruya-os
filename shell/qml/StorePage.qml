pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell
import "controls"

// The Store (spec 02 §1, 03 §4.2): a toolbar (Search, Show all apps) above four rows of app
// cards. Apps without controller support are hidden unless "Show all apps" is on; the service
// does the filtering (Store.controllerFilter). A search replaces the rows with its results
// until Back. Accept on a card opens the detail page.
Page {
    id: page

    title: qsTr("Store")

    // Row keys never change with the language; titles are bindings (PATTERNS.md).
    readonly property var rowKeys: ["featured", "games", "apps", "installed"]
    property bool searching: false
    property string query: ""
    property var resultIds: []
    // The ids of each row (rowKeys) and of the search grid ("all"), from Store.rowIds (rebuildRows).
    // Neither the rows nor the cards search the catalogue themselves: with a real remote's thousands
    // of apps a scan per card made the Store's first frames take hundreds of milliseconds (T-377).
    property var rowIds: ({ all: [], featured: [], games: [], apps: [], installed: [] })
    // How many times a row's place (slotY) was set: updateSlots touches only the rows whose place moved (T-428).
    property int slotUpdates: 0
    // Counts the catalogue's changes: a card looks its record up again when it moves (Store.app).
    property int catalogueRevision: 0

    readonly property real cardWidth: Theme.cardWidthCompact * u
    readonly property real cardHeight: (Theme.cardArtHeight(Theme.cardWidthCompact) + Theme.cardCaptionHeight) * u
    readonly property real rowTitleHeight: 56 * u
    readonly property real rowHeight: rowTitleHeight + cardHeight + Theme.spaceL * u
    // The lists are `glowPad` larger than their place on every side, so the glow of a card at an edge
    // is not cut off (04 §3.8).
    readonly property real glowPad: Theme.glowPad * u
    // Above and below the free gap is only `spaceM` (the toolbar, the hint bar): a list extends that far
    // and no more, so no card is drawn over the hint bar; the glow is clipped there.
    readonly property real glowPadV: Math.min(Theme.glowPad, Theme.spaceM) * u

    function rowTitle(key) {
        switch (key) {
        case "featured": return qsTr("Featured")
        case "games": return qsTr("Games")
        case "apps": return qsTr("Apps & media")
        case "installed": return qsTr("Installed")
        }
        return ""
    }

    // The spec has no genre yet, so the rows follow what the record says: official apps, apps that
    // play with a controller, everything else, and what is installed (Store.rowIds, one pass in C++:
    // with a real remote's thousands of apps, reading every record in QML cost a long frame, T-377).
    // Every row whose ids changed then takes its new list.
    //
    // While the results are still those of the other filter (the page sets "gamepad" when it opens,
    // and the service's answer follows a moment later) rowIds applies the filter's rule itself, so
    // the rows built in the first frame are already the ones the answer brings and are not built a
    // second time when it arrives. The answer is still what counts: the rows follow it.
    function rebuildRows() {
        const rows = Store.rowIds(Store.controllerFilter === "gamepad")
        page.rowIds = rows
        page.updateSlots()
        if (rows.all.join("|") !== page.resultIds.join("|"))
            page.resultIds = rows.all
        for (let r = 0; r < rowRepeater.count; ++r) {
            const row = rowRepeater.itemAt(r) as StoreRow
            if (row)
                row.refresh()
        }
    }

    // The place each row has in the Column (the rows above it that have apps, times their height),
    // set on the rows whose place moved and on no other (a row's `onScreen` follows it).
    function updateSlots() {
        let above = 0
        for (let r = 0; r < rowRepeater.count; ++r) {
            const row = rowRepeater.itemAt(r) as StoreRow
            if (!row)
                continue
            const y = above * page.rowHeight
            if (row.slotY !== y) {
                row.slotY = y
                page.slotUpdates += 1
            }
            if ((page.rowIds[row.modelData] ?? []).length > 0)
                above += 1
        }
    }

    // The places are multiples of the row height, which follows the UI size `u` (the window's height,
    // Theme.uiScale; the shell binds `u` after the page is made, and the page lives on behind other pages).
    onRowHeightChanged: page.updateSlots()

    function sourceKind(source) {
        return source === "official" ? "success" : source === "developer" ? "warning" : "info"
    }

    function sourceText(source) {
        return source === "official" ? qsTr("Official") : source === "developer" ? qsTr("Developer") : qsTr("Community")
    }

    function openApp(id) {
        Sfx.select()
        page.openRequested("appDetail", { appId: id })
    }

    function beginSearch(text) {
        page.query = text
        page.searching = text.length > 0
        Store.search(text)
        Qt.callLater(page.focusContent)
    }

    function endSearch() {
        page.searching = false
        page.query = ""
        Store.search("")
        Qt.callLater(page.focusContent)
    }

    // First card of the first non-empty row, or the results grid, else the toolbar.
    function focusContent() {
        if (page.searching) {
            if (resultsGrid.count > 0)
                resultsGrid.forceActiveFocus()
            else
                searchRow.forceActiveFocus()
            return
        }
        for (let i = 0; i < rowRepeater.count; ++i) {
            const row = rowRepeater.itemAt(i) as FocusScope
            if (row && row.visible) {
                row.forceActiveFocus()
                return
            }
        }
        searchRow.forceActiveFocus()
    }

    // Rows fill in after the service answers, and a row can vanish under the focus: when
    // nothing inside the page holds focus any more, take the first card.
    function settleFocus() {
        const holder = Window.activeFocusItem
        if (!holder || holder === root || holder === page)
            page.focusContent()
    }

    function currentRowIndex() {
        for (let i = 0; i < rowRepeater.count; ++i) {
            if (rowRepeater.itemAt(i).activeFocus)
                return i
        }
        return -1
    }

    function moveRow(delta) {
        let i = page.currentRowIndex() + delta
        while (i >= 0 && i < rowRepeater.count && !rowRepeater.itemAt(i).visible)
            i += delta
        if (i < 0) {
            Sfx.navigate()
            searchRow.forceActiveFocus()
        } else if (i < rowRepeater.count) {
            Sfx.navigate()
            const row = rowRepeater.itemAt(i)
            row.forceActiveFocus()
            const top = row.y                      // in the column, which sits `glowPadV` into the flickable
            const bottom = row.y + row.height + page.glowPadV
            if (top < flick.contentY)
                flick.contentY = top
            else if (bottom > flick.contentY + flick.height - page.glowPadV)
                flick.contentY = Math.min(bottom + page.glowPadV - flick.height, Math.max(0, flick.contentHeight - flick.height))
        }
    }

    Component.onCompleted: {
        Store.controllerFilter = "gamepad"
        rebuildRows()
    }
    Component.onDestruction: {
        Store.search("")
        Store.controllerFilter = "any"
    }

    Connections {
        target: Store
        function onResultsChanged() { page.rebuildRows(); Qt.callLater(page.settleFocus) }
        function onInstalledChanged() { page.rebuildRows(); Qt.callLater(page.settleFocus) }
        function onCatalogueChanged() { page.catalogueRevision += 1 }
    }

    component AppCard: Item {
        id: card

        required property int index
        required property string modelData
        property real u: 1

        // The record from the Store's index (one lookup, not a scan of the catalogue: T-377), again
        // whenever the catalogue changes (installed flags, details).
        readonly property var app: page.catalogueRevision >= 0 ? Store.app(modelData) : ({})
        readonly property bool focused: (ListView.view ? ListView.isCurrentItem && ListView.view.activeFocus
                                                       : GridView.isCurrentItem && GridView.view.activeFocus)

        objectName: "appCard_" + modelData
        Accessible.role: Accessible.Button
        Accessible.name: (app.name ?? "") + (app.updateAvailable ? ", " + qsTr("Update available")
                                              : app.installed ? ", " + qsTr("Installed") : "")
        width: page.cardWidth
        height: page.cardHeight
        scale: focused ? Theme.focusScale : 1.0
        z: focused ? 1 : 0
        Behavior on scale { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeGlide } }

        GlassShadow {
            objectName: "cardLiftShadow"
            anchors.fill: art
            u: card.u
            radius: art.radius        // one radius for the picture, the shadow's cut-out and the ring (T-314)
            kind: "lift"
            active: card.focused
            glow: art.glowColor
            glowStrength: art.glowStrength
            halo: true
        }

        AppArt {
            id: art
            width: parent.width
            height: Theme.cardArtHeight(width)
            u: card.u
            glowing: true
            appId: card.modelData
            appName: card.app.name ?? ""
            picture: card.app.tile ?? ""

            CardFocusLayers {
                objectName: "cardFocusLayers"
                anchors.fill: parent
                u: card.u
                radius: art.radius
                focused: card.focused
            }

            Badge {
                anchors { left: parent.left; bottom: parent.bottom; margins: Theme.spaceXs * card.u }
                u: card.u
                text: page ? page.sourceText(card.app.source ?? "") : ""
                kind: page ? page.sourceKind(card.app.source ?? "") : "info"
            }
        }

        // The focus ring: above the picture and its badge (a border on the art is covered by the picture).
        Rectangle {
            objectName: "cardRing"
            anchors.fill: art
            radius: art.radius
            color: "transparent"
            border.width: card.focused ? Theme.focusRingWidth * card.u : 0
            border.color: Theme.focusRing
        }

        Text {
            id: nameText
            anchors { left: parent.left; right: parent.right; top: art.bottom; topMargin: Theme.spaceXs * card.u }
            textFormat: Text.PlainText
            text: card.app.name ?? ""
            color: Theme.text
            font.pixelSize: Theme.typeCaption * card.u
            font.weight: Theme.weightDemiBold
            elide: Text.ElideRight
        }

        Text {
            anchors { left: parent.left; right: parent.right; top: nameText.bottom }
            textFormat: Text.PlainText
            text: card.app.updateAvailable ? qsTr("Update available")
                : card.app.installed ? qsTr("Installed") : (card.app.developer ?? "")
            color: card.app.updateAvailable ? Theme.warningText : Theme.text
            font.pixelSize: Theme.typeMicro * card.u
            font.weight: Theme.weightDemiBold
            elide: Text.ElideRight
        }
    }

    // One row: a heading and a horizontal list of cards. Its ids come from the page (rebuildRows);
    // `refresh` keeps the list (and its current card) when they did not change.
    component StoreRow: FocusScope {
        id: row

        required property int index
        required property string modelData
        property var ids: []
        // A row below the fold has no cards until it scrolls into view or takes focus (then keeps
        // them): opening the Store builds the cards of the rows on screen only (T-377). Its height
        // and visibility follow `ids`, so the layout does not wait for the cards.
        // Where the Column puts it (the rows above it that have apps), known before the Column lays out;
        // set by the page's updateSlots, only when it moved.
        property real slotY: 0
        // The card the player left this row on, kept while the row has no cards to hold it (not built
        // yet, or emptied for a moment); applied when its model fills.
        property int pendingIndex: -1
        readonly property bool onScreen: page.glowPadV + slotY < flick.contentY + flick.height
        property bool cardsBuilt: false
        readonly property bool wantsCards: onScreen || activeFocus
        onWantsCardsChanged: if (wantsCards) cardsBuilt = true

        function refresh() {
            const next = page.rowIds[modelData] ?? []
            if (next.join("|") === ids.join("|"))
                return
            const keep = cards.count > 0 ? Math.max(0, cards.currentIndex) : Math.max(0, pendingIndex)
            ids = next
            pendingIndex = keep
            row.applyPendingIndex()
        }

        // The remembered card goes to the list as soon as it has cards (they may come later: a row
        // below the fold builds them when it shows). A list that fills puts its current card on the
        // first one when it lays out, so it is laid out first.
        function applyPendingIndex() {
            if (pendingIndex < 0 || cards.count === 0)
                return
            cards.forceLayout()
            cards.currentIndex = Math.min(pendingIndex, cards.count - 1)
            pendingIndex = -1
        }

        objectName: "storeRow_" + modelData
        width: rowColumn.width
        visible: ids.length > 0
        height: visible ? page.rowHeight : 0
        Component.onCompleted: {
            refresh()
            if (wantsCards)
                cardsBuilt = true      // on screen from the start: no change signal to latch it
        }

        Text {
            id: rowHeading
            height: page.rowTitleHeight
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            text: page.rowTitle(row.modelData)
            color: Theme.text
            font.pixelSize: Theme.typeHeadline * page.u
            font.weight: Theme.weightDemiBold
        }

        ListView {
            id: cards
            objectName: "storeCards_" + row.modelData
            Accessible.role: Accessible.List
            Accessible.name: currentItem ? currentItem.Accessible.name : page.rowTitle(row.modelData)
            anchors { left: parent.left; right: parent.right; top: rowHeading.bottom }
            height: page.cardHeight + Theme.cardGap * page.u
            focus: true
            orientation: ListView.Horizontal
            spacing: Theme.cardGap * page.u
            leftMargin: Theme.spaceS * page.u
            rightMargin: Theme.spaceS * page.u
            topMargin: Theme.spaceS * page.u
            keyNavigationEnabled: true
            highlightMoveDuration: 0
            model: row.cardsBuilt || row.wantsCards ? row.ids : []
            onCurrentIndexChanged: if (activeFocus) Sfx.navigate()
            onCountChanged: Qt.callLater(row.applyPendingIndex)

            delegate: AppCard { u: page.u }

            Keys.onReturnPressed: if (currentIndex >= 0) page.openApp(row.ids[currentIndex])
            Keys.onEnterPressed: if (currentIndex >= 0) page.openApp(row.ids[currentIndex])
            Keys.onUpPressed: page.moveRow(-1)
            Keys.onDownPressed: page.moveRow(1)
        }
    }

    FocusScope {
        id: root
        anchors.fill: parent
        focus: true

        // Back leaves a search first; only then the page.
        Keys.onPressed: event => {
            if (page.searching && BackKey.isBackOrBackspace(event.key)) {
                Sfx.back()
                page.endSearch()
                event.accepted = true
            }
        }

        FocusScope {
            id: toolbar
            objectName: "storeToolbar"
            width: parent.width
            height: Theme.rowHeight * page.u

            SettingRow {
                id: searchRow
                objectName: "storeSearch"
                kind: "page"
                width: toolbar.width * 0.5 - Theme.spaceS * page.u
                u: page.u
                label: qsTr("Search")
                value: page.query
                onActivated: searchEntry.open(qsTr("Search the Store"), page.query, {})
                Keys.onRightPressed: { Sfx.navigate(); showAll.forceActiveFocus() }
                Keys.onDownPressed: { Sfx.navigate(); page.focusContent() }
            }

            ToggleRow {
                id: showAll
                objectName: "storeShowAll"
                x: toolbar.width * 0.5 + Theme.spaceS * page.u
                width: toolbar.width * 0.5 - Theme.spaceS * page.u
                u: page.u
                label: qsTr("Show all apps")
                checked: Store.controllerFilter === "any"
                onToggled: checked => Store.controllerFilter = checked ? "any" : "gamepad"
                Keys.onLeftPressed: { Sfx.navigate(); searchRow.forceActiveFocus() }
                Keys.onDownPressed: { Sfx.navigate(); page.focusContent() }
            }
        }

        Flickable {
            id: flick
            objectName: "storeRows"
            visible: !page.searching
            anchors {
                left: parent.left; leftMargin: -page.glowPad
                right: parent.right; rightMargin: -page.glowPad
                top: toolbar.bottom; topMargin: Theme.spaceM * page.u - page.glowPadV
                bottom: parent.bottom; bottomMargin: -page.glowPadV
            }
            contentWidth: width
            contentHeight: rowColumn.height + 2 * page.glowPadV
            clip: true
            interactive: false
            Behavior on contentY { NumberAnimation { duration: Theme.focusMs; easing.type: Easing.OutCubic } }

            Column {
                id: rowColumn
                x: page.glowPad
                y: page.glowPadV
                width: flick.width - 2 * page.glowPad

                Repeater {
                    id: rowRepeater
                    model: page.rowKeys

                    delegate: StoreRow { }
                }
            }
        }

        GridView {
            id: resultsGrid
            objectName: "storeResults"
            Accessible.role: Accessible.List
            Accessible.name: currentItem ? currentItem.Accessible.name : qsTr("Search results")
            visible: page.searching
            anchors {
                left: parent.left; leftMargin: -page.glowPad
                right: parent.right; rightMargin: -page.glowPad
                top: toolbar.bottom; topMargin: Theme.spaceM * page.u - page.glowPadV
                bottom: parent.bottom; bottomMargin: -page.glowPadV
            }
            clip: true
            cellWidth: page.cardWidth + Theme.cardGap * page.u
            cellHeight: page.cardHeight + Theme.cardGap * page.u
            leftMargin: page.glowPad + Theme.spaceS * page.u
            topMargin: page.glowPadV + Theme.spaceS * page.u
            keyNavigationEnabled: true
            highlightMoveDuration: 0
            // Only while searching: hidden behind the rows, it would build a screen of cards for nothing (T-377).
            model: page.searching ? page.resultIds : []
            onCurrentIndexChanged: if (activeFocus) Sfx.navigate()

            delegate: AppCard { u: page.u }

            Keys.onReturnPressed: if (currentIndex >= 0) page.openApp(page.resultIds[currentIndex])
            Keys.onEnterPressed: if (currentIndex >= 0) page.openApp(page.resultIds[currentIndex])
            Keys.onUpPressed: {
                if (currentIndex < Math.max(1, Math.floor((width - 2 * page.glowPad) / cellWidth))) {
                    Sfx.navigate()
                    searchRow.forceActiveFocus()
                } else {
                    moveCurrentIndexUp()
                }
            }
        }

        Text {
            objectName: "storeNoResults"
            visible: page.searching && page.resultIds.length === 0
            anchors { horizontalCenter: parent.horizontalCenter; top: toolbar.bottom; topMargin: Theme.spaceXxl * page.u }
            textFormat: Text.PlainText
            text: qsTr("No apps found for \"%1\"").arg(page.query)
            color: Theme.text
            font.pixelSize: Theme.typeBody * page.u
        }
    }

    TextEntry {
        id: searchEntry
        objectName: "storeSearchEntry"
        parent: page.overlay
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        u: page.u
        onAccepted: text => page.beginSearch(text.trim())
    }
}
