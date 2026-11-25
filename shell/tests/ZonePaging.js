.pragma library

// LB/RB (PageUp/PageDown) paging in a ZoneChooser list (RUY-671), shared by the wizard's chooser
// (tst_setup.qml) and Settings' picker (tst_timezone.qml). `tc` is the test's TestCase, `chooser` the
// ZoneChooser, `list` the focused list (regions or cities) and `count` a function giving its length
// (the cities change with the region). The page is the chooser's own visibleRows - 1, never a
// number of this file.

// True when the list's current row lies inside the part of the list that is shown.
function currentInView(list) {
    const item = list.currentItem
    return item !== null && item.y >= list.contentY - 1
           && item.y + item.height <= list.contentY + list.height + 1
}

// Walks `list` to its start and its end and back with the paging keys: each press moves by a page
// (or to the end it clamps at), the focus stays in the list, and the row is in view.
function checkPaging(tc, chooser, list, count, what) {
    const page = chooser.visibleRows - 1
    tc.verify(page >= 2, what + ": a page is more than one row")
    tc.verify(count() > 2 * page + 1, what + ": the list takes two whole pages (" + count() + " rows)")

    const press = (key, expected) => {
        tc.keyClick(key)
        tc.compare(list.currentIndex, expected, what + ": " + (key === Qt.Key_PageDown ? "PageDown" : "PageUp"))
        tc.verify(list.activeFocus, what + ": the focus stays in the list")
        tc.tryVerify(() => currentInView(list), 2000, what + ": row " + expected + " is in view")
    }
    const up = () => press(Qt.Key_PageUp, Math.max(0, list.currentIndex - page))
    const down = () => press(Qt.Key_PageDown, Math.min(count() - 1, list.currentIndex + page))
    const last = () => count() - 1

    for (let i = 0; i < count() && list.currentIndex > 0; ++i)
        up()
    tc.compare(list.currentIndex, 0, what + ": PageUp reaches the start")
    up()                                    // clamps: no wrap to the end

    let pages = 0
    for (let i = 0; i < count() && list.currentIndex < last(); ++i, ++pages)
        down()
    tc.compare(list.currentIndex, last(), what + ": PageDown reaches the end")
    tc.verify(pages >= 2, what + ": it took more than one page")
    down()                                  // clamps: no wrap to the start

    for (let i = 0; i < count() && list.currentIndex > 0; ++i)
        up()
    tc.compare(list.currentIndex, 0, what + ": and back to the start")
}

// PageUp/PageDown while the Search row has the focus change nothing: not the lists, not the focus.
function checkSearchIgnoresPaging(tc, search, regions, cities) {
    tc.verify(search.activeFocus, "Search has the focus")
    const region = regions.currentIndex
    const city = cities.currentIndex
    tc.keyClick(Qt.Key_PageDown)
    tc.keyClick(Qt.Key_PageUp)
    tc.keyClick(Qt.Key_PageDown)
    tc.compare(regions.currentIndex, region, "Search: the region did not move")
    tc.compare(cities.currentIndex, city, "Search: the city did not move")
    tc.verify(search.activeFocus, "Search keeps the focus")
}
