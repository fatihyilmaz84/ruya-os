pragma ComponentBehavior: Bound
import QtQuick
import RuyaShell

// The Theme row of Display & motion (T-209): a ChoiceRow whose value is preceded by three
// small chips drawn in the colours of the option shown: its ground, its glass over that
// ground, and its tint. The chips are the one place that reads a theme other than the active one.
ChoiceRow {
    id: row

    options: Themes.all.map(s => ({ value: s.key, label: s.label }))

    readonly property var shown: Themes.byKey(row.value)

    Row {
        objectName: "themeChips"
        anchors { right: row.valueText.left; rightMargin: Theme.spaceM * row.u; verticalCenter: parent.verticalCenter }
        spacing: Theme.spaceXs * row.u

        Repeater {
            model: [
                { name: "chipGround", color: row.shown.background },
                { name: "chipGlass", color: ThemeMath.over(row.shown.glass, row.shown.background) },
                { name: "chipTint", color: row.shown.defaultTint },
            ]
            delegate: Rectangle {
                id: chip
                required property var modelData
                objectName: modelData.name
                width: 32 * row.u
                height: width
                radius: width / 2
                color: modelData.color
                border.width: Theme.hairlineAt(row.u)
                border.color: Theme.glassBorder
            }
        }
    }
}
