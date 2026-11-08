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

    // The spec has no genre yet, so the rows follow what the record says: official apps,
    // apps that play with a controller, everything else, and what is installed.
    function idsFor(key) {
        if (key === "installed")
            return Store.installed.map(a => a.id)
        return Store.results.filter(a => {
            if (key === "featured")
                return a.source === "official"
            if (key === "games")
                return a.controller === "full"
            return a.controller !== "full"
        }).map(a => a.id)
    }

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

    function refreshResults() {
        const ids = Store.results.map(a => a.id)
        if (ids.join("|") !== page.resultIds.join("|"))
            page.resultIds = ids
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
        refreshResults()
    }
    Component.onDestruction: {
        Store.search("")
        Store.controllerFilter = "any"
    }

    Connections {
        target: Store
        function onResultsChanged() { page.refreshResults(); Qt.callLater(page.settleFocus) }
        function onInstalledChanged() { Qt.callLater(page.settleFocus) }
    }

    component AppCard: Item {
        id: card

        required property int index
        required property string modelData
        property real u: 1

        readonly property var app: Store.catalogue.find(a => a.id === modelData) ?? ({})
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
            radius: Theme.radiusM * card.u
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
            radius: Theme.radiusM * card.u
            color: "transparent"
            border.width: card.focused ? Theme.focusRingWidth * card.u : 0
            border.color: Theme.focusRing
        }

        Text {
            id: nameText
            anchors { left: parent.left; right: parent.right; top: art.bottom; topMargin: Theme.spaceXs * card.u }
            text: card.app.name ?? ""
            color: Theme.text
            font.pixelSize: Theme.typeCaption * card.u
            font.weight: Theme.weightDemiBold
            elide: Text.ElideRight
        }

        Text {
            anchors { left: parent.left; right: parent.right; top: nameText.bottom }
            text: card.app.updateAvailable ? qsTr("Update available")
                : card.app.installed ? qsTr("Installed") : (card.app.developer ?? "")
            color: card.app.updateAvailable ? Theme.warningText : Theme.text
            font.pixelSize: Theme.typeMicro * card.u
            font.weight: Theme.weightDemiBold
            elide: Text.ElideRight
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

                    delegate: FocusScope {
                        id: row

                        required property int index
                        required property string modelData
                        property var ids: []

                        function refresh() {
                            const next = page.idsFor(modelData)
                            if (next.join("|") === ids.join("|"))
                                return
                            const keep = Math.max(0, cards.currentIndex)
                            ids = next
                            cards.currentIndex = Math.min(keep, next.length - 1)
                        }

                        objectName: "storeRow_" + modelData
                        width: rowColumn.width
                        visible: ids.length > 0
                        height: visible ? page.rowHeight : 0
                        Component.onCompleted: refresh()

                        Connections {
                            target: Store
                            function onResultsChanged() { row.refresh() }
                            function onInstalledChanged() { row.refresh() }
                        }

                        Text {
                            id: rowHeading
                            height: page.rowTitleHeight
                            verticalAlignment: Text.AlignVCenter
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
                            model: row.ids
                            onCurrentIndexChanged: if (activeFocus) Sfx.navigate()

                            delegate: AppCard { u: page.u }

                            Keys.onReturnPressed: if (currentIndex >= 0) page.openApp(row.ids[currentIndex])
                            Keys.onEnterPressed: if (currentIndex >= 0) page.openApp(row.ids[currentIndex])
                            Keys.onUpPressed: page.moveRow(-1)
                            Keys.onDownPressed: page.moveRow(1)
                        }
                    }
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
            model: page.resultIds
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
