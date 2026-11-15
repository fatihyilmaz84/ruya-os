import QtQuick
import RuyaShell

// A player's round avatar with their seat number (04 §5 "Player chip", RUY-629): the status cluster
// (player 1 and the others) and the Hub's players row. Never focusable. `profileId` is a profile or a
// temporary guest; the name and colour follow Profiles. The number dot (28 u, `primaryFill`) overhangs
// the circle by 6 u at the bottom right; it shows only while `showNumber` (two or more players).
Item {
    id: chip

    property string profileId
    property int slot: 1
    property bool showNumber: false
    property real u: 1

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
                                          : guest ? qsTr("Guest %1").arg(guest.number)
                                          : Profiles.nameOf(chip.profileId)
    readonly property color tint: record ? record.avatar : guest ? guest.avatar : Theme.glass

    width: Theme.statusAvatarSize * u
    height: width

    Accessible.role: Accessible.StaticText
    Accessible.name: qsTr("%1, player %2").arg(displayName).arg(slot)

    Rectangle {
        id: circle
        objectName: "playerAvatar"
        anchors.fill: parent
        radius: width / 2
        color: chip.tint
        Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: (chip.displayName || "?").charAt(0).toUpperCase()
            color: Theme.text
            font.pixelSize: Theme.typeCaption * chip.u
            font.weight: Theme.weightLight
        }
    }

    Rectangle {
        id: dot
        objectName: "playerDot"
        visible: chip.showNumber
        width: 28 * chip.u
        height: width
        radius: width / 2
        // Its right and bottom edges are 6 u outside the circle's.
        x: circle.width - width + 6 * chip.u
        y: circle.height - height + 6 * chip.u
        color: Theme.primaryFill
        Text {
            objectName: "playerDigit"
            anchors.centerIn: parent
            text: chip.slot
            color: Theme.onPrimary
            font.pixelSize: Theme.typeMicro * chip.u
            font.weight: Theme.weightBold
        }
    }
}
