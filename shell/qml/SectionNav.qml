pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// Section nav (04 §5, §5.5): a glass pill of section pills (Home, Games, Media, Store, Settings) and the notification
// bell, the last section (RUY-1136) but drawn apart, on its own glass pill at `bellX`, which Shell sets to the left edge
// of the status tray (RUY-1170). `keys` stays the one list and `stepSection` the one order. The current section is
// filled with `primaryFill`; the focused pill carries the
// white ring. Left/Right move between pills, Accept emits `activated(key)`, Down leaves downwards, LB/RB
// ask for the next/previous section (`stepRequested`), Back asks to go back (`backRequested`).
// One instance lives in the shell's top layer and is shown on Home and the section pages.
// One FocusGlide highlight glides under the pills to the focused one (04 §3.8).
// The glass blurs a crop of `blurSource` (the shared backdrop layer); with no blur (the
// Performance tier) it is `glassOpaque`. The words and glyphs of the pills at rest are drawn in the top bar's adaptive
// ink (TopBarInk, RUY-1136, 04 §5.5) of the art behind them through the glass (`light`, Shell's barLight): the words as
// one group (`navInk`), the bell on its own (`bellInk`), each pill with the glyph halo while its ink's art is busy;
// the current and the focused pill keep their own text colours (`onPrimary`, `text`): they are surfaces of their own.
FocusScope {
    id: nav

    property real u: 1
    // Keys only: labels follow the language. The last two are icons: the Settings gear and the bell.
    property var keys: ["home", "games", "media", "store", "settings", "notifications"]
    property string section: "home"      // the section on screen
    property int currentIndex: 0         // the pill that has (or last had) focus
    // The bell is the last key. Its own glass pill lies at `bellX` (the pill's left edge in this item's coordinates; Shell
    // puts it left of the status tray, the one place that decides it), so `width` is the words' pill only.
    readonly property string bellKey: "notifications"
    readonly property var wordKeys: keys.filter(k => k !== bellKey)
    property real bellX: 0
    readonly property real bellWidth: implicitHeight
    property Item blurSource
    property real blurX: 0               // position of this item in `blurSource` coordinates
    property real blurY: 0
    // What lies behind the top bar (Shell's barLight), for the inks of the pills at rest.
    property TopBarLight light: null
    // The bell's badge and glyph (NotificationCentre): the unread count, and whether quiet mode is on.
    property int notificationCount: 0
    property bool quiet: false

    readonly property string currentKey: keys[currentIndex]
    readonly property Item bellPill: bellRepeater.count === 1 ? bellRepeater.itemAt(0) : null
    readonly property string badgeText: notificationCount > 9 ? "9+" : String(notificationCount)

    signal activated(string key)
    signal downRequested()
    signal stepRequested(int direction)
    signal backRequested()
    // Right at the last pill, the bell (Left at the first under a mirrored layout): the status tray is there (T-301).
    signal edgeRequested()

    function label(key) {
        switch (key) {
        case "home": return qsTr("Home")
        case "games": return qsTr("Games")
        case "media": return qsTr("Media")
        case "store": return qsTr("Store")
        case "settings": return qsTr("Settings")
        case "notifications": return qsTr("Notifications")
        }
        return key
    }
    // What a screen reader says for a pill: its label; the bell adds the unread count and quiet mode.
    function accessibleLabel(key) {
        if (key !== "notifications")
            return label(key)
        return quiet ? qsTr("Notifications, %n unread, quiet mode on", "", notificationCount)
                     : qsTr("Notifications, %n unread", "", notificationCount)
    }
    // The glyph of an icon pill, "" for a word pill.
    function iconOf(key) {
        if (key === "settings")
            return "settings"
        if (key === "notifications")
            return quiet ? "notifications_paused" : "notifications"
        return ""
    }

    // The pill of a key (the words' Row or the bell), or null while it is not built.
    function pillOf(key) {
        return key === bellKey ? bellPill : (repeater.count === wordKeys.length ? repeater.itemAt(wordKeys.indexOf(key)) : null)
    }
    // An item's offset in this item, through every parent's x and y (a binding on it follows each of them).
    function offsetOf(item) {
        let x = 0
        let y = 0
        for (let i = item; i && i !== nav; i = i.parent) {
            x += i.x
            y += i.y
        }
        return Qt.point(x, y)
    }

    implicitWidth: pills.width + 2 * Theme.spaceXs * u
    implicitHeight: Theme.buttonHeight * u + 2 * Theme.spaceXs * u
    width: implicitWidth
    height: implicitHeight

    Accessible.role: Accessible.PageTabList
    // The nav holds focus, not its pills: the name follows the current pill.
    Accessible.name: accessibleLabel(currentKey)

    GlassPill {
        objectName: "sectionNavGlass"
        anchors.fill: parent
        u: nav.u
        source: nav.blurSource
        sourceX: nav.blurX
        sourceY: nav.blurY
    }

    // The bell's own glass pill: icon-only, the nav pill's height, at the left of the tray (RUY-1170).
    GlassPill {
        id: bellGlass
        objectName: "bellGlass"
        x: nav.bellX
        width: nav.bellWidth
        height: nav.height
        u: nav.u
        source: nav.blurSource
        sourceX: nav.blurX + nav.bellX
        sourceY: nav.blurY
    }

    // One highlight glides to the focused pill (04 §3.8, T-205). It is a picture under the pills:
    // focus, keys and names stay on the nav and the pills, and each pill keeps its own ring. When
    // the highlight is not drawn (the nav has no focus) a pill shows its own focus fill.
    FocusGlide {
        id: glide
        objectName: "navGlide"
        u: nav.u
        target: nav.currentKey === nav.bellKey ? null : nav.pillOf(nav.currentKey)
        shown: nav.activeFocus && nav.currentKey !== nav.bellKey
    }
    // The bell's own: it glides on its own pill, never across the bar to it.
    FocusGlide {
        id: bellGlide
        objectName: "bellGlide"
        u: nav.u
        target: nav.bellPill
        shown: nav.activeFocus && nav.currentKey === nav.bellKey
    }

    // The words: the pills of the nav's glass, measured as one item of the bar.
    Item {
        id: words
        x: pills.x
        y: pills.y
        width: pills.width
        height: pills.height
    }
    TopBarInk {
        id: navInk
        objectName: "navInk"
        light: nav.light
        under: words
        onGlass: true
    }
    TopBarInk {
        id: bellInk
        objectName: "bellInk"
        light: nav.light
        under: nav.bellPill
        onGlass: true
    }

    // The pills' fills and rings, each under its pill of `pills` (which owns the geometry), so the halo of the words
    // and glyphs (on each pill's own layer) never draws around a pill.
    Repeater {
        id: fills
        model: nav.keys

        delegate: Item {
            id: under

            required property int index
            required property string modelData
            readonly property Item pill: nav.pillOf(modelData)
            readonly property FocusGlide glideOf: modelData === nav.bellKey ? bellGlide : glide
            readonly property bool isSection: modelData === nav.section
            readonly property bool focused: nav.activeFocus && modelData === nav.currentKey

            x: pill ? nav.offsetOf(pill).x : 0
            y: pill ? nav.offsetOf(pill).y : 0
            width: pill ? pill.width : 0
            height: pill ? pill.height : 0

            Rectangle {
                objectName: "navPillFill_" + under.modelData
                anchors.fill: parent
                radius: height / 2
                color: under.isSection ? Theme.primaryFill : (under.focused && !under.glideOf.active ? Theme.focusFill : "transparent")
                border.width: under.focused && !under.isSection ? Theme.focusRingWidth * nav.u : 0
                border.color: Theme.focusRing
            }
            // The current pill is white, so its ring sits outside with a gap (PrimaryButton).
            Rectangle {
                objectName: "navPillRing_" + under.modelData
                anchors.fill: parent
                anchors.margins: -Theme.focusRingOffset * nav.u
                radius: height / 2
                color: "transparent"
                border.width: Theme.focusRingWidth * nav.u
                border.color: Theme.focusRing
                visible: under.focused && under.isSection
            }
        }
    }

    // The words and glyphs, each pill its own layer for the glyph halo (busy art under its ink, 04 §5.5).
    Row {
        id: pills
        objectName: "navPills"
        anchors.centerIn: parent
        spacing: Theme.spaceXxs * nav.u

        Repeater {
            id: repeater
            model: nav.wordKeys
            delegate: pillDelegate
        }
    }

    // The bell's pill, inside its glass (padded as the nav's pills are).
    Item {
        x: nav.bellX + Theme.spaceXs * nav.u
        y: Theme.spaceXs * nav.u
        width: nav.bellWidth - 2 * Theme.spaceXs * nav.u
        height: Theme.buttonHeight * nav.u
        Repeater {
            id: bellRepeater
            model: [nav.bellKey]
            delegate: pillDelegate
        }
    }

    Component {
        id: pillDelegate

        Item {
            id: pill

            required property string modelData
            readonly property bool isSection: modelData === nav.section
            readonly property bool focused: nav.activeFocus && modelData === nav.currentKey
            readonly property string icon: nav.iconOf(modelData)
            // At rest the ink of the art behind it (the bell's own, the words' group); on its own surface (current
            // or focused) that surface's text colour, without the halo.
            readonly property TopBarInk rest: modelData === "notifications" ? bellInk : navInk
            readonly property bool atRest: !isSection && !focused
            readonly property color ink: isSection ? Theme.onPrimary : focused ? Theme.text : rest.color
            layer.enabled: atRest && rest.halo
            layer.effect: GlyphHalo {
                u: nav.u
                haloColor: pill.rest.haloColor
            }

            objectName: "navPill_" + modelData
            width: Math.max(height, text.implicitWidth + 2 * Theme.spaceL * nav.u)
            height: Theme.buttonHeight * nav.u

            Accessible.role: Accessible.PageTab
            Accessible.name: nav.accessibleLabel(modelData)
            Accessible.selected: isSection

            Text {
                id: text
                objectName: "navLabel_" + pill.modelData
                anchors.centerIn: parent
                text: pill.icon !== "" ? "" : nav.label(pill.modelData)
                color: pill.ink
                font.pixelSize: Theme.typeBody * nav.u
                font.weight: pill.isSection ? Theme.weightDemiBold : Theme.weightRegular
            }
            // The icon pills (the Settings gear, the bell): filled while their section is on screen (the bell also
            // while quiet mode is on); their name is the accessible name of the pill.
            Icon {
                objectName: "navIcon_" + pill.modelData
                anchors.centerIn: parent
                visible: pill.icon !== ""
                name: pill.icon
                u: nav.u
                filled: pill.isSection || (pill.modelData === "notifications" && nav.quiet)
                color: pill.ink
            }
        }
    }

    // The bell's unread count (RUY-413): a 32 u pill over the bell pill's top right corner (three quarters of its width
    // inside the pill, a quarter of its height above it), `typeMicro` DemiBold `onPrimary` on `primaryFill`, "9+" above
    // nine, none at 0; its outline in the bar's ink keeps it apart from the art. Above the words' layer, outside its halo.
    Rectangle {
        id: badge
        objectName: "bellBadge"
        readonly property Item bell: nav.bellPill
        visible: bell !== null && nav.notificationCount > 0
        height: 32 * nav.u // token-ok: the badge's size, 04 §5 "Bell"
        width: Math.max(height, badgeLabel.implicitWidth + 2 * Theme.spaceXs * nav.u)
        radius: height / 2
        x: bell ? nav.offsetOf(bell).x + bell.width - width * 0.75 : 0
        y: bell ? nav.offsetOf(bell).y - height * 0.25 : 0
        color: Theme.primaryFill
        border.width: Theme.hairlineAt(nav.u)
        border.color: bellInk.color
        Text {
            id: badgeLabel
            objectName: "bellBadgeText"
            anchors.centerIn: parent
            text: nav.badgeText
            color: Theme.onPrimary
            font.pixelSize: Theme.typeMicro * nav.u
            font.weight: Theme.weightDemiBold
        }
    }

    onCurrentIndexChanged: if (activeFocus) Sfx.navigate()

    Keys.onPressed: event => {
        // Left/Right are visual: under a mirrored layout Left is the next pill.
        const step = nav.LayoutMirroring.enabled ? -1 : 1
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            const next = currentIndex + (event.key === Qt.Key_Right ? step : -step)
            if (next >= 0 && next < keys.length)
                currentIndex = next
            else if (next >= keys.length && !nav.LayoutMirroring.enabled)
                nav.edgeRequested()
            event.accepted = true
        } else if (event.key === Qt.Key_Down) {
            nav.downRequested()
            event.accepted = true
        } else if (event.key === Qt.Key_Up) {
            event.accepted = true          // the top of the screen
        } else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
            nav.stepRequested(event.key === Qt.Key_PageDown ? 1 : -1)
            event.accepted = true
        } else if (BackKey.isBackOrBackspace(event.key)) {
            nav.backRequested()
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            Sfx.select()
            nav.activated(currentKey)
            event.accepted = true
        }
    }
}
