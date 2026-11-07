pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Two lists to pick a time zone with a controller (T-213): the region on the left (Europe, Asia,
// ...), its cities on the right. Up/Down move in the focused list; Accept or Right on a region goes
// to its cities; Accept on a city chooses it (chosen(zone)); Left or Back on a city goes back to
// the regions, Back on a region emits cancelled(). LB/RB (PageUp/PageDown) move a page. Keys the
// chooser does not use (Start) are left unaccepted for its host, which is modal and takes the rest.
// The host calls start(zone) to open on a zone (or the current one), which focuses the regions.
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

    readonly property var regions: TimeZone.regions
    readonly property string region: regions.length > 0 && regionList.currentIndex >= 0
                                     && regionList.currentIndex < regions.length ? regions[regionList.currentIndex] : ""
    // Reading timezones makes the binding follow the list when it arrives late.
    readonly property var cities: { const known = TimeZone.timezones; return known.length > 0 && region.length > 0 ? TimeZone.citiesIn(region) : [] }
    readonly property bool inCities: cityList.activeFocus
    readonly property string selectedZone: cityList.currentIndex >= 0 && cityList.currentIndex < cities.length
                                           ? cities[cityList.currentIndex].zone : ""
    readonly property bool loading: regions.length === 0

    implicitWidth: (regionWidth + gap + cityWidth) * u
    implicitHeight: listHeight
    readonly property real regionWidth: 420
    readonly property real cityWidth: 640
    readonly property real gap: Theme.spaceL
    readonly property real rowStep: (Theme.rowHeight + Theme.spaceS) * u
    readonly property real listHeight: rowStep * visibleRows

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
    property string wanted: ""
    onRegionsChanged: if (visible && regions.length > 0) start(wanted)

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
        if (cities.length === 0)
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
        const count = inCities ? cities.length : regions.length
        switch (event.key) {
        case Qt.Key_Up:
            chooser.move(list, count, -1)
            break
        case Qt.Key_Down:
            chooser.move(list, count, 1)
            break
        case Qt.Key_PageUp:
            chooser.move(list, count, 1 - chooser.visibleRows)
            break
        case Qt.Key_PageDown:
            chooser.move(list, count, chooser.visibleRows - 1)
            break
        case Qt.Key_Right:
            if (!chooser.inCities)
                chooser.toCities()
            break
        case Qt.Key_Left:
            if (chooser.inCities)
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
            anchors { left: parent.left; leftMargin: Theme.spaceL * chooser.u; right: markText.visible ? markText.left : parent.right
                      rightMargin: Theme.spaceM * chooser.u; verticalCenter: parent.verticalCenter }
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: zoneRow.label
            color: Theme.text
            font.pixelSize: Theme.typeBody * chooser.u
            font.weight: zoneRow.restingSelection ? Theme.weightDemiBold : Theme.weightRegular
        }
        Text {
            id: markText
            objectName: "currentMark"
            visible: zoneRow.marked
            anchors { right: parent.right; rightMargin: Theme.spaceL * chooser.u; verticalCenter: parent.verticalCenter }
            text: qsTr("Current")
            color: Theme.text           // on translucent glass textDim is too faint
            font.pixelSize: Theme.typeCaption * chooser.u
            font.weight: Theme.weightDemiBold
        }
    }

    ListView {
        id: regionList
        objectName: chooser.prefix + "Regions"
        x: 0
        width: chooser.regionWidth * chooser.u
        height: chooser.listHeight
        visible: !chooser.loading
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
        x: (chooser.regionWidth + chooser.gap) * chooser.u
        width: chooser.cityWidth * chooser.u
        height: chooser.listHeight
        visible: !chooser.loading
        clip: true
        interactive: false
        keyNavigationEnabled: false
        spacing: Theme.spaceS * chooser.u
        model: chooser.cities
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        Accessible.role: Accessible.List
        Accessible.name: qsTr("City")

        delegate: ZoneRow {
            id: cityDelegate
            required property int index
            required property var modelData
            objectName: chooser.prefix + "City_" + modelData.zone
            label: modelData.city
            // The chosen city only shows as selected while the cities have the focus: from the
            // regions it is a preview.
            selected: ListView.isCurrentItem && cityList.activeFocus
            listFocused: cityList.activeFocus
            marked: modelData.zone === chooser.current
        }
    }
}
