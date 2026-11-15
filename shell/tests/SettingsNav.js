.pragma library

// Selects a Settings category by its key ("storage", "about", ...: the keys list in
// SettingsPage.qml) with the controller's Up/Down keys, so that adding a category never changes
// a test (RUY-640). `tc` is the test's TestCase (it has the shell, findChild, keyClick, compare);
// the category list must have focus. Fails the test, naming the key, when it is not listed.
function select(tc, key) {
    const list = tc.findChild(tc.shell, "categoryList")
    tc.tryVerify(() => list !== null && list.activeFocus, 2000, "category list has focus")
    const at = () => tc.findChild(tc.shell, "page_settings").categories.findIndex(c => c.key === key)
    tc.verify(at() >= 0, "the " + key + " category is listed")
    for (let i = 0; i < 30 && list.currentIndex < at(); ++i)
        tc.keyClick(Qt.Key_Down)
    for (let i = 0; i < 30 && list.currentIndex > at(); ++i)
        tc.keyClick(Qt.Key_Up)
    tc.compare(list.currentItem.objectName, "category_" + key, "the " + key + " category is selected")
}
