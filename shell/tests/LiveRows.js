.pragma library

// "This row is the same object, not rebuilt" (RUY-677, RUY-1189). find() and findChild() search the QObject tree,
// and a delegate that a rebuild removed stays in that tree until its deferred delete runs: `find(name) === held`
// is also true for a row that was rebuilt, and a `find()` taken after the rebuild returns the new delegate or the
// dying one, either way the one you wanted to compare. What the page shows now is the live children of the
// container the rows are in (their Column), so these helpers read that list.
//
//   const row = LiveRows.track(find("healthDrive_0"))        // BEFORE the action that could rebuild it
//   ... the action, then wait on a visible effect (tryCompare / tryVerify) ...
//   LiveRows.verifySame(tc, row, "a changed value keeps the row")
//
// A row that is only reached by the action itself (a key press whose answer is applied at once) cannot be held
// before it: mark the live delegate (a property nothing in the page sets, such as `z`) before the action and read
// the mark with children() afterwards (`test_next_page_on_end`). Never fix a test like this with a wait: the loop
// running does not tell the old delegate from the new one.

// The direct children of `parent` named `name`: the delegates the page shows now.
function children(parent, name) {
    const found = []
    const all = parent.children
    for (let i = 0; i < all.length; ++i) {
        if (all[i].objectName === name)
            found.push(all[i])
    }
    return found
}

// Remembers a live row and the container it is in, now: a removed delegate loses its parent.
function track(item) {
    return { item: item, parent: item.parent, name: item.objectName }
}

// Fails the test unless the container holds exactly the tracked item under that name.
function verifySame(tc, tracked, message) {
    const rows = children(tracked.parent, tracked.name)
    tc.compare(rows.length, 1, message + ": one row " + tracked.name + " in the list, not an old and a rebuilt one")
    tc.verify(rows[0] === tracked.item, message + ": " + tracked.name + " is the object it was, not a rebuilt one")
}
