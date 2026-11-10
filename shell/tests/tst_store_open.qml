import QtQuick
import QtTest
import RuyaShell

// T-377: opening the Store is cheap with a real remote's catalogue. Only the rows on screen get
// cards at open (a row below the fold builds them when it takes focus, then keeps them), the
// hidden search grid builds none, the rows built before the service answers the page's filter are
// the ones the answer brings (not built a second time), and the cards look their records up in the
// Store's index instead of reading the whole catalogue. Counts objects and reads, never time.
// Signs in as "Ada" (p2, no PIN).
Item {
    id: host
    width: 1280
    height: 720

    Component {
        id: shellComponent
        Shell { anchors.fill: parent; version: "test"; focus: true }
    }

    TestCase {
        id: tc
        name: "StoreOpen"
        when: windowShown

        property Shell shell: null

        function find(name) { return findChild(tc.shell, name) }

        function init() {
            verify(windowGuard.ensureActive() === "", windowGuard.ensureActive())
            Store.mockReset()
            Store.controllerFilter = "any"
            Profiles.lock()
            tryCompare(Profiles, "activeProfile", "")
            tc.shell = createTemporaryObject(shellComponent, host)
            verify(tc.shell)
            tc.shell.forceActiveFocus()
            tryVerify(() => Profiles.profiles.length === 3)
            tryVerify(() => find("profileList").activeFocus, 2000, "picker has focus on start")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Return)
            tryCompare(Profiles, "activeProfile", "p2")
            tryVerify(() => find("homePlay").activeFocus, 2000, "Play takes focus after sign-in")
        }

        function cleanup() {
            // mockReset drops the added apps from the mock; the catalogue the Store holds follows
            // once it is announced as changed.
            Store.mockReset()
            Store.mockCatalogChanged()
            tryVerify(() => Store.mockPendingReplies() === 0 && Store.app("org.example.Many0").id === undefined, 2000)
        }

        // A catalogue the size of a real remote's: 1000 more apps, one in five with full controller support.
        function addManyApps() {
            Store.mockAddApps(1000)
            tryVerify(() => Store.app("org.example.Many999").id === "org.example.Many999", 2000)
            tryVerify(() => Store.mockPendingReplies() === 0, 2000)
        }

        function pressStore() {
            keyClick(Qt.Key_Up)                          // the section nav
            for (let i = 0; i < 3; ++i)
                keyClick(Qt.Key_Right)
            compare(find("sectionNav").currentKey, "store")
            keyClick(Qt.Key_Return)
            tryCompare(tc.shell, "currentPage", "store")
        }

        function openStore() {
            pressStore()
            tryVerify(() => find("storeCards_featured") && find("storeCards_featured").activeFocus, 2000,
                      "first card of Featured has focus")
        }

        function test_only_the_rows_on_screen_have_cards() {
            addManyApps()
            openStore()
            const flick = find("storeRows")
            for (const key of ["featured", "games"])
                verify(find("storeCards_" + key).count > 0, key + " is on screen and has cards")
            for (const key of ["apps", "installed"]) {
                const row = find("storeRow_" + key)
                verify(row.visible && row.ids.length > 0, key + " has apps")
                verify(row.mapToItem(flick, 0, 0).y >= flick.height, key + " starts below the fold")
                compare(find("storeCards_" + key).count, 0, key + " has no cards before it shows")
            }
            compare(find("storeResults").count, 0, "the hidden search grid builds no cards")

            keyClick(Qt.Key_Down)
            verify(find("storeCards_games").activeFocus, "Down: Games")
            keyClick(Qt.Key_Down)
            const apps = find("storeCards_apps")
            verify(apps.activeFocus, "Down: Apps & media")
            verify(apps.count > 0, "the row builds its cards when it takes focus")
            tryVerify(() => apps.currentItem !== null && apps.currentItem.focused, 2000, "its first card shows the focus")
            compare(apps.model[apps.currentIndex], find("storeRow_apps").ids[0])
            keyClick(Qt.Key_Down)
            const installed = find("storeCards_installed")
            verify(installed.activeFocus, "Down: Installed")
            verify(installed.count > 0)
            keyClick(Qt.Key_Up)
            verify(apps.activeFocus, "Up: Apps & media again")
            verify(apps.count > 0, "a row keeps its cards")
            keyClick(Qt.Key_Up)
            keyClick(Qt.Key_Up)
            verify(find("storeCards_featured").activeFocus, "Up twice: Featured")
        }

        function test_a_search_builds_the_result_cards() {
            openStore()
            compare(find("storeResults").count, 0)
            keyClick(Qt.Key_Up)
            verify(find("storeSearch").activeFocus)
            find("page_store").beginSearch("racer")
            tryVerify(() => find("storeResults").visible && find("storeResults").count === 2, 2000, "Turbo Racer, Racer Beta")
            tryVerify(() => find("storeResults").activeFocus, 2000, "the results take focus")
            keyClick(Qt.Key_Escape)
            tryVerify(() => find("storeCards_featured").activeFocus, 2000, "Back leaves the search to the rows")
            compare(find("storeResults").count, 0, "the grid lets its cards go with the search")
        }

        function test_rows_are_not_built_again_when_the_filter_answer_arrives() {
            addManyApps()
            Store.mockSearchReplyDelay(400)
            pressStore()
            // The page set the "gamepad" filter; the results it holds are still those of "any".
            const featured = find("storeCards_featured")
            const games = find("storeCards_games")
            tryVerify(() => featured.count > 0 && games.count > 0, 2000, "cards in the first frames")
            verify(Store.mockPendingReplies() > 0, "the service has not answered the filter yet")
            const before = {}
            for (const key of ["featured", "games", "apps", "installed"])
                before[key] = find("storeRow_" + key).ids.slice()
            verify(before.apps.indexOf("org.example.Browser") < 0, "no app without controller support in the rows")
            verify(before.apps.indexOf("org.example.Chess") >= 0, "a partial one is")
            const firstFeatured = featured.itemAtIndex(0)
            const firstGame = games.itemAtIndex(0)
            verify(firstFeatured !== null && firstGame !== null)

            tryVerify(() => Store.mockPendingReplies() === 0, 3000, "the answer arrived")
            tryVerify(() => featured.activeFocus, 2000, "first card of Featured has focus")
            for (const key of ["featured", "games", "apps", "installed"])
                compare(find("storeRow_" + key).ids, before[key], key + ": the answer brought the same apps")
            verify(featured.itemAtIndex(0) === firstFeatured, "Featured kept its cards")
            verify(games.itemAtIndex(0) === firstGame, "Games kept its cards")
        }

        function test_cards_look_their_record_up_and_follow_the_catalogue() {
            const reads = Store.mockCatalogueReads()
            openStore()
            compare(Store.mockCatalogueReads(), reads, "opening the Store reads no whole catalogue")
            const card = find("appCard_org.example.Racer")
            verify(card !== null)
            compare(card.app.name, "Turbo Racer")
            compare(card.Accessible.name, "Turbo Racer")
            Store.mockSetAppText("org.example.Racer", "Turbo Racer Deluxe", "Faster.", "Example Games")
            tryVerify(() => card.app.name === "Turbo Racer Deluxe", 2000, "the card took the new record")
            compare(card.Accessible.name, "Turbo Racer Deluxe")
            verify(find("storeCards_featured").activeFocus, "the focus stays on the card")
        }

        // How many items with this objectName hang below `item` (visual children, also those a Loader made).
        function countNamed(item, name) {
            let n = item.objectName === name ? 1 : 0
            const kids = item.contentItem ? [item.contentItem] : item.children
            for (let i = 0; i < kids.length; ++i)
                n += countNamed(kids[i], name)
            return n
        }

        // T-428: of the forty cards one has focus, and only that one holds a halo and a glare effect.
        function test_halo_and_glare_exist_only_on_the_focused_card() {
            openStore()
            const flick = find("storeRows")
            const featured = find("storeCards_featured")
            const first = featured.currentItem
            tryCompare(findChild(first, "cardLiftShadow"), "haloShown", true)
            tryVerify(() => countNamed(flick, "haloEffect") === 1, 2000)
            compare(countNamed(flick, "haloEffect"), 1, "one halo on the page")
            compare(countNamed(flick, "glareEffect"), 1, "one glare on the page")
            verify(findChild(first, "haloEffect") !== null, "on the focused card")
            verify(findChild(first, "glareEffect") !== null)
            verify(featured.count > 1)

            keyClick(Qt.Key_Right)
            const second = featured.currentItem
            verify(second !== first)
            tryVerify(() => findChild(second, "haloEffect") !== null, 2000, "the halo moved to the new card")
            verify(findChild(second, "glareEffect") !== null)
            tryVerify(() => findChild(first, "haloEffect") === null, 2000, "and left the old one after its fade")
            compare(findChild(first, "glareEffect"), null)
            tryVerify(() => countNamed(flick, "haloEffect") === 1)
            compare(countNamed(flick, "glareEffect"), 1)
            verify(findChild(second, "cardLiftShadow").shown, "the lift shadow still fades in with the focus")
            verify(findChild(first, "cardLiftShadow") !== null)
            compare(findChild(first, "cardLiftShadow").shown, false)
        }

        // T-428: slotY is set on the rows whose place moved, and on no other.
        function test_a_row_place_is_set_only_when_it_moves() {
            openStore()
            const page = find("page_store")
            const h = page.rowHeight
            const places = () => ["featured", "games", "apps", "installed"].map(k => Math.round(find("storeRow_" + k).slotY / h))
            tryVerify(() => places().join() === "0,1,2,3")
            const before = page.slotUpdates
            page.rebuildRows()
            compare(page.slotUpdates, before, "the same rows: no place is set again")
            const full = page.rowIds
            page.rowIds = Object.assign({}, full, { games: [] })
            page.updateSlots()
            compare(places().join(), "0,1,1,2")
            compare(page.slotUpdates, before + 2, "only the two rows below Games moved")
            page.rebuildRows()
            compare(places().join(), "0,1,2,3")
            compare(page.slotUpdates, before + 4, "and only they moved back")
        }

        // T-428 round 2: the places follow the UI size; a row that the new size brings into view builds its cards.
        function test_row_places_follow_the_ui_size() {
            openStore()
            const page = find("page_store")
            const apps = find("storeRow_apps")
            const flick = find("storeRows")
            const places = () => ["featured", "games", "apps", "installed"].map(k => Math.round(find("storeRow_" + k).slotY))
            const expected = () => [0, 1, 2, 3].map(n => Math.round(n * page.rowHeight))
            compare(places().join(), expected().join(), "the places fit the size the page opened at")
            verify(apps.slotY >= flick.height, "Apps & media starts below the fold")
            compare(find("storeCards_apps").count, 0)
            page.u = page.u * 0.5
            compare(places().join(), expected().join(), "smaller: the places follow")
            verify(apps.slotY < flick.height, "Apps & media is in view now")
            tryVerify(() => find("storeCards_apps").count > 0, 2000, "and builds its cards")
            page.u = page.u * 4
            compare(places().join(), expected().join(), "larger: the places follow")
        }

        // T-428: a row remembers its card while it has no cards to hold it.
        function test_a_row_that_was_emptied_returns_on_the_card_it_left() {
            addManyApps()
            openStore()
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            const cards = find("storeCards_apps")
            verify(cards.activeFocus, "Apps & media")
            keyClick(Qt.Key_Right)
            keyClick(Qt.Key_Right)
            compare(cards.currentIndex, 2)
            const page = find("page_store")
            const row = find("storeRow_apps")
            page.rowIds = Object.assign({}, page.rowIds, { apps: [] })
            row.refresh()
            verify(!row.visible, "the row vanishes while it has no apps")
            compare(cards.count, 0)
            compare(row.pendingIndex, 2, "it remembers the card")
            page.rebuildRows()
            verify(row.visible)
            tryVerify(() => cards.count > 3)
            compare(cards.currentIndex, 2, "its cards came back on the card it left")
            compare(row.pendingIndex, -1)
            row.forceActiveFocus()
            tryVerify(() => cards.currentItem !== null && cards.currentItem.focused, 2000, "the card shows the focus")
            compare(cards.currentIndex, 2)
        }

        function test_a_row_built_late_lands_on_its_remembered_card() {
            openStore()
            const row = find("storeRow_installed")
            const cards = find("storeCards_installed")
            compare(cards.count, 0, "Installed is below the fold: no cards yet")
            row.pendingIndex = 1
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            keyClick(Qt.Key_Down)
            verify(cards.activeFocus, "Down x3: Installed")
            tryCompare(cards, "currentIndex", 1)
            tryVerify(() => cards.currentItem !== null && cards.currentItem.focused, 2000)
            compare(cards.currentIndex, 1)
            tryCompare(row, "pendingIndex", -1)
        }
    }
}
