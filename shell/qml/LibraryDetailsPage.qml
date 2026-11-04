import QtQuick
import RuyaShell

// Details of a library item, opened from the Home hero: a placeholder until the game page exists.
Page {
    id: page

    title: Library.item(params.id ?? "").title ?? qsTr("Details")

    hints: backOnlyHints     // nothing to select here

    ComingSoon { u: page.u }
}
