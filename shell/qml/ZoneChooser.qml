pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Two lists to pick a time zone with a controller (T-213): the region on the left (Europe, Asia,
// ...), its cities on the right. Up/Down move in the focused list; Accept or Right on a region goes
// to its cities; Accept on a city chooses it (chosen(zone)); Left or Back on a city goes back to
// the regions, Back on a region emits cancelled(). LB/RB (PageUp/PageDown) move a page. Keys the
// chooser does not use (Start) are left unaccepted for its host, which is modal and takes the rest.
// The host calls start(zone) to open on a zone (or the current one), which focuses the regions.
// A "Search" row above the lists (T-295) emits searchRequested(text); the host opens the on-screen
// keyboard full-screen (this item is sized, so it cannot) and answers with applyFilter(text). While a
// filter is set one flat list of the matching cities replaces the two lists; Back clears the filter
// first (focus returns to Search), then leaves as before.
FocusScope {
    id: chooser

    property real u: 1
    // The object names of the lists and rows are this plus Regions, Cities, Region_<name> and
    // City_<zone>: two choosers (the wizard's and Settings') exist at once.
    property string prefix: "zone"
    // The zone that is set now: marked "Current" in the list, and where start("") begins.
    property string current: ""
    property int visibleRows: 5

    signal chosen(string zone)
    signal cancelled()
    signal searchRequested(string text)

    // What the player typed (trimmed); empty = the two lists. Set through applyFilter().
    property string filter: ""
    readonly property bool filtering: filter.length > 0
    readonly property bool onSearch: searchRow.activeFocus

    readonly property var regions: TimeZone.regions
    readonly property string region: regions.length > 0 && regionList.currentIndex >= 0
                                     && regionList.currentIndex < regions.length ? regions[regionList.currentIndex] : ""
    // Reading timezones makes the binding follow the list when it arrives late.
    readonly property var cities: { const known = TimeZone.timezones; return known.length > 0 && region.length > 0 ? TimeZone.citiesIn(region) : [] }
    readonly property bool inCities: cityList.activeFocus
    // The matching cities across all regions: [{ zone, city, region }], region names as shown.
    readonly property var results: {
        const q = normalize(filter)
        const known = TimeZone.timezones
        if (q.length === 0 || known.length === 0)
            return []
        const out = []
        for (const r of regions) {
            const label = regionLabel(r)
            const regionHit = normalize(r).indexOf(q) >= 0 || normalize(label).indexOf(q) >= 0
            for (const c of TimeZone.citiesIn(r)) {
                if (regionHit || normalize(c.city).indexOf(q) >= 0)
                    out.push({ zone: c.zone, city: c.city, region: label })
            }
        }
        return out
    }
    readonly property var shownCities: filtering ? results : cities
    readonly property string selectedZone: cityList.currentIndex >= 0 && cityList.currentIndex < shownCities.length
                                           ? shownCities[cityList.currentIndex].zone : ""
    readonly property bool loading: regions.length === 0

    implicitWidth: (regionWidth + gap + cityWidth) * u
    implicitHeight: listTop + listHeight
    readonly property real regionWidth: 420
    readonly property real cityWidth: 640
    readonly property real gap: Theme.spaceL
    readonly property real rowStep: (Theme.rowHeight + Theme.spaceS) * u
    readonly property real listHeight: rowStep * visibleRows
    readonly property real listTop: rowStep      // the Search row sits above the lists

    // Lower case, no accents, Turkish dotless i as i, "_" as a space: "İstanbul" and "istanbul" match,
    // "Zürich" and "zurich" too. NFD splits an accent off its letter; the combining marks go.
    function normalize(text) {
        let out = ""
        for (const ch of (text ?? "").normalize("NFD")) {
            const code = ch.codePointAt(0)
            if (code >= 0x300 && code <= 0x36f)
                continue                    // a combining accent
            out += code === 0x131 ? "i" : ch    // the Turkish dotless i
        }
        return out.toLowerCase().split("_").join(" ").trim()
    }

    // The host's keyboard answered: filter by `text` and land on the first result (Search when none).
    function applyFilter(text) {
        filter = (text ?? "").trim()
        if (filtering && results.length > 0) {
            cityList.currentIndex = 0
            cityList.positionViewAtIndex(0, ListView.Beginning)
            cityList.forceActiveFocus()
        } else {
            searchRow.forceActiveFocus()
        }
    }

    function clearFilter() {
        Sfx.back()
        filter = ""
        const city = indexOfZone(current)
        cityList.currentIndex = city >= 0 ? city : 0
        searchRow.forceActiveFocus()
    }

    // The words for IANA's region names (the city names stay as IANA spells them).
    function regionLabel(name) {
        switch (name) {
        case "Africa": return qsTr("Africa")
        case "America": return qsTr("Americas")
        case "Antarctica": return qsTr("Antarctica")
        case "Arctic": return qsTr("Arctic")
        case "Asia": return qsTr("Asia")
        case "Atlantic": return qsTr("Atlantic Ocean")
        case "Australia": return qsTr("Australia")
        case "Europe": return qsTr("Europe")
        case "Indian": return qsTr("Indian Ocean")
        case "Pacific": return qsTr("Pacific Ocean")
        case "Other": return qsTr("Other")
        }
        return name
    }

    function indexOfZone(zone) {
        const list = cities ?? []       // not yet evaluated while the component is being created
        for (let i = 0; i < list.length; ++i) {
            if (list[i].zone === zone)
                return i
        }
        return -1
    }

    // Opens on `zone` (else the current zone, else the first region) with the regions focused.
    function start(zone) {
        const target = zone && zone.length > 0 ? zone : current
        wanted = target
        filter = ""
        const wantedRegion = target.length > 0 ? TimeZone.regionOf(target) : ""
        const at = regions.indexOf(wantedRegion)
        regionList.currentIndex = at >= 0 ? at : 0
        const city = indexOfZone(target)
        cityList.currentIndex = city >= 0 ? city : 0
        regionList.positionViewAtIndex(regionList.currentIndex, ListView.Contain)
        cityList.positionViewAtIndex(cityList.currentIndex, ListView.Contain)
        regionList.forceActiveFocus()
    }

    // A new region shows its first city, or the current zone when it is in that region.
    onRegionChanged: {
        const city = indexOfZone(current)
        cityList.currentIndex = city >= 0 ? city : 0
        cityList.positionViewAtIndex(cityList.currentIndex, ListView.Contain)
    }
    // The list arrives after the shell started (or after start()): begin again where we meant to.
    // Not while the chooser is being built: `visible` is not settled then, and start() would take the
    // focus for a picker that is still closed (T-349: the Time zone picker is built on its first
    // opening, so this was the moment the row lost its focus).
    property string wanted: ""
    property bool built: false
    Component.onCompleted: built = true
    onRegionsChanged: if (built && visible && regions.length > 0) start(wanted)

    function move(list, count, delta) {
        if (count <= 0)
            return
        const next = Math.max(0, Math.min(count - 1, list.currentIndex + delta))
        if (next === list.currentIndex)
            return
        list.currentIndex = next
        Sfx.navigate()
    }

    function toCities() {
        if (shownCities.length === 0)
            return
        Sfx.navigate()
        cityList.forceActiveFocus()
    }

    function toRegions() {
        Sfx.navigate()
        regionList.forceActiveFocus()
    }

    function accept() {
        Sfx.select()
        if (!inCities)
            toCities()
        else if (selectedZone.length > 0)
            chosen(selectedZone)
    }

    Keys.onPressed: event => {
        const list = inCities ? cityList : regionList
        const count = inCities ? shownCities.length : regions.length
        switch (event.key) {
        case Qt.Key_Up:
            if (chooser.onSearch) {
                // nothing above Search
            } else if (list.currentIndex <= 0) {
                Sfx.navigate()
                searchRow.forceActiveFocus()
            } else {
                chooser.move(list, count, -1)
            }
            break
        case Qt.Key_Down:
            if (chooser.onSearch) {
                if (chooser.filtering) {
                    if (chooser.results.length > 0)
                        chooser.toCities()
                } else if (!chooser.loading) {
                    Sfx.navigate()
                    regionList.forceActiveFocus()
                }
            } else {
                chooser.move(list, count, 1)
            }
            break
        case Qt.Key_PageUp:
            if (!chooser.onSearch)
                chooser.move(list, count, 1 - chooser.visibleRows)
            break
        case Qt.Key_PageDown:
            if (!chooser.onSearch)
                chooser.move(list, count, chooser.visibleRows - 1)
            break
        case Qt.Key_Right:
            if (!chooser.inCities && !chooser.onSearch)
                chooser.toCities()
            break
        case Qt.Key_Left:
            if (chooser.inCities && !chooser.filtering)
                chooser.toRegions()
            break
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (!event.isAutoRepeat)
                chooser.accept()
            break
        default:
            if (BackKey.isBackOrBackspace(event.key)) {
                if (event.isAutoRepeat) {
                    // a held Back does not walk out of the screen
                } else if (chooser.filtering) {
                    chooser.clearFilter()
                } else if (chooser.inCities) {
                    Sfx.back()
                    regionList.forceActiveFocus()
                } else {
                    chooser.cancelled()
                }
                break
            }
            return          // not ours (Start, ...): the host decides
        }
        event.accepted = true
    }

    SettingRow {
        id: searchRow
        objectName: chooser.prefix + "Search"
        kind: "page"
        width: parent.width
        u: chooser.u
        visible: !chooser.loading
        label: qsTr("Search")
        value: chooser.filter
        onActivated: chooser.searchRequested(chooser.filter)
    }

    Text {
        objectName: chooser.prefix + "NoMatch"
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: chooser.listTop + chooser.rowStep }
        visible: chooser.filtering && chooser.results.length === 0
        text: qsTr("No match")
        color: Theme.text
        font.pixelSize: Theme.typeBody * chooser.u
    }

    Text {
        objectName: chooser.prefix + "Loading"
        anchors.centerIn: parent
        visible: chooser.loading
        text: qsTr("Loading time zones…")
        color: Theme.text
        font.pixelSize: Theme.typeBody * chooser.u
    }

    component ZoneRow: Rectangle {
        id: zoneRow
        property string label
        property bool selected: false      // the list's current row
        property bool listFocused: false   // the list has the focus
        property bool marked: false        // the zone that is set now
        property string detail: ""         // the region, beside a search result
        readonly property bool focused: selected && listFocused
        readonly property bool restingSelection: selected && !listFocused   // the region while the cities have focus (04 §4)

        width: ListView.view ? ListView.view.width : 0
        height: Theme.rowHeight * chooser.u
        radius: height / 2
        color: focused ? Theme.focusFill : restingSelection ? Theme.selectedFill : Theme.glass
        border.width: focused ? Theme.focusRingWidth * chooser.u : 0
        border.color: Theme.focusRing
        Accessible.role: Accessible.ListItem
        Accessible.name: marked ? qsTr("%1, current").arg(label) : label
        Accessible.selected: selected

        GlassLayers {
            objectName: "rowLayers"
            anchors.fill: parent
            u: chooser.u
            radius: parent.radius
            grain: false                // a row is not blurred
            rim: !zoneRow.focused       // the focus ring replaces the rim
        }

        Text {
            anchors { left: parent.left; leftMargin: Theme.spaceL * chooser.u; right: markText.visible ? markText.left : detailText.visible ? detailText.left : parent.right
                      rightMargin: Theme.spaceM * chooser.u; verticalCenter: parent.verticalCenter }
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: zoneRow.label
            color: Theme.text
            font.pixelSize: Theme.typeBody * chooser.u
            font.weight: zoneRow.restingSelection || zoneRow.marked ? Theme.weightDemiBold : Theme.weightRegular
        }
        Text {
            id: detailText
            objectName: "zoneDetail"
            visible: zoneRow.detail.length > 0 && !zoneRow.marked
            anchors { right: parent.right; rightMargin: Theme.spaceL * chooser.u; verticalCenter: parent.verticalCenter }
            textFormat: Text.PlainText
            text: zoneRow.detail
            color: Theme.text
            font.pixelSize: Theme.typeCaption * chooser.u
        }
        Text {
            id: markText
            objectName: "currentWord"
            visible: zoneRow.marked
            anchors { right: markIcon.left; rightMargin: Theme.spaceXxs * chooser.u; verticalCenter: parent.verticalCenter }
            text: qsTr("Current")
            color: Theme.text           // on translucent glass textDim is too faint
            font.pixelSize: Theme.typeCaption * chooser.u
            font.weight: Theme.weightDemiBold
        }
        // The same mark as SettingRow's current item (04 section 5).
        Icon {
            id: markIcon
            objectName: "currentMark"
            visible: zoneRow.marked
            anchors { right: parent.right; rightMargin: Theme.spaceS * chooser.u; verticalCenter: parent.verticalCenter }
            u: chooser.u
            name: "check_circle"
            filled: true
            color: Theme.text
        }
    }

    ListView {
        id: regionList
        objectName: chooser.prefix + "Regions"
        x: 0
        y: chooser.listTop
        width: chooser.regionWidth * chooser.u
        height: chooser.listHeight
        visible: !chooser.loading && !chooser.filtering
        clip: true
        interactive: false
        keyNavigationEnabled: false      // the chooser moves the selection
        spacing: Theme.spaceS * chooser.u
        model: chooser.regions
        focus: true
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Region")

        delegate: ZoneRow {
            id: regionDelegate
            required property int index
            required property string modelData
            objectName: chooser.prefix + "Region_" + modelData
            label: chooser.regionLabel(modelData)
            selected: ListView.isCurrentItem
            listFocused: regionList.activeFocus
            marked: TimeZone.regionOf(chooser.current) === modelData
        }
    }

    ListView {
        id: cityList
        objectName: chooser.prefix + "Cities"
        x: chooser.filtering ? 0 : (chooser.regionWidth + chooser.gap) * chooser.u
        y: chooser.listTop
        width: (chooser.filtering ? chooser.regionWidth + chooser.gap + chooser.cityWidth : chooser.cityWidth) * chooser.u
        height: chooser.listHeight
        visible: !chooser.loading
        clip: true
        interactive: false
        keyNavigationEnabled: false
        spacing: Theme.spaceS * chooser.u
        model: chooser.shownCities
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        Accessible.role: Accessible.List
        Accessible.name: qsTr("City")

        delegate: ZoneRow {
            id: cityDelegate
            required property int index
            required property var modelData
            objectName: chooser.prefix + "City_" + modelData.zone
            label: modelData.city
            detail: chooser.filtering ? (modelData.region ?? "") : ""
            // The chosen city only shows as selected while the cities have the focus: from the
            // regions it is a preview.
            selected: ListView.isCurrentItem && cityList.activeFocus
            listFocused: cityList.activeFocus
            marked: modelData.zone === chooser.current
        }
    }
}
