pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The permission rows (04 §5.4, RUY-802): the Store's "This app can" grid, extracted so the .play package
// page and its confirm sheet use the same rows. `entries` is [{ key, words, risk, reason }] (the Inspect
// record's `permissions`, `reason` the developer's own line for the key, optional).
//
//  - The words are the shell's own by key (PlayTrust.permissionWords); the service's `words` only for a key
//    the shell has none for. A caller with its own words (the Store) sets `shellWords: false`.
//  - `risk` "high": the Store's warning Badge "High risk" before the words, which turn `warningText`.
//  - `reason` is the developer's text: a second `typeCaption` line under the words in curly quotes, plain
//    text, elided, never translated.
//  - `always` puts the row every game has ("Plays sound, uses graphics") first.
//  - `maxRows` (0 = all) shows that many rows and "And %n more" under them (the confirm sheet).
//
// The row for a key is `permission_<key>`, its flag `riskFlag_<key>`, its reason `permissionReason_<key>`.
Column {
    id: list

    property real u: 1
    property var entries: []
    property bool always: false
    property bool shellWords: true
    property int maxRows: 0
    // Columns of the grid: the Store's page uses 2 (its rows are short), the package page 1.
    property int columns: 1
    // The row height without a reason (the Store's grid rows).
    readonly property real rowMin: 44 * u        // token-ok: the Store grid's row, 04 §5

    readonly property var allRows: always
        ? [{ key: "always", words: "", risk: "low", reason: "" }].concat(entries ?? []) : (entries ?? [])
    readonly property int shownCount: maxRows > 0 ? Math.min(maxRows, allRows.length) : allRows.length
    readonly property int hiddenCount: allRows.length - shownCount
    readonly property real cellWidth: (width - (columns - 1) * Theme.spaceM * u) / columns

    // The text a row reads as (the page's accessible value).
    readonly property string summary: allRows.slice(0, shownCount).map(e => list.wordsOf(e)).join(", ")

    function wordsOf(e) {
        return shellWords ? PlayTrust.permissionWords(e.key, e.words) : (e.words || e.key)
    }

    spacing: Theme.spaceXs * u

    Grid {
        id: grid
        columns: list.columns
        columnSpacing: Theme.spaceM * list.u
        rowSpacing: Theme.spaceXs * list.u

        Repeater {
            model: list.allRows.slice(0, list.shownCount)

            delegate: Row {
                id: perm

                required property var modelData
                readonly property bool risky: modelData.risk === "high"
                readonly property string reason: modelData.reason ?? ""

                objectName: "permission_" + modelData.key
                width: list.cellWidth
                height: Math.max(list.rowMin, text.implicitHeight + (reason !== "" ? Theme.spaceXxs * list.u + because.implicitHeight : 0))
                spacing: Theme.spaceS * list.u

                Badge {
                    objectName: "riskFlag_" + perm.modelData.key
                    visible: perm.risky
                    anchors.verticalCenter: parent.verticalCenter
                    u: list.u
                    kind: "warning"
                    text: qsTr("High risk")
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: perm.width - (perm.risky ? 120 * list.u + perm.spacing : 0)      // token-ok: the Store grid's flag column, 04 §5
                    spacing: Theme.spaceXxs * list.u

                    Text {
                        id: text
                        objectName: "permissionWords"
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText      // an id the service sent shows raw
                        text: list.wordsOf(perm.modelData)
                        color: perm.risky ? Theme.warningText : Theme.text
                        font.pixelSize: Theme.typeBody * list.u
                    }
                    Text {
                        id: because
                        objectName: "permissionReason_" + perm.modelData.key
                        visible: perm.reason !== ""
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText      // the developer's words, as they wrote them
                        text: "“" + perm.reason + "”"
                        color: Theme.text
                        font.pixelSize: Theme.typeCaption * list.u
                    }
                }
            }
        }
    }

    Text {
        objectName: "permissionMore"
        visible: list.hiddenCount > 0
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: qsTr("And %n more", "", list.hiddenCount)
        color: Theme.text
        font.pixelSize: Theme.typeCaption * list.u
    }
}
