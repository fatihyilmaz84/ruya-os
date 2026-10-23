import QtQuick
import RuyaShell

// Base for every full-screen section opened from the home shelf: a title below the header,
// a content area inside the safe area, and Back handling. Content goes in as children and
// should contain one `focus: true` element, which receives focus when the page opens.
FocusScope {
    id: page

    property real u: 1
    property string title
    property string version      // image version, set by the shell
    property Item overlay        // full-screen layer above pages, for modals (PIN pad, keyboard)
    property var params: ({})    // plain object given to Shell.openPage(key, params)

    // Safe-area insets, set by the shell.
    property real marginX: 0
    property real marginY: 0

    default property alias content: contentArea.data

    signal backRequested()

    Text {
        id: heading
        x: page.marginX
        y: page.marginY + 110 * page.u
        text: page.title
        color: Theme.text
        font.pixelSize: 64 * page.u
        font.weight: Font.Light
    }

    Item {
        id: contentArea
        anchors {
            left: parent.left; leftMargin: page.marginX
            right: parent.right; rightMargin: page.marginX
            top: heading.bottom; topMargin: 40 * page.u
            bottom: parent.bottom; bottomMargin: page.marginY
        }
    }

    // Only Back is handled here; everything else bubbles up (the shell opens the Guide
    // overlay from any page).
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Back) {
            Sfx.back()
            page.backRequested()
            event.accepted = true
        }
    }
}
