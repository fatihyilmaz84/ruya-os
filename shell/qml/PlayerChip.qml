import QtQuick
import RuyaShell

// A player's round avatar with their seat number (04 §5 "Player chip", RUY-629): the status cluster
// (player 1 and the others) and the Hub's players row. Never focusable. `profileId` is a profile or a
// temporary guest; the name and colour follow Profiles. The number dot (28 u, `primaryFill`) overhangs
// the circle by 6 u at the bottom right; it shows only while `showNumber` (two or more players). A held
// seat draws the avatar at half opacity and a `schedule` glyph in the dot instead of the digit. `ring` outlines the
// circle (a hairline): the status tray draws it in its adaptive ink (RUY-1136, 04 §5.5), so the avatar stays apart
// from the art behind it; none elsewhere.
Item {
    id: chip

    property string profileId
    property int slot: 1
    property bool showNumber: false
    // The player's pad is gone and the seat is held for it (RUY-627, `held` of Input.players): the avatar is
    // dimmed and the dot shows a waiting glyph in place of the number.
    property bool held: false
    property real u: 1
    property color ring: "transparent"

    readonly property var guest: {
        const guests = Profiles.guests
        for (let i = 0; i < guests.length; ++i) {
            if (guests[i].id === chip.profileId)
                return guests[i]
        }
        return null
    }
    // The profile's own record; read through `Profiles.profiles` so the chip follows a rename.
    readonly property var record: {
        const list = Profiles.profiles
        for (let i = 0; i < list.length; ++i) {
            if (list[i].id === chip.profileId)
                return list[i]
        }
        return null
    }
    readonly property string displayName: record ? record.name
                                          : guest ? (guest.number <= 1 ? qsTr("Guest") : qsTr("Guest %1").arg(guest.number))
                                          : Profiles.nameOf(chip.profileId)
    readonly property color tint: record ? record.avatar : guest ? guest.avatar : Theme.glass

    width: Theme.statusAvatarSize * u
    height: width

    Accessible.role: Accessible.StaticText
    Accessible.name: held ? qsTr("%1, player %2, held").arg(displayName).arg(slot)
                          : qsTr("%1, player %2").arg(displayName).arg(slot)

    Rectangle {
        id: circle
        objectName: "playerAvatar"
        anchors.fill: parent
        radius: width / 2
        color: chip.tint
        border.width: chip.ring.a > 0 ? Theme.hairlineAt(chip.u) : 0
        border.color: chip.ring
        opacity: chip.held ? 0.5 : 1.0 // token-ok: component-local, 04 §5
        Text {
            anchors.centerIn: parent
            // Clear of the number dot: up and left by its overhang while the dot shows.
            anchors.horizontalCenterOffset: chip.showNumber ? -6 * chip.u : 0 // token-ok: component-local, 04 §5
            anchors.verticalCenterOffset: chip.showNumber ? -6 * chip.u : 0 // token-ok: component-local, 04 §5
            textFormat: Text.PlainText
            text: CapsText.initial(chip.displayName || "?")
            color: Theme.text
            font.pixelSize: Theme.typeCaption * chip.u
            font.weight: Theme.weightLight
        }
    }

    Rectangle {
        id: dot
        objectName: "playerDot"
        visible: chip.showNumber
        width: 28 * chip.u // token-ok: component-local, 04 §5
        height: width
        radius: width / 2
        // Its right and bottom edges are 6 u outside the circle's.
        x: circle.width - width + 6 * chip.u // token-ok: component-local, 04 §5
        y: circle.height - height + 6 * chip.u // token-ok: component-local, 04 §5
        color: Theme.primaryFill
        Icon {
            objectName: "playerHeldGlyph"
            anchors.centerIn: parent
            visible: chip.held
            u: chip.u
            size: Theme.typeMicro
            name: "schedule"
            color: Theme.onPrimary
        }
        Text {
            objectName: "playerDigit"
            anchors.centerIn: parent
            visible: !chip.held
            text: chip.slot
            color: Theme.onPrimary
            font.pixelSize: Theme.typeMicro * chip.u
            font.weight: Theme.weightBold
        }
    }
}
