import QtQuick
import QtTest
import RuyaShell

// AppName (RUY-854): what an installed app is called on the settings and game pages. A .play game is named by the title of
// its package (the Library's), any other app by the Store's installed name, and a binding follows both lists. Against the
// mocks: Block Puzzle is a Store app; Star Hopper is the .play game of the Library's "play" scenario, which the Store
// knows only by the last part of its id.
Item {
    id: host
    width: 320
    height: 240

    readonly property string hopper: "play.com.example.starhopper"
    property string hopperName: AppName.of(hopper)

    TestCase {
        id: tc
        name: "AppName"
        when: windowShown

        function init() {
            Store.mockReset()
            Library.resetMockForTests("")
            tryVerify(() => Store.installed.length === 3)
        }

        function cleanup() {
            Store.mockReset()
            Library.resetMockForTests("")
        }

        function test_a_store_app_is_named_by_the_store_and_an_unknown_app_by_nobody() {
            compare(AppName.of("org.example.Puzzle"), "Block Puzzle")
            compare(AppName.of("org.example.Nothing"), "")
            compare(AppName.of(""), "")
        }

        function test_a_play_game_is_named_by_its_package_title() {
            Library.resetMockForTests("play")
            tryVerify(() => Library.item("flatpak:" + host.hopper).play === true)
            Store.mockInstallOutside(host.hopper, "starhopper", ["network"])
            Store.refreshInstalled()
            tryVerify(() => Store.installed.some(a => a.id === host.hopper))
            compare(Store.installed.find(a => a.id === host.hopper).name, "starhopper", "the Store's own name for it")
            compare(AppName.of(host.hopper), "Star Hopper")
        }

        function test_a_play_game_the_library_does_not_list_keeps_the_stores_name() {
            Store.mockInstallOutside(host.hopper, "starhopper", ["network"])
            Store.refreshInstalled()
            tryVerify(() => Store.installed.some(a => a.id === host.hopper))
            compare(AppName.of(host.hopper), "starhopper")
        }

        function test_a_binding_follows_the_library_and_the_store() {
            Store.mockInstallOutside(host.hopper, "starhopper", ["network"])
            Store.refreshInstalled()
            tryCompare(host, "hopperName", "starhopper")
            Library.resetMockForTests("play")
            tryCompare(host, "hopperName", "Star Hopper")
            Library.resetMockForTests("")
            tryCompare(host, "hopperName", "starhopper")
            Store.mockReset()
            tryCompare(host, "hopperName", "")
        }
    }
}
