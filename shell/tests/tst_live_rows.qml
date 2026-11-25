import QtQuick
import QtTest
import RuyaShell
import "LiveRows.js" as LiveRows

// LiveRows.js (RUY-1189): "this row is the object it was" read from the container's live children, because
// find()/findChild() also return a delegate that only waits for its deferred delete.
Item {
    width: 400
    height: 300

    ListModel { id: model }

    Column {
        id: column
        objectName: "rows"
        Repeater {
            model: model
            Text {
                required property string key
                required property string label
                objectName: "row_" + key
                text: label
            }
        }
    }

    TestCase {
        id: tc
        name: "LiveRows"
        when: windowShown

        function init() {
            model.clear()
            model.append({ key: "a", label: "A" })
            model.append({ key: "b", label: "B" })
        }

        function test_a_changed_value_keeps_the_row() {
            const a = LiveRows.track(findChild(column, "row_a"))
            verify(a.item !== null)
            model.set(0, { key: "a", label: "A2" })
            tryCompare(a.item, "text", "A2")
            compare(LiveRows.children(column, "row_a").length, 1)
            LiveRows.verifySame(tc, a, "a changed value")
        }

        // The rebuild leaves the old delegate in the QObject tree until the event loop runs: only the live
        // children tell it from the new one, in the same tick and after it.
        function test_a_rebuilt_row_is_not_the_tracked_one() {
            const a = LiveRows.track(findChild(column, "row_a"))
            const old = a.item
            model.clear()
            model.append({ key: "a", label: "A" })
            const live = LiveRows.children(column, "row_a")
            compare(live.length, 1, "one live row, not the old one and the new one")
            verify(live[0] !== old, "a new object")
            tryVerify(() => findChild(column, "row_a") === live[0], 2000, "find() agrees once the old one is destroyed")
            compare(LiveRows.children(column, "row_a").length, 1)
        }

        function test_children_lists_only_the_rows_with_that_name() {
            compare(LiveRows.children(column, "row_b").length, 1)
            compare(LiveRows.children(column, "row_c").length, 0)
        }
    }
}
