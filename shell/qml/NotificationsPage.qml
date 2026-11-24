import QtQuick
import RuyaShell

// The bell's section (RUY-1136, 02 §1 System UI, 04 §5.5): the last key of the section nav opens the notification
// centre as a page (the standard Page, PATTERNS.md "How to add a page"), the same content as the Hub's sheet
// (NotificationCentreView): opening it marks everything read and puts the focus on the first row, or on Quiet mode
// when the list is empty (its empty state below). Up from the top stop goes to the nav, LB/RB step the section,
// Back goes Home as from any section. The list is the width of a full page's list (the Downloads page's, 04 §5.5),
// from the content's top. A picked action or an app to open goes to the Shell (`actionRequested`, `appRequested`).
Page {
    id: page

    signal actionRequested(var item, string action)
    signal appRequested(var item)       // A on a row without actions whose item has an app

    title: qsTr("Notifications")
    // Like every section page: the section switch after the centre's own (RUY-1159).
    hints: centre.hints.concat([{ actions: ["tabPrev", "tabNext"], text: qsTr("Sections") }])

    NotificationCentreView {
        id: centre
        objectName: "centreView"
        focus: true
        width: Math.min(parent.width, 1200 * page.u) // token-ok: a full page's list width, 04 §5.5 (Downloads page)
        height: parent.height
        u: page.u
        // Shown while it is the page on top and no app covers it: items that arrive then are new and seen.
        active: page.enabled
        showTitle: false
        opaque: false
        backText: qsTr("Back")
        onActionRequested: (item, action) => page.actionRequested(item, action)
        onOpenRequested: item => page.appRequested(item)
    }

    Component.onCompleted: centre.begin()
}
